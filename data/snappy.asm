; snappy decompression, the raw format (no framing) that parquet uses.
; a varint length, then tagged elements: literals, or copies from earlier output
default rel
bits 64

section .text

; rcx = dst, rdx = dst capacity, r8 = src, r9 = src size.
; rax = bytes written, -1 if the data is bad
global snappy_decompress
snappy_decompress:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov rdi, rcx
    mov rbx, rcx                ; start of output
    lea r12, [rcx+rdx]
    mov rsi, r8
    lea r13, [r8+r9]
    xor eax, eax
    xor ecx, ecx
.len:
    cmp rsi, r13
    jae .bad
    movzx edx, byte [rsi]
    inc rsi
    mov r8d, edx
    and r8d, 0x7f
    shl r8, cl
    or rax, r8
    add ecx, 7
    test dl, 0x80
    jnz .len
    lea r8, [rbx+rax]
    cmp r8, r12
    ja .bad
    mov r12, r8                 ; we should land exactly here
.tag:
    cmp rsi, r13
    jae .end
    movzx eax, byte [rsi]
    inc rsi
    mov ecx, eax
    and ecx, 3
    jz .lit
    cmp ecx, 2
    jb .copy1
    je .copy2
    shr eax, 2                  ; 11: len-1 in the tag, 4 byte offset
    inc eax
    mov edx, [rsi]
    add rsi, 4
    jmp .copy
.copy2:
    shr eax, 2                  ; 10: len-1 in the tag, 2 byte offset
    inc eax
    movzx edx, word [rsi]
    add rsi, 2
    jmp .copy
.copy1:
    mov edx, eax                ; 01: 3 bits of len-4, 11 bits of offset
    shr edx, 5
    shl edx, 8
    movzx ecx, byte [rsi]
    inc rsi
    or edx, ecx
    shr eax, 2
    and eax, 7
    add eax, 4
.copy:
    test edx, edx
    jz .bad
    mov rcx, rdi
    sub rcx, rbx
    cmp rdx, rcx
    ja .bad                     ; reaches back before the start
    lea rcx, [rdi+rax]
    cmp rcx, r12
    ja .bad
    mov r8, rsi
    mov rsi, rdi
    sub rsi, rdx
    mov ecx, eax
    rep movsb                   ; byte-by-byte semantics, so overlapping runs repeat properly
    mov rsi, r8
    jmp .tag
.lit:
    shr eax, 2
    cmp eax, 60
    jb .litlen
    lea ecx, [rax-59]           ; 60..63: len-1 is in the next 1..4 bytes
    mov eax, [rsi]
    add rsi, rcx
    shl ecx, 3
    bzhi eax, eax, ecx
.litlen:
    inc eax
    lea rcx, [rsi+rax]
    cmp rcx, r13
    ja .bad
    lea rcx, [rdi+rax]
    cmp rcx, r12
    ja .bad
    mov ecx, eax
    rep movsb
    jmp .tag
.end:
    cmp rdi, r12
    jne .bad
    mov rax, rdi
    sub rax, rbx
    jmp .ret
.bad:
    mov rax, -1
.ret:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
