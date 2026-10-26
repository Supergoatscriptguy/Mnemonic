; still more of mathgen's algebra: x^2 = k (and the ones that come down to it), logs,
; and derivatives of polynomials by the power rule
default rel
bits 64
%include "lib.inc"
%include "math/math.inc"

section .rdata
sq0 db "Solve @i.", 0
sq1 db "Find x if @i.", 0
sq2 db "Solve for x: @i.", 0
sq3 db "What are the solutions of @i?", 0
sq4 db "If @i, what is x?", 0
align 8
qsq dq sq0, sq1, sq2, sq3, sq4
NQSQ equ 5

lg0 db "What is @i?", 0
lg1 db "Evaluate @i.", 0
lg2 db "Find @i.", 0
lg3 db "@i = ?", 0
align 8
qlog dq lg0, lg1, lg2, lg3
NQLOG equ 4
lw0 db "What is log base @n of @k?", 0
lw1 db "Find log base @n of @k.", 0
lw2 db "What power of @n gives @k?", 0
align 8
qlogw dq lw0, lw1, lw2
ls0 db "Solve @i.", 0
ls1 db "If @i, what is x?", 0
ls2 db "Find x if @i.", 0
align 8
qlogs dq ls0, ls1, ls2

; derivatives: the question, and how the answer is said (0 the derivative is,
; 1 f'(x) =, 2 dy/dx =)
dv0 db "Find the derivative of @i.", 0
dv1 db "Differentiate @i.", 0
dv2 db "What is the derivative of @i?", 0
dv3 db "d/dx (@i) = ?", 0
dv4 db "If f(x) = @i, what is f'(x)?", 0
dv5 db "Find dy/dx if y = @i.", 0
align 8
qdv dq dv0, 0, dv1, 0, dv2, 0, dv3, 0, dv4, 1, dv5, 2
dt0 db "What is the slope of the tangent line to y = @i at x = @m?", 0
dt1 db "If f(x) = @i, find f'(@m).", 0
dt2 db "Find the slope of y = @i when x = @m.", 0
align 8
qdt dq dt0, 0, dt1, 1, dt2, 0
d20 db "Find the second derivative of @i.", 0
d21 db "What is the second derivative of @i?", 0
d22 db "If f(x) = @i, what is f''(x)?", 0
align 8
qd2 dq d20, 0, d21, 0, d22, 1
sins dq 2, 3, 5, 6, 7, 10, 11, 13, 15
NSINS equ 9

section .bss
alignb 8
qbuf  resb 256                  ; the equation or polynomial, for the question
pa    resq 8                    ; a polynomial, by power
pb    resq 8                    ; its derivative
pc2   resq 8                    ;  and the next one
hf    resq 8                    ; highest power first, for poly
vals  resq 8

section .text

global square_one, log_one, deriv_one

; askt and fill live in applied.asm, as do the @ fields
extern askt, fi, fn, fk

; rcx = out, rdx = in: 5√2, √7, or 6
prad:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    cmp r12, 1
    je .n
    cmp rbx, 1
    je .r1
    num rbx
.r1:
    emit "√"
    num r12
    jmp .r
.n:
    num rbx
.r:
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = k >= 1: √k worked out. small squares are just known, the rest by factoring.
; rax = out, rdx = in
sqroot:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov rbx, rcx
    xor r12d, r12d
.s:
    inc r12
    mov rax, r12
    imul rax, r12
    cmp rax, rbx
    jb .s
    jne .f
    cmp r12, 12
    ja .f
    emit "√"
    num rbx
    emit " = "
    num r12
    emit ", since "
    num r12
    emit " × "
    num r12
    emit " = "
    num rbx
    emit ".", 10
    mov rax, r12
    mov edx, 1
    jmp .r
.f:
    mov rcx, rbx
    call rootwork
.r:
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rax = a k for x^2 = k: a square most of the time, otherwise s^2 × t
sqk:
    push rbx
    sub rsp, 32
    xor ecx, ecx
    mov edx, 9
    call rnd
    cmp eax, 6
    jae .ns
    mov ecx, 1
    mov edx, 30
    cmp eax, 5
    jne .sq
    mov ecx, 31
    mov edx, 99
.sq:
    call rnd
    imul rax, rax
    jmp .r
.ns:
    mov ecx, 1
    mov edx, 12
    call rnd
    mov rbx, rax
    imul rbx, rax
    xor ecx, ecx
    mov edx, NSINS - 1
    call rnd
    lea rcx, [sins]
    imul rbx, [rcx+rax*8]
    mov rax, rbx
.r:
    add rsp, 32
    pop rbx
    ret

; x^2 = k, ax^2 = c, x^2 + c = d, (x + a)^2 = k
square_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    mov byte [letter], 'x'
    xor ecx, ecx
    mov edx, 9
    call rnd
    mov r15, rax
    mov [rsp+32], rdi
    lea rdi, [qbuf]
    cmp r15, 4
    jb .plain
    cmp r15, 6
    jb .ax
    cmp r15, 8
    jb .pc
    ; (x + a)^2 = k
    mov rcx, -9
    mov edx, 9
    call rnd
    test rax, rax
    jz .ax
    mov r13, rax
    mov ecx, 1
    mov edx, 12
    call rnd
    mov r14, rax
    imul rax, rax
    mov r12, rax
    emit "(x"
    mov rcx, r13
    xor edx, edx
    call sterm
    emit ")^2 = "
    num r12
    jmp .qd
.plain:
    cmp r15, 3
    jne .pk
    mov ecx, 1                  ; a negative one
    mov edx, 20
    call rnd
    imul rax, rax
    neg rax
    mov r12, rax
    jmp .pw
.pk:
    call sqk
    mov r12, rax
.pw:
    emit "x^2 = "
    sint r12
    jmp .qd
.ax:
    mov r15d, 4
    mov ecx, 2
    mov edx, 9
    call rnd
    mov r13, rax
    call sqk
    mov r12, rax
    cmp rax, 400
    ja .ax
    mov rcx, r13
    mov edx, 2
    call mono
    emit " = "
    mov rax, r12
    imul rax, r13
    num rax
    jmp .qd
.pc:
    mov ecx, 1
    mov edx, 50
    call rnd
    mov r13, rax                ; c
    call sqk
    mov r12, rax
    cmp rax, 900
    ja .pc
    call coin
    test eax, eax
    jz .pcm
    cmp r12, r13                ; x^2 - c = d: d stays above 0
    jbe .pc
    neg r13
.pcm:
    emit "x^2"
    mov rcx, r13
    xor edx, edx
    call sterm
    emit " = "
    mov rax, r12
    add rax, r13
    sint rax
.qd:
    mov byte [rdi], 0
    mov rdi, [rsp+32]
    lea rax, [qbuf]
    mov [fi], rax
    lea rcx, [qsq]
    mov edx, NQSQ
    call askt
    emit "assistant: "
    cmp r15, 4
    jb .solve
    cmp r15, 6
    jb .sax
    cmp r15, 8
    jb .spc
    ; (x + a)^2 = k
    emit "Take the square root of both sides, and remember the negative root too.", 10
    mov rcx, r12
    call sqroot
    emit "x"
    mov rcx, r13
    xor edx, edx
    call sterm
    emit " = "
    num r14
    emit " or x"
    mov rcx, r13
    xor edx, edx
    call sterm
    emit " = -"
    num r14
    emit ".", 10
    emit "x = "
    num r14
    mov rbx, r14
    sub rbx, r13
    call minus
    emit " = "
    sint rbx
    emit " or x = -"
    num r14
    mov rbx, r14
    neg rbx
    sub rbx, r13
    call minus
    emit " = "
    sint rbx
    emit ".", 10
    emit "x = "
    mov rax, r14
    sub rax, r13
    sint rax
    emit " or x = "
    sint rbx
    emit 10
    jmp .r
.sax:
    emit "Divide both sides by "
    num r13
    emit ":", 10
    mov rcx, r12
    imul rcx, r13
    mov rdx, r13
    call divline
    emit 10
    emit "x^2 = "
    num r12
    emit ".", 10
    jmp .root
.spc:
    emit "Move the "
    mov rax, r13
    test rax, rax
    jns .sp1
    neg rax
.sp1:
    num rax
    emit " to the other side:", 10
    mov rcx, r12
    add rcx, r13                ; d
    test r13, r13
    js .spa
    mov rdx, r13
    call substep
    jmp .spd
.spa:
    mov rdx, r13
    neg rdx
    call addstep
.spd:
    emit "x^2 = "
    num r12
    emit ".", 10
    jmp .root
.solve:
    test r12, r12
    jns .root
    emit "A square is never negative, so x^2 can't be "
    sint r12
    emit ".", 10
    emit "There are no real solutions.", 10
    jmp .r
.root:
    emit "Take the square root of both sides, and remember the negative root too: x = √"
    num r12
    emit " or x = -√"
    num r12
    emit ".", 10
    mov rcx, r12
    call sqroot
    mov rbx, rax
    mov r12, rdx
    emit "x = "
    mov rcx, rbx
    mov rdx, r12
    call prad
    emit " or x = -"
    mov rcx, rbx
    mov rdx, r12
    call prad
    emit 10
.r:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; " - a" or " + |a|" for square_one's r13
minus:
    push rsi
    sub rsp, 32
    test r13, r13
    js .p
    emit " - "
    num r13
    jmp .r
.p:
    emit " + "
    mov rax, r13
    neg rax
    num rax
.r:
    add rsp, 32
    pop rsi
    ret

; ---- logs

; log_b(n), log_b(1/n), log_b(x) = k, and log_4(8) = 3/2
log_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    xor ecx, ecx
    mov edx, 9
    call rnd
    mov r15, rax
    cmp r15, 9
    je .frac
.pick:
    mov ecx, 2
    mov edx, 10
    call rnd
    mov rbx, rax                ; b
    xor r14d, r14d              ; 1 = written log(), base 10
    cmp rbx, 10
    jne .pk
    call coin
    mov r14, rax
.pk:
    xor ecx, ecx
    mov edx, 9
    call rnd
    mov r12, rax                ; k
    cmp r15, 6
    jae .k1
    cmp r12, 2                  ; log_b(1) and log_b(b) now and then
    jae .k1
    call coin
    test eax, eax
    jnz .pk
.k1:
    test r12, r12
    jnz .k2
    cmp r15, 6
    jae .pk
.k2:
    mov eax, 1
    mov rcx, r12
.pw:
    test rcx, rcx
    jz .pd
    imul rax, rbx
    dec rcx
    jmp .pw
.pd:
    cmp rax, 1000000
    ja .pick
    mov r13, rax                ; b^k
    cmp r15, 6
    jb .val
    je .inv
    jmp .solve

.val:
    mov [fn], rbx
    mov [fk], r13
    test r14, r14
    jnz .vq
    cmp r15, 5                  ; in words now and then
    jne .vq
    test r12, r12
    jz .vq
    lea rcx, [qlogw]
    mov edx, 3
    cmp r12, 1
    ja .vw
    mov edx, 2
.vw:
    call askt
    jmp .va
.vq:
    mov [rsp+32], rdi
    lea rdi, [qbuf]
    call logn
    mov byte [rdi], 0
    mov rdi, [rsp+32]
    lea rax, [qbuf]
    mov [fi], rax
    lea rcx, [qlog]
    mov edx, NQLOG
    call askt
.va:
    emit "assistant: "
    test r12, r12
    jnz .v1
    emit "Any number to the power 0 is 1, so "
    call logn
    emit " = 0.", 10
    call logn
    emit " = 0", 10
    jmp .r
.v1:
    cmp rbx, 10
    jne .v2
    num r13
    emit " is 1 followed by "
    num r12
    emit " zero"
    cmp r12, 1
    je .vz
    emit "s"
.vz:
    emit ", so "
    num r13
    emit " = 10^"
    num r12
    emit ".", 10
    jmp .vend
.v2:
    call logn
    emit " asks what power of "
    num rbx
    emit " makes "
    num r13
    emit ".", 10
    cmp r12, 1
    jne .v3
    num rbx
    emit "^1 = "
    num rbx
    emit 10
    jmp .vend
.v3:
    emit "Multiply "
    num rbx
    emit "s until it gets there.", 10
    mov rcx, rbx
    mov rdx, r12
    call powchain
    emit "So "
    num rbx
    emit "^"
    num r12
    emit " = "
    num r13
    emit ".", 10
.vend:
    call logn
    emit " = "
    num r12
    emit 10
    jmp .r

.inv:
    test r12, r12
    jz .pk
    cmp rbx, 10
    je .pick
    mov [rsp+32], rdi
    lea rdi, [qbuf]
    call logi
    mov byte [rdi], 0
    mov rdi, [rsp+32]
    lea rax, [qbuf]
    mov [fi], rax
    lea rcx, [qlog]
    mov edx, NQLOG
    call askt
    emit "assistant: "
    cmp r12, 1
    je .i1
    emit "Find the power of "
    num rbx
    emit " on the bottom first.", 10
    mov rcx, rbx
    mov rdx, r12
    call powchain
.i1:
    emit "So 1/"
    num r13
    emit " = 1/"
    num rbx
    emit "^"
    num r12
    emit " = "
    num rbx
    emit "^(-"
    num r12
    emit "), which makes "
    call logi
    emit " = -"
    num r12
    emit ".", 10
    call logi
    emit " = -"
    num r12
    emit 10
    jmp .r

.solve:
    test r12, r12
    jz .pk
    mov [rsp+32], rdi
    lea rdi, [qbuf]
    call logx
    emit " = "
    num r12
    mov byte [rdi], 0
    mov rdi, [rsp+32]
    lea rax, [qbuf]
    mov [fi], rax
    lea rcx, [qlogs]
    mov edx, 3
    call askt
    emit "assistant: "
    call logx
    emit " = "
    num r12
    emit " means x = "
    num rbx
    emit "^"
    num r12
    emit ".", 10
    cmp r12, 1
    je .s1
    cmp rbx, 10
    jne .s10
    emit "10^"
    num r12
    emit " is 1 followed by "
    num r12
    emit " zeros.", 10
    jmp .s1
.s10:
    mov rcx, rbx
    mov rdx, r12
    call powchain
.s1:
    emit "x = "
    num r13
    emit 10
    jmp .r

.frac:
    ; log_(c^i)(c^j), j not a multiple of i
    call coin
    lea rbx, [rax+2]            ; c = 2 or 3
    mov ecx, 2
    mov edx, 3
    call rnd
    mov r12, rax                ; i
    mov ecx, 1
    mov edx, 7
    call rnd
    mov r13, rax                ; j
    xor edx, edx
    div r12
    test rdx, rdx
    jz .frac
    cmp rbx, 3
    jne .fq
    cmp r13, 6
    ja .frac
.fq:
    mov rcx, rbx
    mov rdx, r12
    call ipow
    mov [rsp+40], rax           ; the base
    mov rcx, rbx
    mov rdx, r13
    call ipow
    mov [rsp+48], rax           ; n
    mov [rsp+32], rdi
    lea rdi, [qbuf]
    call logf
    mov byte [rdi], 0
    mov rdi, [rsp+32]
    lea rax, [qbuf]
    mov [fi], rax
    lea rcx, [qlog]
    mov edx, NQLOG
    call askt
    emit "assistant: Write both as powers of "
    num rbx
    emit ".", 10
    mov rdx, r12
    cmp rdx, r13
    jae .fp
    mov rdx, r13
.fp:
    mov rcx, rbx
    call powchain
    emit "So "
    num [rsp+40]
    emit " = "
    num rbx
    emit "^"
    num r12
    emit " and "
    num [rsp+48]
    emit " = "
    num rbx
    emit "^"
    num r13
    emit ".", 10
    num [rsp+48]
    emit " = "
    num rbx
    emit "^"
    num r13
    emit " = ("
    num rbx
    emit "^"
    num r12
    emit ")^("
    num r13
    emit "/"
    num r12
    emit ") = "
    num [rsp+40]
    emit "^("
    num r13
    emit "/"
    num r12
    emit "), which makes "
    call logf
    emit " = "
    num r13
    emit "/"
    num r12
    emit ".", 10
    call logf
    emit " = "
    num r13
    emit "/"
    num r12
    emit 10
.r:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; log_one's log_b(n) (rbx = b, r13 = n, r14 = 1 for log(n))
logn:
    push rsi
    sub rsp, 32
    test r14, r14
    jz .b
    emit "log("
    jmp .n
.b:
    emit "log_"
    num rbx
    emit "("
.n:
    num r13
    emit ")"
    add rsp, 32
    pop rsi
    ret

; log_b(1/n)
logi:
    push rsi
    sub rsp, 32
    emit "log_"
    num rbx
    emit "(1/"
    num r13
    emit ")"
    add rsp, 32
    pop rsi
    ret

; log_b(x), or log(x)
logx:
    push rsi
    sub rsp, 32
    test r14, r14
    jz .b
    emit "log(x)"
    jmp .r
.b:
    emit "log_"
    num rbx
    emit "(x)"
.r:
    add rsp, 32
    pop rsi
    ret

; log_(c^i)(c^j), from log_one's frame: the base at [rsp+40], n at [rsp+48]
logf:
    push rsi
    sub rsp, 32
    emit "log_"
    num [rsp+40+48]
    emit "("
    num [rsp+48+48]
    emit ")"
    add rsp, 32
    pop rsi
    ret

; rcx = b, rdx = k: rax = b^k, quietly
ipow:
    mov eax, 1
.l:
    test rdx, rdx
    jz .r
    imul rax, rcx
    dec rdx
    jmp .l
.r:
    ret

; ---- derivatives

; rcx = a polynomial by power, rdx = its degree: written out, highest power first
ppoly:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    xor eax, eax
.l:
    mov r8, rdx
    sub r8, rax
    mov r9, [rbx+r8*8]
    lea r10, [hf]
    mov [r10+rax*8], r9
    inc rax
    cmp rax, rdx
    jbe .l
    lea rcx, [hf]
    call poly
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = a polynomial by power, rdx = its degree, r8 = where its derivative goes: a
; line a term. rax = the derivative's degree
dterms:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    mov r13, r8
    xor eax, eax
.z:
    mov qword [r13+rax*8], 0
    inc rax
    cmp rax, 8
    jb .z
    mov r14, r12                ; the power
.t:
    mov r15, [rbx+r14*8]
    test r15, r15
    jz .n
    mov rcx, r15
    mov rdx, r14
    call mono
    emit ": "
    cmp r14, 1
    ja .pw
    je .lin
    emit "a number on its own, so 0", 10
    jmp .n
.lin:
    emit "just "
    sint r15
    emit 10
    mov [r13], r15
    jmp .n
.pw:
    num r14
    emit " × "
    pint r15
    emit " = "
    mov rax, r15
    imul rax, r14
    mov [r13+r14*8-8], rax
    sint rax
    emit ", so "
    mov rcx, [r13+r14*8-8]
    lea rdx, [r14-1]
    call mono
    emit 10
.n:
    dec r14
    jns .t
    lea rax, [r12-1]
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = how it's said (0, 1 f'(x), 2 dy/dx), rdx = 1 for the second one: the start of
; the answer line
dsay:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    cmp rbx, 1
    jb .the
    je .f
    emit "dy/dx = "
    jmp .r
