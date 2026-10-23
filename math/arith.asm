; mathgen's number topics: adding and subtracting in columns, negative numbers, gcd and
; lcm, fractions, powers and square roots, percentages, order of operations, word
; problems. and the steps everyone shares: a sum, product or quotient goes on one line
; when it's small enough to just know, and gets worked out in full when it isn't
default rel
bits 64
%include "lib.inc"
%include "math/math.inc"

section .rdata
qa0 db "What is ", 0
qa1 db "Add ", 0
qa2 db "Compute ", 0
qa3 db "What's the sum of ", 0
qa4 db "Find ", 0
oplus  db " + ", 0
oand   db " and ", 0
oplusw db " plus ", 0
sq     db "?", 0
sdot   db ".", 0
seq    db " = ?", 0
align 8
qadd dq qa0, oplus, sq,  qa1, oand, sdot,  qa2, oplus, sdot,  empty, oplus, seq
     dq qa3, oand, sq,  qa4, oplusw, sdot,  qa0, oplusw, sq
NQADD equ 7

qs0 db "What's ", 0
qs1 db "Subtract ", 0
qs2 db "Take ", 0
ominus  db " - ", 0
ominusw db " minus ", 0
ofrom   db " from ", 0
oaway   db " away from ", 0
align 8
qsub  dq qa0, ominus, sq,  empty, ominus, seq,  qs0, ominusw, sq,  qa2, ominus, sdot
NQSUB equ 4
qsubr dq qs1, ofrom, sdot,  qs2, oaway, sdot      ; these say b first
NQSUBR equ 2

qw0 db "Work out ", 0
align 8
qsg dq qa0, sq,  qa2, sdot,  empty, seq,  qw0, sdot,  qs0, sq
NQSG equ 5
otimes db " × ", 0
odiv   db " ÷ ", 0
align 8
sgop dq oplus, ominus, otimes, odiv

qg0 db "What is the greatest common divisor of ", 0
qg1 db "Find the GCD of ", 0
qg2 db "What's the highest common factor of ", 0
qg3 db "gcd(", 0
qg4 db "Find the greatest common factor of ", 0
ocomma db ", ", 0
sbr    db ") = ?", 0
qg5 db "gcd of ", 0
qg6 db "What is the GCF of ", 0
align 8
qgcd dq qg0, oand, sq,  qg1, oand, sdot,  qg2, oand, sq,  qg3, ocomma, sbr
     dq qg4, oand, sdot,  qg5, oand, empty,  qg6, oand, sq
NQGCD equ 7
ql0 db "What is the least common multiple of ", 0
ql1 db "Find the LCM of ", 0
ql2 db "What's the lowest common multiple of ", 0
ql3 db "lcm(", 0
ql4 db "What is the smallest number that both ", 0
sgo db " go into?", 0
ql5 db "lcm of ", 0
ql6 db "What is the LCM of ", 0
align 8
qlcm dq ql0, oand, sq,  ql1, oand, sdot,  ql2, oand, sq,  ql3, ocomma, sbr
     dq ql4, oand, sgo,  ql5, oand, empty,  ql6, oand, sq
NQLCM equ 7

qe0 db "Evaluate ", 0
align 8
qpow dq qa0, sq,  qa2, sdot,  empty, seq,  qw0, sdot,  qe0, sdot
NQPOW equ 5
qr0 db "What is √", 0
qr1 db "Simplify √", 0
qr2 db "Find the square root of ", 0
qr3 db "√", 0
qr4 db "What is the square root of ", 0
qr5 db "sqrt(", 0
qr6 db "Simplify sqrt(", 0
qr7 db "square root of ", 0
sbr1 db ")", 0
sbr2 db ").", 0
align 8
qroot dq qr0, sq,  qr1, sdot,  qr2, sdot,  qr3, seq
      dq qr4, sq,  qr5, sbr1,  qr6, sbr2,  qr7, empty
NQROOT equ 8
; the square-free part under the root, 1 most often
inside dq 1, 1, 1, 1, 1, 2, 3, 5, 6, 7, 10, 11, 13, 14, 15, 17, 19, 21, 22, 23, 26, 29, 30
NINSIDE equ 23

qp0 db "What is ", 0
qp1 db "Find ", 0
qp2 db "Work out ", 0
qp3 db "Calculate ", 0
pof db "% of ", 0
pofw db " percent of ", 0
align 8
qpct dq qp0, pof, sq,  qp1, pof, sdot,  qp2, pof, sdot,  qp3, pof, sdot
     dq qp0, pofw, sq,  empty, pof, empty,  qp1, pofw, sdot
NQPCT equ 7
s_upby   db " increased by ", 0
s_downby db " decreased by ", 0
s_inc    db "Increase ", 0
s_dec    db "Decrease ", 0
s_up     db "up", 0
s_down   db "down", 0
align 8
pdivs dq 2, 4, 5, 10, 20, 25, 50

qu0 db "Simplify ", 0
align 8
qrule dq qu0, sdot,  qa0, sq,  empty, seq,  qw0, sdot
NQRULE equ 4
s_out db "Multiply what comes out:", 10, 0
s_in  db "Multiply what stays inside:", 10, 0

; order of operations. ops 1 + 2 - 3 × 4 ÷ 5 ^, tokens 0 a number, then the ops, 6 ( 7 )
opmix db 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 5
prec  db 4, 1, 1, 2, 2, 3
s_pow db "^", 0
s_lp  db "(", 0
s_rp  db ")", 0
align 8
tokstr dq 0, oplus, ominus, otimes, odiv, s_pow, s_lp, s_rp
vb1 db "Add: ", 0
vb2 db "Subtract: ", 0
vb3 db "Multiply: ", 0
vb4 db "Divide: ", 0
vb5 db "Powers: ", 0
align 8
verb dq 0, vb1, vb2, vb3, vb4, vb5
qc0 db "Calculate ", 0
align 8
qord dq qa0, sq,  qe0, sdot,  qw0, sdot,  empty, seq,  qc0, sdot
NQORD equ 5
s_inbr db "In brackets: ", 0

