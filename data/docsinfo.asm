; docsinfo file.docs [n]: checks a .docs file is consistent and shows the first
; n docs (or conversations, for chat files)
default rel
bits 64
%include "lib.inc"
%include "data/docs.inc"

extern ExitProcess

section .rdata
usage   db "usage: docsinfo file.docs [n]", 13, 10, 0
e_open  db "can't open that file", 0
roles   db "system   ", "user     ", "assistant", "other    "

section .bss
alignb 8
base    resq 1
size    resq 1
count   resq 1
line    resb 256

section .text

global start
start:
    sub rsp, 40
    call lib_init
    cmp qword [argc], 2
    jae .go
    lea rcx, [usage]
    call print_z
    mov ecx, 1
    call ExitProcess
.go:
    mov qword [count], 3
    cmp qword [argc], 3
    jb .open
    mov rcx, [argv+16]
    call parse_int
    mov [count], rax
.open:
    mov rcx, [argv+8]
    call file_map
    test rax, rax
    jnz .mapped
    lea rcx, [e_open]
    call fatal
.mapped:
    mov [base], rax
    mov [size], rdx
    mov rbx, rax                ; header

    mov rcx, [argv+8]
    call print_z
    say 13, 10, "  docs "
    mov rcx, [rbx+DH_NDOCS]
    call print_dec
    say "   conversations "
    mov rcx, [rbx+DH_NCONV]
    call print_dec
    say "   text bytes "
    mov rcx, [rbx+DH_BYTES]
    call print_dec
    say 13, 10

    ; consistency: magic, text runs to exactly the end, offsets go up and
    ; finish at the byte count, conversation starts go up and finish at ndocs
    mov rax, DOCS_MAGIC
    cmp [rbx+DH_MAGIC], rax
    jne .bad
    mov rax, [rbx+DH_TEXT]
    add rax, [rbx+DH_BYTES]
    cmp rax, [size]
    jne .bad
    mov rsi, [rbx+DH_OFFS]
    add rsi, rbx
    mov rcx, [rbx+DH_NDOCS]
    xor edx, edx
.ochk:
    mov rax, [rsi]
    cmp rax, rdx
    jb .bad
    mov rdx, rax
    add rsi, 8
    dec rcx
    jns .ochk                   ; ndocs + 1 entries
    cmp rdx, [rbx+DH_BYTES]
    jne .bad
    cmp qword [rbx+DH_NCONV], 0
    je .ok
    mov rsi, [rbx+DH_CONVS]
    add rsi, rbx
    mov rcx, [rbx+DH_NCONV]
    xor edx, edx
.cchk:
    mov rax, [rsi]
    cmp rax, rdx
    jb .bad
    mov rdx, rax
    add rsi, 8
    dec rcx
    jns .cchk
    cmp rdx, [rbx+DH_NDOCS]
    jne .bad
.ok:
    say "  structure ok", 13, 10, 13, 10
    cmp qword [rbx+DH_NCONV], 0
    jne .chat

    ; plain: first few docs
    xor r12d, r12d
.doc:
    cmp r12, [count]
    jae .end
    cmp r12, [rbx+DH_NDOCS]
    jae .end
    say "  ["
    mov rcx, r12
    call print_dec
    say "] "
    mov rcx, r12
    call show
    inc r12
    jmp .doc

.chat:
    ; first few conversations, message by message
    xor r12d, r12d
.conv:
    cmp r12, [count]
    jae .end
    cmp r12, [rbx+DH_NCONV]
    jae .end
    say "  conversation "
    mov rcx, r12
    call print_dec
    say 13, 10
    mov rax, [rbx+DH_CONVS]
    add rax, rbx
    mov r13, [rax+r12*8]
    mov r14, [rax+r12*8+8]
.msg:
    cmp r13, r14
    jae .cnext
    say "    "
    mov rax, [rbx+DH_ROLES]
    add rax, rbx
    movzx ecx, byte [rax+r13]
    and ecx, 3
    imul ecx, ecx, 9
    lea rax, [roles]
    add rcx, rax
    mov edx, 9
    call print
    say " "
    mov rcx, r13
    call show
    inc r13
    jmp .msg
.cnext:
    inc r12
    jmp .conv

.end:
    call con_restore
    xor ecx, ecx
    call ExitProcess
.bad:
    say "  BROKEN: the index doesn't add up", 13, 10
    call con_restore
    mov ecx, 1
    call ExitProcess

; rcx = doc index. prints its length and the start of it on one line
show:
    push rsi
    push rdi
    sub rsp, 40
    mov rax, [rbx+DH_OFFS]
    add rax, rbx
    mov rsi, [rax+rcx*8]
    mov rdx, [rax+rcx*8+8]
    sub rdx, rsi
    add rsi, [rbx+DH_TEXT]
    add rsi, rbx
    mov [rsp+32], rdx
    mov rcx, rdx
    call print_dec
    say " bytes: "
    mov rcx, [rsp+32]
    cmp rcx, 90
    jbe .cp
    mov ecx, 90
.cp:
    lea rdi, [line]
    xor edx, edx
.ch:
    cmp rdx, rcx
    jae .out
    mov al, [rsi+rdx]
    cmp al, 32
    jae .keep
    mov al, ' '
.keep:
    mov [rdi+rdx], al
    inc rdx
    jmp .ch
.out:
    lea rcx, [line]
    call print
    say 13, 10
    add rsp, 40
    pop rdi
    pop rsi
    ret
