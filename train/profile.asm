; profile <preset> [key=value ...]      e.g. bin\profile stretch
; where a training step's gpu time goes. builds the preset's model with random weights
; and tokens (nothing gets loaded or saved), warms up, then times one micro-batch's
; forward and backward and one optimizer step, kernel by kernel. the report is per
; step: micro-batch kernels count once per micro-batch, the optimizer once. matmuls
; are split up by shape. it needs the gpu to itself, so run it while training's stopped
; uses: gpu\cuda gpu\kernels model\model
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"
%include "model/model.inc"

extern ExitProcess

MAXK    equ 1024                ; report rows
; a report row: a kernel, and for matmuls its shape
AG_FN   equ 0
AG_M    equ 8
AG_N    equ 16
AG_K    equ 24
AG_FL   equ 32                  ; flags | split << 32
AG_MS   equ 40                  ; f64, per step
AG_CNT  equ 48                  ; calls per step
AG_FLOP equ 56                  ; f64 per call, 0 = no tflops for it
AG_SIZE equ 64

section .rdata
s_train  db "train\", 0
s_cfg    db ".cfg", 0
k_batch  db "batch", 0
e_usage  db "usage: profile <preset> [key=value ...]", 0
e_preset db "no such preset (looked for train\<name>.cfg)", 0
s_gemm   db "gemm_tc", 0
s_mmref  db "mm_ref", 0
s_ffwd   db "flash_fwd", 0
s_fdq    db "flash_dq", 0
s_fdkv   db "flash_dkv", 0
s_ta     db " tA", 0
s_tb     db " tB", 0
s_bf     db " bf", 0
s_split  db " split ", 0
s_x      db "x", 0
s_sp     db " ", 0
spaces   times 48 db ' '
align 8
opset    dq 1e-6, 0.9, 0.95, 1e-8, 0.1, 1.0     ; lr, betas, eps, wd, clip: tiny steps
c_2      dq 2.0
c_3      dq 3.0
c_4      dq 4.0
c_100    dq 100.0
c_1000   dq 1000.0
c_e9     dq 1e9
c_e12    dq 1e12

section .bss
alignb 8
cfgpath  resb 512
htok     resq 1
hsort    resq 1
mb       resb MB_SIZE
rng      resb RNG_SIZE
nmicro   resq 1
nfwd     resq 1                 ; launches in the forward
nbwd     resq 1                 ; ... up to the end of the backward
nall     resq 1
tfwd     resq 1                 ; f64 ms
tbwd     resq 1
topt     resq 1
unit     resq 1                 ; f64: B H T^2 HD, one causal T x T x HD matmul, all heads
; the key being looked up
kfn      resq 1
km       resq 1
kn       resq 1
kk       resq 1
kfl      resq 1
kflop    resq 1
nag      resq 1
ag       resb MAXK * AG_SIZE
order    resq MAXK
label    resb 256
numbuf   resb 64

section .text

global start
start:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    call lib_init
    xor ecx, ecx
    call pool_init
    cmp qword [argc], 2
    jae .args
    lea rcx, [e_usage]
    call print_z
    say 13, 10
    mov ecx, 1
    call ExitProcess
.args:
    lea rcx, [cfgpath]
    lea rdx, [s_train]
    call fmt_str
    mov rcx, rax
    mov rdx, [argv+8]
    call fmt_str
    mov rcx, rax
    lea rdx, [s_cfg]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [cfgpath]
    call cfg_load
    test eax, eax
    jnz .loaded
    lea rcx, [e_preset]
    call fatal
