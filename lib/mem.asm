; memory straight from VirtualAlloc, plus a simple arena
default rel
bits 64
%include "lib.inc"

extern VirtualAlloc, VirtualFree

MEM_COMMIT   equ 0x1000
MEM_RESERVE  equ 0x2000
MEM_RELEASE  equ 0x8000
PAGE_RW      equ 4
COMMIT_STEP  equ 1 << 20        ; grow the committed part a MB at a time

section .rdata
e_nomem  db "out of memory", 0
e_full   db "arena full", 0

section .text

; rcx = size. returns zeroed, page aligned memory. dies if there isn't any
global mem_alloc
mem_alloc:
    sub rsp, 40
    mov rdx, rcx
    xor ecx, ecx
    mov r8d, MEM_COMMIT | MEM_RESERVE
    mov r9d, PAGE_RW
    call VirtualAlloc
    test rax, rax
    jz .fail
    add rsp, 40
    ret
.fail:
    lea rcx, [e_nomem]
    call fatal

; rcx = ptr from mem_alloc
global mem_free
mem_free:
    xor edx, edx
    mov r8d, MEM_RELEASE
    jmp VirtualFree

; rcx = arena, rdx = bytes of address space to reserve. costs nothing until used
global arena_init
arena_init:
    push rbx
    sub rsp, 32
    mov rbx, rcx
    mov [rbx+AR_RESERVE], rdx
    xor eax, eax
    mov [rbx+AR_USED], rax
    mov [rbx+AR_COMMIT], rax
    xor ecx, ecx
    mov r8d, MEM_RESERVE
    mov r9d, PAGE_RW
    call VirtualAlloc
    test rax, rax
    jz .fail
    mov [rbx+AR_BASE], rax
    add rsp, 32
    pop rbx
    ret
.fail:
    lea rcx, [e_nomem]
    call fatal

; rcx = arena, rdx = size, r8 = alignment (power of 2).
; only zeroed the first time through, not after arena_reset
global arena_alloc
arena_alloc:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rax, [rbx+AR_BASE]
    add rax, [rbx+AR_USED]
    dec r8
    add rax, r8
    not r8
    and rax, r8
    mov rsi, rax                ; aligned start
    add rax, rdx
    sub rax, [rbx+AR_BASE]
    mov [rbx+AR_USED], rax
    cmp rax, [rbx+AR_COMMIT]
    jbe .ok
    cmp rax, [rbx+AR_RESERVE]
    ja .full
    add rax, COMMIT_STEP - 1
    and rax, -COMMIT_STEP
    cmp rax, [rbx+AR_RESERVE]
    cmova rax, [rbx+AR_RESERVE]
    mov rcx, [rbx+AR_COMMIT]
    mov rdx, rax
    sub rdx, rcx
    mov [rbx+AR_COMMIT], rax
    add rcx, [rbx+AR_BASE]
    mov r8d, MEM_COMMIT
    mov r9d, PAGE_RW
    call VirtualAlloc
    test rax, rax
    jz .full
.ok:
    mov rax, rsi
    add rsp, 40
    pop rsi
    pop rbx
    ret
.full:
    lea rcx, [e_full]
    call fatal

; rcx = arena. keeps the committed pages for reuse
global arena_reset
arena_reset:
    mov qword [rcx+AR_USED], 0
    ret
