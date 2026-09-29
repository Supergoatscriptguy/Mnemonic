; stage 8 test: cpu inference.
;  - int8 and int4 matrix x vector on every dot product path the cpu has: the
;    same bits on all of them, and the exact integer math done in f64 agrees
;  - exp8 against the x87's exp
;  - the whole forward pass on the cpu (f32 weights, one token at a time through
;    the kv cache) against the gpu's forward pass, on a small random model
; uses: gpu\cuda gpu\kernels model\model chat\quant chat\kernels chat\engine
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"
%include "model/model.inc"
%include "chat/model.inc"
%include "test/check.inc"

R   equ 256                     ; test matrix
C   equ 768
TT  equ 64                      ; the small model's context

section .rdata
align 8
c_w      dq 0.05
c_tol    dq 1e-5
c_etol   dq 3e-7
c_ftol   dq 1e-4
c_q8tol  dq 0.02
c_q4tol  dq 0.15
c_half   dq 0.5
c_step   dq 0.37
c_start  dq -20.0
c_end    dq 20.0
c_big    dq 8.0
tinypath db "scratch\tiny.mnm", 0
m_same8  db "q8 matvec: every dot product path gives the same bits", 0
m_same4  db "q4 matvec: every dot product path gives the same bits", 0
m_ref8   db "q8 matvec = the same integer math in f64 (max rel diff)", 0
m_ref4   db "q4 matvec = the same integer math in f64 (max rel diff)", 0
m_err8   db "q8 against the f32 product (quantization error, relative)", 0
m_err4   db "q4 against the f32 product (quantization error, relative)", 0
m_exp    db "exp8 against x87 exp, -20..20 (max rel err)", 0
m_fwd    db "cpu forward (f32, kv cache) = gpu forward, max |diff| / max |logit|", 0

section .bss
alignb 32
rng      resb RNG_SIZE
w        resq 1                 ; f32 [R][C]
x        resq 1                 ; f32 [C]
y        resq 3                 ; one result per path
yref     resq 1
yf       resq 1                 ; the f32 product
q8m      resb MX_SIZE
q4m      resb MX_SIZE
q8buf    resq 1
q4buf    resq 1
xq       resb C
xs       resd C / 32
paths    resq 1                 ; how many paths this cpu has (1..3)
tbuf8    resd 8
mb       resb MB_SIZE
hp       resq 1                 ; host params / logits
htok     resq 1
glog     resq 1

section .text

global start
start:
    sub rsp, 40
    call lib_init
    xor ecx, ecx
    call pool_init
    lea rcx, [rng]
    mov edx, 17
    call rng_seed
    call kern_pick
    say "  cpu dot product path: "
    call kern_name
    mov rcx, rax
    call print_z
    say 13, 10
    ; paths to compare: avx2 always, then whatever else the cpu has
    mov qword [paths], 1
    test dword [cpu_feat], F_AVXVNNI
    jz .p
    mov qword [paths], 2
    test dword [cpu_feat], F_VNNIINT8
    jz .p
    mov qword [paths], 3
.p:
    call t_matvec
    call t_exp
    call gpu_init
    call t_forward
    jmp t_done

; ---- matrix x vector
t_matvec:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov ecx, R * C * 4
    call mem_alloc
    mov [w], rax
    mov ecx, C * 4
    call mem_alloc
    mov [x], rax
    xor ebx, ebx
.y:
    mov ecx, R * 4
    call mem_alloc
    lea rcx, [y]
    mov [rcx+rbx*8], rax
    inc ebx
    cmp ebx, 3
    jb .y
    mov ecx, R * 8
    call mem_alloc
    mov [yref], rax
    mov ecx, R * 8
    call mem_alloc
    mov [yf], rax
    ; weights normal * 0.05, x normal with a few big values (like real activations)
    xor ebx, ebx
.wf:
    lea rcx, [rng]
    call rng_normal
    mulsd xmm0, [c_w]
    cvtsd2ss xmm0, xmm0
    mov rax, [w]
    movss [rax+rbx*4], xmm0
    inc ebx
    cmp ebx, R * C
    jb .wf
    xor ebx, ebx
.xf:
    lea rcx, [rng]
    call rng_normal
    test ebx, 63
    jnz .xs
    mulsd xmm0, [c_big]         ; every 64th one is 8x bigger
.xs:
    cvtsd2ss xmm0, xmm0
    mov rax, [x]
    movss [rax+rbx*4], xmm0
    inc ebx
    cmp ebx, C
    jb .xf
    ; the f32 product, in f64
    xor ebx, ebx