.f:
    emit "f'"
    test r12, r12
    jz .f1
    emit "'"
.f1:
    emit "(x) = "
    jmp .r
.the:
    emit "The "
    test r12, r12
    jz .t1
    emit "second "
.t1:
    emit "derivative is "
.r:
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; the derivative of a polynomial, its value at a point, or the second derivative
deriv_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72
    mov byte [letter], 'x'
    xor ecx, ecx
    mov edx, 9
    call rnd
    mov r15, rax                ; 0-5 the derivative, 6-7 at a point, 8-9 the second
    ; the degree, and how big the coefficients get
    mov ecx, 2
    mov edx, 5
    mov r13d, 12
    cmp r15, 6
    jb .deg
    mov ecx, 2
    mov edx, 3
    mov r13d, 9
    cmp r15, 8
    jb .deg
    mov ecx, 3
    mov edx, 5
    mov r13d, 12
.deg:
    call rnd
    mov r12, rax
.terms:
    xor ebx, ebx
.c:
    lea rax, [pa]
    mov qword [rax+rbx*8], 0
    cmp rbx, r12
    je .lead
    xor ecx, ecx                ; each lower power in 2 times out of 3
    mov edx, 2
    call rnd
    test eax, eax
    jz .cn
.lead:
    mov rcx, r13
    neg rcx
    mov rdx, r13
    call rnd
    test rax, rax
    jz .lead
    lea rcx, [pa]
    mov [rcx+rbx*8], rax