.loaded:
    call cfg_args
    call gpu_init
    call model_config
    mov dword [mdl_fast], 1
    mov ecx, 2
    call model_setup
    mov ecx, 1
    call model_init
    lea rcx, [k_batch]
    mov edx, 524288
    call cfg_int
    xor edx, edx
    div qword [mdl+MD_M]
    mov ecx, 1
    test rax, rax
    cmovz rax, rcx
    mov [nmicro], rax

    ; random tokens, sorted for the embedding backward like the loader does it
    mov r12, [mdl+MD_B]
    mov r13, [mdl+MD_T]
    mov r14, [mdl+MD_M]
    lea rbx, [r13+1]
    imul rbx, r12               ; tokens, with each row's extra one
    lea rcx, [rbx*2]
    call mem_alloc
    mov [htok], rax
    lea rcx, [rng]
    mov edx, 7
    call rng_seed
    xor esi, esi
.tok:
    lea rcx, [rng]
    call rng_next
    xor edx, edx
    div qword [mdl+MD_V]
    mov rax, [htok]
    mov [rax+rsi*2], dx
    inc rsi
    cmp rsi, rbx
    jb .tok
    lea rcx, [r14*3+1]
    shl rcx, 2
    call mem_alloc
    mov [hsort], rax
    mov rcx, [htok]
    mov rdx, r12
    mov r8, r13
    mov r9, [hsort]
    call model_sort
    mov [mb+MB_NU], rax
    lea rcx, [rbx*2]
    call gpu_alloc
    mov [mb+MB_TOK], rax
    mov rcx, rax
    mov rdx, [htok]
    lea r8, [rbx*2]
    call gpu_up
    lea rcx, [r14*3+1]
    shl rcx, 2
    call gpu_alloc
    mov [mb+MB_POS], rax
    lea rcx, [rax+r14*4]
    mov [mb+MB_UTOK], rcx
    lea rcx, [rax+r14*8]
    mov [mb+MB_UST], rcx
    mov rcx, rax
    mov rdx, [hsort]
    lea r8, [r14*3+1]
    shl r8, 2
    call gpu_up
    mov [mb+MB_B], r12
    mov [mb+MB_T], r13
    cvtsi2ss xmm0, r14
    mov eax, 0x3f800000
    movd xmm1, eax
    divss xmm1, xmm0
    movd [mb+MB_SCALE], xmm1
    mov dword [mb+MB_FLAGS], 0

    ; warm up: jit, caches, clocks
    call model_zero
    mov ebx, 3
.warm:
    lea rcx, [mb]
    mov edx, FW_GRAD
    call model_fwd
    lea rcx, [mb]
    call model_bwd
    dec ebx
    jnz .warm
    lea rcx, [opset]
    mov edx, 1
    call model_step
    call gpu_sync

    ; the real thing
    call model_zero
    call gpu_prof_begin
    lea rcx, [mb]
    mov edx, FW_GRAD
    call model_fwd
    mov rax, [prof_n]
    mov [nfwd], rax
    lea rcx, [mb]
    call model_bwd
    mov rax, [prof_n]
    mov [nbwd], rax
    lea rcx, [opset]
    mov edx, 2
    call model_step
    xor ecx, ecx
    call gpu_prof_end
    mov [nall], rax

    call tally
    call report
    xor ecx, ecx
    call ExitProcess

; rcx, rdx = zero-terminated strings. eax = 1 if they're the same
streq:
    mov al, [rcx]
    cmp al, [rdx]
    jne .no
    test al, al
    jz .yes
    inc rcx
    inc rdx
    jmp streq
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; the launches into report rows, and the per-part totals
tally:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    cvtsi2sd xmm0, qword [mdl+MD_B]
    cvtsi2sd xmm1, qword [mdl+MD_H]
    mulsd xmm0, xmm1
    cvtsi2sd xmm1, qword [mdl+MD_T]
    mulsd xmm0, xmm1
    mulsd xmm0, xmm1
    cvtsi2sd xmm1, qword [mdl+MD_HD]
    mulsd xmm0, xmm1
    movsd [unit], xmm0
    xor ebx, ebx
.l:
    cmp rbx, [nall]
    jae .done
    ; which part it's in
    lea rax, [prof_ms]
    cvtss2sd xmm0, [rax+rbx*4]
    lea rax, [topt]
    cmp rbx, [nbwd]
    jae .part
    lea rax, [tbwd]
    cmp rbx, [nfwd]
    jae .part
    lea rax, [tfwd]
