; quantize checkpoint.ckpt out.mnm [q8|q4|f32] [rope_base=10000] [tok=datasets\tokenizer.bin] [fit=0]
; a training checkpoint -> a model file for the cpu (chat/model.inc): the f32
; weights, int8 with a scale per row, or int4 with a scale per group of 32.
; the norm weights stay f32. int4 scales are searched for (q4_row_fit), fit=0 gives the
; old max/7 ones (q4_row)
; uses: chat\quant tokenizer\tok tokenizer\pretok
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"
%include "train/train.inc"
%include "chat/model.inc"

extern ExitProcess

section .rdata
k_rope   db "rope_base", 0
k_tok    db "tok", 0
k_fit    db "fit", 0
d_tok    db "datasets\tokenizer.bin", 0
e_usage  db "usage: quantize checkpoint.ckpt out.mnm [q8|q4|f32]", 0
e_ckpt   db "not a checkpoint: ", 0
e_write  db "couldn't write ", 0
e_tok    db "can't load the tokenizer", 0
e_cols   db "every matrix width has to be a multiple of 32", 0
s_qt     db "f32", 0, "q8", 0, 0, "q4", 0, 0
align 8
c_rope   dq 10000.0
c_mb     dq 9.5367431640625e-07

section .bss
alignb 8
hdr      resb MF_SIZE
ck       resq 1                 ; the mapped checkpoint
qt       resq 1
outh     resq 1
buf      resq 1
bufsz    resq 1
written  resq 1
L        resq 1
D        resq 1
H        resq 1
KVH      resq 1
F        resq 1
V        resq 1
QKV      resq 1
QD       resq 1
q4fn     resq 1                 ; q4_row, or q4_row_fit

section .text

global start
start:
    sub rsp, 40
    call lib_init
    cmp qword [argc], 3
    jae .args
    lea rcx, [e_usage]
    call print_z
    say 13, 10
    mov ecx, 1
    call ExitProcess
.args:
    ; the type: the 4th arg if it isn't a key=value
    mov qword [qt], QT_Q8
    cmp qword [argc], 4
    jb .typed
    mov rax, [argv+24]
    cmp word [rax], 'q4'
    jne .t8
    mov qword [qt], QT_Q4
.t8:
    cmp word [rax], 'f3'
    jne .typed
    mov qword [qt], QT_F32
.typed:
    call cfg_args
    lea rcx, [k_fit]
    mov edx, 1
    call cfg_int
    lea rdx, [q4_row]
    lea r8, [q4_row_fit]
    test rax, rax
    cmovnz rdx, r8
    mov [q4fn], rdx
    mov rcx, [argv+8]
    call file_map
    test rax, rax
    jz .badck
    mov [ck], rax
    mov rcx, CK_MAGIC_V
    cmp [rax+CK_MAGIC], rcx
    jne .badck
    mov rcx, [rax+CK_L]
    mov [L], rcx
    mov rcx, [rax+CK_D]
    mov [D], rcx
    mov rcx, [rax+CK_H]
    mov [H], rcx
    mov rcx, [rax+CK_KVH]
    mov [KVH], rcx
    mov rcx, [rax+CK_F]
    mov [F], rcx
    mov rcx, [rax+CK_V]
    mov [V], rcx
    ; header
    mov rax, MF_MAGIC_V
    mov [hdr+MF_MAGIC], rax
    mov rbx, [ck]
    mov rax, [L]
    mov [hdr+MF_L], rax
    mov rax, [D]
    mov [hdr+MF_D], rax
    mov rax, [H]
    mov [hdr+MF_H], rax
    mov rax, [KVH]
    mov [hdr+MF_KVH], rax
    mov rax, [D]
    xor edx, edx
    div qword [H]
    mov [hdr+MF_HD], rax
    mov rcx, rax
    imul rax, [H]
    mov [QD], rax
    imul rcx, [KVH]
    lea rax, [rax+rcx*2]
    mov [QKV], rax
    mov rax, [F]
    mov [hdr+MF_F], rax
    mov rax, [V]
    mov [hdr+MF_V], rax
    mov rax, [rbx+CK_T]
    mov [hdr+MF_T], rax
    mov rax, [qt]
    mov [hdr+MF_QT], rax
    lea rcx, [k_rope]
    movsd xmm1, [c_rope]
    call cfg_float
    movsd [hdr+MF_ROPE], xmm0
    lea rcx, [k_tok]
    lea rdx, [d_tok]
    call cfg_str
    mov rcx, rax
    call tok_load
    test eax, eax
    jnz .tok
    lea rcx, [e_tok]
    call fatal
.tok:
    mov rax, [tok_hash]
    mov [hdr+MF_TOKHASH], rax
    ; every matrix gets quantized along rows of D, QD or F: all multiples of 32
    mov rax, [D]
    or rax, [F]
    or rax, [QD]
    test eax, 31
    jz .cols
    lea rcx, [e_cols]
    call fatal