.cn:
    inc rbx
    cmp rbx, r12
    jbe .c
    xor eax, eax                ; two terms at least
    xor ecx, ecx
.cnt:
    lea rdx, [pa]
    cmp qword [rdx+rcx*8], 0
    je .cnt1
    inc eax
.cnt1:
    inc rcx
    cmp rcx, r12
    jbe .cnt
    cmp eax, 2
    jb .terms
    ; the question
    mov [rsp+32], rdi
    lea rdi, [qbuf]
    lea rcx, [pa]
    mov rdx, r12
    call ppoly
    mov byte [rdi], 0
    mov rdi, [rsp+32]
    lea rax, [qbuf]
    mov [fi], rax
    lea rcx, [qdv]
    mov edx, 6
    cmp r15, 6
    jb .q
    lea rcx, [qdt]
    mov edx, 3
    cmp r15, 8
    jb .qp
    lea rcx, [qd2]
.q:
    mov [rsp+40], rcx
    lea rdx, [rdx-1]
    xor ecx, ecx
    call rnd
    shl rax, 4
    add rax, [rsp+40]
    mov rcx, [rax+8]
    mov [rsp+48], rcx           ; how the answer is said
    lea rcx, [rax]
    mov edx, 1
    call askt
    jmp .a
.qp:
    mov [rsp+40], rcx