.part:
    addsd xmm0, [rax]
    movsd [rax], xmm0
    ; the key: the kernel, plus the shape for a matmul
    lea rax, [prof_fn]
    mov r12, [rax+rbx*8]
    mov [kfn], r12
    xor eax, eax
    mov [km], rax
    mov [kn], rax
    mov [kk], rax
    mov [kfl], rax
    mov [kflop], rax
    mov rcx, r12
    call gpu_fname
    mov r13, rax
    mov rcx, r13
    lea rdx, [s_gemm]
    call streq
    test eax, eax
    jnz .mm
    mov rcx, r13
    lea rdx, [s_mmref]
    call streq
    test eax, eax
    jnz .mm
    ; flash kernels: fwd does 2 of the attention matmuls, dq 3 (s, dp, dq), dkv 4
    movsd xmm1, [c_2]
    mov rcx, r13
    lea rdx, [s_ffwd]
    call streq
    test eax, eax
    jnz .fl
    movsd xmm1, [c_3]
    mov rcx, r13
    lea rdx, [s_fdq]
    call streq
    test eax, eax
    jnz .fl
    movsd xmm1, [c_4]
    mov rcx, r13
    lea rdx, [s_fdkv]
    call streq
    test eax, eax
    jz .find
.fl:
    mulsd xmm1, [unit]
    movsd [kflop], xmm1
    jmp .find
.mm:
    mov rax, rbx
    shl rax, 5
    lea rcx, [prof_arg]
    add rcx, rax
    mov rax, [rcx]
    mov [km], rax
    mov rax, [rcx+8]
    mov [kn], rax
    mov rax, [rcx+16]
    mov [kk], rax
    mov rax, [rcx+24]
    mov [kfl], rax
    cvtsi2sd xmm1, qword [km]
    cvtsi2sd xmm2, qword [kn]
    mulsd xmm1, xmm2
    cvtsi2sd xmm2, qword [kk]
    mulsd xmm1, xmm2
    addsd xmm1, xmm1
    movsd [kflop], xmm1
.find:
    xor esi, esi
.f:
    cmp rsi, [nag]
    jae .new
    mov rdi, rsi
    imul rdi, AG_SIZE
    lea rax, [ag]
    add rdi, rax
    mov rax, [kfn]
    cmp [rdi+AG_FN], rax
    jne .fn
    mov rax, [km]
    cmp [rdi+AG_M], rax
    jne .fn
    mov rax, [kn]
    cmp [rdi+AG_N], rax
    jne .fn
    mov rax, [kk]
    cmp [rdi+AG_K], rax
    jne .fn
    mov rax, [kfl]
    cmp [rdi+AG_FL], rax
    je .got
.fn:
    inc rsi
    jmp .f
.new:
    cmp rsi, MAXK
    jae .next
    mov rdi, rsi
    imul rdi, AG_SIZE
    lea rax, [ag]
    add rdi, rax
    mov rax, [kfn]
    mov [rdi+AG_FN], rax
    mov rax, [km]
    mov [rdi+AG_M], rax
    mov rax, [kn]
    mov [rdi+AG_N], rax
    mov rax, [kk]
    mov [rdi+AG_K], rax
    mov rax, [kfl]
    mov [rdi+AG_FL], rax
    mov rax, [kflop]
    mov [rdi+AG_FLOP], rax
    xor eax, eax
    mov [rdi+AG_MS], rax
    mov [rdi+AG_CNT], rax
    inc qword [nag]
.got:
    ; micro-batch launches happen nmicro times a step
    mov eax, 1
    cmp rbx, [nbwd]
    cmovb rax, [nmicro]
    add [rdi+AG_CNT], rax
    cvtsi2sd xmm1, rax
    lea rax, [prof_ms]
    cvtss2sd xmm0, [rax+rbx*4]
    mulsd xmm0, xmm1
    addsd xmm0, [rdi+AG_MS]
    movsd [rdi+AG_MS], xmm0