; word problems. in the text: the name, the numbers A B C, the things, the answers
WN equ 1
WA equ 2
WB equ 3
WC equ 4
WI equ 5
WR equ 6
WS equ 7
t0q  db WN, " has ", WA, " ", WI, ". ", WN, " buys ", WB, " more. How many ", WI, " does ", WN, " have now?", 0
t0e  db WN, " starts with ", WA, " and gets ", WB, " more, so add: ", WA, " + ", WB, ".", 0
t0a  db "Answer: ", WR, " ", WI, 0
t1q  db "There are ", WA, " ", WI, " in a jar, and ", WN, " puts in ", WB, " more. How many ", WI, " are in the jar now?", 0
t1e  db WB, " more on top of ", WA, " means adding: ", WA, " + ", WB, ".", 0
t2q  db WN, " had ", WA, " ", WI, " and gave ", WB, " of them away. How many ", WI, " are left?", 0
t2e  db "Giving ", WB, " away means subtracting: ", WA, " - ", WB, ".", 0
t3q  db "A shop had ", WA, " ", WI, " and sold ", WB, " of them. How many ", WI, " does the shop have left?", 0
t3e  db "Selling ", WB, " takes them away: ", WA, " - ", WB, ".", 0
t4q  db "There are ", WA, " boxes with ", WB, " ", WI, " in each box. How many ", WI, " are there altogether?", 0
t4e  db WA, " boxes of ", WB, " means multiplying: ", WA, " × ", WB, ".", 0
t5q  db "A ticket costs ", WB, " dollars. How much do ", WA, " tickets cost?", 0
t5e  db WA, " tickets at ", WB, " dollars each: ", WA, " × ", WB, ".", 0
t5a  db "Answer: ", WR, " dollars", 0
t6q  db WN, " reads ", WB, " pages every day. How many pages does ", WN, " read in ", WA, " days?", 0
t6e  db WB, " pages a day for ", WA, " days: ", WA, " × ", WB, ".", 0
t6a  db "Answer: ", WR, " pages", 0
t7q  db WN, " shares ", WA, " ", WI, " equally between ", WB, " friends. How many does each friend get?", 0
t7e  db "Sharing equally means dividing: ", WA, " ÷ ", WB, ".", 0
t8q  db "A car goes ", WA, " km in ", WB, " hours at a steady speed. How far does it go in one hour?", 0
t8e  db "Split the distance over the hours: ", WA, " ÷ ", WB, ".", 0
t8a  db "Answer: ", WR, " km", 0
t9q  db WN, " has ", WA, " ", WI, " and packs them into bags of ", WB, ". How many bags are full, and how many ", WI, " are left over?", 0
t9e  db "Each bag takes ", WB, ", so divide: ", WA, " ÷ ", WB, ".", 0
t9a  db "Answer: ", WR, " full bags, ", WS, " left over", 0
t10q db WN, " buys ", WA, " packs of ", WI, " with ", WB, " in each pack, then gives ", WC, " away. How many ", WI, " does ", WN, " have now?", 0
t10e db "First the packs: ", WA, " × ", WB, ". Then take away ", WC, ".", 0
t11q db WN, " had ", WA, " dollars, spent ", WB, " on lunch and ", WC, " on a book. How much money is left?", 0
t11e db "Take off ", WB, ", then take off ", WC, ".", 0
t12q db "A fence goes around a garden ", WA, " m long and ", WB, " m wide. How long is the fence?", 0
t12e db "The fence is the perimeter, 2 × (length + width): first ", WA, " + ", WB, ", then double it.", 0
t12a db "Answer: ", WR, " m", 0
t13q db WN, "'s garden is ", WA, " m long and ", WB, " m wide. How much ground does it cover?", 0
t13e db "That's its area, length × width: ", WA, " × ", WB, ".", 0
t13a db "Answer: ", WR, " square m", 0
t14q db WN, " scored ", WA, ", ", WB, " and ", WC, " points in three games. How many points is that in total?", 0
t14e db "Add them up: ", WA, " + ", WB, ", then add ", WC, ".", 0
t14a db "Answer: ", WR, " points", 0
t15q db WA, " people are going on a trip, and each bus holds ", WB, ". How many buses are needed?", 0
t15e db "Divide ", WA, " by ", WB, ", and anyone left over still needs a bus.", 0
t15a db "Answer: ", WR, " buses", 0
t16q db "The temperature was ", WA, " degrees, then it fell by ", WB, " degrees. What is the temperature now?", 0
t16e db "Falling ", WB, " degrees means subtracting: ", WA, " - ", WB, ".", 0
t16a db "Answer: ", WR, " degrees", 0
t17q db WN, " is ", WA, " years old, and ", WN, "'s grandmother is ", WB, " times as old. How old is the grandmother?", 0
t17e db WB, " times as old means multiplying: ", WA, " × ", WB, ".", 0
t17a db "Answer: ", WR, " years old", 0
t18q db WN, " walked ", WA, " meters in the morning and ", WB, " meters in the afternoon. How far did ", WN, " walk in all?", 0
t18e db "Put the two walks together: ", WA, " + ", WB, ".", 0
t18a db "Answer: ", WR, " meters", 0
t19q db WN, " has ", WA, " ", WI, " and a friend has ", WB, ". How many more does ", WN, " have?", 0
t19e db "The difference is ", WA, " - ", WB, ".", 0
t19a db "Answer: ", WR, " more", 0
align 8
; question, working, answer, what it takes (wkind), then A, B, C's ranges. kind 3's A
; is how many each gets, and the fix-ups in word_one keep the rest sensible
wtab dq t0q, t0e, t0a, 0,  2, 500,  2, 500,  0, 0
     dq t1q, t1e, t0a, 0,  2, 300,  2, 300,  0, 0
     dq t2q, t2e, t0a, 1,  10, 999,  1, 999,  0, 0
     dq t3q, t3e, t0a, 1,  20, 999,  1, 999,  0, 0
     dq t4q, t4e, t0a, 2,  2, 30,  2, 48,  0, 0
     dq t5q, t5e, t5a, 2,  2, 30,  2, 99,  0, 0
     dq t6q, t6e, t6a, 2,  2, 60,  2, 31,  0, 0
     dq t7q, t7e, t0a, 3,  2, 30,  2, 12,  0, 0
     dq t8q, t8e, t8a, 3,  20, 90,  2, 9,  0, 0
     dq t9q, t9e, t9a, 4,  10, 500,  2, 12,  0, 0
     dq t10q, t10e, t0a, 5,  2, 12,  2, 24,  0, 0
     dq t11q, t11e, t5a, 6,  50, 999,  1, 300,  1, 300
     dq t12q, t12e, t12a, 7,  2, 99,  2, 99,  0, 0
     dq t13q, t13e, t13a, 2,  2, 60,  2, 60,  0, 0
     dq t14q, t14e, t14a, 8,  1, 99,  1, 99,  1, 99
     dq t15q, t15e, t15a, 9,  20, 500,  10, 60,  0, 0
     dq t16q, t16e, t16a, 10,  0, 35,  1, 50,  0, 0
     dq t17q, t17e, t17a, 2,  5, 15,  3, 8,  0, 0
     dq t18q, t18e, t18a, 0,  100, 2000,  100, 2000,  0, 0
     dq t19q, t19e, t19a, 1,  10, 999,  1, 999,  0, 0
NWORD equ 20
wkind dq word_one.add, word_one.sub, word_one.mul, word_one.div, word_one.div
      dq word_one.mulsub, word_one.subsub, word_one.perim, word_one.add3
      dq word_one.ceil, word_one.temp

nm0  db "Sam", 0
nm1  db "Maya", 0
nm2  db "Leo", 0
nm3  db "Priya", 0
nm4  db "Ben", 0
nm5  db "Ava", 0
nm6  db "Omar", 0
nm7  db "Mia", 0
nm8  db "Noah", 0
nm9  db "Zoe", 0
nm10 db "Ravi", 0
nm11 db "Lily", 0
nm12 db "Jack", 0
nm13 db "Emma", 0
nm14 db "Kai", 0
nm15 db "Nora", 0
nm16 db "Tom", 0
nm17 db "Ella", 0
nm18 db "Yuki", 0
nm19 db "Ana", 0
nm20 db "Max", 0
nm21 db "Ivy", 0
nm22 db "Ali", 0
nm23 db "Rosa", 0
nm24 db "Finn", 0
nm25 db "Lena", 0
nm26 db "Joe", 0
nm27 db "Amara", 0
nm28 db "Theo", 0
nm29 db "Sofia", 0
align 8
names dq nm0, nm1, nm2, nm3, nm4, nm5, nm6, nm7, nm8, nm9, nm10, nm11, nm12, nm13, nm14
      dq nm15, nm16, nm17, nm18, nm19, nm20, nm21, nm22, nm23, nm24, nm25, nm26, nm27
      dq nm28, nm29
NNAME equ 30
it0  db "apples", 0
it1  db "marbles", 0
it2  db "stickers", 0
it3  db "books", 0
it4  db "cookies", 0
it5  db "pencils", 0
it6  db "cards", 0
it7  db "stamps", 0
it8  db "shells", 0
it9  db "coins", 0
it10 db "balloons", 0
it11 db "crayons", 0
it12 db "eggs", 0
it13 db "oranges", 0
it14 db "toy cars", 0
it15 db "beads", 0
align 8
items dq it0, it1, it2, it3, it4, it5, it6, it7, it8, it9, it10, it11, it12, it13, it14, it15
NITEM equ 16

section .bss
alignb 8
nv    resq 32                   ; expression tree: value, op, left, right
xop   resb 32
nl    resb 32
nr    resb 32
nn    resq 1
nops  resq 1
bad   resq 1                    ; a step came out too big, or not whole
tv    resq 64                   ; the expression as tokens
tt    resb 64
ntok  resq 1
ov    resq 64                   ; and as it was asked
ot    resb 64
nto   resq 1
wv    resq 8                    ; a word problem's numbers, by their WA... codes
wname resq 1
witem resq 1

section .text

global mulstep, mulsmall, divstep, addstep, substep, subcols, euclid, simp, pfrac, gcd
global add_one, sub_one, signed_one, gcd_one, frac_one, pow_one, root_one, pct_one
global order_one, word_one, sadd, coin, upto, powchain, divline

; ---- steps

; rcx = a, rdx = b. "a + b = s" on a line when both are under 100, columns when
; not. rax = s
addstep:
    cmp rcx, 99
    ja addcols
    cmp rdx, 99
    ja addcols
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    num rbx
    emit " + "
    num r12
    emit " = "
    lea rax, [rbx+r12]
    num rax
    emit 10
    lea rax, [rbx+r12]
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = a, rdx = b, a >= b. the same for a - b
substep:
    cmp rcx, 99
    ja subcols
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    num rbx
    emit " - "
    num r12
    emit " = "
    mov rax, rbx
    sub rax, r12
    num rax
    emit 10
    mov rax, rbx
    sub rax, r12
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = a, rdx = b: eax = 1 if a × b is a times table fact or one digit times two
mulsmall:
    mov rax, rcx
    mov r8, rdx
    cmp rax, r8
    jae .mm
    xchg rax, r8                ; rax the bigger, r8 the smaller
.mm:
    cmp r8, 1
    jbe .yes
    cmp rax, 12
    jbe .yes
    cmp r8, 9
    ja .no
    cmp rax, 99
    jbe .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; rcx = a, rdx = b. "a × b = p" on a line when mulsmall says so, long multiplication
; (the bigger one on top) when not. rax = p
mulstep:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    call mulsmall
    test eax, eax
    jnz .line
    mov rcx, rbx
    mov rdx, r12
    cmp rcx, rdx
    jae .w
    xchg rcx, rdx
.w:
    call mulwork
    jmp .r
.line:
    num rbx
    emit " × "
    num r12
    emit " = "
    mov rax, rbx
    imul rax, r12
    num rax
    emit 10
    mov rax, rbx
    imul rax, r12
.r:
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = a, rdx = b. "a ÷ b = q remainder r" on a line when a is under 100, long
; division when it isn't (b has to be under 100 then). rax = q, rdx = r
divstep:
    cmp rcx, 99
    ja divwork
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    mov rax, rbx
    xor edx, edx
    div r12
    mov r13, rax
    mov [rsp+32], rdx
    num rbx
    emit " ÷ "
    num r12
    emit " = "
    num r13
    cmp qword [rsp+32], 0
    je .ex
    emit " remainder "
    num [rsp+32]
