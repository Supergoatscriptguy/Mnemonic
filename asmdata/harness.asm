; harness for generated NASM functions. runs the tests in tests.inc (written by
; verify.asm from the model's test lines) against the function it names. before each
; call every register the win64 abi says must survive gets a canary, and after it
; they're all checked, plus rsp and the direction flag. prints what went wrong so the
; model can be shown its mistake.
; exit code: 0 all passed, 1 wrong results, 2 broke the abi, 3 crashed.
; verify.asm builds it next to each candidate, build.bat doesn't
default rel
bits 64

extern GetStdHandle, WriteFile, ExitProcess, AddVectoredExceptionHandler, SetErrorMode
; the function under test, through a jmp thunk verify.asm writes, so its name can't
; clash with anything in here
extern __entry

; tests.inc: NTESTS, and tests: a table of records: dq arg0, arg1, arg2, arg3,
; checkret, ret, nchk, then nchk x (buf, expected, len)
%include "tests.inc"

; canaries for rbx, rbp, rsi, rdi, r12-r15
C0 equ 0x5ca1ab1e00000b0b
C1 equ 0x5ca1ab1e00000b1b
C2 equ 0x5ca1ab1e00000b2b
C3 equ 0x5ca1ab1e00000b3b
C4 equ 0x5ca1ab1e00000b4b
C5 equ 0x5ca1ab1e00000b5b
C6 equ 0x5ca1ab1e00000b6b
C7 equ 0x5ca1ab1e00000b7b

section .rdata
align 16
canx     times 10 dd 0x0ddba11, 0xf00dcafe, 0x5eed5eed, 0xabad1dea
regnames db "rbx rbp rsi rdi r12 r13 r14 r15 "
m_test   db "test ", 0
m_ret    db ": returned ", 0
m_exp    db ", expected ", 0
m_buf    db ": the buffer in argument ", 0
m_at     db " is wrong at byte ", 0
m_npres  db " was not preserved (the win64 abi says it must be)", 0
m_xmm    db "xmm6-xmm15 were not preserved (the win64 abi says they must be)", 0
m_rsp    db "rsp was different after the call returned (unbalanced push/pop or stack adjust)", 0
m_df     db "the direction flag was left set (it must be clear when the function returns)", 0
m_ok     db "all tests passed: ", 0
m_crash  db "crashed with exception 0x", 0
m_in     db " (", 0
m_close  db ")", 0
m_nl     db 13, 10, 0

section .bss
alignb 16
gotx     resb 160
stdout   resq 1
written  resd 1
cur      resq 1                 ; test number
rec      resq 1
saved    resq 1                 ; rsp at the call
retval   resq 1
rflags   resq 1
got      resq 8
fails    resq 1
abibad   resq 1
num      resb 32

section .text

global __harness_start
__harness_start:
    sub rsp, 40
    mov ecx, 0x8003             ; no error dialogs, just die
    call SetErrorMode
    mov ecx, 1
    lea rdx, [crashed]
    call AddVectoredExceptionHandler
    mov ecx, -11
    call GetStdHandle
    mov [stdout], rax
    mov qword [cur], 0
.test:
    mov rax, [cur]
    cmp rax, NTESTS
    jae .done
    lea rcx, [tests]
    mov rax, [rcx+rax*8]
    mov [rec], rax
    mov rcx, [rax]
    mov rdx, [rax+8]
    mov r8, [rax+16]
    mov r9, [rax+24]
    mov rbx, C0
    mov rbp, C1
    mov rsi, C2
    mov rdi, C3
    mov r12, C4
    mov r13, C5
    mov r14, C6
    mov r15, C7
    movdqa xmm6, [canx]
    movdqa xmm7, [canx+16]
    movdqa xmm8, [canx+32]
    movdqa xmm9, [canx+48]
    movdqa xmm10, [canx+64]
    movdqa xmm11, [canx+80]
    movdqa xmm12, [canx+96]
    movdqa xmm13, [canx+112]
    movdqa xmm14, [canx+128]
    movdqa xmm15, [canx+144]
    mov [saved], rsp
    cld
    call __entry
    ; first thing, before any call can touch them: the result and the flags
    mov [retval], rax
    pushfq
    pop rax
    mov [rflags], rax
    cld
    ; is the stack where we left it? if not, put it back
    cmp rsp, [saved]
    je .rspok
    mov rsp, [saved]
    lea rcx, [m_rsp]
    call line
    mov qword [abibad], 1
.rspok:
    test dword [rflags], 0x400
    jz .dfok
    lea rcx, [m_df]
    call line
    mov qword [abibad], 1
.dfok:
    mov [got], rbx
    mov [got+8], rbp
    mov [got+16], rsi
    mov [got+24], rdi
    mov [got+32], r12
    mov [got+40], r13
    mov [got+48], r14
    mov [got+56], r15
    movdqa [gotx], xmm6
    movdqa [gotx+16], xmm7
    movdqa [gotx+32], xmm8
    movdqa [gotx+48], xmm9
    movdqa [gotx+64], xmm10
    movdqa [gotx+80], xmm11
    movdqa [gotx+96], xmm12
    movdqa [gotx+112], xmm13
    movdqa [gotx+128], xmm14
    movdqa [gotx+144], xmm15
    call regs
    call results
    inc qword [cur]
    jmp .test
.done:
    mov ecx, 2
    cmp qword [abibad], 0
    jne .exit
    mov ecx, 1
    cmp qword [fails], 0
    jne .exit
    lea rcx, [m_ok]
    call str
    mov rcx, NTESTS
    call dec
    lea rcx, [m_nl]
    call str
    xor ecx, ecx
.exit:
    call ExitProcess

; the callee-saved registers against their canaries
regs:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    lea rsi, [got]
    xor ebx, ebx
.r:
    mov rax, rbx                ; canary i = C0 + 16 i
    shl rax, 4
    mov rcx, C0
    add rax, rcx
    cmp [rsi+rbx*8], rax
    je .next
    lea rcx, [regnames]
    lea rcx, [rcx+rbx*4]
    mov edx, 3
    call write
    lea rcx, [m_npres]
    call line
    mov qword [abibad], 1
.next:
    inc ebx
    cmp ebx, 8
    jb .r
    ; xmm6-15: compare the 160 bytes
    lea rsi, [gotx]
    lea rdi, [canx]
    mov ecx, 160
    repe cmpsb
    je .x
    lea rcx, [m_xmm]
    call line
    mov qword [abibad], 1
.x:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; the return value and the buffers against the test's expectations
results:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, [rec]
    cmp qword [rbx+32], 0
    je .bufs
    mov rax, [retval]
    cmp rax, [rbx+40]
    je .bufs
    call testno
    lea rcx, [m_ret]
    call str
    mov rcx, [retval]
    call dec
    lea rcx, [m_exp]
    call str
    mov rcx, [rbx+40]
    call dec
    lea rcx, [m_nl]
    call str
    inc qword [fails]
.bufs:
    mov r12, [rbx+48]           ; checks
    lea rbx, [rbx+56]
.chk:
    test r12, r12
    jz .done
    mov rsi, [rbx]
    mov rdi, [rbx+8]
    mov rcx, [rbx+16]
    xor eax, eax
.cmp:
    cmp rax, rcx
    jae .ok
    mov dl, [rsi+rax]
    cmp dl, [rdi+rax]
    jne .bad
    inc rax
    jmp .cmp
.bad:
    mov [rsp+32], rax
    call testno
    lea rcx, [m_buf]
    call str
    ; which argument: find the buffer among the four args
    mov rax, [rec]
    mov rdx, [rbx]
    xor ecx, ecx
.which:
    cmp [rax+rcx*8], rdx
    je .found
    inc ecx
    cmp ecx, 4
    jb .which
.found:
    inc ecx
    call dec
    lea rcx, [m_at]
    call str
    mov rcx, [rsp+32]
    call dec
    lea rcx, [m_nl]
    call str
    inc qword [fails]
.ok:
    add rbx, 24
    dec r12
    jmp .chk
.done:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; "test N" (counting from 1)
testno:
    sub rsp, 40
    lea rcx, [m_test]
    call str
    mov rcx, [cur]
    inc rcx
    call dec
    add rsp, 40
    ret

; rcx = zero-terminated string
str:
    mov rdx, rcx
.l:
    cmp byte [rdx], 0
    je .go
    inc rdx
    jmp .l
.go:
    sub rdx, rcx
    jmp write

; rcx = zero-terminated string, then a line break
line:
    sub rsp, 40
    call str
    lea rcx, [m_nl]
    call str
    add rsp, 40
    ret

; rcx = text, rdx = length
write:
    sub rsp, 56
    mov r8, rdx
    mov rdx, rcx
    mov rcx, [stdout]
    lea r9, [written]
    mov qword [rsp+32], 0
    call WriteFile
    add rsp, 56
    ret

; rcx = signed value, printed in decimal
dec:
    sub rsp, 40
    lea r8, [num+31]
    mov byte [r8], 0
    mov rax, rcx
    test rax, rax
    jns .pos
    neg rax
.pos:
    mov r9d, 10
.d:
    xor edx, edx
    div r9
    add dl, '0'
    dec r8
    mov [r8], dl
    test rax, rax
    jnz .d
    test rcx, rcx
    jns .print
    dec r8
    mov byte [r8], '-'
.print:
    mov rcx, r8
    call str
    add rsp, 40
    ret

; rcx = value, printed as 8 hex digits
hex8:
    sub rsp, 40
    lea r8, [num+8]
    mov byte [r8], 0
    mov eax, ecx
    mov r9d, 8
.h:
    mov edx, eax
    and edx, 15
    cmp edx, 10
    jb .digit
    add edx, 'a' - 10 - '0'
.digit:
    add edx, '0'
    dec r8
    mov [r8], dl
    shr eax, 4
    dec r9d
    jnz .h
    mov rcx, r8
    call str
    add rsp, 40
    ret

; vectored exception handler: any error exception (access violation, divide error,
; stack overflow...) ends the run with code 3 and says which test
crashed:
    mov rax, [rcx]              ; EXCEPTION_RECORD
    mov eax, [rax]
    mov edx, eax
    and edx, 0xf0000000
    cmp edx, 0xc0000000
    jne .pass
    and rsp, -16
    sub rsp, 48
    mov [rsp+32], rax
    lea rcx, [m_crash]
    call str
    mov ecx, [rsp+32]
    call hex8
    lea rcx, [m_in]
    call str
    call testno
    lea rcx, [m_close]
    call line
    mov ecx, 3
    call ExitProcess
.pass:
    xor eax, eax
    ret