.f:
    xorpd xmm0, xmm0
    xor ecx, ecx
.fk:
    mov rax, [w]
    imul edx, ebx, C
    add edx, ecx
    cvtss2sd xmm1, [rax+rdx*4]
    mov rax, [x]
    cvtss2sd xmm2, [rax+rcx*4]
    mulsd xmm1, xmm2
    addsd xmm0, xmm1
    inc ecx
    cmp ecx, C
    jb .fk
    mov rax, [yf]
    movsd [rax+rbx*8], xmm0
    inc ebx
    cmp ebx, R
    jb .f

    ; quantize the matrix both ways
    mov ecx, R
    mov edx, C
    mov r8d, QT_Q8
    call mf_size
    mov rcx, rax
    call mem_alloc
    mov [q8buf], rax
    lea rdi, [q8m]
    mov rsi, rax
    mov ecx, R
    mov edx, C
    mov r8d, QT_Q8
    call eng_mx
    mov ecx, R
    mov edx, C
    mov r8d, QT_Q4
    call mf_size
    mov rcx, rax
    call mem_alloc
    mov [q4buf], rax
    lea rdi, [q4m]
    mov rsi, rax
    mov ecx, R
    mov edx, C
    mov r8d, QT_Q4
    call eng_mx
    xor ebx, ebx
.qr:
    imul ecx, ebx, C
    shl rcx, 2
    add rcx, [w]
    mov edx, C
    imul r8d, ebx, C
    add r8, [q8m+MX_Q]
    mov r9, [q8m+MX_S]
    lea r9, [r9+rbx*4]
    call q8_row
    imul ecx, ebx, C
    shl rcx, 2
    add rcx, [w]
    mov edx, C
    imul r8d, ebx, C / 2
    add r8, [q4m+MX_Q]
    imul r9d, ebx, C / 32 * 4
    add r9, [q4m+MX_S]
    call q4_row
    inc ebx
    cmp ebx, R
    jb .qr

    ; the activation quantization every path uses
    mov rcx, [x]
    mov edx, C
    lea r8, [xq]
    lea r9, [xs]
    call qx_vec

    lea rcx, [q8m]
    call allpaths
    check e, "q8 matvec: every dot product path gives the same bits"
    lea rcx, [q8m]
    call exact
    lea rdx, [m_ref8]
    lea r8, [c_tol]
    call cmpref
    lea r8, [c_q8tol]
    lea rdx, [m_err8]
    call cmpf32
    lea rcx, [q4m]
    call allpaths
    check e, "q4 matvec: every dot product path gives the same bits"
    lea rcx, [q4m]
    call exact
    lea rdx, [m_ref4]
    lea r8, [c_tol]
    call cmpref
    lea r8, [c_q4tol]
    lea rdx, [m_err4]
    call cmpf32
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = matrix. mv_run on every path into y[path], zf set if they all match path 0
allpaths:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    xor ebx, ebx
.p:
    cmp rbx, [paths]
    jae .cmp
    mov ecx, ebx
    call kern_set
    mov rcx, rsi
    mov rdx, [x]
    lea rax, [y]
    mov r8, [rax+rbx*8]
    call mv_run
    inc ebx
    jmp .p
.cmp:
    call kern_pick              ; back to the normal one
    mov ebx, 1
.c:
    cmp rbx, [paths]
    jae .same
    mov rsi, [y]
    lea rax, [y]
    mov rdi, [rax+rbx*8]
    mov ecx, R * 4
    repe cmpsb
    jne .out
    inc ebx
    jmp .c
.same:
    xor eax, eax                ; zf
.out:
    lea rsp, [rsp+32]           ; add would change zf
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = matrix. yref = the same integer dot products and scales, in f64
exact:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov rsi, rcx
    xor ebx, ebx                ; row
.r:
    cmp ebx, R
    jae .done
    xorpd xmm0, xmm0
    xor r12d, r12d              ; group
.g:
    xor r13d, r13d              ; int dot
    xor ecx, ecx
.j:
    ; weight j of the group, as a signed int
    cmp qword [rsi+MX_T], QT_Q4
    je .w4
    imul eax, ebx, C
    mov edx, r12d
    shl edx, 5
    add eax, edx                ; + group * 32
    add eax, ecx
    mov rdx, [rsi+MX_Q]
    movsx eax, byte [rdx+rax]
    jmp .have
