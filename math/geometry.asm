; mathgen's geometry: area and perimeter of the usual flat shapes, volume of a cube,
; a box and a cylinder, Pythagoras, and angles. circles stay in terms of π
default rel
bits 64
%include "lib.inc"
%include "math/math.inc"

section .rdata
un0 db "cm", 0
un1 db "m", 0
un2 db "inches", 0
un3 db "feet", 0
align 8
units dq un0, un1, un2, un3

sa_sq   db "A square's area is side × side.", 10, 0
sp_sq   db "A square's perimeter is 4 × side.", 10, 0
sa_rect db "Area is length × width.", 10, 0
sp_rect db "The perimeter is 2 × (length + width).", 10, 0
sa_tri  db "A triangle's area is base × height ÷ 2.", 10, 0
sa_par  db "A parallelogram's area is base × height.", 10, 0
sa_trap db "A trapezoid's area is (the two parallel sides added) × height ÷ 2.", 10, 0
sa_circ db "A circle's area is π × radius^2.", 10, 0
sp_circ db "A circle's circumference is 2 × π × radius.", 10, 0
q_area  db " What is its area?", 10, 0
q_perim db " What is its perimeter?", 10, 0
q_circ  db " What is its circumference?", 10, 0

; triples a, b, c
trip dq 3, 4, 5,  5, 12, 13,  8, 15, 17,  7, 24, 25,  20, 21, 29,  9, 40, 41,  12, 35, 37
     dq 11, 60, 61
NTRIP equ 8

pn3  db "triangle", 0
pn4  db "quadrilateral", 0
pn5  db "pentagon", 0
pn6  db "hexagon", 0
pn7  db "heptagon", 0
pn8  db "octagon", 0
pn9  db "nonagon", 0
pn10 db "decagon", 0
pn12 db "dodecagon", 0
align 8
pname dq 0, 0, 0, pn3, pn4, pn5, pn6, pn7, pn8, pn9, pn10, 0, pn12
; regular polygons whose angles come out whole
regn dq 3, 4, 5, 6, 8, 9, 10, 12, 15, 18, 20, 24, 30, 36
NREGN equ 14

section .bss
alignb 8
gunit resq 1

section .text

global geo_one

; the unit at rdi
%macro unit 0
    mov rcx, [gunit]
    call emz
%endmacro

; " 12 cm" style: a number and the unit
%macro nu 1
    num %1
    mov byte [rdi], ' '
    inc rdi
    unit
%endmacro

; flat shapes, solids, Pythagoras or angles
geo_one:
    sub rsp, 40
    xor ecx, ecx
    mov edx, 3
    call rnd
    lea rcx, [units]
    mov rax, [rcx+rax*8]
    mov [gunit], rax
    xor ecx, ecx
    mov edx, 9
    call rnd
    cmp eax, 4
    jb .flat
    cmp eax, 6
    jb .vol
    cmp eax, 8
    jb .pyth
    call geo_ang
    jmp .r
.flat:
    call geo_flat
    jmp .r
.vol:
    call geo_vol
    jmp .r
.pyth:
    call geo_pyth
.r:
    add rsp, 40
    ret

; "Answer: n unit", "Answer: n square unit", "Answer: nπ cubic unit"... rcx = n,
; rdx = 0 plain, 1 square, 2 cubic, r8 = 1 for π
ganswer:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    mov r13, r8
    emit "Answer: "
    num rbx
    test r13, r13
    jz .np
    emit "π"
.np:
    emit " "
    cmp r12, 1
    jb .u
    je .sq
    emit "cubic "
    jmp .u
.sq:
    emit "square "
.u:
    unit
    emit 10
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; area or perimeter of a square, rectangle, triangle, parallelogram, trapezoid, circle
geo_flat:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    xor ecx, ecx
    mov edx, 5
    call rnd
    mov r15, rax
    call coin
    mov r14, rax                ; 1 = perimeter (square, rectangle, circle)
    cmp r15, 1
    jb .sq
    je .rect
    cmp r15, 3
    jb .tri
    je .par
    cmp r15, 4
    je .trap
    jmp .circ
.sq:
    mov ecx, 2
    mov edx, 30
    call rnd
    mov rbx, rax
    emit "user: A square has sides of "
    nu rbx
    emit "."
    call aorp
    test r14, r14
    jnz .sqp
    lea rcx, [sa_sq]
    call emz
    mov rcx, rbx
    mov rdx, rbx
    call mulstep
    jmp .area