.cols:
    mov rcx, [argv+16]
    call file_create
    cmp rax, -1
    jne .made
    lea rcx, [e_write]
    call print_z
    mov rcx, [argv+16]
    call fatal
.made:
    mov [outh], rax
    lea rdx, [hdr]
    mov r8d, MF_SIZE
    call out

    ; the embedding, then every layer's four matrices, then the norms
    mov rsi, [ck]
    add rsi, CK_SIZE            ; f32 params
    mov rcx, rsi
    mov rdx, [V]
    mov r8, [D]
    call mat
    mov rax, [V]
    imul rax, [D]
    lea rsi, [rsi+rax*4]
    xor edi, edi
.layer:
    cmp rdi, [L]
    jae .norms
    mov rcx, rsi
    mov rdx, [QKV]
    mov r8, [D]
    call mat
    mov rax, [QKV]
    imul rax, [D]
    lea rsi, [rsi+rax*4]
    mov rcx, rsi
    mov rdx, [D]
    mov r8, [QD]
    call mat
    mov rax, [D]
    imul rax, [QD]
    lea rsi, [rsi+rax*4]
    mov rcx, rsi
    mov rdx, [F]
    add rdx, rdx
    mov r8, [D]
    call mat
    mov rax, [F]
    imul rax, [D]
    lea rsi, [rsi+rax*8]
    mov rcx, rsi
    mov rdx, [D]
    mov r8, [F]
    call mat
    mov rax, [D]
    imul rax, [F]
    lea rsi, [rsi+rax*4]
    inc rdi
    jmp .layer
.norms:
    mov rcx, [outh]
    mov rdx, rsi
    mov r8, [L]
    lea r8, [r8*2+1]
    imul r8, [D]
    shl r8, 2
    call out
    mov rcx, [outh]
    call file_close

    say "  "
    mov rcx, [argv+16]
    call print_z
    say ": "
    lea rcx, [s_qt]
    mov rax, [qt]
    lea rax, [rax*4]
    add rcx, rax
    call print_z
    say ", "
    cvtsi2sd xmm0, qword [written]
    mulsd xmm0, [c_mb]
    mov edx, 1
    call print_fixed
    say " MB", 13, 10
    xor ecx, ecx
    call ExitProcess
.badck:
    lea rcx, [e_ckpt]
    call print_z
    mov rcx, [argv+8]
    call fatal

; rcx = handle (ignored, it's outh), rdx = data, r8 = bytes
out:
    sub rsp, 40
    add [written], r8
    mov rcx, [outh]
    call file_write
    test eax, eax
    jnz .ok
    lea rcx, [e_write]
    call print_z
    mov rcx, [argv+16]
    call fatal
.ok:
    add rsp, 40
    ret

; rcx = f32 matrix, rdx = rows, r8 = cols. writes it in the chosen type
mat:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rsi, rcx
    mov r12, rdx
    mov r13, r8
    mov rcx, r12
    mov rdx, r13
    mov r8, [qt]
    call mf_size
    mov r14, rax
    ; a zeroed buffer big enough (the padding has to be zeros)
    cmp rax, [bufsz]
    jbe .have
    mov rcx, [buf]
    test rcx, rcx
    jz .alloc
    call mem_free
.alloc:
    mov rcx, r14
    call mem_alloc
    mov [buf], rax
    mov [bufsz], r14
.have:
    mov rdi, [buf]
    mov rcx, r14
    xor eax, eax
    push rdi
    rep stosb
    pop rdi
    cmp qword [qt], QT_F32
    jne .q
    mov rcx, r12
    imul rcx, r13
    push rsi
    rep movsd
    pop rsi
    jmp .write
.q:
    ; scales start after the weights, on 64
    mov rbx, r12
    imul rbx, r13
    cmp qword [qt], QT_Q4
    jne .s
    shr rbx, 1
.s:
    add rbx, 63
    and rbx, -64
    add rbx, rdi
    xor edi, edi                ; row
.r:
    cmp rdi, r12
    jae .write
    mov rcx, rdi
    imul rcx, r13
    lea rcx, [rsi+rcx*4]        ; the f32 row
    mov rdx, r13
    cmp qword [qt], QT_Q4
    je .r4
    mov r8, rdi
    imul r8, r13
    add r8, [buf]
    lea r9, [rbx+rdi*4]
    call q8_row
    jmp .rn
.r4:
    mov r8, rdi
    imul r8, r13
    shr r8, 1
    add r8, [buf]
    mov r9, rdi
    imul r9, r13
    shr r9, 3                   ; row * groups * 4
    add r9, rbx
    call [q4fn]
.rn:
    inc rdi
    jmp .r
.write:
    mov rcx, [outh]
    mov rdx, [buf]
    mov r8, r14
    call out
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
