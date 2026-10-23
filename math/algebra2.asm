; more of mathgen's algebra: inequalities, arithmetic and geometric sequences, slopes
; and lines through two points, factoring (common factors, ax^2 + bx + c by splitting
; the middle term, differences of squares), absolute values, and b^x = n
default rel
bits 64
%include "lib.inc"
%include "math/math.inc"

section .rdata
sq   db "?", 0
sdot db ".", 0
i0 db " < ", 0
i1 db " > ", 0
i2 db " ≤ ", 0
i3 db " ≥ ", 0
align 8
iops dq i0, i1, i2, i3          ; op ^ 1 flips it
qi0 db "Solve ", 0
qi1 db "Find all x with ", 0
qi2 db "For which x is ", 0
qi3 db "Solve the inequality ", 0
align 8
qineq dq qi0, sdot,  qi1, sdot,  qi2, sq,  qi3, sdot
NQINEQ equ 4
qs0 db "What is the ", 0
qs1 db "Find the ", 0
qss0 db " term of the sequence ", 0
qss1 db " term of ", 0
qf0 db "Factor ", 0
qf1 db "Factor out the greatest common factor: ", 0
qf2 db "Take out the common factor in ", 0
align 8
qgcf dq qf0, sdot,  qf1, sdot,  qf2, sdot
NQGCF equ 3

section .bss
alignb 8
tc    resq 4                    ; gcf terms: coefficients
tpw   resq 4                    ;  and powers
pq    resq 3                    ; the quadratic being factored (lin overwrites cf)

section .text

global ineq_one, seq_one, line_one, fac2_one, abs_one, expeq_one

; rcx = lo, rdx = hi: a random number in [lo, hi] that isn't 0
nz:
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

; rcx = n: 1st, 2nd, 3rd, 4th, 11th, 12th, 13th, 21st ...
ord:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    num rbx
    mov rax, rbx
    xor edx, edx
    mov ecx, 100
    div rcx
    cmp rdx, 11                 ; 11-13 are all th
    jb .d
    cmp rdx, 13
    jbe .th
.d:
    mov rax, rdx
    xor edx, edx
    mov ecx, 10
    div rcx
    cmp rdx, 1
    je .st
    cmp rdx, 2
    je .nd
    cmp rdx, 3
    je .rd
.th:
    emit "th"
    jmp .r
.st:
    emit "st"
    jmp .r
.nd:
    emit "nd"
    jmp .r
.rd:
    emit "rd"
.r:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; |rcx|
%macro absc 0
    mov rax, rcx
    neg rax
    cmovns rcx, rax
%endmacro

; ax + b op c, a and b not 0 and |a| at least 2, the answer's edge a whole number
ineq_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    mov byte [letter], 'x'
.a:
    mov rcx, -9
    mov edx, 9
    call nz
    cmp rax, 1
    je .a
    cmp rax, -1
    je .a
    mov rbx, rax                ; a
    mov rcx, -20
    mov edx, 20
    call nz
    mov r12, rax                ; b
    mov rcx, -12
    mov edx, 12
    call rnd
    mov r13, rax                ; the edge
    mov r14, rbx
    imul r14, r13
    add r14, r12                ; c
    xor ecx, ecx
    mov edx, 3
    call rnd
    mov r15, rax                ; the op
    lea rcx, [qineq]
    mov edx, NQINEQ
    call askpre
    mov [rsp+32], rax
    mov rcx, rbx
    mov rdx, r12
    call lin
    lea rax, [iops]
    mov rcx, [rax+r15*8]
    call emz
    sint r14
    mov rcx, [rsp+32]
    call emz
    emit 10
    emit "assistant: Solve it like an equation, but flip the sign if you multiply or divide by a negative number.", 10
    mov rax, r14
    sub rax, r12
    mov [rsp+40], rax           ; what ax is up against
    test r12, r12
    js .add
    emit "Subtract "
    num r12
    emit " from both sides: "
    call axop
    sint r14
    emit " - "
    num r12
    jmp .bd