.next:
    inc rbx
    jmp .l
.done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; xmm0 = value, edx = decimals, r8d = width. right-aligned
pnum:
    push rbx
    sub rsp, 96
    mov ebx, r8d
    movapd xmm1, xmm0
    mov r8d, edx
    lea rcx, [rsp+32]
    call fmt_fixed
    lea rcx, [rsp+32]
    sub rax, rcx
    mov [rsp+88], rax
    sub rbx, rax
    jle .p
    lea rcx, [spaces]
    mov rdx, rbx
    call print
.p:
    lea rcx, [rsp+32]
    mov rdx, [rsp+88]
    call print
    add rsp, 96
    pop rbx
    ret

; rcx = value, edx = width. right-aligned
pint:
    push rbx
    sub rsp, 96
    mov ebx, edx
    mov rdx, rcx
    lea rcx, [rsp+32]
    call fmt_dec
    lea rcx, [rsp+32]
    sub rax, rcx
    mov [rsp+88], rax
    sub rbx, rax
    jle .p
    lea rcx, [spaces]
    mov rdx, rbx
    call print
.p:
    lea rcx, [rsp+32]
    mov rdx, [rsp+88]
    call print
    add rsp, 96
    pop rbx
    ret

; rdi = report row. prints "name MxNxK tA tB bf split n", padded to 40
plabel:
    push rbx
    push rsi
    sub rsp, 40
    mov rcx, [rdi+AG_FN]
    call gpu_fname
    lea rcx, [label]
    mov rdx, rax
    call fmt_str
    mov rbx, rax
    cmp qword [rdi+AG_M], 0
    je .out
    mov rcx, rbx
    lea rdx, [s_sp]
    call fmt_str
    mov rcx, rax
    mov rdx, [rdi+AG_M]
    call fmt_dec
    mov rcx, rax
    lea rdx, [s_x]
    call fmt_str
    mov rcx, rax
    mov rdx, [rdi+AG_N]
    call fmt_dec
    mov rcx, rax
    lea rdx, [s_x]
    call fmt_str
    mov rcx, rax
    mov rdx, [rdi+AG_K]
    call fmt_dec
    mov rbx, rax
    mov rsi, [rdi+AG_FL]
%macro flag 2
    test esi, %1
    jz %%no
    mov rcx, rbx
    lea rdx, [%2]
    call fmt_str
    mov rbx, rax
%%no:
%endmacro
    flag MM_TA, s_ta
    flag MM_TB, s_tb
    flag MM_BF, s_bf
    shr rsi, 32
    cmp rsi, 1
    jbe .out
    mov rcx, rbx
    lea rdx, [s_split]
    call fmt_str
    mov rcx, rax
    mov rdx, rsi
    call fmt_dec
    mov rbx, rax
.out:
    lea rcx, [label]
    mov rdx, rbx
    sub rdx, rcx
    mov rsi, rdx
    call print
    mov edx, 40
    sub rdx, rsi
    jle .done
    lea rcx, [spaces]
    call print
.done:
    add rsp, 40
    pop rsi
    pop rbx
    ret

report:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    ; the model
    say "  "
    mov rcx, [argv+8]
    call print_z
    say ": "
    mov rcx, [mdl+MD_L]
    call print_dec
    say " layers, d "
    mov rcx, [mdl+MD_D]
    call print_dec
    say ", heads "
    mov rcx, [mdl+MD_H]
    call print_dec
    say "/"
    mov rcx, [mdl+MD_KVH]
    call print_dec
    say ", ffn "
    mov rcx, [mdl+MD_F]
    call print_dec
    say ", ctx "
    mov rcx, [mdl+MD_T]
    call print_dec
    say ", micro-batch "
    mov rcx, [mdl+MD_B]
    call print_dec
    say " x "
    mov rcx, [mdl+MD_T]
    call print_dec
    say 13, 10, "  per micro-batch: forward "
    movsd xmm0, [tfwd]
    mov edx, 1
    call print_fixed
    say " ms, backward "
    movsd xmm0, [tbwd]
    mov edx, 1
    call print_fixed
    say " ms. optimizer step "
    movsd xmm0, [topt]
    mov edx, 1
    call print_fixed
    say " ms", 13, 10
    ; a whole step: nmicro micro-batches and one optimizer step
    movsd xmm0, [tfwd]
    addsd xmm0, [tbwd]
    cvtsi2sd xmm1, qword [nmicro]
    mulsd xmm0, xmm1
    addsd xmm0, [topt]
    movsd [rsp+40], xmm0        ; ms per step
    say "  a step, "
    mov rcx, [nmicro]
    call print_dec
    say " micro-batches: "
    movsd xmm0, [rsp+40]
    divsd xmm0, [c_1000]
    mov edx, 2
    call print_fixed
    say " s, "
    mov rax, [nmicro]
    imul rax, [mdl+MD_M]
    cvtsi2sd xmm0, rax
    mulsd xmm0, [c_1000]
    divsd xmm0, [rsp+40]
    movsd [rsp+48], xmm0        ; tok/s
    mov edx, 0
    call print_fixed
    say " tok/s, "
    movsd xmm0, [rsp+48]
    mulsd xmm0, [mdl+MD_FLOPS]
    divsd xmm0, [c_e12]
    mov edx, 1
    call print_fixed
    say " TFLOPS", 13, 10, 13, 10

    ; rows, biggest first
    xor ecx, ecx
.o:
    cmp rcx, [nag]
    jae .sort
    lea rax, [order]
    mov [rax+rcx*8], rcx
    inc rcx
    jmp .o
.sort:
    xor ebx, ebx
.s1:
    mov rax, [nag]
    dec rax
    cmp rbx, rax
    jge .print
    mov rsi, rbx                ; the biggest from rbx on
    lea r12, [rbx+1]
.s2:
    cmp r12, [nag]
    jae .swap
    lea rax, [order]
    mov rcx, [rax+r12*8]
    imul rcx, AG_SIZE
    lea rdx, [ag]
    movsd xmm0, [rdx+rcx+AG_MS]
    mov rcx, [rax+rsi*8]
    imul rcx, AG_SIZE
    comisd xmm0, [rdx+rcx+AG_MS]
    jbe .s3
    mov rsi, r12
.s3:
    inc r12
    jmp .s2
.swap:
    lea rax, [order]
    mov rcx, [rax+rbx*8]
    mov rdx, [rax+rsi*8]
    mov [rax+rbx*8], rdx
    mov [rax+rsi*8], rcx
    inc rbx
    jmp .s1

.print:
    say "   ms/step      %  calls/step  kernel                                  TFLOPS", 13, 10
    xor ebx, ebx
.row:
    cmp rbx, [nag]
    jae .done
    lea rax, [order]
    mov rdi, [rax+rbx*8]
    imul rdi, AG_SIZE
    lea rax, [ag]
    add rdi, rax
    movsd xmm0, [rdi+AG_MS]
    mov edx, 1
    mov r8d, 10
    call pnum
    movsd xmm0, [rdi+AG_MS]
    mulsd xmm0, [c_100]
    divsd xmm0, [rsp+40]
    mov edx, 1
    mov r8d, 7
    call pnum
    mov rcx, [rdi+AG_CNT]
    mov edx, 11
    call pint
    say "  "
    call plabel
    movsd xmm0, [rdi+AG_FLOP]
    xorpd xmm1, xmm1
    comisd xmm0, xmm1
    jbe .eol
    cvtsi2sd xmm1, qword [rdi+AG_CNT]
    mulsd xmm0, xmm1
    divsd xmm0, [rdi+AG_MS]
    divsd xmm0, [c_e9]
    mov edx, 1
    mov r8d, 6
    call pnum
.eol:
    say 13, 10
    inc rbx
    jmp .row
.done:
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
