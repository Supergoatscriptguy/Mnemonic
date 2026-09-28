; stage 0: prove the toolchain works end to end
default rel
bits 64

extern GetStdHandle
extern WriteFile
extern ExitProcess

section .data
msg     db "Mnemonic online. x86-64, no CRT, just kernel32.", 13, 10
msglen  equ $ - msg

section .bss
written resd 1

section .text
global start
start:
    sub rsp, 40                 ; 32 shadow + 8 to fix alignment (we enter at rsp = 8 mod 16)

    mov ecx, -11                ; STD_OUTPUT_HANDLE
    call GetStdHandle

    mov rcx, rax
    lea rdx, [msg]
    mov r8d, msglen
    lea r9, [written]
    mov qword [rsp+32], 0       ; 5th arg goes above the shadow space
    call WriteFile

    xor ecx, ecx
    call ExitProcess