.add:
    emit "Add "
    mov rax, r12
    neg rax
    mov [rsp+48], rax
    num rax
    emit " to both sides: "
    call axop
    sint r14
    emit " + "
    num [rsp+48]
.bd:
    emit " = "
    sint [rsp+40]
    emit 10
    emit "Divide both sides by "
    sint rbx
    test rbx, rbx
    jns .pos
    emit ", and flip the sign since that's negative"
    xor r15, 1
.pos:
    emit ": x"
    lea rax, [iops]
    mov rcx, [rax+r15*8]
    call emz
    sint [rsp+40]
    emit " ÷ "
    pint rbx
    emit " = "
    sint r13
    emit 10
    emit "x"
    lea rax, [iops]
    mov rcx, [rax+r15*8]
    call emz
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

; "ax op " from ineq_one's rbx and r15
axop:
    push rsi
    sub rsp, 32
    mov rcx, rbx
    mov edx, 1
    call mono
    lea rax, [iops]
    mov rcx, [rax+r15*8]
    call emz
    add rsp, 32
    pop rsi
    ret

; the nth term of an arithmetic sequence, or of a geometric one a third of the time
seq_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    xor ecx, ecx
    mov edx, 2
    call rnd
    mov r15, rax                ; 2 = geometric
    cmp r15, 2
    je .geo
    mov rcx, -20
    mov edx, 50
    call rnd
    mov rbx, rax                ; first
    mov rcx, -9
    mov edx, 12
    call nz
    mov r12, rax                ; step
    mov ecx, 5
    mov edx, 60
    call rnd
    mov r13, rax                ; n
    jmp .q
.geo:
    mov ecx, 1
    mov edx, 9
    call rnd
    mov rbx, rax
    mov ecx, 2
    mov edx, 5
    call rnd
    mov r12, rax                ; ratio
    mov ecx, 4
    mov edx, 10
    call rnd
    mov r13, rax
.gn:
    mov rax, rbx                ; the term stays under a million
    mov rcx, r13
.gp:
    dec rcx
    jz .gd
    imul rax, r12
    jmp .gp
.gd:
    cmp rax, 1000000
    jbe .q
    dec r13
    jmp .gn
.q:
    call coin
    mov [rsp+32], rax
    emit "user: "
    lea rcx, [qs0]
    cmp qword [rsp+32], 0
    je .q1
    lea rcx, [qs1]
.q1:
    call emz
    mov rcx, r13
    call ord
    lea rcx, [qss0]
    cmp qword [rsp+32], 0
    je .q2
    lea rcx, [qss1]
.q2:
    call emz
    xor r14d, r14d              ; the first four terms
    mov rax, rbx
.t:
    mov [rsp+40], rax
    sint rax
    emit ", "
    mov rax, [rsp+40]
    cmp r15, 2
    je .tg
    add rax, r12
    jmp .tn
.tg:
    imul rax, r12
.tn:
    inc r14
    cmp r14, 4
    jb .t
    emit "..."
    lea rcx, [sq]
    cmp qword [rsp+32], 0
    je .q3
    lea rcx, [empty]
.q3:
    call emz
    emit 10
    emit "assistant: "
    cmp r15, 2
    je .ga
    ; arithmetic: first + (n - 1) × step
    lea rax, [rbx+r12]
    mov [rsp+40], rax
    emit "Each term changes by the same amount: "
    sint [rsp+40]
    emit " - "
    pint rbx
    emit " = "
    sint r12
    emit ". So term n is "
    sint rbx
    emit " + (n - 1) × "
    pint r12
    emit ".", 10
    call nless
    mov rcx, r12
    absc
    mov rdx, rcx
    lea rcx, [r13-1]
    call mulstep
    mov r14, rax
    test r12, r12
    jns .ap
    neg r14
    emit "so "
    lea rax, [r13-1]
    num rax
    emit " × "
    pint r12
    emit " = "
    sint r14
    emit 10
.ap:
    sint rbx
    emit " + "
    pint r14
    emit " = "
    add r14, rbx
    sint r14
    emit 10
    jmp .fin
.ga:
    lea rax, [rbx]
    imul rax, r12
    mov [rsp+40], rax
    emit "Each term is the one before times the same number: "
    num [rsp+40]
    emit " ÷ "
    num rbx
    emit " = "
    num r12
    emit ". So term n is "
    num rbx
    emit " × "
    num r12
    emit "^(n - 1).", 10
    call nless
    lea r14, [r13-1]            ; r^(n-1) as a chain of products
    mov rax, r12
    mov [rsp+40], r14
.gc:
    dec qword [rsp+40]
    jz .gcd
    mov rcx, rax
    mov rdx, r12
    call mulstep
    jmp .gc
.gcd:
    mov [rsp+48], rax
    num r12
    emit "^"
    num r14
    emit " = "
    num [rsp+48]
    emit 10
    mov rcx, rbx
    mov rdx, [rsp+48]
    call mulstep
    mov r14, rax
.fin:
    emit "The "
    mov rcx, r13
    call ord
    emit " term is "
    sint r14
    emit ".", 10
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; "For the 25th term, n - 1 = 24." from seq_one's r13
nless:
    push rsi
    sub rsp, 32
    emit "For the "
    mov rcx, r13
    call ord
    emit " term, n - 1 = "
    lea rax, [r13-1]
    num rax
    emit ".", 10
    add rsp, 32
    pop rsi
    ret

; the point (rcx, rdx) at rdi
point:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    mov byte [rdi], '('
    inc rdi
    sint rbx
    emit ", "
    sint r12
    mov byte [rdi], ')'
    inc rdi
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; the slope through two points, or the line y = mx + b through them
line_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72
    mov byte [letter], 'x'
    call coin
    mov [rsp+64], rax           ; 1 = the whole line
.px:
    mov rcx, -9
    mov edx, 9
    call rnd
    mov rbx, rax                ; x1
    mov rcx, -9
    mov edx, 9
    call rnd
    mov r13, rax                ; x2
    cmp rbx, r13
    je .px
    cmp qword [rsp+64], 0
    jne .ln
    mov rcx, -12
    mov edx, 12
    call rnd
    mov r12, rax                ; y1
    mov rcx, -12
    mov edx, 12
    call rnd
    mov r14, rax                ; y2
    emit "user: "
    call coin
    test eax, eax
    jz .s2
    emit "What is the slope of the line through "
    call pts
    emit "?", 10
    jmp .sa
.s2:
    emit "Find the slope between "
    call pts
    emit ".", 10
    jmp .sa
.ln:
    mov rcx, -5
    mov edx, 5
    call nz
    mov [rsp+40], rax           ; m
    mov rcx, -10
    mov edx, 10
    call rnd
    mov [rsp+48], rax           ; b
    mov r12, rbx
    imul r12, [rsp+40]
    add r12, rax
    mov r14, r13
    imul r14, [rsp+40]
    add r14, [rsp+48]
    emit "user: "
    call coin
    test eax, eax
    jz .l2
    emit "Find the equation of the line through "
    call pts
    emit ".", 10
    jmp .sa
.l2:
    emit "What line goes through "
    call pts
    emit "? Give it as y = mx + b.", 10
.sa:
    emit "assistant: The slope is the change in y over the change in x, (y2 - y1) ÷ (x2 - x1).", 10
    sint r14
    emit " - "
    pint r12
    emit " = "
    mov r15, r14
    sub r15, r12
    sint r15                    ; dy
    emit 10
    sint r13
    emit " - "
    pint rbx
    emit " = "
    mov rax, r13
    sub rax, rbx
    mov [rsp+32], rax           ; dx
    sint rax
    emit 10
    mov rax, r15                ; whole?
    cqo
    idiv qword [rsp+32]
    test rdx, rdx
    jnz .frac
    mov [rsp+56], rax
    sint r15
    emit " ÷ "
    pint [rsp+32]
    emit " = "
    sint [rsp+56]
    emit 10
    cmp qword [rsp+64], 0
    jne .eq
    emit "The slope is "
    sint [rsp+56]
    emit ".", 10
    jmp .r
.frac:
    emit "That doesn't divide evenly, so the slope is the fraction "
    mov rax, r15                ; with the sign on top
    xor rax, [rsp+32]
    jns .fp
    mov byte [rdi], '-'
    inc rdi
.fp:
    mov rcx, r15
    absc
    mov [rsp+40], rcx
    num rcx
    emit "/"
    mov rcx, [rsp+32]
    absc
    mov [rsp+48], rcx
    num rcx
    emit ".", 10
    mov rcx, [rsp+40]
    mov rdx, [rsp+48]
    call simp
    mov [rsp+40], rax
    mov [rsp+48], rdx
    mov rax, r15
    xor rax, [rsp+32]
    jns .fs
    neg qword [rsp+40]
.fs:
    emit "The slope is "
    mov rcx, [rsp+40]
    mov rdx, [rsp+48]
    call pfrac
    emit ".", 10
    jmp .r
.eq:
    emit "So y = "
    mov rcx, [rsp+56]
    mov edx, 1
    call mono
    emit " + b. Put in "
    mov rcx, rbx
    mov rdx, r12
    call point
    emit ": "
    sint r12
    emit " = "
    sint [rsp+56]
    emit " × "
    pint rbx
    emit " + b, so "
    sint r12
    emit " = "
    mov rax, [rsp+56]
    imul rax, rbx
    mov [rsp+40], rax
    sint rax
    emit " + b.", 10
    emit "b = "
    sint r12
    emit " - "
    pint [rsp+40]
    emit " = "
    mov rax, r12
    sub rax, [rsp+40]
    mov [rsp+48], rax
    sint rax
    emit 10
    emit "y = "
    mov rcx, [rsp+56]
    mov rdx, [rsp+48]
    call lin
    emit 10
.r:
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; "(x1, y1) and (x2, y2)" from line_one's rbx, r12, r13, r14
pts:
    push rsi
    sub rsp, 32
    mov rcx, rbx
    mov rdx, r12
    call point
    emit " and "
    mov rcx, r13
    mov rdx, r14
    call point
    add rsp, 32
    pop rsi
    ret

; factoring: a common factor, ax^2 + bx + c by splitting the middle, a^2x^2 - b^2
fac2_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88
    mov byte [letter], 'x'
    xor ecx, ecx
    mov edx, 2
    call rnd
    cmp eax, 1
    jb .gcf
    je .ac
    ; a^2x^2 - b^2
    mov ecx, 1
    mov edx, 6
    call rnd
    mov rbx, rax
    mov ecx, 1
    mov edx, 12
    call rnd
    mov r12, rax
    mov rax, rbx
    imul rax, rbx
    mov [pq], rax
    mov qword [pq+8], 0
    mov rax, r12
    imul rax, r12
    neg rax
    mov [pq+16], rax
    emit "user: Factor "
    call pcf
    emit ".", 10
    emit "assistant: Both terms are squares: "
    mov rcx, [pq]
    mov edx, 2
    call mono
    emit " = ("
    mov rcx, rbx
    mov edx, 1
    call mono
    emit ")^2 and "
    mov rax, r12
    imul rax, r12
    num rax
    emit " = "
    num r12
    emit "^2. A difference of two squares, A^2 - B^2, is (A - B)(A + B).", 10
    call pcf
    emit " = ("
    mov rcx, rbx
    mov rdx, r12
    neg rdx
    call lin
    emit ")("
    mov rcx, rbx
    mov rdx, r12
    call lin
    emit ")", 10
    jmp .r
.gcf:
    mov ecx, 2
    mov edx, 9
    call rnd
    mov rbx, rax                ; the number taken out
    xor ecx, ecx
    mov edx, 2
    call rnd
    mov r12, rax                ; the power of x taken out
    mov ecx, 2
    mov edx, 3
    call rnd
    mov r13, rax                ; terms
.gt:
    xor r14d, r14d
.gtt:
    mov rcx, -9
    mov edx, 9
    call nz
    lea rcx, [tc]
    mov [rcx+r14*8], rax
    lea rax, [r13-1]            ; powers r12 + terms - 1 down to r12
    sub rax, r14
    add rax, r12
    lea rcx, [tpw]
    mov [rcx+r14*8], rax
    inc r14
    cmp r14, r13
    jb .gtt
    lea rcx, [tc]               ; leading one positive, and nothing more in common
    cmp qword [rcx], 0
    jl .gt
    mov rcx, [tc]
    mov rdx, [tc+8]
    absc
    xchg rcx, rdx
    absc
    call gcd
    cmp r13, 3
    jb .g1
    mov r15, rax
    mov rcx, [tc+16]
    absc
    mov rdx, r15
    call gcd
.g1:
    cmp rax, 1
    jne .gt
    lea rcx, [qgcf]
    mov edx, NQGCF
    call askpre
    mov [rsp+32], rax
    call pgcf
    mov rcx, [rsp+32]
    call emz
    emit 10
    emit "assistant: The biggest number that goes into "
    xor r14d, r14d
.gl:
    lea rax, [tc]
    mov rax, [rax+r14*8]
    imul rax, rbx
    mov rcx, rax
    absc
    mov [rsp+40], rcx
    num [rsp+40]
    inc r14
    cmp r14, r13
    jae .gle
    lea rax, [r13-1]
    cmp r14, rax
    je .gla
    emit ", "
    jmp .gl
.gla:
    emit " and "
    jmp .gl
.gle:
    emit " is "
    num rbx
    test r12, r12
    jz .gn
    emit ", and every term has at least "
    mov ecx, 1
    mov rdx, r12
    call mono
    emit ", so take out "
    jmp .gto
.gn:
    emit ", so take it out"
    jmp .gte
.gto:
    mov rcx, rbx
    mov rdx, r12
    call mono
.gte:
    emit ".", 10
    xor r14d, r14d
.gd:
    lea rax, [tc]
    mov rcx, [rax+r14*8]
    imul rcx, rbx
    lea rax, [tpw]
    mov rdx, [rax+r14*8]
    call mono
    emit " ÷ "
    mov rcx, rbx
    mov rdx, r12
    call mono
    emit " = "
    lea rax, [tc]
    mov rcx, [rax+r14*8]
    lea rax, [tpw]
    mov rdx, [rax+r14*8]
    sub rdx, r12
    call mono
    emit 10
    inc r14
    cmp r14, r13
    jb .gd
    call pgcf
    emit " = "
    mov rcx, rbx
    mov rdx, r12
    call mono
    mov byte [rdi], '('
    inc rdi
    lea rcx, [tc]               ; what's left, in order
    mov rdx, [rcx]
    lea rax, [tpw]
    mov rax, [rax]
    sub rax, r12
    mov rcx, rdx
    mov rdx, rax
    call mono
    mov r14d, 1
.gr:
    cmp r14, r13
    jae .grd
    lea rax, [tc]
    mov rcx, [rax+r14*8]
    lea rax, [tpw]
    mov rdx, [rax+r14*8]
    sub rdx, r12
    call sterm
    inc r14
    jmp .gr
.grd:
    mov byte [rdi], ')'
    inc rdi
    emit 10
    jmp .r
.ac:
    ; (px + q)(rx + s) with nothing in common in either bracket
    mov ecx, 1
    mov edx, 4
    call rnd
    mov r12, rax                ; p
    mov ecx, 1
    mov edx, 4
    call rnd
    mov r14, rax                ; r
    mov rax, r12
    imul rax, r14
    cmp rax, 2
    jb .ac
    mov rcx, -6
    mov edx, 6
    call nz
    mov r13, rax                ; q
    mov rcx, -6
    mov edx, 6
    call nz
    mov r15, rax                ; s
    mov rcx, r13
    absc
    mov rdx, r12
    call gcd
    cmp rax, 1
    jne .ac
    mov rcx, r15
    absc
    mov rdx, r14
    call gcd
    cmp rax, 1
    jne .ac
    mov rax, r12
    imul rax, r14
    mov [pq], rax               ; a
    mov rax, r12
    imul rax, r15
    mov rcx, r13
    imul rcx, r14
    add rax, rcx
    test rax, rax
    jz .ac                      ; no middle: that's the difference of squares
    mov [pq+8], rax             ; b
    mov rax, r13
    imul rax, r15
    mov [pq+16], rax            ; c
    emit "user: Factor "
    call pcf
    emit ".", 10
    emit "assistant: Multiply a and c: "
    num [pq]
    emit " × "
    pint [pq+16]
    emit " = "
    mov rbx, [pq]
    imul rbx, [pq+16]           ; ac
    sint rbx
    emit ". Find two numbers that multiply to "
    sint rbx
    emit " and add to "
    sint [pq+8]
    emit ".", 10
    mov rcx, rbx
    mov rdx, [pq+8]
    call pairs
    mov [rsp+40], rax           ; u
    mov [rsp+48], rdx           ; v
    emit "Split the middle term: "
    mov rcx, [pq]
    mov edx, 2
    call mono
    mov rcx, [rsp+40]
    mov edx, 1
    call sterm
    mov rcx, [rsp+48]
    mov edx, 1
    call sterm
    mov rcx, [pq+16]
    xor edx, edx
    call sterm
    emit 10
    ; group: ax^2 + ux = g1 x (a/g1 x + u/g1), vx + c = g2 (v/g2 x + c/g2)
    mov rcx, [rsp+40]
    absc
    mov rdx, [pq]
    call gcd
    mov [rsp+56], rax           ; g1
    mov rcx, [rsp+48]
    absc
    mov [rsp+80], rcx
    mov rcx, [pq+16]
    absc
    mov rdx, [rsp+80]
    call gcd
    cmp qword [rsp+48], 0
    jge .g2
    neg rax
.g2:
    mov [rsp+64], rax           ; g2
    mov rax, [pq]
    cqo
    idiv qword [rsp+56]
    mov r12, rax                ; the bracket's x
    mov rax, [rsp+40]
    cqo
    idiv qword [rsp+56]
    mov r13, rax                ; and its number
    emit "Group them: "
    mov rcx, [rsp+56]
    mov edx, 1
    call mono
    emit "("
    mov rcx, r12
    mov rdx, r13
    call lin
    emit ")"
    mov rax, [rsp+64]
    test rax, rax
    js .gm
    emit " + "
    num [rsp+64]
    jmp .gb
.gm:
    emit " - "
    mov rax, [rsp+64]
    neg rax
    num rax
.gb:
    emit "("
    mov rcx, r12
    mov rdx, r13
    call lin
    emit ")", 10
    emit "Both have ("
    mov rcx, r12
    mov rdx, r13
    call lin
    emit ") in them, so take it out.", 10
    call pcf
    emit " = "
    mov rax, [rsp+56]           ; (g1 x + g2) is the other bracket
    cmp rax, r12
    jne .two
    mov rax, [rsp+64]
    cmp rax, r13
    jne .two
    emit "("
    mov rcx, r12
    mov rdx, r13
    call lin
    emit ")^2", 10
    jmp .r
.two:
    emit "("
    mov rcx, [rsp+56]
    mov rdx, [rsp+64]
    call lin
    emit ")("
    mov rcx, r12
    mov rdx, r13
    call lin
    emit ")", 10
.r:
    add rsp, 88
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; pq as ax^2 + bx + c
pcf:
    sub rsp, 40
    mov rax, [pq]
    mov [cf], rax
    mov rax, [pq+8]
    mov [cf+8], rax
    mov rax, [pq+16]
    mov [cf+16], rax
    lea rcx, [cf]
    mov edx, 2
    call poly
    add rsp, 40
    ret

; fac2_one's common-factor polynomial: rbx × tc, powers tpw, r13 terms
pgcf:
    push r14
    push rsi
    sub rsp, 40
    xor r14d, r14d
.l:
    lea rax, [tc]
    mov rcx, [rax+r14*8]
    imul rcx, rbx
    lea rax, [tpw]
    mov rdx, [rax+r14*8]
    test r14, r14
    jnz .s
    call mono
    jmp .n
.s:
    call sterm
.n:
    inc r14
    cmp r14, r13
    jb .l
    add rsp, 40
    pop rsi
    pop r14
    ret

; rcx = product, rdx = sum: the factor pairs of the product tried in turn, like
; quadwork, down to the one that adds up. rax, rdx = the pair
pairs:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    mov r12, rcx
    mov r13, rdx
    mov rcx, r12
    absc
    mov r14, rcx                ; |product|
    mov r15d, 1
.d:
    mov rax, r14
    xor edx, edx
    div r15
    test rdx, rdx
    jnz .dn
    mov r8, r15
    mov r9, rax
    ; product > 0: both have the sum's sign. < 0: the bigger one does
    test r12, r12
    js .neg
    test r13, r13
    jns .set
    neg r8
    neg r9
    jmp .set
.neg:
    test r13, r13
    js .bneg
    neg r8
    jmp .set
.bneg:
    neg r9
.set:
    mov [rsp+32], r8
    mov [rsp+40], r9
    sint [rsp+32]
    emit " × "
    pint [rsp+40]
    emit " = "
    sint r12
    emit ", "
    sint [rsp+32]
    emit " + "
    pint [rsp+40]
    emit " = "
    mov rax, [rsp+32]
    add rax, [rsp+40]
    mov [rsp+48], rax
    sint rax
    cmp [rsp+48], r13
    je .found
    emit 10
.dn:
    inc r15
    mov rax, r15
    imul rax, rax
    cmp rax, r14
    jbe .d
.found:
    emit ", that's it", 10
    mov rax, [rsp+32]
    mov rdx, [rsp+40]
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; |ax + b| = c, two whole answers, or no answer when c is negative
abs_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72
    mov byte [letter], 'x'
    xor ecx, ecx
    mov edx, 4
    call rnd
    mov ebx, 1
    cmp eax, 3
    jb .x
    lea rbx, [rax-1]            ; a = 2 or 3
.x:
    mov rcx, -15
    mov edx, 15
    call rnd
    mov r14, rax                ; x1
    mov rcx, -15
    mov edx, 15
    call rnd
    mov r15, rax                ; x2
    cmp r14, r15
    je .x
    jg .o
    xchg r14, r15
.o:
    lea rax, [r14+r15]          ; a (x1 + x2) even, so b is whole, and not 0
    test rax, rax
    jz .x
    imul rax, rbx
    test rax, 1
    jnz .x
    sar rax, 1
    neg rax
    mov r12, rax                ; b
    mov rax, r14
    sub rax, r15
    imul rax, rbx
    sar rax, 1
    mov r13, rax                ; c
    xor ecx, ecx                ; one in ten has no answer
    mov edx, 9
    call rnd
    mov [rsp+64], rax
    test rax, rax
    jnz .q
    neg r13
.q:
    emit "user: Solve |"
    mov rcx, rbx
    mov rdx, r12
    call lin
    emit "| = "
    sint r13
    emit ".", 10
    emit "assistant: "
    cmp qword [rsp+64], 0
    jne .two
    emit "An absolute value is never negative, so it can't be "
    sint r13
    emit ".", 10
    emit "There is no solution.", 10
    jmp .r
.two:
    emit "|"
    mov rcx, rbx
    mov rdx, r12
    call lin
    emit "| = "
    num r13
    emit " means "
    mov rcx, rbx
    mov rdx, r12
    call lin
    emit " = "
    num r13
    emit " or "
    mov rcx, rbx
    mov rdx, r12
    call lin
    emit " = -"
    num r13
    emit ".", 10
    mov rcx, r13
    call side
    mov rcx, r13
    neg rcx
    call side
    emit "x = "
    sint r14
    emit " or x = "
    sint r15
    emit 10
.r:
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = t: ax + b = t solved, from abs_one's rbx = a, r12 = b
side:
    push rsi
    push r13
    push r14
    sub rsp, 32
    mov r13, rcx
    mov rcx, rbx
    mov rdx, r12
    call lin
    emit " = "
    sint r13
    emit ": "
    mov rcx, rbx
    mov edx, 1
    call mono
    emit " = "
    sint r13
    emit " - "
    pint r12
    emit " = "
    mov r14, r13
    sub r14, r12
    sint r14
    cmp rbx, 1
    je .e
    emit ", so x = "
    sint r14
    emit " ÷ "
    num rbx
    emit " = "
    mov rax, r14
    cqo
    idiv rbx
    sint rax
.e:
    emit 10
    add rsp, 32
    pop r14
    pop r13
    pop rsi
    ret

; b^x = n or b^(x + s) = n: multiply b's up to n
expeq_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
.pick:
    mov ecx, 2
    mov edx, 10
    call rnd
    mov rbx, rax                ; b
    mov ecx, 2
    mov edx, 8
    call rnd
    mov r12, rax                ; the power
    mov eax, 1
    mov rcx, r12
.p:
    imul rax, rbx
    dec rcx
    jnz .p
    cmp rax, 1000000
    ja .pick
    mov r13, rax                ; n
    xor r14d, r14d              ; s
    xor ecx, ecx
    mov edx, 4
    call rnd
    cmp eax, 2
    jb .q
    mov rcx, -3
    mov edx, 3
    call nz
    mov r14, rax
.q:
    call coin
    mov [rsp+32], rax
    emit "user: "
    cmp qword [rsp+32], 0
    je .q1
    emit "Solve "
    jmp .q2
.q1:
    emit "Find x if "
.q2:
    call pexp
    emit " = "
    num r13
    emit ".", 10
    emit "assistant: Write "
    num r13
    emit " as a power of "
    num rbx
    emit " by multiplying "
    num rbx
    emit "s until it gets there.", 10
    mov rax, rbx
    mov r15, r12
.m:
    dec r15
    jz .md
    mov rcx, rax
    mov rdx, rbx
    call mulstep
    jmp .m
.md:
    emit "So "
    num r13
    emit " = "
    num rbx
    emit "^"
    num r12
    emit ", which makes "
    test r14, r14
    jnz .sh
    emit "x = "
    num r12
    emit ".", 10
    emit "x = "
    num r12
    emit 10
    jmp .r
.sh:
    emit "x"
    mov rcx, r14
    xor edx, edx
    call sterm
    emit " = "
    num r12
    emit ".", 10
    emit "x = "
    num r12
    test r14, r14
    js .sp
    emit " - "
    num r14
    jmp .se
.sp:
    emit " + "
    mov rax, r14
    neg rax
    num rax
.se:
    emit " = "
    mov rax, r12
    sub rax, r14
    mov [rsp+40], rax
    sint rax
    emit 10
    emit "x = "
    sint [rsp+40]
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

; b^x or b^(x + s) from expeq_one's rbx, r14
pexp:
    push rsi
    sub rsp, 32
    num rbx
    test r14, r14
    jnz .s
    emit "^x"
    jmp .r
.s:
    emit "^(x"
    mov rcx, r14
    xor edx, edx
    call sterm
    emit ")"
.r:
    add rsp, 32
    pop rsi
    ret
