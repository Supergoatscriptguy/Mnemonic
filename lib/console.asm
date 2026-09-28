; console output. all through WriteFile so it still works redirected to a file
default rel
bits 64
%include "lib.inc"

extern GetStdHandle
extern WriteFile

section .rdata
hexdig  db "0123456789abcdef"
minus   db "-"

section .bss
stdout  resq 1
written resd 1

section .text

global con_init
con_init:
    sub rsp, 40
    mov ecx, -11                ; STD_OUTPUT_HANDLE
    call GetStdHandle
    mov [stdout], rax
    add rsp, 40
    ret

; rcx = ptr, rdx = len
global print
print:
    sub rsp, 40
    mov r8, rdx
    mov rdx, rcx
    mov rcx, [stdout]
    lea r9, [written]
    mov qword [rsp+32], 0
    call WriteFile
    add rsp, 40
    ret

; rcx = zero terminated string
global print_z
print_z:
    mov rdx, rcx
.len:
    cmp byte [rdx], 0
    je .go
    inc rdx
    jmp .len
.go:
    sub rdx, rcx
    jmp print                   ; tail call, stack is untouched so print returns straight to our caller

; rcx = unsigned 64-bit value
global print_dec
print_dec:
    sub rsp, 72                 ; 40 for calls + 32 byte digit buffer at rsp+40
    lea r8, [rsp+72]            ; one past the end, digits get written backwards
    mov r9, r8
    mov rax, rcx
    mov r10, 0xcccccccccccccccd ; ceil(2^67 / 10): x/10 = (x * this) >> 67
.loop:
    mov rcx, rax
    mul r10
    shr rdx, 3                  ; rdx = x / 10
    lea rax, [rdx+rdx*4]
    add rax, rax
    sub rcx, rax                ; x - q*10
    add cl, '0'
    dec r9
    mov [r9], cl
    mov rax, rdx
    test rax, rax
    jnz .loop

    mov rcx, r9
    mov rdx, r8
    sub rdx, r9
    call print
    add rsp, 72
    ret

; rcx = signed 64-bit value
global print_int
print_int:
    test rcx, rcx
    jns print_dec
    sub rsp, 40
    mov [rsp+48], rcx           ; park it in the home slot our caller gave us
    lea rcx, [minus]
    mov edx, 1
    call print
    mov rcx, [rsp+48]
    neg rcx                     ; INT64_MIN stays 0x8000.. which is right as unsigned
    add rsp, 40
    jmp print_dec

; rcx = value, edx = number of hex digits (1-16)
global print_hex
print_hex:
    sub rsp, 72
    lea r8, [rsp+72]
    mov r9, r8
    mov eax, edx
    lea r10, [hexdig]
.loop:
    mov edx, ecx
    and edx, 15
    mov dl, [r10+rdx]
    dec r9
    mov [r9], dl
    shr rcx, 4
    dec eax
    jnz .loop

    mov rcx, r9
    mov rdx, r8
    sub rdx, r9
    call print
    add rsp, 72
    ret