.w4:
    imul eax, ebx, C / 2
    mov edx, r12d
    shl edx, 4
    add eax, edx                ; + group * 16
    mov edx, ecx
    and edx, 15
    add eax, edx
    mov rdx, [rsi+MX_Q]
    movzx eax, byte [rdx+rax]
    cmp ecx, 16
    jb .lo
    shr eax, 4
.lo:
    and eax, 15
    sub eax, 8
.have:
    mov edx, r12d
    shl edx, 5
    add edx, ecx
    lea rdi, [xq]
    movsx edx, byte [rdi+rdx]
    imul eax, edx
    add r13d, eax
    inc ecx
    cmp ecx, 32
    jb .j
    cvtsi2sd xmm1, r13d
    lea rdi, [xs]
    cvtss2sd xmm2, [rdi+r12*4]
    mulsd xmm1, xmm2
    cmp qword [rsi+MX_T], QT_Q4
    jne .acc
    imul eax, ebx, C / 32
    add eax, r12d
    mov rdx, [rsi+MX_S]
    cvtss2sd xmm2, [rdx+rax*4]
    mulsd xmm1, xmm2
.acc:
    addsd xmm0, xmm1
    inc r12d
    cmp r12d, C / 32
    jb .g
    cmp qword [rsi+MX_T], QT_Q8
    jne .st
    mov rdx, [rsi+MX_S]
    cvtss2sd xmm2, [rdx+rbx*4]
    mulsd xmm0, xmm2
.st:
    mov rax, [yref]
    movsd [rax+rbx*8], xmm0
    inc ebx
    jmp .r
.done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rdx = name, r8 = tolerance. max |y[0] - yref| / max |yref|
cmpref:
    mov rcx, [yref]
    jmp cmpd

; rdx = name, r8 = tolerance. max |y[0] - yf| / max |yf|
cmpf32:
    mov rcx, [yf]
    ; fall through

; rcx = f64 reference [R], rdx = name, r8 = tolerance: checks y[0] against it
cmpd:
    push rbx
    sub rsp, 48
    mov rbx, [y]
    xorpd xmm3, xmm3            ; max diff
    xorpd xmm4, xmm4            ; max ref
    mov rax, 0x7fffffffffffffff
    movq xmm5, rax
    xor eax, eax
.l:
    cvtss2sd xmm0, [rbx+rax*4]
    movsd xmm1, [rcx+rax*8]
    subsd xmm0, xmm1
    andpd xmm0, xmm5
    andpd xmm1, xmm5
    maxsd xmm3, xmm0
    maxsd xmm4, xmm1
    inc eax
    cmp eax, R
    jb .l
    divsd xmm3, xmm4
    movsd [rsp+32], xmm3
    comisd xmm3, [r8]
    setb cl
    movzx ecx, cl
    movsd xmm2, [rsp+32]
    call t_okf
    add rsp, 48
    pop rbx
    ret

; ---- exp8 over -20..20 against x87
t_exp:
    push rbx
    sub rsp, 48
    xorpd xmm6, xmm6            ; max rel err
    movsd [rsp+32], xmm6
    movsd xmm0, [c_start]
    movsd [rsp+40], xmm0
.l:
    movsd xmm0, [rsp+40]
    comisd xmm0, [c_end]
    jae .done
    cvtsd2ss xmm1, xmm0
    vbroadcastss ymm0, xmm1
    call exp8
    vmovss [tbuf8], xmm0
    vzeroupper
    movss xmm1, [tbuf8]
    cvtsd2ss xmm0, [rsp+40]     ; the same f32 input, in f64
    cvtss2sd xmm0, xmm0
    cvtss2sd xmm7, xmm1
    call math_exp
    subsd xmm7, xmm0
    divsd xmm7, xmm0
    mov rax, 0x7fffffffffffffff
    movq xmm1, rax
    andpd xmm7, xmm1
    maxsd xmm7, [rsp+32]
    movsd [rsp+32], xmm7
    movsd xmm0, [rsp+40]
    addsd xmm0, [c_step]
    movsd [rsp+40], xmm0
    jmp .l
.done:
    movsd xmm2, [rsp+32]
    comisd xmm2, [c_etol]
    setb cl
    movzx ecx, cl
    lea rdx, [m_exp]
    call t_okf
    add rsp, 48
    pop rbx
    ret

