; tiny test harness for the self-checking tests. include after lib.inc,
; finish with jmp t_done (exit code = number of failures)

extern ExitProcess

section .bss
tbuf    resb 512
fails   resq 1

section .text

; ecx = passed?, rdx = name
t_ok:
    push rbx
    sub rsp, 48
    mov ebx, ecx
    mov [rsp+32], rdx
    test ebx, ebx
    jz .bad
    say "  ok    "
    jmp .name
.bad:
    inc qword [fails]
    say "  FAIL  "
.name:
    mov rcx, [rsp+32]
    call print_z
    say 13, 10
    add rsp, 48
    pop rbx
    ret

; same, plus xmm2 = a value to show
t_okf:
    push rbx
    sub rsp, 48
    mov ebx, ecx
    mov [rsp+32], rdx
    movsd [rsp+40], xmm2
    test ebx, ebx
    jz .bad
    say "  ok    "
    jmp .name
.bad:
    inc qword [fails]
    say "  FAIL  "
.name:
    mov rcx, [rsp+32]
    call print_z
    say " = "
    movsd xmm0, [rsp+40]
    mov edx, 15
    call print_sci
    say 13, 10
    add rsp, 48
    pop rbx
    ret

; rcx = expected, edx = its length, r8 = end of what got written to tbuf
t_str:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov [rsp+32], rcx
    mov ebx, edx
    lea rdi, [tbuf]
    mov r12, r8
    sub r12, rdi                ; got length
    cmp r12, rbx
    jne .bad
    mov rcx, rbx
    repe cmpsb
    jne .bad
    say "  ok    "
    lea rcx, [tbuf]
    mov rdx, r12
    call print
    say 13, 10
    jmp .out
.bad:
    inc qword [fails]
    say "  FAIL  got '"
    lea rcx, [tbuf]
    mov rdx, r12
    call print
    say "' want '"
    mov rcx, [rsp+32]
    mov rdx, rbx
    call print
    say "'", 13, 10
.out:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; jmp here, don't call. never returns, so just realign whatever the stack is
t_done:
    and rsp, -16
    sub rsp, 32
    mov rcx, [fails]
    test rcx, rcx
    jnz .some
    say "  all passed", 13, 10
    jmp .out
.some:
    call print_dec
    say " FAILED", 13, 10
.out:
    call con_restore
    mov rcx, [fails]
    call ExitProcess

; compare [tbuf, rax) with a literal
%macro expect 1+
    section .rdata
    %%s db %1
    %%n equ $ - %%s
    section .text
    mov r8, rax
    lea rcx, [%%s]
    mov edx, %%n
    call t_str
%endmacro

; pass/fail from the flags:  cmp rax, 5 / check e, "name"
%macro check 2+
    set%1 cl
    movzx ecx, cl
    section .rdata
    %%s db %2, 0
    section .text
    lea rdx, [%%s]
    call t_ok
%endmacro

; xmm0 within tol of the expected value:  close_to 2.718281828459045, 1e-15, "exp(1)"
%macro close_to 3+
    section .rdata
    align 8
    %%e dq %1
    %%t dq %2
    %%s db %3, 0
    section .text
    movapd xmm2, xmm0
    subsd xmm0, [%%e]
    movq rax, xmm0
    btr rax, 63
    movq xmm0, rax
    movsd xmm1, [%%t]
    comisd xmm1, xmm0           ; written this way round so nan fails
    seta cl
    movzx ecx, cl
    lea rdx, [%%s]
    call t_okf
%endmacro