.ex:
    emit 10
    mov rax, r13
    mov rdx, [rsp+32]
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = x, rdx = y, x >= y: column subtraction, ones first. rax = x - y
subcols:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    mov rbx, rcx
    mov r12, rdx
    num rbx
    emit " - "
    num r12
    emit ":", 10
    mov r14, rbx
    mov r15, r12
    xor r13d, r13d              ; borrowed
.c:
    test r14, r14
    jz .end
    mov rax, r14
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r14, rax
    mov [rsp+32], rdx           ; the top digit
    mov rax, r15
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r15, rax
    mov [rsp+40], rdx           ; the bottom one (0 once y runs out)
    num [rsp+32]
    emit " - "
    num [rsp+40]
    test r13, r13
    jz .nb
    emit " - 1"
.nb:
    mov rax, [rsp+32]
    sub rax, [rsp+40]
    sub rax, r13
    jns .ok
    emit ", borrow: "
    mov rax, [rsp+32]
    add rax, 10
    num rax
    emit " - "
    num [rsp+40]
    test r13, r13
    jz .nb2
    emit " - 1"
.nb2:
    mov rax, [rsp+32]
    add rax, 10
    sub rax, [rsp+40]
    sub rax, r13
    mov r13d, 1
    jmp .w
.ok:
    xor r13d, r13d
.w:
    mov [rsp+48], rax
    emit " = "
    num [rsp+48]
    emit ", write "
    num [rsp+48]
    emit 10
    jmp .c
.end:
    num rbx
    emit " - "
    num r12
    emit " = "
    mov rax, rbx
    sub rax, r12
    num rax
    emit 10
    mov rax, rbx
    sub rax, r12
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = a, rdx = b, a >= b > 0: Euclid's algorithm, a line a step in long division's
; style, "84 ÷ 36 = 2, 2 × 36 = 72, 84 - 72 = 12". rax = the gcd
euclid:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
.l:
    mov rax, rbx
    xor edx, edx
    div r12
    mov r13, rdx
    mov [rsp+32], rax
    num rbx
    emit " ÷ "
    num r12
    emit " = "
    num [rsp+32]
    emit ", "
    num [rsp+32]
    emit " × "
    num r12
    emit " = "
    mov rax, [rsp+32]
    imul rax, r12
    num rax
    emit ", "
    num rbx
    emit " - "
    mov rax, [rsp+32]
    imul rax, r12
    num rax
    emit " = "
    num r13
    emit 10
    test r13, r13
    jz .done
    mov rbx, r12
    mov r12, r13
    jmp .l
.done:
    mov rax, r12
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx, rdx: their gcd, quietly
gcd:
    mov rax, rcx
.l:
    test rdx, rdx
    jz .r
    mov r8, rdx
    xor edx, edx
    div r8
    mov rax, r8
    jmp .l
.r:
    ret

; rcx = n >= 0, rdx = d >= 1: n/d in lowest terms, the gcd by Euclid's algorithm.
; rax = top, rdx = bottom. 0 comes back as 0/1, and n/1 is left alone
simp:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 56
    mov rbx, rcx
    mov r12, rdx
    test rbx, rbx
    jnz .n
    mov r12d, 1
    jmp .same
.n:
    cmp r12, 1
    je .same
    emit "Simplify "
    num rbx
    emit "/"
    num r12
    emit " with the gcd of "
    num rbx
    emit " and "
    num r12
    emit ":", 10
    mov rcx, rbx
    mov rdx, r12
    cmp rcx, rdx
    jae .big
    xchg rcx, rdx
.big:
    call euclid
    mov r13, rax
    cmp r13, 1
    jne .div
    emit "gcd = 1, so "
    num rbx
    emit "/"
    num r12
    emit " can't be simplified.", 10
    jmp .same
.div:
    mov rax, rbx
    xor edx, edx
    div r13
    mov [rsp+32], rax
    mov rax, r12
    xor edx, edx
    div r13
    mov [rsp+40], rax
    cmp rbx, 99
    ja .big2
    cmp r12, 99
    jbe .small
.big2:
    emit "gcd = "               ; too big to divide in your head: short division
    num r13
    emit ", so divide the top and the bottom by it.", 10
    mov rcx, rbx
    mov rdx, r13
    call divline
    emit 10
    mov rcx, r12
    mov rdx, r13
    call divline
    emit 10
    emit "so "
    num rbx
    emit "/"
    num r12
    emit " = "
    mov rcx, [rsp+32]
    mov rdx, [rsp+40]
    call pfrac
    emit 10
    mov rax, [rsp+32]
    mov rdx, [rsp+40]
    jmp .r
.small:
    emit "gcd = "
    num r13
    emit ": "
    num rbx
    emit " ÷ "
    num r13
    emit " = "
    num [rsp+32]
    emit " and "
    num r12
    emit " ÷ "
    num r13
    emit " = "
    num [rsp+40]
    emit ", so "
    num rbx
    emit "/"
    num r12
    emit " = "
    mov rcx, [rsp+32]
    mov rdx, [rsp+40]
    call pfrac
    emit 10
    mov rax, [rsp+32]
    mov rdx, [rsp+40]
    jmp .r
.same:
    mov rax, rbx
    mov rdx, r12
.r:
    add rsp, 56
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = top (signed), rdx = bottom: "3/4", "-5/2", or just "3" over 1
pfrac:
    push rbx
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    sint rbx
    cmp r12, 1
    je .r
    mov byte [rdi], '/'
    inc rdi
    num r12
.r:
    add rsp, 40
    pop r12
    pop rbx
    ret

; rcx = b, rdx = k: b^2 up to b^k a line each, each labelled with its power so
; nobody loses count: "3^3 = 9 × 3 = 27", or "3^7 = 729 × 3:" and the long
; multiplication. rax = b^k
powchain:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    mov r13, rbx                ; b^i so far
    mov r14d, 1
.l:
    cmp r14, r12
    jae .r
    inc r14
    num rbx
    emit "^"
    num r14
    emit " = "
    mov rcx, r13
    mov rdx, rbx
    call mulsmall
    test eax, eax
    jz .long
    num r13
    emit " × "
    num rbx
    emit " = "
    imul r13, rbx
    num r13
    emit 10
    jmp .l
.long:
    num r13
    emit " × "
    num rbx
    emit ":", 10
    mov rcx, r13
    mov rdx, rbx
    call mulstep
    mov r13, rax
    jmp .l
.r:
    mov rax, r13
    test r12, r12
    jnz .nz
    mov eax, 1
.nz:
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = n, rdx = d: "n ÷ d = q" when n is under 100, short division when it isn't.
; rax = q
divline:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    num rbx
    emit " ÷ "
    num r12
    cmp rbx, 99
    ja .s
    emit " = "
    jmp .q
.s:
    emit ": "
    mov rcx, rbx
    mov rdx, r12
    call sdiv
    emit ", so "
.q:
    mov rax, rbx
    xor edx, edx
    div r12
    mov rbx, rax
    num rax
    mov rax, rbx
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rax = 0 or 1
coin:
    sub rsp, 40
    xor ecx, ecx
    mov edx, 1
    call rnd
    add rsp, 40
    ret

; rcx = k: a random number with 1-k digits, as many of each length
upto:
    sub rsp, 40
    mov edx, ecx
    mov ecx, 1
    call rnd
    mov ecx, eax
    call ndig
    add rsp, 40
    ret

; ---- topics

; a + b, 1-7 digits each, or three numbers a quarter of the time
add_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    sub rsp, 32
.pick:
    mov ecx, 7
    call upto
    mov rbx, rax
    mov ecx, 7
    call upto
    mov r12, rax
    cmp rbx, 9
    ja .ok
    cmp r12, 9
    jbe .pick                   ; one digit each is just a fact
.ok:
    xor ecx, ecx
    mov edx, 3
    call rnd
    test eax, eax
    jz .three
    lea rcx, [qadd]
    mov edx, NQADD
    mov r8, rbx
    mov r9, r12
    call ask
    emit "assistant: Add in columns, ones first.", 10
    mov rcx, rbx
    mov rdx, r12
    call addcols
    jmp .r
.three:
    mov ecx, 5
    call upto
    mov r13, rax
    xor ecx, ecx
    mov edx, 2
    call rnd
    mov r14, rax
    emit "user: "
    cmp r14, 1
    jb .t0
    je .t1
    num rbx
    emit " + "
    num r12
    emit " + "
    num r13
    emit " = ?", 10
    jmp .ta
.t0:
    emit "What is "
    num rbx
    emit " + "
    num r12
    emit " + "
    num r13
    emit "?", 10
    jmp .ta
.t1:
    emit "Add "
    num rbx
    emit ", "
    num r12
    emit " and "
    num r13
    emit ".", 10
.ta:
    emit "assistant: Add the first two, then add the third.", 10
    mov rcx, rbx
    mov rdx, r12
    call addcols
    mov rcx, rax
    mov rdx, r13
    call addcols
    mov r14, rax
    num rbx
    emit " + "
    num r12
    emit " + "
    num r13
    emit " = "
    num r14
    emit 10
.r:
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; a - b, 1-7 digits each. b is the bigger one a quarter of the time
sub_one:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
.pick:
    mov ecx, 7
    call upto
    mov rbx, rax
    mov ecx, 7
    call upto
    mov r12, rax
    cmp rbx, r12
    je .pick
    cmp rbx, 9
    ja .ok
    cmp r12, 9
    jbe .pick