; ---- cpu forward against the gpu's, small random model, f32 everywhere
t_forward:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    mov qword [mdl+MD_L], 2
    mov qword [mdl+MD_D], 128
    mov qword [mdl+MD_H], 2
    mov qword [mdl+MD_KVH], 1
    mov qword [mdl+MD_F], 384
    mov qword [mdl+MD_V], 512
    mov qword [mdl+MD_T], TT
    mov qword [mdl+MD_B], 1
    mov qword [mdl+MD_NAIVE], 1
    mov rax, __?float64?__(10000.0)
    mov [mdl+MD_ROPE], rax
    mov dword [mdl_fast], 0
    mov ecx, 4
    call model_setup
    mov ecx, 23
    call model_init

    ; the model file: the header, then the params exactly as they are (every
    ; matrix here is a multiple of 64 bytes, so there's no padding between them)
    mov rcx, [mdl+MD_NP]
    lea rcx, [rcx*4+MF_SIZE]
    call mem_alloc
    mov [hp], rax
    mov rbx, rax
    mov rax, MF_MAGIC_V
    mov [rbx+MF_MAGIC], rax
    mov rax, [mdl+MD_L]
    mov [rbx+MF_L], rax
    mov rax, [mdl+MD_D]
    mov [rbx+MF_D], rax
    mov rax, [mdl+MD_H]
    mov [rbx+MF_H], rax
    mov rax, [mdl+MD_KVH]
    mov [rbx+MF_KVH], rax
    mov rax, [mdl+MD_HD]
    mov [rbx+MF_HD], rax
    mov rax, [mdl+MD_F]
    mov [rbx+MF_F], rax
    mov rax, [mdl+MD_V]
    mov [rbx+MF_V], rax
    mov qword [rbx+MF_T], TT
    mov rax, [mdl+MD_ROPE]
    mov [rbx+MF_ROPE], rax
    mov qword [rbx+MF_QT], QT_F32
    lea rcx, [rbx+MF_SIZE]
    mov rdx, [d_params]
    mov r8, [mdl+MD_NP]
    shl r8, 2
    call gpu_down
    lea rcx, [tinypath]
    call file_create
    mov rsi, rax
    mov rcx, rsi
    mov rdx, rbx
    mov r8, [mdl+MD_NP]
    lea r8, [r8*4+MF_SIZE]
    call file_write
    mov rcx, rsi
    call file_close
    lea rcx, [tinypath]
    call eng_load

    ; random tokens, the gpu's logits for all of them in one go
    mov ecx, 4096
    call mem_alloc
    mov [htok], rax
    xor ebx, ebx
.tk:
    lea rcx, [rng]
    call rng_next
    and eax, 511
    mov rdx, [htok]
    mov [rdx+rbx*2], ax
    inc ebx
    cmp ebx, TT + 1
    jb .tk
    mov ecx, 4096
    call gpu_alloc
    mov [mb+MB_TOK], rax
    mov rcx, rax
    mov rdx, [htok]
    mov r8d, 4096
    call gpu_up
    mov qword [mb+MB_B], 1
    mov qword [mb+MB_T], TT
    lea rcx, [mb]
    mov edx, FW_LOGITS
    call model_fwd
    mov ecx, TT * 512 * 4
    call mem_alloc
    mov [glog], rax
    mov rcx, rax
    mov rdx, [d_logits]
    mov r8d, TT * 512 * 4
    call gpu_down

    ; the cpu, one token at a time, every row of logits against the gpu's
    call eng_reset
    xorpd xmm6, xmm6
    movsd [rsp+32], xmm6        ; max diff
    movsd [rsp+40], xmm6        ; max logit
    xor r12d, r12d
.t:
    cmp r12d, TT
    jae .cmp
    mov rax, [htok]
    movzx ecx, word [rax+r12*2]
    mov edx, 1
    call eng_step
    mov rsi, [eng+EN_LOGITS]
    mov rdi, r12
    imul rdi, 512 * 4
    add rdi, [glog]
    xor ecx, ecx
.v:
    cvtss2sd xmm0, [rsi+rcx*4]
    cvtss2sd xmm1, [rdi+rcx*4]
    subsd xmm0, xmm1
    mov rax, 0x7fffffffffffffff
    movq xmm2, rax
    andpd xmm0, xmm2
    andpd xmm1, xmm2
    maxsd xmm0, [rsp+32]
    movsd [rsp+32], xmm0
    maxsd xmm1, [rsp+40]
    movsd [rsp+40], xmm1
    inc ecx
    cmp ecx, 512
    jb .v
    inc r12d
    jmp .t
.cmp:
    movsd xmm2, [rsp+32]
    divsd xmm2, [rsp+40]
    movsd [rsp+32], xmm2
    comisd xmm2, [c_ftol]
    setb cl
    movzx ecx, cl
    lea rdx, [m_fwd]
    movsd xmm2, [rsp+32]
    call t_okf
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
