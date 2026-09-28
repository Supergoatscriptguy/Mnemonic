; training data: every .tok file matching a pattern, in name order, read front to
; back. a row is T+1 tokens (the last one is only a target) and the next row starts
; on that last token, so every token is a target exactly once. rows never cross
; files, the few tokens left at a file's end get skipped. after the last file it
; wraps around. (file, offset) is the whole state, a checkpoint saves just that
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"
%include "train/train.inc"

extern PrefetchVirtualMemory

MAXF   equ 4096
PCHUNK equ 8 << 20              ; prefetch 8M tokens (16 MB) at a time

section .rdata
e_none   db "no .tok files match the data pattern", 0
e_tok    db "not a .tok file for this vocab: ", 0
e_short  db "the val file is too short for val_batches", 0

section .bss
alignb 8
global ld_nfiles, ld_file, ld_off, ld_chat
ld_nfiles resq 1
ld_file   resq 1                ; file the next row comes from
ld_off    resq 1                ; and its first token
ld_chat   resq 1                ; 1 = chat files, MASKBIT marks the targets
names     resq MAXF
base      resq 1                ; mapped file, 0 = none
mapped    resq 1                ; which one
ntok      resq 1
pref      resq 1                ; prefetched up to here (tokens)
range     resq 2                ; for PrefetchVirtualMemory

section .text

; rcx = pattern, rdx = a path to leave out (the val file), or 0
global ld_init
ld_init:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov ecx, MAXF * 300
    call mem_alloc
    mov rcx, rsi
    mov rdx, rax
    mov r8d, MAXF * 300
    call file_find
    ; keep the pointers, minus the excluded one
    xor ebx, ebx
    xor ecx, ecx
    mov r8, rdx
.f:
    cmp rcx, rax
    jae .fd
    mov r9, [r8+rcx*8]
    test rdi, rdi
    jz .keep
    xor r10d, r10d
.cmp:
    mov r11b, [r9+r10]
    cmp r11b, [rdi+r10]
    jne .keep
    test r11b, r11b
    jz .skip                    ; same path
    inc r10
    jmp .cmp
.keep:
    cmp rbx, MAXF
    jae .skip
    lea r10, [names]
    mov [r10+rbx*8], r9
    inc rbx
.skip:
    inc rcx
    jmp .f
.fd:
    mov [ld_nfiles], rbx
    test rbx, rbx
    jnz .have
    lea rcx, [e_none]
    call fatal
.have:
    xor eax, eax
    mov [ld_file], rax
    mov [ld_off], rax
    mov qword [mapped], -1
    xor ecx, ecx
    call use
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = file index. maps it (unmapping the last one) and checks its header
use:
    push rbx
    sub rsp, 32
    cmp rcx, [mapped]
    je .done
    mov rbx, rcx
    mov rcx, [base]
    test rcx, rcx
    jz .map
    call file_unmap
.map:
    lea rax, [names]
    mov rcx, [rax+rbx*8]
    call mapfile
    mov [mapped], rbx
    mov qword [pref], 0
.done:
    add rsp, 32
    pop rbx
    ret

; rcx = path. maps it into base/ntok/ld_chat, dies unless it's a .tok for our vocab
mapfile:
    push rbx
    sub rsp, 32
    mov rbx, rcx
    call file_map
    test rax, rax
    jz .bad
    mov [base], rax
    mov rcx, TF_MAGIC_V
    cmp [rax+TF_MAGIC], rcx
    jne .bad
    cmp qword [rax+TF_VOCAB], VOCAB
    jne .bad
    mov rcx, [rax+TF_NTOK]
    mov [ntok], rcx
    mov rcx, [rax+TF_FLAGS]
    and ecx, 1
    mov [ld_chat], rcx
    add rsp, 32
    pop rbx
    ret
.bad:
    lea rcx, [e_tok]
    call print_z
    mov rcx, rbx
    call fatal

; rcx = dst (u16), rdx = rows, r8 = T. the next rows, T+1 tokens each
global ld_rows
ld_rows:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rdi, rcx
    mov r12, rdx
    mov r13, r8
.row:
    test r12, r12
    jz .done
    mov rcx, [ld_file]
    call use
    mov rax, [ld_off]
    lea rcx, [rax+r13+1]
    cmp rcx, [ntok]
    jbe .fits
    ; not enough left in this file: next one, from the start
    mov rax, [ld_file]
    inc rax
    xor edx, edx
    div qword [ld_nfiles]
    mov [ld_file], rdx
    mov qword [ld_off], 0
    jmp .row
.fits:
    ; keep the os reading ahead of us, a chunk at a time
    mov rax, [pref]
    sub rax, PCHUNK / 2
    cmp rcx, rax
    jl .copy
    mov rax, [pref]
    mov rdx, [base]
    lea rdx, [rdx+rax*2+TF_SIZE]
    mov [range], rdx
    mov rdx, [ntok]
    sub rdx, rax
    jbe .copy
    mov r8d, PCHUNK
    cmp rdx, r8
    cmova rdx, r8
    add [pref], rdx
    shl rdx, 1
    mov [range+8], rdx
    mov rcx, -1                 ; GetCurrentProcess
    mov edx, 1
    lea r8, [range]
    xor r9d, r9d
    call PrefetchVirtualMemory
.copy:
    mov rsi, [base]
    mov rax, [ld_off]
    lea rsi, [rsi+rax*2+TF_SIZE]
    lea rcx, [r13*2+2]
    rep movsb
    add [ld_off], r13
    dec r12
    jmp .row
.done:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = path, rdx = dst, r8 = rows, r9 = T. the first rows of a file (validation),
; without touching the training position
global ld_val
ld_val:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    mov rdi, rdx
    mov r12, r8
    mov r13, r9
    mov rcx, [base]
    test rcx, rcx
    jz .map
    call file_unmap
    mov qword [base], 0
    mov qword [mapped], -1
.map:
    mov rcx, rbx
    call mapfile
    mov rax, r12
    imul rax, r13
    inc rax
    cmp rax, [ntok]
    jbe .ok
    lea rcx, [e_short]
    call fatal
.ok:
    mov rsi, [base]
    add rsi, TF_SIZE
.row:
    test r12, r12
    jz .done
    mov rbx, rsi
    lea rcx, [r13*2+2]
    rep movsb
    lea rsi, [rbx+r13*2]
    dec r12
    jmp .row
.done:
    mov rcx, [base]
    call file_unmap
    mov qword [base], 0
    mov rcx, [ld_file]
    call use                    ; back to the training file (and its ld_chat)
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