.ok:
    cmp rbx, r12
    ja .q
    xor ecx, ecx
    mov edx, 3
    call rnd
    test eax, eax
    jz .q
    xchg rbx, r12
.q:
    xor ecx, ecx
    mov edx, 2
    call rnd
    test eax, eax
    jz .rev
    lea rcx, [qsub]
    mov edx, NQSUB
    mov r8, rbx
    mov r9, r12
    call ask
    jmp .ans
.rev:
    lea rcx, [qsubr]
    mov edx, NQSUBR
    mov r8, r12
    mov r9, rbx
    call ask
.ans:
    emit "assistant: "
    cmp rbx, r12
    jb .neg
    emit "Subtract in columns, ones first, and borrow 10 when the top digit is too small.", 10
    mov rcx, rbx
    mov rdx, r12
    call subcols
    jmp .r
.neg:
    num r12
    emit " is bigger than "
    num rbx
    emit ", so work out "
    num r12
    emit " - "
    num rbx
    emit " and make it negative.", 10
    mov rcx, r12
    mov rdx, rbx
    call subcols
    mov r13, rax
    num rbx
    emit " - "
    num r12
    emit " = -"
    num r13
    emit 10
.r:
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = x, rdx = y, signed: x + y, saying which rule it is. rax = x + y
sadd:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    mov rax, rbx
    xor rax, r12
    js .mixed
    test rbx, rbx
    js .bneg
    emit "Both are positive, so add them.", 10
    mov rcx, rbx
    mov rdx, r12
    call addstep
    jmp .r
.bneg:
    emit "Both are negative, so add the sizes and keep the minus sign.", 10
    mov rcx, rbx
    neg rcx
    mov rdx, r12
    neg rdx
    call addstep
    neg rax
    jmp .r
.mixed:
    emit "The signs are different, so take the smaller size from the bigger one.", 10
    mov rcx, rbx
    mov rax, rcx
    neg rax
    cmovns rcx, rax
    mov rdx, r12
    mov rax, rdx
    neg rax
    cmovns rdx, rax
    mov r13, rbx                ; whichever has the bigger size
    cmp rcx, rdx
    jae .sub
    xchg rcx, rdx
    mov r13, r12
.sub:
    call substep
    test rax, rax
    jnz .sign
    emit "The sizes are the same, so they cancel out to 0.", 10
    xor eax, eax
    jmp .r
.sign:
    mov [rsp+32], rax
    sint r13
    emit " has the bigger size, so the answer is "
    test r13, r13
    js .n
    emit "positive.", 10
    mov rax, [rsp+32]
    jmp .r
.n:
    emit "negative.", 10
    mov rax, [rsp+32]
    neg rax
.r:
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; +, -, × or ÷ with negative numbers in it
signed_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    xor ecx, ecx
    mov edx, 3
    call rnd
    mov r14, rax                ; 0 +, 1 -, 2 ×, 3 ÷
    cmp r14, 2
    je .mul
    ja .dv
    mov ecx, 3
    call upto
    mov rbx, rax
    mov ecx, 3
    call upto
    mov r12, rax
    xor ecx, ecx
    mov edx, 3
    call rnd
    test r14, r14
    jnz .subs
    test eax, eax
    jnz .sg                     ; adding: at least one of them is negative
    inc eax
    jmp .sg
.subs:
    test eax, eax
    jnz .sg
    cmp rbx, r12                ; both positive is fine if it goes below 0
    jb .sg
    ja .swap
    inc eax
    jmp .sg
.swap:
    xchg rbx, r12
    jmp .sg
.mul:
    mov ecx, 3
    call upto
    mov rbx, rax
    mov ecx, 2
    call upto
    mov r12, rax
    jmp .sg1
.dv:
    mov ecx, 2
    call upto
    mov rbx, rax
    mov ecx, 2
    mov edx, 99
    call rnd
    mov r12, rax
    imul rbx, r12
.sg1:
    mov ecx, 1
    mov edx, 3
    call rnd
.sg:
    test eax, 1
    jz .s2
    neg rbx
.s2:
    test eax, 2
    jz .ask
    neg r12
.ask:
    lea rcx, [qsg]
    mov edx, NQSG
    call askpre
    mov r13, rax
    sint rbx
    lea rax, [sgop]
    mov rcx, [rax+r14*8]
    call emz
    pint r12
    mov rcx, r13
    call emz
    emit 10
    emit "assistant: "
    cmp r14, 2
    jae .amd
    mov r13, r12                ; what gets added
    test r14, r14
    jz .add
    neg r13
    emit "Subtracting "
    sint r12
    emit " is the same as adding "
    sint r13
    emit ", so this is "
    sint rbx
    emit " + "
    pint r13
    emit ".", 10
.add:
    mov rcx, rbx
    mov rdx, r13
    call sadd
    mov r15, rax
    jmp .fin
.amd:
    mov rax, rbx
    xor rax, r12
    js .diff
    emit "Both are negative, so the answer is positive.", 10
    jmp .sz
.diff:
    emit "The signs are different, so the answer is negative.", 10
.sz:
    mov rcx, rbx
    mov rax, rcx
    neg rax
    cmovns rcx, rax
    mov rdx, r12
    mov rax, rdx
    neg rax
    cmovns rdx, rax
    cmp r14, 3
    je .adv
    call mulstep
    jmp .sgn
.adv:
    call divstep
.sgn:
    mov r15, rax
    mov rax, rbx
    xor rax, r12
    jns .fin
    neg r15
.fin:
    sint rbx
    lea rax, [sgop]
    mov rcx, [rax+r14*8]
    call emz
    pint r12
    emit " = "
    sint r15
    emit 10
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; gcd or lcm of a (up to 999) and b (6-99), with a < 10b so Euclid's first step fits
; on a line too. most of them have a common factor bigger than 1
gcd_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
.pick:
    mov ecx, 1
    mov edx, 25
    call rnd
    mov r13, rax                ; a common factor
    xor ecx, ecx
    mov edx, 3
    call rnd
    test eax, eax
    jnz .m
    mov r13d, 1
.m:
    mov ecx, 2
    mov edx, 60
    call rnd
    mov rbx, rax
    mov ecx, 1
    lea rdx, [rbx-1]
    call rnd
    mov r12, rax
    imul rbx, r13               ; a
    imul r12, r13               ; b
    cmp rbx, 999
    ja .pick
    cmp r12, 6
    jb .pick
    cmp r12, 99
    ja .pick
    imul rax, r12, 10
    cmp rbx, rax
    jae .pick
    mov r13, rbx                ; the question's order
    mov r15, r12
    call coin
    test eax, eax
    jz .which
    xchg r13, r15
.which:
    call coin
    mov r14, rax                ; 0 gcd, 1 lcm
    lea rcx, [qgcd]
    mov edx, NQGCD
    test r14, r14
    jz .q
    lea rcx, [qlcm]
    mov edx, NQLCM
.q:
    mov r8, r13
    mov r9, r15
    call ask
    emit "assistant: "
    test r14, r14
    jnz .lcm
    emit "Euclid's algorithm: divide the bigger number by the smaller, then the smaller by the remainder, and so on until the remainder is 0.", 10
    mov rcx, rbx
    mov rdx, r12
    call euclid
    mov [rsp+32], rax
    emit "The remainder is 0, so the gcd is the last divisor: "
    num [rsp+32]
    emit ".", 10
    emit "gcd("
    jmp .fin
.lcm:
    emit "lcm("
    num r13
    emit ", "
    num r15
    emit ") = "
    num r12
    emit " ÷ gcd × "
    num rbx
    emit ", and Euclid's algorithm gives the gcd.", 10
    mov rcx, rbx
    mov rdx, r12
    call euclid
    mov [rsp+32], rax
    emit "gcd = "
    num [rsp+32]
    emit 10
    mov rcx, r12
    mov rdx, [rsp+32]
    call divstep
    mov rcx, rax
    mov rdx, rbx
    call mulstep
    mov [rsp+32], rax
    emit "lcm("
.fin:
    num r13
    emit ", "
    num r15
    emit ") = "
    num [rsp+32]
    emit 10
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; a/b op c/d, from rbx, r12, r14 (the op), r13, r15
%macro fexpr 0
    num rbx
    emit "/"
    num r12
    lea rax, [sgop]
    mov rcx, [rax+r14*8]
    call emz
    num r13
    emit "/"
    num r15
%endmacro

; rcx = top, rdx = bottom, r8 = the common bottom: "3/4 = (3 × 3)/(4 × 3) = 9/12".
; rax = the new top
scale:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    mov r13, r8
    num rbx
    emit "/"
    num r12
    cmp r12, r13
    jne .s
    emit " already has "
    num r13
    emit " at the bottom.", 10
    mov rax, rbx
    jmp .r
.s:
    mov rax, r13
    xor edx, edx
    div r12
    mov r14, rax
    emit " = ("
    num rbx
    emit " × "
    num r14
    emit ")/("
    num r12
    emit " × "
    num r14
    emit ") = "
    mov rax, rbx
    imul rax, r14
    num rax
    emit "/"
    num r13
    emit 10
    mov rax, rbx
    imul rax, r14