.qx:
    mov rcx, -3
    mov edx, 3
    call rnd
    test rax, rax
    jz .qx
    mov r14, rax                ; x
    mov [fn], rax
    xor ecx, ecx
    mov edx, 2
    call rnd
    shl rax, 4
    add rax, [rsp+40]
    mov rcx, [rax+8]
    mov [rsp+48], rcx
    lea rcx, [rax]
    mov edx, 1
    call askt
.a:
    emit "assistant: Take each term on its own: ax^n becomes (n × a)x^(n - 1), and a number on its own becomes 0.", 10
    lea rcx, [pa]
    mov rdx, r12
    lea r8, [pb]
    call dterms
    mov rbx, rax                ; the derivative's degree
    cmp r15, 6
    jb .one
    cmp r15, 8
    jae .two
    ; at a point
    emit "f'(x) = "
    lea rcx, [pb]
    mov rdx, rbx
    call ppoly
    emit 10
    emit "Put x = "
    sint r14
    emit " in, one term at a time, then add them up.", 10
    call dval
    mov rbx, rax
    cmp qword [rsp+48], 1
    je .fv
    emit "The slope is "
    sint rbx
    emit ".", 10
    jmp .r
.fv:
    emit "f'("
    sint r14
    emit ") = "
    sint rbx
    emit 10
    jmp .r
.one:
    mov rcx, [rsp+48]
    xor edx, edx
    call dsay
    lea rcx, [pb]
    mov rdx, rbx
    call ppoly
    cmp qword [rsp+48], 0
    jne .nl
    emit "."
.nl:
    emit 10
    jmp .r
.two:
    emit "So the first derivative is "
    lea rcx, [pb]
    mov rdx, rbx
    call ppoly
    emit ". Now the same again:", 10
    lea rcx, [pb]
    mov rdx, rbx
    lea r8, [pc2]
    call dterms
    mov rbx, rax
    mov rcx, [rsp+48]
    mov edx, 1
    call dsay
    lea rcx, [pc2]
    mov rdx, rbx
    call ppoly
    cmp qword [rsp+48], 0
    jne .nl
    emit "."
    jmp .nl
.r:
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; deriv_one's derivative pb (degree rbx) at x = r14, a line a term, then the sum.
; rax = the value
dval:
    push rbx
    push rsi
    push r12
    push r13
    push r15
    sub rsp, 48
    xor r13d, r13d              ; values so far
    mov r12, rbx                ; the power
.t:
    lea rax, [pb]
    mov r15, [rax+r12*8]
    test r15, r15
    jz .n
    test r12, r12
    jnz .tx
    lea rax, [vals]
    mov [rax+r13*8], r15
    inc r13
    jmp .n
.tx:
    mov rcx, r15
    mov rdx, r12
    call mono
    emit " = "
    sint r15
    emit " × "
    cmp r12, 1
    ja .pw
    pint r14
    emit " = "
    mov rax, r15
    imul rax, r14
    jmp .tv
.pw:
    test r14, r14
    jns .pp
    mov byte [rdi], '('
    inc rdi
    sint r14
    mov byte [rdi], ')'
    inc rdi
    jmp .pe
.pp:
    num r14
.pe:
    emit "^"
    num r12
    emit " = "
    sint r15
    emit " × "
    mov rax, r14
    mov rcx, r12
.xk:
    dec rcx
    jz .xd
    imul rax, r14
    jmp .xk
.xd:
    mov [rsp+32], rax
    pint rax
    emit " = "
    mov rax, [rsp+32]
    imul rax, r15
.tv:
    lea rcx, [vals]
    mov [rcx+r13*8], rax
    inc r13
    sint rax
    emit 10
.n:
    dec r12
    jns .t
    mov r15, [vals]
    mov ebx, 1
.s:
    cmp rbx, r13
    jae .fin
    sint r15
    emit " + "
    lea rax, [vals]
    pint [rax+rbx*8]
    emit " = "
    lea rax, [vals]
    add r15, [rax+rbx*8]
    sint r15
    emit 10
    inc rbx
    jmp .s
.fin:
    mov rax, r15
    add rsp, 48
    pop r15
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret
