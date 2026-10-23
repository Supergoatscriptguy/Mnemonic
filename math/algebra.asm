; mathgen's algebra, besides what's in mathgen.asm: two equations at once, expanding
; brackets, collecting like terms, putting a number into a polynomial, and quadratic
; equations, by factoring or by the formula
default rel
bits 64
%include "lib.inc"
%include "math/math.inc"

section .rdata
sq0 db "Solve the system: ", 0
sq1 db "Solve ", 0
sq2 db "Find x and y if ", 0
sq3 db "Solve for x and y: ", 0
oand   db " and ", 0
ocomma db ", ", 0
sq     db "?", 0
sdot   db ".", 0
align 8
qsys dq sq0, oand, sdot,  sq1, oand, sdot,  sq2, oand, sdot,  sq3, ocomma, sdot
NQSYS equ 4

ex0 db "Expand ", 0
ex1 db "Multiply out ", 0
ex2 db "What is ", 0
ex3 db "Expand and simplify ", 0
exs db " expanded?", 0
align 8
qexp dq ex0, sdot,  ex1, sdot,  ex2, exs,  ex3, sdot
NQEXP equ 4
ds0 db "Simplify ", 0
ds1 db "Multiply out and simplify ", 0
align 8
qdist dq ex3, sdot,  ds0, sdot,  ds1, sdot
NQDIST equ 3

lk0 db "Collect like terms: ", 0
lk1 db "Combine the like terms in ", 0
lks db " simplified?", 0
align 8
qlike dq ds0, sdot,  lk0, sdot,  lk1, sdot,  ex2, lks
NQLIKE equ 4

qe0 db "Solve ", 0
qe1 db "Find x if ", 0
qe2 db "What are the solutions of ", 0
qe3 db "Solve for x: ", 0
align 8
qqeq dq qe0, sdot,  qe1, sdot,  qe2, sq,  qe3, sdot
NQQEQ equ 4

ev0 db "What is ", 0
ev1 db "Evaluate ", 0
ev2 db "Find the value of ", 0
evw db " when ", 0
evf db " for ", 0
s_xsq  db "^2 terms: ", 0
s_xs   db " terms: ", 0
s_nums db "numbers: ", 0

section .bss
alignb 8
eqs   resq 6                    ; a1 b1 c1 a2 b2 c2
sc    resq 6                    ; the same, scaled so the y's match
sx    resq 1
sy    resq 1
sm    resq 2
lc    resq 6                    ; like terms: coefficient, power
lp    resq 6
vals  resq 4

section .text

global sys_one, expand_one, like_one, evalp_one, qeq_one

; rcx = lo, rdx = hi: a random number in [lo, hi] that isn't 0
nzr:
    push rbx
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
.l:
    mov rcx, rbx
    mov rdx, r12
    call rnd
    test rax, rax
    jz .l
    add rsp, 40
    pop r12
    pop rbx
    ret

; a random letter for the variable
rletter:
    sub rsp, 40
    xor ecx, ecx
    mov edx, 3
    call rnd
    lea rcx, [letters]
    mov al, [rcx+rax]
    mov [letter], al
    add rsp, 40
    ret

; rcx = |rcx|
%macro absc 0
    mov rax, rcx
    neg rax
    cmovns rcx, rax
%endmacro

; rcx = a, rdx = b, r8 = c: "ax + by = c"
xyeq:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    mov r13, r8
    mov byte [letter], 'x'
    mov rcx, rbx
    mov edx, 1
    call mono
    mov byte [letter], 'y'
    mov rcx, r12
    mov edx, 1
    call sterm
    emit " = "
    sint r13
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = coefficient, dl = the letter, r8 = 1 for brackets when it's negative: 3x, (-3y)
xyterm:
    mov [letter], dl
    mov edx, 1
    test r8, r8
    jnz pmono
    jmp mono

; ax + by = c and dx + ey = f with whole answers from -6 to 6, by getting rid of y
sys_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
.pick:
    mov rcx, -6
    mov edx, 6
    call rnd
    mov [sx], rax
    mov rcx, -6
    mov edx, 6
    call rnd
    mov [sy], rax
    mov rcx, -5
    mov edx, 5
    call nzr
    mov [eqs], rax
    mov rcx, -5
    mov edx, 5
    call nzr
    mov [eqs+8], rax
    mov rcx, -5
    mov edx, 5
    call nzr
    mov [eqs+24], rax
    mov rcx, -5
    mov edx, 5
    call nzr
    mov [eqs+32], rax
    mov rax, [eqs]              ; one answer only
    imul rax, [eqs+32]
    mov rdx, [eqs+24]
    imul rdx, [eqs+8]
    cmp rax, rdx
    je .pick
    mov rax, [eqs]
    imul rax, [sx]
    mov rdx, [eqs+8]
    imul rdx, [sy]
    add rax, rdx
    mov [eqs+16], rax
    mov rax, [eqs+24]
    imul rax, [sx]
    mov rdx, [eqs+32]
    imul rdx, [sy]
    add rax, rdx
    mov [eqs+40], rax
    lea rcx, [qsys]
    mov edx, NQSYS
    call askpre3
    mov [rsp+32], rax
    mov [rsp+40], rdx
    mov rcx, [eqs]
    mov rdx, [eqs+8]
    mov r8, [eqs+16]
    call xyeq
    mov rcx, [rsp+32]
    call emz
    mov rcx, [eqs+24]
    mov rdx, [eqs+32]
    mov r8, [eqs+40]
    call xyeq
    mov rcx, [rsp+40]
    call emz
    emit 10
    emit "assistant: Get rid of y: make its coefficients the same size, then add or subtract the equations.", 10
    emit "(1) "
    mov rcx, [eqs]
    mov rdx, [eqs+8]
    mov r8, [eqs+16]
    call xyeq
    emit 10
    emit "(2) "
    mov rcx, [eqs+24]
    mov rdx, [eqs+32]
    mov r8, [eqs+40]
    call xyeq
    emit 10
    mov rcx, [eqs+8]
    absc
    mov r12, rcx                ; |b1|
    mov rcx, [eqs+32]
    absc
    mov r13, rcx                ; |b2|
    mov rcx, r12
    mov rdx, r13
    call gcd
    mov r14, rax
    mov rax, r13                ; (1) times |b2|/g and (2) times |b1|/g
    xor edx, edx
    div r14
    mov [sm], rax
    mov rax, r12
    xor edx, edx
    div r14
    mov [sm+8], rax
    xor ebx, ebx
    lea r8, [eqs]
    lea r9, [sc]
.sc:
    mov rax, [r8+rbx*8]
    imul rax, [sm]
    mov [r9+rbx*8], rax
    mov rax, [r8+rbx*8+24]
    imul rax, [sm+8]
    mov [r9+rbx*8+24], rax
    inc rbx
    cmp rbx, 3
    jb .sc
    cmp qword [sm], 1
    je .n1
    emit "(1) × "
    num [sm]
    emit ": "
    mov rcx, [sc]
    mov rdx, [sc+8]
    mov r8, [sc+16]
    call xyeq
    emit 10
.n1:
    cmp qword [sm+8], 1
    je .n2
    emit "(2) × "
    num [sm+8]
    emit ": "
    mov rcx, [sc+24]
    mov rdx, [sc+32]
    mov r8, [sc+40]
    call xyeq
    emit 10
.n2:
    mov rax, [sc+8]
    xor rax, [sc+32]
    js .addq
    emit "The y terms are the same, so subtract the equations: "
    mov rcx, [sc]
    mov dl, 'x'
    xor r8d, r8d
    call xyterm
    emit " - "
    mov rcx, [sc+24]
    mov dl, 'x'
    mov r8d, 1
    call xyterm
    emit " = "
    mov r14, [sc]
    sub r14, [sc+24]            ; A
    mov rcx, r14
    mov dl, 'x'
    xor r8d, r8d
    call xyterm
    emit ", and "
    sint [sc+16]
    emit " - "
    pint [sc+40]
    emit " = "
    mov r15, [sc+16]
    sub r15, [sc+40]            ; C
    sint r15
    jmp .ax
.addq:
    emit "The y terms have opposite signs, so add the equations: "
    mov rcx, [sc]
    mov dl, 'x'
    xor r8d, r8d
    call xyterm
    emit " + "
    mov rcx, [sc+24]
    mov dl, 'x'
    mov r8d, 1
    call xyterm
    emit " = "
    mov r14, [sc]
    add r14, [sc+24]
    mov rcx, r14
    mov dl, 'x'
    xor r8d, r8d
    call xyterm
    emit ", and "
    sint [sc+16]
    emit " + "
    pint [sc+40]
    emit " = "
    mov r15, [sc+16]
    add r15, [sc+40]
    sint r15
.ax:
    emit ".", 10
    cmp r14, 1                  ; Ax = C
    jne .xd
    emit "So x = "
    sint r15
    emit ".", 10
    jmp .back
.xd:
    mov rcx, r14
    mov dl, 'x'
    xor r8d, r8d
    call xyterm
    emit " = "
    sint r15
    emit ", so x = "
    sint r15
    emit " ÷ "
    pint r14
    emit " = "
    sint [sx]
    emit 10
.back:
    emit "Put x = "
    sint [sx]
    emit " into (1): "
    sint [eqs]
    emit " × "
    pint [sx]
    mov byte [letter], 'y'
    mov rcx, [eqs+8]
    mov edx, 1
    call sterm
    emit " = "
    sint [eqs+16]
    emit ", so "
    mov r14, [eqs]
    imul r14, [sx]              ; a1 x
    sint r14
    mov rcx, [eqs+8]
    mov edx, 1
    call sterm
    emit " = "
    sint [eqs+16]
    emit 10
    mov rcx, [eqs+8]
    mov dl, 'y'
    xor r8d, r8d
    call xyterm
    emit " = "
    sint [eqs+16]
    emit " - "
    pint r14
    emit " = "
    mov r15, [eqs+16]
    sub r15, r14
    sint r15
    cmp qword [eqs+8], 1
    je .y1
    emit ", so y = "
    sint r15
    emit " ÷ "
    pint [eqs+8]
    emit " = "
    sint [sy]
.y1:
    emit 10
    emit "Check with (2): "
    sint [eqs+24]
    emit " × "
    pint [sx]
    emit " + "
    pint [eqs+32]
    emit " × "
    pint [sy]
    emit " = "
    mov rax, [eqs+24]
    imul rax, [sx]
    sint rax
    emit " + "
    mov rax, [eqs+32]
    imul rax, [sy]
    pint rax
    emit " = "
    sint [eqs+40]
    emit 10
    emit "x = "
    sint [sx]
    emit ", y = "
    sint [sy]
    emit 10
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; (ax + b)(cx + d) from rbx, r12, r13, r14, or (ax + b)^2 when r15 = 1
%macro pfoil 0
    mov byte [rdi], '('
    inc rdi
    mov rcx, rbx
    mov rdx, r12
    call lin
    mov byte [rdi], ')'
    inc rdi
    test r15, r15
    jz %%two
    emit "^2"
    jmp %%e
%%two:
    mov byte [rdi], '('
    inc rdi
    mov rcx, r13
    mov rdx, r14
    call lin
    mov byte [rdi], ')'
    inc rdi
%%e:
%endmacro

; k(ax + b) + m(cx + d) from rbx = k, r12 = a, r13 = b, r14 = m, r15 = c, [rsp+40] = d
%macro pdist 0
    sint rbx
    mov byte [rdi], '('
    inc rdi
    mov rcx, r12
    mov rdx, r13
    call lin
    mov byte [rdi], ')'
    inc rdi
    test r14, r14
    js %%neg
    emit " + "
    mov rcx, r14
    jmp %%m
%%neg:
    emit " - "
    mov rcx, r14
    neg rcx
%%m:
    num rcx
    mov byte [rdi], '('
    inc rdi
    mov rcx, r15
    mov rdx, [rsp+40]
    call lin
    mov byte [rdi], ')'
    inc rdi
%endmacro

; rcx = a sum of like terms, rdx = its power: the term, or 0 when they cancelled
psum:
    test rcx, rcx
    jnz mono
    mov byte [rdi], '0'
    inc rdi
    ret

; (ax + b)(cx + d) term by term, or k(ax + b) + m(cx + d) a third of the time
expand_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88
    call rletter
    xor ecx, ecx
    mov edx, 2
    call rnd
    cmp eax, 2
    je .dist
    mov ecx, 1
    mov edx, 4
    call rnd
    mov rbx, rax                ; a
    xor ecx, ecx
    mov edx, 4
    call rnd
    test eax, eax
    jnz .b
    neg rbx
.b:
    mov rcx, -9
    mov edx, 9
    call nzr
    mov r12, rax                ; b
    mov r13, rbx
    mov r14, r12
    mov r15d, 1
    xor ecx, ecx
    mov edx, 4
    call rnd
    test eax, eax
    jz .q                       ; a square
    xor r15d, r15d
    mov ecx, 1
    mov edx, 4
    call rnd
    mov r13, rax                ; c
    xor ecx, ecx
    mov edx, 4
    call rnd
    test eax, eax
    jnz .d
    neg r13
.d:
    mov rcx, -9
    mov edx, 9
    call nzr
    mov r14, rax                ; d
.q:
    lea rcx, [qexp]
    mov edx, NQEXP
    call askpre
    mov [rsp+32], rax
    pfoil
    mov rcx, [rsp+32]
    call emz
    emit 10
    emit "assistant: Multiply each term in the first bracket by each term in the second, then collect like terms.", 10
    test r15, r15
    jz .terms
    pfoil
    emit " = ("
    mov rcx, rbx
    mov rdx, r12
    call lin
    emit ")("
    mov rcx, rbx
    mov rdx, r12
    call lin
    emit ")", 10
.terms:
    mov rax, rbx
    imul rax, r13
    mov [rsp+40], rax           ; ac
    mov rax, rbx
    imul rax, r14
    mov [rsp+48], rax           ; ad
    mov rax, r12
    imul rax, r13
    mov [rsp+56], rax           ; bc
    mov rax, r12
    imul rax, r14
    mov [rsp+64], rax           ; bd
    mov rcx, rbx
    mov edx, 1
    call mono
    emit " × "
    mov rcx, r13
    mov edx, 1
    call pmono
    emit " = "
    mov rcx, [rsp+40]
    mov edx, 2
    call mono
    emit 10
    mov rcx, rbx
    mov edx, 1
    call mono
    emit " × "
    pint r14
    emit " = "
    mov rcx, [rsp+48]
    mov edx, 1
    call mono
    emit 10
    sint r12
    emit " × "
    mov rcx, r13
    mov edx, 1
    call pmono
    emit " = "
    mov rcx, [rsp+56]
    mov edx, 1
    call mono
    emit 10
    sint r12
    emit " × "
    pint r14
    emit " = "
    sint [rsp+64]
    emit 10
    mov rcx, [rsp+40]
    mov edx, 2
    call mono
    mov rcx, [rsp+48]
    mov edx, 1
    call sterm
    mov rcx, [rsp+56]
    mov edx, 1
    call sterm
    mov rcx, [rsp+64]
    xor edx, edx
    call sterm
    emit 10
    mov rcx, [rsp+48]
    mov edx, 1
    call mono
    emit " + "
    mov rcx, [rsp+56]
    mov edx, 1
    call pmono
    emit " = "
    mov rcx, [rsp+48]
    add rcx, [rsp+56]
    mov edx, 1
    call psum
    emit 10
    pfoil
    emit " = "
    mov rax, [rsp+40]
    mov [cf], rax
    mov rax, [rsp+48]
    add rax, [rsp+56]
    mov [cf+8], rax
    mov rax, [rsp+64]
    mov [cf+16], rax
    lea rcx, [cf]
    mov edx, 2
    call poly
    emit 10
    jmp .r
.dist:
    mov ecx, 2
    mov edx, 9
    call rnd
    mov rbx, rax                ; k
    xor ecx, ecx
    mov edx, 2
    call rnd
    test eax, eax
    jnz .a
    neg rbx
.a:
    mov ecx, 1
    mov edx, 6
    call rnd
    mov r12, rax                ; a
    mov rcx, -9
    mov edx, 9
    call nzr
    mov r13, rax                ; b
    mov ecx, 2
    mov edx, 9
    call rnd
    mov r14, rax                ; m
    call coin
    test eax, eax
    jz .c
    neg r14
.c:
    mov ecx, 1
    mov edx, 6
    call rnd
    mov r15, rax                ; c
    mov rcx, -9
    mov edx, 9
    call nzr
    mov [rsp+40], rax           ; d
    lea rcx, [qdist]
    mov edx, NQDIST
    call askpre
    mov [rsp+32], rax
    pdist
    mov rcx, [rsp+32]
    call emz
    emit 10
    emit "assistant: Multiply out each bracket, then collect like terms.", 10
    mov rax, rbx
    imul rax, r12
    mov [rsp+48], rax           ; ka
    mov rax, rbx
    imul rax, r13
    mov [rsp+56], rax           ; kb
    mov rax, r14
    imul rax, r15
    mov [rsp+64], rax           ; mc
    mov rax, r14
    imul rax, [rsp+40]
    mov [rsp+72], rax           ; md
    sint rbx
    emit " × "
    mov rcx, r12
    mov edx, 1
    call pmono
    emit " = "
    mov rcx, [rsp+48]
    mov edx, 1
    call mono
    emit ", "
    sint rbx
    emit " × "
    pint r13
    emit " = "
    sint [rsp+56]
    emit 10
    sint r14
    emit " × "
    mov rcx, r15
    mov edx, 1
    call pmono
    emit " = "
    mov rcx, [rsp+64]
    mov edx, 1
    call mono
    emit ", "
    sint r14
    emit " × "
    pint [rsp+40]
    emit " = "
    sint [rsp+72]
    emit 10
    mov rcx, [rsp+48]
    mov edx, 1
    call mono
    mov rcx, [rsp+56]
    xor edx, edx
    call sterm
    mov rcx, [rsp+64]
    mov edx, 1
    call sterm
    mov rcx, [rsp+72]
    xor edx, edx
    call sterm
    emit 10
    mov rcx, [rsp+48]
    mov edx, 1
    call mono
    emit " + "
    mov rcx, [rsp+64]
    mov edx, 1
    call pmono
    emit " = "
    mov rcx, [rsp+48]
    add rcx, [rsp+64]
    mov edx, 1
    call psum
    emit 10
    sint [rsp+56]
    emit " + "
    pint [rsp+72]
    emit " = "
    mov rax, [rsp+56]
    add rax, [rsp+72]
    sint rax
    emit 10
    pdist
    emit " = "
    mov rcx, [rsp+48]
    add rcx, [rsp+64]
    mov rdx, [rsp+56]
    add rdx, [rsp+72]
    call lin
    emit 10
.r:
    add rsp, 88
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; r12 = how many terms: the lc/lp terms as written, 3x - 5 + x^2 ...
plike:
    push rbx
    push rsi
    sub rsp, 40
    mov rcx, [lc]
    mov rdx, [lp]
    call mono
    mov ebx, 1
.l:
    cmp rbx, r12
    jae .r
    lea rax, [lc]
    mov rcx, [rax+rbx*8]
    lea rax, [lp]
    mov rdx, [rax+rbx*8]
    call sterm
    inc rbx
    jmp .l
.r:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; 3-6 terms in x^2, x and plain numbers, mixed up, to collect
like_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    call rletter
.pick:
    mov ecx, 3
    mov edx, 6
    call rnd
    mov r12, rax
    xor ebx, ebx
.t:
    mov rcx, -9
    mov edx, 9
    call nzr
    lea rcx, [lc]
    mov [rcx+rbx*8], rax
    xor ecx, ecx
    mov edx, 2
    call rnd
    lea rcx, [lp]
    mov [rcx+rbx*8], rax
    inc rbx
    cmp rbx, r12
    jb .t
    mov qword [rsp+32], 0       ; how many of each power
    mov qword [rsp+40], 0
    mov qword [rsp+48], 0
    xor ebx, ebx
.cnt:
    lea rax, [lp]
    mov rax, [rax+rbx*8]
    inc qword [rsp+32+rax*8]
    inc rbx
    cmp rbx, r12
    jb .cnt
    cmp qword [rsp+32], 2       ; something to collect
    jae .q
    cmp qword [rsp+40], 2
    jae .q
    cmp qword [rsp+48], 2
    jb .pick
.q:
    lea rcx, [qlike]
    mov edx, NQLIKE
    call askpre
    mov r15, rax
    call plike
    mov rcx, r15
    call emz
    emit 10
    emit "assistant: Group the like terms, then add up each group.", 10
    mov r13d, 2                 ; the power
.g:
    xor r14d, r14d              ; the group's sum
    xor r15d, r15d              ; terms in it so far
    xor ebx, ebx
.gt:
    cmp rbx, r12
    jae .gd
    lea rax, [lp]
    cmp [rax+rbx*8], r13
    jne .gn
    lea rax, [lc]
    mov rcx, [rax+rbx*8]
    add r14, rcx
    test r15, r15
    jnz .more
    mov [rsp+40], rcx
    lea rcx, [s_xsq]
    cmp r13, 1
    ja .lab
    lea rcx, [s_xs]
    je .lab
    lea rcx, [s_nums]
.lab:
    cmp r13, 0
    je .lab2
    mov al, [letter]
    mov [rdi], al
    inc rdi
.lab2:
    call emz
    mov rcx, [rsp+40]
    mov rdx, r13
    call mono
    jmp .cnt2
.more:
    mov [rsp+40], rcx
    emit " + "
    mov rcx, [rsp+40]
    mov rdx, r13
    call pmono
.cnt2:
    inc r15
.gn:
    inc rbx
    jmp .gt
.gd:
    cmp r15, 2
    jb .gs
    emit " = "
    mov rcx, r14
    mov rdx, r13
    call psum
.gs:
    test r15, r15
    jz .gz
    emit 10
.gz:
    mov eax, 2
    sub rax, r13
    lea rcx, [cf]
    mov [rcx+rax*8], r14
    dec r13
    jns .g
    call plike
    emit " = "
    lea rcx, [cf]
    mov edx, 2
    call poly
    emit 10
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; a polynomial of degree 1-3 with a number put in for x, term by term
evalp_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    call rletter
.pick:
    mov ecx, 1
    mov edx, 3
    call rnd
    mov r12, rax                ; the degree
    mov edx, 9                  ; how big x gets: 9, 6, 4
    cmp r12, 2
    jb .xr
    mov edx, 6
    je .xr
    mov edx, 4
.xr:
    mov rcx, rdx
    neg rcx
    call nzr
    mov r13, rax                ; x
    mov rcx, -9
    mov edx, 9
    call nzr
    mov [cf], rax
    mov ebx, 1
.c:
    cmp rbx, r12
    ja .cd
    mov rcx, -9
    mov edx, 9
    call rnd
    lea rcx, [cf]
    mov [rcx+rbx*8], rax
    inc rbx
    jmp .c
.cd:
    xor ebx, ebx                ; two terms at least
    xor ecx, ecx
.nz:
    lea rax, [cf]
    cmp qword [rax+rbx*8], 0
    je .z
    inc ecx
.z:
    inc rbx
    cmp rbx, r12
    jbe .nz
    cmp ecx, 2
    jb .pick
    xor ecx, ecx
    mov edx, 3
    call rnd
    mov r15, rax
    emit "user: "
    cmp r15, 3
    jne .q0
    emit "If "
    call letr
    emit " = "
    sint r13
    emit ", what is "
    jmp .p
.q0:
    lea rcx, [ev0]
    cmp r15, 1
    jb .qs
    lea rcx, [ev1]
    je .qs
    lea rcx, [ev2]
.qs:
    call emz
.p:
    lea rcx, [cf]
    mov rdx, r12
    call poly
    cmp r15, 3
    jne .q1
    emit "?", 10
    jmp .a
.q1:
    lea rcx, [evw]
    cmp r15, 1
    jne .qw
    lea rcx, [evf]
.qw:
    call emz
    call letr
    emit " = "
    sint r13
    test r15, r15
    jnz .dot
    emit "?", 10
    jmp .a
.dot:
    emit ".", 10
.a:
    emit "assistant: Put "
    sint r13
    emit " in for "
    call letr
    emit ", one term at a time, then add them up.", 10
    xor r14d, r14d              ; values so far
    xor ebx, ebx
.term:
    cmp rbx, r12
    ja .sum
    lea rax, [cf]
    mov r15, [rax+rbx*8]
    test r15, r15
    jz .tn
    mov rax, r12
    sub rax, rbx
    mov [rsp+32], rax           ; the power
    test rax, rax
    jnz .tx
    lea rax, [vals]
    mov [rax+r14*8], r15        ; a plain number goes straight in
    inc r14
    jmp .tn
.tx:
    mov rcx, r15
    mov rdx, [rsp+32]
    call mono
    emit " = "
    sint r15
    emit " × "
    cmp qword [rsp+32], 1
    ja .pw
    pint r13
    emit " = "
    mov rax, r15
    imul rax, r13
    jmp .tv
.pw:
    test r13, r13
    jns .pp
    mov byte [rdi], '('
    inc rdi
    sint r13
    mov byte [rdi], ')'
    inc rdi
    jmp .pe
.pp:
    num r13
.pe:
    emit "^"
    num [rsp+32]
    emit " = "
    sint r15
    emit " × "
    mov rax, r13                ; x^k
    mov rcx, [rsp+32]
.xk:
    dec rcx
    jz .xd
    imul rax, r13
    jmp .xk
.xd:
    mov [rsp+40], rax
    pint rax
    emit " = "
    mov rax, [rsp+40]
    imul rax, r15
.tv:
    lea rcx, [vals]
    mov [rcx+r14*8], rax
    inc r14
    sint rax
    emit 10
.tn:
    inc rbx
    jmp .term
.sum:
    mov r15, [vals]
    mov ebx, 1
.s:
    cmp rbx, r14
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
    lea rcx, [cf]
    mov rdx, r12
    call poly
    emit " = "
    sint r15
    emit " when "
    call letr
    emit " = "
    sint r13
    emit 10
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = a > 0, rdx = b, r8 = c: b^2, 4ac and b^2 - 4ac a line each (long
; multiplication when they're too big). rax = b^2 - 4ac
qdisc:
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
    mov rcx, r12
    absc
    mov r14, rcx                ; |b|
    emit "b^2 = "
    pint r12
    emit " × "
    pint r12
    mov rcx, r14
    mov rdx, r14
    call mulsmall
    test eax, eax
    jz .bl
    emit " = "
    mov rax, r14
    imul rax, r14
    num rax
    emit 10
    jmp .ac
.bl:
    emit ":", 10
    mov rcx, r14
    mov rdx, r14
    call mulstep
.ac:
    imul r14, r14               ; b^2
    lea r15, [rbx*4]            ; 4a
    emit "4ac = 4 × "
    num rbx
    emit " × "
    pint r13
    emit " = "
    num r15
    emit " × "
    pint r13
    mov rcx, r13
    absc
    mov rdx, rcx
    mov rcx, r15
    call mulsmall
    imul r15, r13               ; 4ac
    test eax, eax
    jz .al
    emit " = "
    sint r15
    emit 10
    jmp .d
.al:
    emit ":", 10
    mov rcx, r13
    absc
    mov rdx, rcx
    lea rcx, [rbx*4]
    call mulstep
    emit "so 4ac = "
    sint r15
    emit 10
.d:
    emit "b^2 - 4ac = "
    num r14
    emit " - "
    pint r15
    emit " = "
    mov rax, r14
    sub rax, r15
    mov r14, rax
    sint rax
    emit 10
    mov rax, r14
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = top (signed), rdx = bottom: "x = " the top over the bottom in lowest terms,
; with simp's working before it. rax = top after, rdx = bottom after
sroot:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    mov rcx, rbx
    absc
    mov rdx, r12
    call simp
    mov r13, rdx
    test rbx, rbx
    jns .p
    neg rax
.p:
    mov rbx, rax
    emit "x = "
    mov rcx, rbx
    mov rdx, r13
    call pfrac
    emit 10
    mov rax, rbx
    mov rdx, r13
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; a quadratic equation = 0: x^2 + bx + c by factoring, ax^2 + bx + c by the formula
; (it factors too, so the root comes out whole), now and then one with no real roots
qeq_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88
    mov byte [letter], 'x'
    xor ecx, ecx
    mov edx, 9
    call rnd
    cmp eax, 4
    jb .fac
    cmp eax, 9
    je .none
    ; (px + q)(rx + s), p and r not both 1
.fp:
    mov ecx, 1
    mov edx, 3
    call rnd
    mov r14, rax
    mov ecx, 1
    mov edx, 3
    call rnd
    mov r15, rax
    mov rax, r14
    imul rax, r15
    cmp rax, 1
    je .fp
    mov rbx, rax                ; a
    mov rcx, -6
    mov edx, 6
    call nzr
    mov [rsp+40], rax           ; q
    mov rcx, -6
    mov edx, 6
    call nzr
    mov [rsp+48], rax           ; s
    mov r12, r14
    imul r12, [rsp+48]
    mov rax, [rsp+40]
    imul rax, r15
    add r12, rax                ; b = ps + qr
    mov r13, [rsp+40]
    imul r13, [rsp+48]          ; c = qs
    call qask
    call qintro
    mov rcx, rbx
    mov rdx, r12
    mov r8, r13
    call qdisc
    mov r14, rax
    lea r15, [rbx+rbx]          ; 2a
    test r14, r14
    jnz .two
    emit "That's 0, so there's just one answer: x = "
    mov rax, r12
    neg rax
    sint rax
    emit "/"
    num r15
    emit 10
    mov rcx, r12
    neg rcx
    mov rdx, r15
    call sroot
    jmp .r
.two:
    xor eax, eax                ; its square root, a whole number
.sq:
    lea rcx, [rax+1]
    imul rcx, rcx
    cmp rcx, r14
    ja .sqd
    inc rax
    jmp .sq
.sqd:
    mov [rsp+56], rax           ; k
    emit "√"
    num r14
    emit " = "
    num [rsp+56]
    emit ", since "
    num [rsp+56]
    emit " × "
    num [rsp+56]
    emit " = "
    num r14
    emit 10
    emit "2a = 2 × "
    num rbx
    emit " = "
    num r15
    emit 10
    emit "x = ("
    mov rax, r12
    neg rax
    sint rax
    emit " + "
    num [rsp+56]
    emit ")/"
    num r15
    emit " = "
    mov rcx, r12
    neg rcx
    add rcx, [rsp+56]
    mov [rsp+64], rcx
    sint rcx
    emit "/"
    num r15
    emit 10
    mov rcx, [rsp+64]
    mov rdx, r15
    call sroot
    mov [rsp+40], rax
    mov [rsp+48], rdx
    emit "x = ("
    mov rax, r12
    neg rax
    sint rax
    emit " - "
    num [rsp+56]
    emit ")/"
    num r15
    emit " = "
    mov rcx, r12
    neg rcx
    sub rcx, [rsp+56]
    mov [rsp+64], rcx
    sint rcx
    emit "/"
    num r15
    emit 10
    mov rcx, [rsp+64]
    mov rdx, r15
    call sroot
    mov [rsp+64], rax
    mov [rsp+72], rdx
    emit "x = "
    mov rcx, [rsp+40]
    mov rdx, [rsp+48]
    call pfrac
    emit " or x = "
    mov rcx, [rsp+64]
    mov rdx, [rsp+72]
    call pfrac
    emit 10
    jmp .r
.none:
    mov ecx, 1                  ; b^2 < 4ac
    mov edx, 5
    call rnd
    mov rbx, rax
    mov rcx, -9
    mov edx, 9
    call rnd
    mov r12, rax
    mov ecx, 1
    mov edx, 9
    call rnd
    mov r13, rax
    mov rax, r12
    imul rax, r12
    mov rcx, rbx
    imul rcx, r13
    shl rcx, 2
    cmp rax, rcx
    jae .none
    call qask
    call qintro
    mov rcx, rbx
    mov rdx, r12
    mov r8, r13
    call qdisc
    emit "That's negative, and a negative number has no real square root.", 10
    emit "There are no real solutions.", 10
    jmp .r
.fac:
    mov rcx, -12
    mov edx, 12
    call nzr
    mov r14, rax
    mov rcx, -12
    mov edx, 12
    call nzr
    lea r12, [r14+rax]          ; b
    imul rax, r14
    mov r13, rax                ; c
    mov ebx, 1
    call qask
    emit "assistant: Factor the left side, then set each bracket to 0.", 10
    mov rcx, r12
    mov rdx, r13
    call quadwork
    mov r14, rax
    mov r15, rdx
    emit "So "
    mov rcx, r14
    mov rdx, r15
    call twobin
    emit " = 0, which means x"
    mov rcx, r14
    xor edx, edx
    call sterm
    emit " = 0"
    cmp r14, r15
    je .one
    emit " or x"
    mov rcx, r15
    xor edx, edx
    call sterm
    emit " = 0"
.one:
    emit ".", 10
    emit "x = "
    mov rax, r14
    neg rax
    sint rax
    cmp r14, r15
    je .eol
    emit " or x = "
    mov rax, r15
    neg rax
    sint rax
.eol:
    emit 10
.r:
    add rsp, 88
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; the question for ax^2 + bx + c = 0, from rbx, r12, r13
qask:
    push rsi
    sub rsp, 48
    mov [cf], rbx
    mov [cf+8], r12
    mov [cf+16], r13
    lea rcx, [qqeq]
    mov edx, NQQEQ
    call askpre
    mov [rsp+32], rax
    lea rcx, [cf]
    mov edx, 2
    call poly
    emit " = 0"
    mov rcx, [rsp+32]
    call emz
    emit 10
    add rsp, 48
    pop rsi
    ret

; "assistant: use the formula, with a, b and c" from rbx, r12, r13
qintro:
    push rsi
    sub rsp, 32
    emit "assistant: Use the quadratic formula, x = (-b ± √(b^2 - 4ac))/2a, with a = "
    num rbx
    emit ", b = "
    sint r12
    emit " and c = "
    sint r13
    emit ".", 10
    add rsp, 32
    pop rsi
    ret