.r:
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; a/b and c/d, tops 1-12 and bottoms 2-12: + - × ÷, and the answer in lowest terms
frac_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88
    xor ecx, ecx
    mov edx, 3
    call rnd
    mov r14, rax
.pick:
    mov ecx, 1
    mov edx, 12
    call rnd
    mov rbx, rax
    mov ecx, 2
    mov edx, 12
    call rnd
    mov r12, rax
    mov ecx, 1
    mov edx, 12
    call rnd
    mov r13, rax
    mov ecx, 2
    mov edx, 12
    call rnd
    mov r15, rax
    cmp r14, 1
    jne .q
    mov rax, rbx                ; a subtraction stays above 0, swap them if not
    imul rax, r15
    mov rdx, r13
    imul rdx, r12
    cmp rax, rdx
    je .pick
    ja .q
    xchg rbx, r13
    xchg r12, r15
.q:
    lea rcx, [qsg]
    mov edx, NQSG
    call askpre
    mov [rsp+32], rax
    fexpr
    mov rcx, [rsp+32]
    call emz
    emit 10
    emit "assistant: "
    cmp r14, 2
    jae .md
    cmp r12, r15
    jne .lcd
    emit "They already have the same denominator.", 10
    mov [rsp+40], rbx
    mov [rsp+48], r13
    mov [rsp+56], r12
    jmp .tops
.lcd:
    emit "First give them the same denominator: the smallest number that both "
    num r12
    emit " and "
    num r15
    emit " go into.", 10
    mov rax, r12
    mov rdx, r15
    cmp rax, rdx
    jae .mx
    xchg rax, rdx
.mx:
    mov [rsp+64], rax           ; count up in the bigger one
    mov [rsp+72], rdx
    mov qword [rsp+80], 0
.cnt:
    inc qword [rsp+80]
    num [rsp+64]
    emit " × "
    num [rsp+80]
    emit " = "
    mov rax, [rsp+64]
    imul rax, [rsp+80]
    mov [rsp+56], rax
    num rax
    emit ", "
    num [rsp+56]
    emit " ÷ "
    num [rsp+72]
    emit " = "
    mov rax, [rsp+56]
    xor edx, edx
    div qword [rsp+72]
    mov [rsp+48], rdx
    num rax
    cmp qword [rsp+48], 0
    je .yes
    emit " remainder "
    num [rsp+48]
    emit ", no", 10
    jmp .cnt
.yes:
    emit ", yes", 10
    mov rcx, rbx
    mov rdx, r12
    mov r8, [rsp+56]
    call scale
    mov [rsp+40], rax
    mov rcx, r13
    mov rdx, r15
    mov r8, [rsp+56]
    call scale
    mov [rsp+48], rax
.tops:
    test r14, r14
    jnz .tsub
    emit "Now add the tops:", 10
    mov rcx, [rsp+40]
    mov rdx, [rsp+48]
    call addstep
    jmp .that
.tsub:
    emit "Now subtract the tops:", 10
    mov rcx, [rsp+40]
    mov rdx, [rsp+48]
    call substep
.that:
    mov [rsp+64], rax
    emit "That's "
    num [rsp+64]
    emit "/"
    num [rsp+56]
    emit ".", 10
    mov rcx, [rsp+64]
    mov rdx, [rsp+56]
    call simp
    jmp .fin
.md:
    mov [rsp+40], r13
    mov [rsp+48], r15
    cmp r14, 3
    jne .mm
    emit "Dividing by "
    num r13
    emit "/"
    num r15
    emit " is the same as multiplying by "
    num r15
    emit "/"
    num r13
    emit ", so this is "
    num rbx
    emit "/"
    num r12
    emit " × "
    num r15
    emit "/"
    num r13
    emit ".", 10
    mov [rsp+40], r15
    mov [rsp+48], r13
.mm:
    emit "Multiply the tops and multiply the bottoms.", 10
    mov rcx, rbx
    mov rdx, [rsp+40]
    call mulstep
    mov [rsp+56], rax
    mov rcx, r12
    mov rdx, [rsp+48]
    call mulstep
    mov [rsp+64], rax
    emit "That's "
    num [rsp+56]
    emit "/"
    num [rsp+64]
    emit ".", 10
    mov rcx, [rsp+56]
    mov rdx, [rsp+64]
    call simp
.fin:
    mov [rsp+40], rax
    mov [rsp+48], rdx
    fexpr
    emit " = "
    mov rcx, [rsp+40]
    mov rdx, [rsp+48]
    call pfrac
    emit 10
    add rsp, 88
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; b^n from rbx, r12, and r14 = 1 for a negative b: 3^4 or (-3)^4
%macro ppow 0
    test r14, r14
    jz %%pos
    emit "(-"
    num rbx
    emit ")"
    jmp %%e
%%pos:
    num rbx
%%e:
    emit "^"
    num r12
%endmacro

; the rules' expressions, from r14 (which), rbx = a, r12 = b, r13 = k, r15 = m:
; x^a × x^b, x^a ÷ x^b, (x^a)^b, (kx^a)(mx^b)
%macro rexpr 0
    cmp r14, 2
    je %%pp
    ja %%km
    mov ecx, 1
    mov rdx, rbx
    call mono
    lea rcx, [otimes]
    test r14, r14
    jz %%op
    lea rcx, [odiv]
%%op:
    call emz
    mov ecx, 1
    mov rdx, r12
    call mono
    jmp %%e
%%pp:
    mov byte [rdi], '('
    inc rdi
    mov ecx, 1
    mov rdx, rbx
    call mono
    emit ")^"
    num r12
    jmp %%e
%%km:
    mov byte [rdi], '('
    inc rdi
    mov rcx, r13
    mov rdx, rbx
    call mono
    emit ")("
    mov rcx, r15
    mov rdx, r12
    call mono
    mov byte [rdi], ')'
    inc rdi
%%e:
%endmacro

; b^n worked out as a chain of products, now and then with a negative b, or a third
; of the time one of the rules for powers of x
pow_one:
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
    cmp eax, 2
    je .rules
.pick:
    mov ecx, 2
    mov edx, 12
    call rnd
    mov rbx, rax                ; b
    mov ecx, 2
    mov edx, 6
    call rnd
    mov r12, rax                ; n
    xor ecx, ecx
    mov edx, 15
    call rnd
    cmp eax, 1
    ja .big
    mov r12, rax                ; now and then a power of 0 or 1
.big:
    mov eax, 1
    mov rcx, r12
.p:
    test rcx, rcx
    jz .pd
    imul rax, rbx
    dec rcx
    jmp .p
.pd:
    cmp rax, 1000000            ; b^n stays under a million
    ja .pick
    mov r13, rax
    xor r14d, r14d
    xor ecx, ecx
    mov edx, 3
    call rnd
    test eax, eax
    jnz .q
    mov r14d, 1
.q:
    test r14, r14               ; a third of the plain ones in words: 5 squared
    jnz .qs
    xor ecx, ecx
    mov edx, 2
    call rnd
    test eax, eax
    jnz .qs
    call pword
    jmp .qd
.qs:
    lea rcx, [qpow]
    mov edx, NQPOW
    call askpre
    mov r15, rax
    ppow
    mov rcx, r15
    call emz
    emit 10
.qd:
    emit "assistant: "
    cmp r12, 1
    ja .chain
    je .one
    emit "Any number but 0 to the power 0 is 1.", 10
    jmp .fin
.one:
    emit "A number to the power 1 is just itself.", 10
    jmp .fin
.chain:
    test r14, r14
    jz .ch
    test r12, 1
    jnz .odd
    emit "A negative number to an even power is positive, so work out "
    num rbx
    emit "^"
    num r12
    emit ".", 10
    jmp .ch
.odd:
    emit "A negative number to an odd power is negative, so work out "
    num rbx
    emit "^"
    num r12
    emit " and make it negative.", 10
.ch:
    num rbx
    emit "^"
    num r12
    emit " = "
    mov r15, r12
.ml:
    num rbx
    dec r15
    jz .mld
    emit " × "
    jmp .ml
.mld:
    emit 10
    mov rcx, rbx
    mov rdx, r12
    call powchain
.md:
    test r14, r14
    jz .fin
    num rbx
    emit "^"
    num r12
    emit " = "
    num r13
    emit 10
.fin:
    ppow
    emit " = "
    mov rax, r13
    test r14, r14
    jz .v
    test r12, 1
    jz .v
    neg rax
.v:
    sint rax
    emit 10
    jmp .r
.rules:
    xor ecx, ecx
    mov edx, 3
    call rnd
    lea rcx, [letters]
    mov al, [rcx+rax]
    mov [letter], al
    xor ecx, ecx
    mov edx, 3
    call rnd
    mov r14, rax
    mov ecx, 2
    mov edx, 9
    call rnd
    mov rbx, rax                ; a
    mov ecx, 2
    mov edx, 9
    call rnd
    mov r12, rax                ; b
    cmp r14, 1
    jne .km
    add rbx, r12                ; dividing: a > b