.sqp:
    lea rcx, [sp_sq]
    call emz
    mov ecx, 4
    mov rdx, rbx
    call mulstep
    jmp .line
.rect:
    mov ecx, 3
    mov edx, 40
    call rnd
    mov rbx, rax
    mov ecx, 2
    lea rdx, [rbx-1]
    call rnd
    mov r12, rax
    emit "user: A rectangle is "
    nu rbx
    emit " long and "
    nu r12
    emit " wide."
    call aorp
    test r14, r14
    jnz .rp
    lea rcx, [sa_rect]
    call emz
    mov rcx, rbx
    mov rdx, r12
    call mulstep
    jmp .area
.rp:
    lea rcx, [sp_rect]
    call emz
    mov rcx, rbx
    mov rdx, r12
    call addstep
    mov ecx, 2
    mov rdx, rax
    call mulstep
    jmp .line
.tri:
    call tbh
    emit "user: A triangle has a base of "
    nu rbx
    emit " and a height of "
    nu r12
    emit "."
    lea rcx, [q_area]
    call emz
    emit "assistant: "
    lea rcx, [sa_tri]
    call emz
    mov rcx, rbx
    mov rdx, r12
    call mulstep
    mov rcx, rax
    mov edx, 2
    call divstep
    jmp .area
.par:
    mov ecx, 2
    mov edx, 40
    call rnd
    mov rbx, rax
    mov ecx, 2
    mov edx, 40
    call rnd
    mov r12, rax
    emit "user: A parallelogram has a base of "
    nu rbx
    emit " and a height of "
    nu r12
    emit "."
    lea rcx, [q_area]
    call emz
    emit "assistant: "
    lea rcx, [sa_par]
    call emz
    mov rcx, rbx
    mov rdx, r12
    call mulstep
    jmp .area
.trap:
    mov ecx, 2                  ; parallel sides a < b, height h, (a + b) h even
    mov edx, 30
    call rnd
    mov rbx, rax
    lea rcx, [rbx+1]
    mov edx, 40
    call rnd
    mov r12, rax
    mov ecx, 2
    mov edx, 30
    call rnd
    mov r13, rax
    lea rax, [rbx+r12]
    imul rax, r13
    test rax, 1
    jz .tq
    inc r13
.tq:
    emit "user: A trapezoid has parallel sides of "
    nu rbx
    emit " and "
    nu r12
    emit ", and a height of "
    nu r13
    emit "."
    lea rcx, [q_area]
    call emz
    emit "assistant: "
    lea rcx, [sa_trap]
    call emz
    mov rcx, rbx
    mov rdx, r12
    call addstep
    mov rcx, rax
    mov rdx, r13
    call mulstep
    mov rcx, rax
    mov edx, 2
    call divstep
    jmp .area
.circ:
    mov ecx, 1
    mov edx, 20
    call rnd
    mov rbx, rax                ; r
    call coin
    mov r12, rax                ; 1 = given the diameter
    emit "user: A circle has a "
    test r12, r12
    jnz .cd
    emit "radius of "
    nu rbx
    jmp .cq
.cd:
    emit "diameter of "
    lea rax, [rbx+rbx]
    mov [rsp+32], rax
    nu [rsp+32]
.cq:
    emit "."
    lea rcx, [q_area]
    test r14, r14
    jz .cq2
    lea rcx, [q_circ]
.cq2:
    call emz
    emit "assistant: "
    test r12, r12
    jz .cr
    emit "The radius is half the diameter.", 10
    lea rcx, [rbx+rbx]
    mov edx, 2
    call divstep
.cr:
    test r14, r14
    jnz .cc
    lea rcx, [sa_circ]
    call emz
    mov rcx, rbx
    mov rdx, rbx
    call mulstep
    mov rcx, rax
    mov edx, 1
    mov r8d, 1
    call ganswer
    jmp .r
.cc:
    lea rcx, [sp_circ]
    call emz
    mov ecx, 2
    mov rdx, rbx
    call mulstep
    mov rcx, rax
    xor edx, edx
    mov r8d, 1
    call ganswer
    jmp .r
.area:
    mov rcx, rax
    mov edx, 1
    xor r8d, r8d
    call ganswer
    jmp .r
.line:
    mov rcx, rax
    xor edx, edx
    xor r8d, r8d
    call ganswer
.r:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; " What is its area/perimeter?" and "assistant: ", from r14
aorp:
    push rsi
    sub rsp, 32
    lea rcx, [q_area]
    test r14, r14
    jz .q
    lea rcx, [q_perim]
.q:
    call emz
    emit "assistant: "
    add rsp, 32
    pop rsi
    ret

; rbx = base, r12 = height for a triangle, 2-40 each with an even product
tbh:
    sub rsp, 40
    mov ecx, 2
    mov edx, 40
    call rnd
    mov rbx, rax
    mov ecx, 2
    mov edx, 40
    call rnd
    mov r12, rax
    mov rax, rbx
    imul rax, r12
    test rax, 1
    jz .r
    inc rbx
.r:
    add rsp, 40
    ret

; volume of a cube, a box or a cylinder
geo_vol:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    sub rsp, 32
    xor ecx, ecx
    mov edx, 2
    call rnd
    cmp eax, 1
    jb .cube
    je .box
    mov ecx, 1                  ; cylinder
    mov edx, 12
    call rnd
    mov rbx, rax
    mov ecx, 2
    mov edx, 20
    call rnd
    mov r12, rax
    emit "user: A cylinder has a radius of "
    nu rbx
    emit " and a height of "
    nu r12
    emit ". What is its volume?", 10
    emit "assistant: A cylinder's volume is π × radius^2 × height.", 10
    mov rcx, rbx
    mov rdx, rbx
    call mulstep
    mov rcx, rax
    mov rdx, r12
    call mulstep
    mov rcx, rax
    mov edx, 2
    mov r8d, 1
    call ganswer
    jmp .r
.cube:
    mov ecx, 2
    mov edx, 15
    call rnd
    mov rbx, rax
    emit "user: A cube has edges of "
    nu rbx
    emit ". What is its volume?", 10
    emit "assistant: A cube's volume is edge × edge × edge.", 10
    mov rcx, rbx
    mov rdx, rbx
    call mulstep
    mov rcx, rax
    mov rdx, rbx
    call mulstep
    jmp .ans
.box:
    mov ecx, 2
    mov edx, 20
    call rnd
    mov rbx, rax
    mov ecx, 2
    mov edx, 20
    call rnd
    mov r12, rax
    mov ecx, 2
    mov edx, 20
    call rnd
    mov r13, rax
    emit "user: A box is "
    nu rbx
    emit " long, "
    nu r12
    emit " wide and "
    nu r13
    emit " tall. What is its volume?", 10
    emit "assistant: Volume is length × width × height.", 10
    mov rcx, rbx
    mov rdx, r12
    call mulstep
    mov rcx, rax
    mov rdx, r13
    call mulstep
.ans:
    mov rcx, rax
    mov edx, 2
    xor r8d, r8d
    call ganswer
.r:
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; a right triangle from a Pythagorean triple: the hypotenuse, or the other leg
geo_pyth:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    xor ecx, ecx
    mov edx, NTRIP - 1
    call rnd
    imul rax, rax, 24
    lea rcx, [trip]
    add rax, rcx
    mov rbx, [rax]
    mov r12, [rax+8]
    mov r13, [rax+16]
    mov eax, 60                 ; scaled so the hypotenuse stays under ~60
    xor edx, edx
    div r13
    mov rdx, rax
    mov ecx, 1
    cmp rdx, 1
    jae .k
    mov edx, 1
.k:
    call rnd
    imul rbx, rax
    imul r12, rax
    imul r13, rax
    call coin
    test eax, eax
    jz .ord
    xchg rbx, r12               ; either leg can come first
.ord:
    call coin
    test eax, eax
    jnz .leg
    emit "user: A right triangle has legs of "
    nu rbx
    emit " and "
    nu r12
    emit ". How long is the hypotenuse?", 10
    emit "assistant: By Pythagoras, hypotenuse^2 = "
    num rbx
    emit "^2 + "
    num r12
    emit "^2.", 10
    mov rcx, rbx
    mov rdx, rbx
    call mulstep
    mov r14, rax
    mov rcx, r12
    mov rdx, r12
    call mulstep
    mov rcx, r14
    mov rdx, rax
    call addstep
    mov r14, rax
    mov r15, r13
    jmp .root
.leg:
    emit "user: A right triangle has a hypotenuse of "
    nu r13
    emit " and one leg of "
    nu rbx
    emit ". How long is the other leg?", 10
    emit "assistant: By Pythagoras, leg^2 = "
    num r13
    emit "^2 - "
    num rbx
    emit "^2.", 10
    mov rcx, r13
    mov rdx, r13
    call mulstep
    mov r14, rax
    mov rcx, rbx
    mov rdx, rbx
    call mulstep
    mov rcx, r14
    mov rdx, rax
    call substep
    mov r14, rax
    mov r15, r12
.root:
    emit "√"
    num r14
    emit " = "
    num r15
    emit ", since "
    num r15
    emit " × "
    num r15
    emit " = "
    num r14
    emit ".", 10
    mov rcx, r15
    xor edx, edx
    xor r8d, r8d
    call ganswer
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; the polygon in rbx: "a hexagon (6 sides)" or "a 14-sided polygon"
ppoly:
    push rsi
    push r12
    sub rsp, 40
    cmp rbx, 12
    ja .n
    lea rax, [pname]
    mov r12, [rax+rbx*8]
    test r12, r12
    jz .n
    mov byte [rdi], 'a'
    inc rdi
    cmp rbx, 8                  ; "an octagon"
    jne .a
    mov byte [rdi], 'n'
    inc rdi
.a:
    mov byte [rdi], ' '
    inc rdi
    mov rcx, r12
    call emz
    emit " ("
    num rbx
    emit " sides)"
    jmp .r
.n:
    emit "a "
    num rbx
    emit "-sided polygon"
.r:
    add rsp, 40
    pop r12
    pop rsi
    ret

; the third angle of a triangle, supplementary, complementary, a polygon's angles
geo_ang:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    xor ecx, ecx
    mov edx, 4
    call rnd
    cmp eax, 1
    jb .tri
    je .sup
    cmp eax, 3
    jb .comp
    je .sum
    xor ecx, ecx                ; each angle of a regular one
    mov edx, NREGN - 1
    call rnd
    lea rcx, [regn]
    mov rbx, [rcx+rax*8]
    emit "user: What is each interior angle of a regular "
    cmp rbx, 12
    ja .rn
    lea rax, [pname]
    cmp qword [rax+rbx*8], 0
    je .rn
    mov rcx, [rax+rbx*8]
    call emz
    jmp .rq
.rn:
    num rbx
    emit "-sided polygon"
.rq:
    emit "?", 10
    emit "assistant: The angles add up to (sides - 2) × 180 degrees, and a regular one has them all the same, so divide by the number of sides.", 10
    call psum
    mov rcx, rax
    mov rdx, rbx
    call divstep
    jmp .deg
.tri:
    mov ecx, 10
    mov edx, 120
    call rnd
    mov rbx, rax
    mov ecx, 10
    mov edx, 170
    sub rdx, rbx
    call rnd
    mov r12, rax
    emit "user: Two angles of a triangle are "
    num rbx
    emit " degrees and "
    num r12
    emit " degrees. What is the third angle?", 10
    emit "assistant: The angles in a triangle add up to 180 degrees.", 10
    mov rcx, rbx
    mov rdx, r12
    call addstep
    mov ecx, 180
    mov rdx, rax
    call substep
    jmp .deg
.sup:
    mov ecx, 1
    mov edx, 179
    call rnd
    mov rbx, rax
    call coin
    test eax, eax
    jz .s2
    emit "user: What angle is supplementary to "
    num rbx
    emit " degrees?", 10
    jmp .sa
.s2:
    emit "user: Two angles on a straight line add to 180 degrees. One is "
    num rbx
    emit " degrees. What is the other?", 10
.sa:
    emit "assistant: Supplementary angles add up to 180 degrees.", 10
    mov ecx, 180
    mov rdx, rbx
    call substep
    jmp .deg
.comp:
    mov ecx, 1
    mov edx, 89
    call rnd
    mov rbx, rax
    emit "user: What angle is complementary to "
    num rbx
    emit " degrees?", 10
    emit "assistant: Complementary angles add up to 90 degrees.", 10
    mov ecx, 90
    mov rdx, rbx
    call substep
    jmp .deg
.sum:
    mov ecx, 3
    mov edx, 20
    call rnd
    mov rbx, rax
    emit "user: What do the interior angles of "
    call ppoly
    emit " add up to?", 10
    emit "assistant: The interior angles add up to (sides - 2) × 180 degrees.", 10
    call psum
.deg:
    mov [rsp+32], rax
    emit "Answer: "
    num [rsp+32]
    emit " degrees", 10
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rbx = sides: "n - 2 = k" and k × 180. rax = the sum
psum:
    push rsi
    push r12
    sub rsp, 40
    num rbx
    emit " - 2 = "
    lea r12, [rbx-2]
    num r12
    emit 10
    mov rcx, r12
    mov edx, 180
    call mulstep
    add rsp, 40
    pop r12
    pop rsi
    ret