.km:
    mov ecx, 2
    mov edx, 9
    call rnd
    mov r13, rax                ; k
    mov ecx, 2
    mov edx, 9
    call rnd
    mov r15, rax                ; m
    lea rcx, [qrule]
    mov edx, NQRULE
    call askpre
    mov [rsp+32], rax
    rexpr
    mov rcx, [rsp+32]
    call emz
    emit 10
    emit "assistant: "
    mov qword [rsp+32], 1       ; the coefficient
    cmp r14, 1
    jb .r0
    je .r1
    cmp r14, 2
    je .r2
    emit "Multiply the numbers and add the exponents: "
    num r13
    emit " × "
    num r15
    emit " = "
    mov rax, r13
    imul rax, r15
    mov [rsp+32], rax
    num rax
    emit ", and "
    jmp .add
.r0:
    emit "When you multiply powers of "
    call letr
    emit ", add the exponents: "
.add:
    num rbx
    emit " + "
    num r12
    emit " = "
    lea rax, [rbx+r12]
    mov [rsp+40], rax
    jmp .rd
.r1:
    emit "When you divide powers of "
    call letr
    emit ", subtract the exponents: "
    num rbx
    emit " - "
    num r12
    emit " = "
    mov rax, rbx
    sub rax, r12
    mov [rsp+40], rax
    jmp .rd
.r2:
    emit "A power of a power multiplies the exponents: "
    num rbx
    emit " × "
    num r12
    emit " = "
    mov rax, rbx
    imul rax, r12
    mov [rsp+40], rax
.rd:
    num [rsp+40]
    emit ".", 10
    rexpr
    emit " = "
    mov rcx, [rsp+32]
    mov rdx, [rsp+40]
    call mono
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

; √n in simplest form, by factoring n = s^2 × t, t square-free
root_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
.pick:
    mov ecx, 1
    mov edx, 30
    call rnd
    mov rbx, rax                ; s
    xor ecx, ecx
    mov edx, NINSIDE - 1
    call rnd
    lea rcx, [inside]
    mov r12, [rcx+rax*8]        ; t
    mov rax, rbx
    imul rax, rbx
    imul rax, r12
    cmp rax, 4
    jb .pick
    mov r13, rax                ; n
    cmp rbx, 1
    jne .q
    xor ecx, ecx                ; nothing comes out: only some of those
    mov edx, 2
    call rnd
    test eax, eax
    jnz .pick
.q:
    lea rcx, [qroot]
    mov edx, NQROOT
    call askpre
    mov r15, rax
    num r13
    mov rcx, r15
    call emz
    emit 10
    emit "assistant: Factor "
    num r13
    emit " into primes. Each pair of the same prime comes out of the root as one of them.", 10
    mov rcx, r13
    call factwork
    mov r14d, 1                 ; what comes out
    mov r15d, 1                 ; what stays inside
    xor ebx, ebx
    mov qword [rsp+48], 0       ; how many come out
.f:
    cmp rbx, [nf]
    jae .fd
    lea rax, [fp]
    mov r12, [rax+rbx*8]
    lea rax, [fe]
    mov rax, [rax+rbx*8]
    mov [rsp+32], rax
    num r12
    cmp qword [rsp+32], 1
    ja .pw
    emit ": no pair, so it stays inside", 10
    imul r15, r12
    jmp .nx
.pw:
    emit "^"
    num [rsp+32]
    emit ": "
    mov rax, [rsp+32]
    shr rax, 1
    mov [rsp+40], rax           ; pairs
    num rax
    cmp qword [rsp+40], 1
    ja .prs
    emit " pair of "
    jmp .of
.prs:
    emit " pairs of "
.of:
    num r12
    emit "s, so "
    cmp qword [rsp+40], 1
    je .p1
    num r12
    emit "^"
    num [rsp+40]
    emit " = "
.p1:
    mov rcx, [rsp+40]
    mov eax, 1
.pk:
    imul rax, r12
    dec rcx
    jnz .pk
    imul r14, rax
    inc qword [rsp+48]
    num rax
    emit " comes out"
    test qword [rsp+32], 1
    jz .eol
    emit " and one "
    num r12
    emit " stays inside"
    imul r15, r12
.eol:
    emit 10
.nx:
    inc rbx
    jmp .f
.fd:
    cmp qword [rsp+48], 0
    jne .some
    emit "No prime comes in a pair, so nothing comes out.", 10
    emit "√"
    num r13
    emit " can't be simplified.", 10
    jmp .r
.some:
    xor ecx, ecx                ; the products, when there's more than one number
    call chain
    mov ecx, 1
    call chain
    emit "√"
    num r13
    emit " = "
    num r14
    cmp r15, 1
    je .eol2
    emit "√"
    num r15
.eol2:
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

; pow_one's question in words, from rbx = b, r12 = n: "What is 5 squared?",
; "2 to the power of 10", "Work out 3 cubed."
pword:
    push rsi
    push r13
    sub rsp, 40
    xor ecx, ecx
    mov edx, 2
    call rnd
    mov r13, rax
    emit "user: "
    test r13, r13
    jnz .w1
    emit "What is "
    jmp .b
.w1:
    cmp r13, 2
    jne .b
    emit "Work out "
.b:
    num rbx
    cmp r12, 2
    jne .c
    emit " squared"
    jmp .e
.c:
    cmp r12, 3
    jne .p
    emit " cubed"
    jmp .e
.p:
    emit " to the power of "
    num r12
.e:
    test r13, r13
    jnz .e1
    emit "?"
    jmp .e3
.e1:
    cmp r13, 2
    jne .e3
    emit "."
.e3:
    emit 10
    add rsp, 40
    pop r13
    pop rsi
    ret

; ecx = 0: what comes out of root_one's factorization, multiplied up a line at a
; time. 1: what stays inside. nothing when it's just one number
chain:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    sub rsp, 48
    mov r12, rcx
    xor ebx, ebx
    xor r13d, r13d              ; the product, 0 = nothing yet
    xor r14d, r14d              ; said which this is
.l:
    cmp rbx, [nf]
    jae .r
    lea rax, [fe]
    mov rax, [rax+rbx*8]
    lea rcx, [fp]
    mov rcx, [rcx+rbx*8]
    test r12, r12
    jnz .in
    cmp rax, 2
    jb .n
    shr rax, 1                  ; p^(e/2)
    mov rdx, rax
    mov eax, 1
.pk:
    imul rax, rcx
    dec rdx
    jnz .pk
    jmp .got
.in:
    test rax, 1
    jz .n
    mov rax, rcx
.got:
    test r13, r13
    jnz .mul
    mov r13, rax
    jmp .n
.mul:
    mov [rsp+32], rax
    test r14, r14
    jnz .said
    mov r14d, 1
    lea rcx, [s_out]
    test r12, r12
    jz .say
    lea rcx, [s_in]
.say:
    call emz
.said:
    mov rcx, r13
    mov rdx, [rsp+32]
    call mulstep
    mov r13, rax
.n:
    inc rbx
    jmp .l
.r:
    add rsp, 48
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; p% of n, what percent m is of n, and n gone up or down by p%
pct_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    xor ecx, ecx
    mov edx, 3
    call rnd
    mov r14, rax                ; 0 of, 1 what percent, 2 up, 3 down
    cmp r14, 1
    je .what
    mov ecx, 1
    mov edx, 99
    call rnd
    mov rbx, rax                ; p
    mov rcx, rax
    mov edx, 100
    call gcd
    mov rcx, rax
    mov eax, 100
    xor edx, edx
    div rcx
    mov r13, rax                ; p/100's bottom in lowest terms
    mov eax, 2000
    xor edx, edx
    div r13
    mov ecx, 1
    mov rdx, rax
    call rnd
    imul rax, r13
    mov r12, rax                ; n, a multiple of it so p% of n is whole
    test r14, r14
    jnz .ud
    lea rcx, [qpct]
    mov edx, NQPCT
    mov r8, rbx
    mov r9, r12
    call ask
    emit "assistant: "
    jmp .of
.ud:
    xor ecx, ecx
    mov edx, 2
    call rnd
    mov [rsp+32], rax
    emit "user: "
    cmp qword [rsp+32], 1
    jb .u0
    je .u1
    emit "What is "
    num r12
    lea rcx, [s_upby]
    cmp r14, 2
    je .u2
    lea rcx, [s_downby]
.u2:
    call emz
    num rbx
    emit "%?", 10
    jmp .uq
.u0:
    lea rcx, [s_inc]
    cmp r14, 2
    je .u3
    lea rcx, [s_dec]
.u3:
    call emz
    num r12
    emit " by "
    num rbx
    emit "%.", 10
    jmp .uq
.u1:
    emit "A price of "
    num r12
    emit " goes "
    lea rcx, [s_up]
    cmp r14, 2
    je .u4
    lea rcx, [s_down]
.u4:
    call emz
    emit " by "
    num rbx
    emit "%. What is it now?", 10
.uq:
    emit "assistant: First find "
    num rbx
    emit "% of "
    num r12
    cmp r14, 2
    jne .dn
    emit ", then add it on.", 10
    jmp .of
.dn:
    emit ", then take it off.", 10
.of:
    num rbx
    emit "% means "
    num rbx
    emit "/100.", 10
    mov rcx, rbx
    mov edx, 100
    call simp
    mov [rsp+40], rax           ; the top, the bottom is r13
    emit "So it's "
    mov rcx, [rsp+40]
    mov rdx, r13
    call pfrac
    emit " of "
    num r12
    emit ": "
    num r12
    emit " ÷ "
    num r13
    cmp qword [rsp+40], 1
    je .na
    emit " × "
    num [rsp+40]
.na:
    emit ".", 10
    mov rcx, r12
    mov rdx, r13
    call divstep
    cmp qword [rsp+40], 1
    je .got
    mov rcx, rax
    mov rdx, [rsp+40]
    call mulstep
.got:
    mov r15, rax                ; p% of n
    test r14, r14
    jnz .chg
    num rbx
    emit "% of "
    num r12
    emit " = "
    num r15
    emit 10
    jmp .r
.chg:
    cmp r14, 2
    jne .take
    mov rcx, r12
    mov rdx, r15
    call addstep
    mov r15, rax
    num r12
    emit " increased by "
    jmp .fin
.take:
    mov rcx, r12
    mov rdx, r15
    call substep
    mov r15, rax
    num r12
    emit " decreased by "
.fin:
    num rbx
    emit "% is "
    num r15
    emit 10
    jmp .r
.what:
    xor ecx, ecx                ; m/n = a/b with b going into 100
    mov edx, 6
    call rnd
    lea rcx, [pdivs]
    mov r13, [rcx+rax*8]
    mov ecx, 1
    lea rdx, [r13-1]
    call rnd
    mov rbx, rax
    mov eax, 2000
    xor edx, edx
    div r13
    mov ecx, 1
    mov rdx, rax
    call rnd
    imul rbx, rax               ; m
    imul r13, rax
    mov r12, r13                ; n
    xor ecx, ecx
    mov edx, 3
    call rnd
    mov [rsp+32], rax
    emit "user: "
    cmp qword [rsp+32], 1
    jb .w0
    je .w1
    cmp qword [rsp+32], 2
    je .w2
    emit "Write "
    num rbx
    emit "/"
    num r12
    emit " as a percent.", 10
    jmp .wa
.w0:
    emit "What percent of "
    num r12
    emit " is "
    num rbx
    emit "?", 10
    jmp .wa
.w1:
    num rbx
    emit " is what percent of "
    num r12
    emit "?", 10
    jmp .wa
.w2:
    emit "What is "
    num rbx
    emit " out of "
    num r12
    emit " as a percentage?", 10
.wa:
    emit "assistant: As a fraction that's "
    num rbx
    emit "/"
    num r12
    emit ", and a percent is out of 100.", 10
    mov rcx, rbx
    mov rdx, r12
    call simp
    mov [rsp+40], rax
    mov [rsp+48], rdx
    emit "100 ÷ "
    num [rsp+48]
    emit " = "
    mov eax, 100
    xor edx, edx
    div qword [rsp+48]
    num rax
    emit 10
    mov rcx, [rsp+40]
    mov rdx, [rsp+48]
    mov r8d, 100
    call scale
    mov r15, rax
    num rbx
    emit " is "
    num r15
    emit "% of "
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

; ---- order of operations

; ecx = depth left: a random expression tree, its value in nv. bad gets set when a
; step would be too big to do in your head, or a division wouldn't come out whole.
; rax = the node
gnode:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    sub rsp, 32
    mov r12d, ecx
    mov rbx, [nn]
    inc qword [nn]
    xor r13d, r13d
    xor r14d, r14d
    test r12d, r12d
    jz .leaf
    xor ecx, ecx
    mov edx, 3
    call rnd
    test eax, eax
    jz .leaf
    xor ecx, ecx
    mov edx, 11
    call rnd
    lea rcx, [opmix]
    movzx esi, byte [rcx+rax]
    lea rcx, [xop]
    mov [rcx+rbx], sil
    inc qword [nops]
    cmp esi, 4
    je .div
    ja .pow
    lea ecx, [r12-1]
    call gnode
    mov r13, rax
    lea ecx, [r12-1]
    call gnode
    mov r14, rax
    lea rcx, [nv]
    mov r8, [rcx+r13*8]
    mov r9, [rcx+r14*8]
    cmp esi, 2
    jb .add
    je .sub
    mov r10, r8                 ; ×: times tables, or one digit times two
    mov r11, r9
    cmp r10, r11
    jae .mm
    xchg r10, r11
.mm:
    cmp r10, 12
    jbe .mok
    cmp r11, 9
    ja .bad
    cmp r10, 99
    ja .bad
.mok:
    mov rax, r8
    imul rax, r9
    jmp .set
.add:
    cmp r8, 99
    ja .bad
    cmp r9, 99
    ja .bad
    lea rax, [r8+r9]
    jmp .set
.sub:
    cmp r8, 99
    ja .bad
    cmp r9, 99
    ja .bad
    cmp r8, r9
    jae .sok
    xchg r13, r14
    xchg r8, r9
.sok:
    mov rax, r8
    sub rax, r9
    jmp .set
.div:
    lea ecx, [r12-1]
    call gnode
    mov r14, rax                ; the divisor
    lea rcx, [nv]
    mov r9, [rcx+r14*8]
    cmp r9, 2
    jb .bad
    cmp r9, 49
    ja .bad
    mov eax, 99
    xor edx, edx
    div r9
    mov ecx, 1
    mov rdx, rax
    call rnd
    mov rsi, rax                ; the answer
    mov r13, [nn]               ; and a number it goes into, under 100
    inc qword [nn]
    lea rcx, [xop]
    mov byte [rcx+r13], 0
    lea rcx, [nv]
    mov r9, [rcx+r14*8]
    imul r9, rsi
    mov [rcx+r13*8], r9
    mov rax, rsi
    jmp .set
.pow:
    lea ecx, [r12-1]
    call gnode
    mov r13, rax                ; the base, 2-12
    lea rcx, [nv]
    mov r8, [rcx+r13*8]
    cmp r8, 2
    jb .bad
    cmp r8, 12
    ja .bad
    mov esi, 2                  ; squared, or now and then cubed up to 9
    cmp r8, 9
    ja .e
    xor ecx, ecx
    mov edx, 2
    call rnd
    test eax, eax
    jnz .e
    mov esi, 3
.e:
    mov r14, [nn]
    inc qword [nn]
    lea rcx, [xop]
    mov byte [rcx+r14], 0
    lea rcx, [nv]
    mov [rcx+r14*8], rsi
    mov r8, [rcx+r13*8]
    mov rax, r8
    imul rax, r8
    cmp esi, 3
    jne .set
    imul rax, r8
    jmp .set
.bad:
    mov qword [bad], 1
    mov eax, 1
.set:
    lea rcx, [nv]
    mov [rcx+rbx*8], rax
    lea rcx, [nl]
    mov [rcx+rbx], r13b
    lea rcx, [nr]
    mov [rcx+rbx], r14b
    mov rax, rbx
    jmp .r
.leaf:
    lea rcx, [xop]
    mov byte [rcx+rbx], 0
    mov ecx, 1
    mov edx, 20
    call rnd
    lea rcx, [nv]
    mov [rcx+rbx*8], rax
    mov rax, rbx
.r:
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; ecx = token type, rdx = its number
tpush:
    mov rax, [ntok]
    lea r9, [tt]
    mov [r9+rax], cl
    lea r9, [tv]
    mov [r9+rax*8], rdx
    inc qword [ntok]
    ret

; rcx = a token to take out
tdel:
    lea r8, [tt]
    lea r9, [tv]
    dec qword [ntok]
.l:
    cmp rcx, [ntok]
    jae .r
    mov al, [r8+rcx+1]
    mov [r8+rcx], al
    mov rax, [r9+rcx*8+8]
    mov [r9+rcx*8], rax
    inc rcx
    jmp .l
.r:
    ret

; ecx = node, edx = its parent's precedence, r8 = 1 if it's on the right: its tokens
; on the end. brackets go on when it binds looser than the parent, or the same on
; the right (so left to right still gives the tree), or anything under a power
tnode:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov ebx, ecx
    lea rax, [xop]
    movzx r12d, byte [rax+rbx]
    test r12d, r12d
    jnz .op
    lea rax, [nv]
    mov rdx, [rax+rbx*8]
    xor ecx, ecx
    call tpush
    jmp .r
.op:
    lea rax, [prec]
    movzx r13d, byte [rax+r12]
    xor esi, esi
    cmp r13d, edx
    jb .br
    ja .nb
    test r8, r8
    jnz .br
    cmp edx, 3
    jne .nb
.br:
    mov esi, 1
    mov ecx, 6
    xor edx, edx
    call tpush
.nb:
    lea rax, [nl]
    movzx ecx, byte [rax+rbx]
    mov edx, r13d
    xor r8d, r8d
    call tnode
    mov ecx, r12d
    xor edx, edx
    call tpush
    lea rax, [nr]
    movzx ecx, byte [rax+rbx]
    mov edx, r13d
    mov r8d, 1
    call tnode
    test esi, esi
    jz .r
    mov ecx, 7
    xor edx, edx
    call tpush
.r:
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; the tokens at rdi
ptoks:
    push rbx
    push rsi
    sub rsp, 40
    xor ebx, ebx
.l:
    cmp rbx, [ntok]
    jae .r
    lea rax, [tt]
    movzx eax, byte [rax+rbx]
    test eax, eax
    jnz .op
    lea rax, [tv]
    num [rax+rbx*8]
    jmp .n
.op:
    lea rcx, [tokstr]
    mov rcx, [rcx+rax*8]
    call emz
.n:
    inc rbx
    jmp .l
.r:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = from, rdx = to (not included), r8 r9 = two op types. rax = the first token
; that's either, or -1
findop:
    lea r10, [tt]
.l:
    cmp rcx, rdx
    jae .none
    movzx eax, byte [r10+rcx]
    cmp eax, r8d
    je .f
    cmp eax, r9d
    je .f
    inc rcx
    jmp .l
.f:
    mov rax, rcx
    ret
.none:
    mov rax, -1
    ret

; an expression with 2-7 operations, worked out a step at a time in the usual order:
; the innermost brackets, then powers, × and ÷, + and -, each left to right
order_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
.gen:
    mov qword [nn], 0
    mov qword [nops], 0
    mov qword [bad], 0
    mov ecx, 3
    call gnode
    cmp qword [bad], 0
    jne .gen
    cmp qword [nops], 2
    jb .gen
    mov qword [ntok], 0
    mov ecx, eax
    xor edx, edx
    xor r8d, r8d
    call tnode
    mov rcx, [ntok]             ; keep it as it was asked
    mov [nto], rcx
.cp:
    dec rcx
    js .cpd
    lea rax, [tt]
    mov dl, [rax+rcx]
    lea rax, [ot]
    mov [rax+rcx], dl
    lea rax, [tv]
    mov rdx, [rax+rcx*8]
    lea rax, [ov]
    mov [rax+rcx*8], rdx
    jmp .cp
.cpd:
    lea rcx, [qord]
    mov edx, NQORD
    call askpre
    mov rbx, rax
    call ptoks
    mov rcx, rbx
    call emz
    emit 10
    emit "assistant: Brackets first, then powers, then × and ÷ from left to right, then + and - from left to right.", 10
.step:
    xor r12d, r12d              ; where to look
    mov r13, [ntok]
    xor r14d, r14d              ; 1 = in brackets
    lea rax, [tt]
    xor ecx, ecx
.fc:
    cmp rcx, [ntok]
    jae .look
    cmp byte [rax+rcx], 7
    je .close
    inc rcx
    jmp .fc
.close:
    mov r13, rcx                ; the first ) and the ( before it
.fo:
    dec rcx
    cmp byte [rax+rcx], 6
    jne .fo
    lea r12, [rcx+1]
    mov r14d, 1
.look:
    mov rcx, r12
    mov rdx, r13
    mov r8d, 5
    mov r9d, 5
    call findop
    cmp rax, -1
    jne .got
    mov rcx, r12
    mov rdx, r13
    mov r8d, 3
    mov r9d, 4
    call findop
    cmp rax, -1
    jne .got
    mov rcx, r12
    mov rdx, r13
    mov r8d, 1
    mov r9d, 2
    call findop
.got:
    mov r15, rax
    lea rax, [tt]
    movzx ebx, byte [rax+r15]
    lea rcx, [verb]
    mov rcx, [rcx+rbx*8]
    test r14, r14
    jz .v
    lea rcx, [s_inbr]
.v:
    call emz
    lea rax, [tv]
    num [rax+r15*8-8]
    lea rcx, [tokstr]
    mov rcx, [rcx+rbx*8]
    call emz
    lea rax, [tv]
    num [rax+r15*8+8]
    emit " = "
    lea rax, [tv]
    mov r8, [rax+r15*8-8]
    mov r9, [rax+r15*8+8]
    cmp ebx, 2
    jb .o1
    je .o2
    cmp ebx, 4
    jb .o3
    je .o4
    mov rax, r8                 ; squared or cubed
    imul rax, r8
    cmp r9, 3
    jne .sv
    imul rax, r8
    jmp .sv
.o1:
    lea rax, [r8+r9]
    jmp .sv
.o2:
    mov rax, r8
    sub rax, r9
    jmp .sv
.o3:
    mov rax, r8
    imul rax, r9
    jmp .sv
.o4:
    mov rax, r8
    xor edx, edx
    div r9
.sv:
    lea rcx, [tv]
    mov [rcx+r15*8-8], rax
    num rax
    lea rcx, [r15+1]
    call tdel
    mov rcx, r15
    call tdel
    test r14, r14               ; a number on its own in brackets loses them
    jz .more
    lea rax, [tt]
    cmp byte [rax+r15], 7
    jne .more
    cmp byte [rax+r15-2], 6
    jne .more
    mov rcx, r15
    call tdel
    lea rcx, [r15-2]
    call tdel
.more:
    cmp qword [ntok], 1
    je .done
    emit ", so "
    call ptoks
    emit 10
    jmp .step
.done:
    emit 10
    mov rbx, [tv]               ; the value
    mov rcx, [nto]
    mov [ntok], rcx
.cb:
    dec rcx
    js .cbd
    lea rax, [ot]
    mov dl, [rax+rcx]
    lea rax, [tt]
    mov [rax+rcx], dl
    lea rax, [ov]
    mov rdx, [rax+rcx*8]
    lea rax, [tv]
    mov [rax+rcx*8], rdx
    jmp .cb
.cbd:
    call ptoks
    emit " = "
    num rbx
    emit 10
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; ---- word problems

; rcx = a template: its name, numbers, things and answers filled in at rdi
wexp:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
.l:
    movzx eax, byte [rbx]
    inc rbx
    test eax, eax
    jz .r
    cmp eax, 8
    jb .slot
    mov [rdi], al
    inc rdi
    jmp .l
.slot:
    cmp eax, WN
    je .name
    cmp eax, WI
    je .item
    lea rcx, [wv]
    sint [rcx+rax*8]
    jmp .l
.name:
    mov rcx, [wname]
    call emz
    jmp .l
.item:
    mov rcx, [witem]
    call emz
    jmp .l
.r:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; one of the templates in wtab, with a random name, things and numbers in its ranges
word_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    xor ecx, ecx
    mov edx, NWORD - 1
    call rnd
    imul rbx, rax, 80
    lea rax, [wtab]
    add rbx, rax
    xor ecx, ecx
    mov edx, NNAME - 1
    call rnd
    lea rcx, [names]
    mov rax, [rcx+rax*8]
    mov [wname], rax
    xor ecx, ecx
    mov edx, NITEM - 1
    call rnd
    lea rcx, [items]
    mov rax, [rcx+rax*8]
    mov [witem], rax
    mov r14, [rbx+24]           ; what it takes
.pick:
    mov rcx, [rbx+32]
    mov rdx, [rbx+40]
    call rnd
    mov r12, rax                ; A
    mov rcx, [rbx+48]
    mov rdx, [rbx+56]
    call rnd
    mov r13, rax                ; B
    mov rcx, [rbx+64]
    mov rdx, [rbx+72]
    call rnd
    mov r15, rax                ; C
    cmp r14, 1
    jne .k3
    cmp r13, r12
    jae .pick
.k3:
    cmp r14, 3
    jne .k4
    imul r12, r13               ; A was how many each
.k4:
    cmp r14, 4
    jne .k5
    mov rax, r12
    xor edx, edx
    div r13
    test rdx, rdx
    jz .pick
.k5:
    cmp r14, 5
    jne .k6
    mov rdx, r12
    imul rdx, r13
    dec rdx
    mov ecx, 1
    call rnd
    mov r15, rax
.k6:
    cmp r14, 6
    jne .k9
    lea rax, [r13+r15]
    cmp rax, r12
    jae .pick
.k9:
    cmp r14, 9
    jne .q
    cmp r12, r13
    jbe .pick
.q:
    mov [wv+16], r12
    mov [wv+24], r13
    mov [wv+32], r15
    emit "user: "
    mov rcx, [rbx]
    call wexp
    emit 10
    emit "assistant: "
    mov rcx, [rbx+8]
    call wexp
    emit 10
    mov rcx, r12
    mov rdx, r13
    lea rax, [wkind]
    jmp [rax+r14*8]
.add:
    call addstep
    jmp .ans
.sub:
    call substep
    jmp .ans
.mul:
    call mulstep
    jmp .ans
.div:
    call divstep
    mov [wv+56], rdx
    jmp .ans
.mulsub:
    call mulstep
    mov rcx, rax
    mov rdx, r15
    call substep
    jmp .ans
.subsub:
    call substep
    mov rcx, rax
    mov rdx, r15
    call substep
    jmp .ans
.perim:
    call addstep
    mov ecx, 2
    mov rdx, rax
    call mulstep
    jmp .ans
.add3:
    call addstep
    mov rcx, rax
    mov rdx, r15
    call addstep
    jmp .ans
.ceil:
    call divstep
    test rdx, rdx
    jz .ans
    mov [rsp+32], rax
    mov [rsp+40], rdx
    emit "That leaves "
    num [rsp+40]
    emit " more, so one more bus: "
    num [rsp+32]
    emit " + 1 = "
    mov rax, [rsp+32]
    inc rax
    mov [rsp+32], rax
    num rax
    emit 10
    mov rax, [rsp+32]
    jmp .ans
.temp:
    cmp r12, r13
    jae .sub
    emit "That goes below 0, so work out "
    num r13
    emit " - "
    num r12
    emit " and make it negative.", 10
    mov rcx, r13
    mov rdx, r12
    call substep
    neg rax
.ans:
    mov [wv+48], rax
    mov rcx, [rbx+16]
    call wexp
    emit 10
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret
