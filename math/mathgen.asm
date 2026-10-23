; mathgen [n=1000] [seed=1] [split=train|eval|all] [out=datasets\math\arith.txt]: math problems worked out
; step by step, as conversations in chatdocs' text format: long multiplication and
; division, prime factorization, linear equations, factoring x^2 + bx + c, polynomial
; long division here, the rest of arithmetic in arith.asm and more algebra in
; algebra.asm. every step gets a line of its own, so the numbers in it stay small
; (under 100 is one token) and the steps always look the same. the last line of an
; answer is the answer, and a "# topic" line before each problem says what it is.
; split: a hash of the worked answer puts 1 in 16 problems in eval, and train never
; gets those, whatever the seed (the question's wording doesn't count)
; uses: math\arith math\algebra
default rel
bits 64
%include "lib.inc"
%include "math/math.inc"

extern ExitProcess

BUFSZ equ 64 << 20

section .rdata
k_n      db "n", 0
k_seed   db "seed", 0
k_out    db "out", 0
k_split  db "split", 0
d_split  db "train", 0
s_eval   db "eval", 0
s_all    db "all", 0
d_out    db "datasets\math\arith.txt", 0
s_dir    db "datasets\math", 0
e_open   db "can't create the output", 0
e_write  db "can't write the output", 0
empty    db 0
align 8
pow10    dq 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000
         dq 1000000000, 10000000000, 100000000000, 1000000000000

; how a question gets asked: before the first number, between, after
mq0 db "What is ", 0
mq1 db "Compute ", 0
mq2 db "What's ", 0
mq3 db "Multiply ", 0
mq4 db "Can you work out ", 0
mo0 db " × ", 0
mo1 db " times ", 0
mo2 db " by ", 0
mo3 db " * ", 0
mo4 db " x ", 0
ms0 db "?", 0
ms1 db ".", 0
ms2 db " = ?", 0
ms3 db " step by step?", 0
align 8
qmul dq mq0, mo0, ms0,  mq1, mo0, ms1,  mq2, mo1, ms0,  mq3, mo2, ms1
     dq empty, mo3, ms2,  mq4, mo4, ms3,  empty, mo0, empty
NQMUL equ 7

dq0 db "Divide ", 0
dq1 db "Do the long division: ", 0
dq2 db "Work out ", 0
do0 db " ÷ ", 0
do1 db " divided by ", 0
do2 db " / ", 0
ds0 db " step by step.", 0
align 8
qdiv dq mq0, do0, ms0,  dq0, mo2, ms1,  mq2, do1, ms0,  empty, do2, ms2
     dq dq1, do0, empty,  dq2, do0, ds0
NQDIV equ 6

; one-thing questions: before, after
fq0 db "Find the prime factorization of ", 0
fq1 db "What is the prime factorization of ", 0
fq2 db "Factor ", 0
fq3 db "Write ", 0
fq4 db "What are the prime factors of ", 0
fs0 db " into primes.", 0
fs1 db " as a product of primes.", 0
align 8
qfac dq fq0, ms1,  fq1, ms0,  fq2, fs0,  fq3, fs1,  fq4, ms0
NQFAC equ 5

qq0 db "Can you factor ", 0
qq1 db "Factorise ", 0
qs0 db " completely.", 0
qs1 db " factored?", 0
align 8
qquad dq fq2, ms1,  fq2, qs0,  qq0, ms0,  mq0, qs1,  qq1, ms1
NQQUAD equ 5

; two-polynomial questions: before, between, after
pq0 db "What is (", 0
pq1 db "Use long division to divide ", 0
pq2 db "Work out (", 0
pm0 db ") ÷ (", 0
pm1 db ") / (", 0
ps0 db ")?", 0
ps1 db ").", 0
align 8
qpdiv dq dq0, mo2, ms1,  pq0, pm0, ps0,  pq1, mo2, ms1,  pq2, pm1, ps1
NQPDIV equ 4

letters db "xynt"

align 8
topics dq mul_one, div_one, factor_one, lin_one, quad_one, pdiv_one
       dq add_one, sub_one, signed_one, gcd_one, frac_one, pow_one, root_one, pct_one
       dq order_one, word_one, sys_one, expand_one, like_one, evalp_one, qeq_one
tname  dq tn0, tn1, tn2, tn3, tn4, tn5, tn6, tn7, tn8, tn9, tn10, tn11, tn12, tn13
       dq tn14, tn15, tn16, tn17, tn18, tn19, tn20
NTOPIC equ 21
; how often each comes up, out of TWSUM. the ones with only a few hundred different
; problems in them (powers, roots, factoring) get less
tw     db 7, 7, 5, 6, 3, 5, 4, 4, 5, 5, 7, 3, 3, 5, 6, 7, 5, 5, 4, 4, 5
TWSUM  equ 105
tn0 db "# mul", 10, 0
tn1 db "# div", 10, 0
tn2 db "# primes", 10, 0
tn3 db "# linear", 10, 0
tn4 db "# quadratic", 10, 0
tn5 db "# polydiv", 10, 0
tn6 db "# add", 10, 0
tn7 db "# sub", 10, 0
tn8 db "# signed", 10, 0
tn9 db "# gcd", 10, 0
tn10 db "# frac", 10, 0
tn11 db "# power", 10, 0
tn12 db "# root", 10, 0
tn13 db "# percent", 10, 0
tn14 db "# order", 10, 0
tn15 db "# words", 10, 0
tn16 db "# system", 10, 0
tn17 db "# expand", 10, 0
tn18 db "# like", 10, 0
tn19 db "# evaluate", 10, 0
tn20 db "# solve", 10, 0

section .bss
alignb 8
rng      resb RNG_SIZE
buf      resq 1
fh       resq 1
outp     resq 1
nprob    resq 1
split    resq 1                 ; 0 train, 1 eval, 2 all
na       resq 1
nb       resq 1
nq       resq 1
rows     resq 4
adig     resb 24                ; digits, the ones first
bdig     resb 24
qdig     resb 24
primes   resq 168               ; the ones under 1000
nprimes  resq 1
nf       resq 1                 ; a factorization: its primes and their powers
fp       resq 24
fe       resq 24
cf       resq 8                 ; a polynomial for poly, highest power first
qc       resq 4                 ; polynomial division: quotient, dividend
pc       resq 5
letter   resb 1                 ; the variable

section .text

global rnd, ndig, digits, emz, ask, askpre, askpre3, letr, mono, pmono, sterm, poly, lin
global mulwork, divwork, addcols, factwork, quadwork, quadp, twobin, binom
global letter, cf, fp, fe, nf, primes, nprimes, pow10, letters, empty

global start
start:
    sub rsp, 56
    call lib_init
    call cfg_args
    lea rcx, [k_n]
    mov edx, 1000
    call cfg_int
    mov [nprob], rax
    lea rcx, [k_seed]
    mov edx, 1
    call cfg_int
    lea rcx, [rng]
    mov rdx, rax
    call rng_seed
    lea rcx, [k_out]
    lea rdx, [d_out]
    call cfg_str
    mov [outp], rax
    lea rcx, [k_split]
    lea rdx, [d_split]
    call cfg_str
    mov rbx, rax
    mov rcx, rax
    lea rdx, [s_eval]
    call streq
    mov [split], rax
    mov rcx, rbx
    lea rdx, [s_all]
    call streq
    add rax, rax
    add [split], rax
    lea rcx, [s_dir]
    call make_dir
    mov rcx, [outp]
    call file_create
    cmp rax, -1
    jne .open
    lea rcx, [e_open]
    call fatal
.open:
    mov [fh], rax
    mov ecx, BUFSZ
    call mem_alloc
    mov [buf], rax
    mov rdi, rax
    call mkprimes
    emit "# made by bin\mathgen, don't edit", 10, 10
    xor ebx, ebx
.p:
    cmp rbx, [nprob]
    jae .done
    xor ecx, ecx
    mov edx, TWSUM - 1
    call rnd
    lea rcx, [tw]
    xor edx, edx
.w:
    movzx r8d, byte [rcx+rdx]
    sub rax, r8
    jb .wd
    inc edx
    jmp .w
.wd:
    mov eax, edx
    mov [rsp+32], rax
    mov [rsp+40], rdi           ; where this one starts
    lea rcx, [tname]
    mov rcx, [rcx+rax*8]
    call emz
    mov rax, [rsp+32]
    lea rcx, [topics]
    call [rcx+rax*8]
    mov rcx, [rsp+40]
    call keep
    test eax, eax
    jnz .kept
    mov rdi, [rsp+40]           ; the other split's: take it back
    jmp .p
.kept:
    emit 10
    inc rbx
    mov rax, rdi
    sub rax, [buf]
    cmp rax, BUFSZ - (1 << 16)
    jb .p
    call flush
    jmp .p
.done:
    call flush
    mov rcx, [fh]
    call file_close
    say "  "
    mov rcx, [nprob]
    call print_dec
    say " problems -> "
    mov rcx, [outp]
    call print_z
    say 13, 10
    xor ecx, ecx
    call ExitProcess

; rcx, rdx = zero-terminated strings. eax = 1 if they're the same
streq:
    mov al, [rcx]
    cmp al, [rdx]
    jne .no
    test al, al
    jz .yes
    inc rcx
    inc rdx
    jmp streq
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; rcx = where the problem just written starts. eax = 1 if it belongs to this split:
; fnv-1a of the answer, from "assistant: " on, and 1 bucket in 16 is eval's
keep:
    cmp qword [split], 2
    je .yes
.find:
    cmp rcx, rdi
    jae .yes                    ; (always has one)
    cmp byte [rcx], 10
    jne .f
    cmp byte [rcx+1], 'a'
    je .hash
.f:
    inc rcx
    jmp .find
.hash:
    mov rax, 0xcbf29ce484222325
    mov r8, 0x100000001b3
.h:
    cmp rcx, rdi
    jae .bucket
    movzx edx, byte [rcx]
    xor rax, rdx
    imul rax, r8
    inc rcx
    jmp .h
.bucket:
    shr rax, 60                 ; the top 4 bits
    xor edx, edx
    test rax, rax
    sete dl                     ; 1 = eval's
    xor eax, eax
    cmp rdx, [split]
    sete al
    ret
.yes:
    mov eax, 1
    ret

; [buf, rdi) to the file, rdi back to the start
flush:
    sub rsp, 40
    mov rcx, [fh]
    mov rdx, [buf]
    mov r8, rdi
    sub r8, rdx
    call file_write
    test eax, eax
    jnz .ok
    lea rcx, [e_write]
    call fatal
.ok:
    mov rdi, [buf]
    add rsp, 40
    ret

; rcx = lo, rdx = hi. rax = a random number in [lo, hi]
rnd:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    lea rsi, [rdx+1]
    sub rsi, rcx
    lea rcx, [rng]
    call rng_next
    xor edx, edx
    div rsi
    lea rax, [rdx+rbx]
    add rsp, 40
    pop rsi
    pop rbx
    ret

; ecx = k. rax = a random k-digit number
ndig:
    sub rsp, 40
    lea rax, [pow10]
    mov rdx, [rax+rcx*8]
    dec rdx
    mov rcx, [rax+rcx*8-8]
    call rnd
    add rsp, 40
    ret

; rcx = value, rdx = where its digits go, the ones first. rax = how many
digits:
    mov rax, rcx
    mov r8, rdx
    xor r9d, r9d
    mov r10d, 10
.d:
    xor edx, edx
    div r10
    mov [r8+r9], dl
    inc r9
    test rax, rax
    jnz .d
    mov rax, r9
    ret

; rcx = zero-terminated string, copied to rdi
emz:
    mov al, [rcx]
    test al, al
    jz .r
    mov [rdi], al
    inc rdi
    inc rcx
    jmp emz
.r:
    ret

; rcx = question table, edx = how many, r8, r9 = the two numbers. "user: ..." at rdi
ask:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov r12, r8
    mov r13, r9
    lea rdx, [rdx-1]
    xor ecx, ecx
    call rnd
    imul rax, rax, 24
    add rbx, rax
    emit "user: "
    mov rcx, [rbx]
    call emz
    num r12
    mov rcx, [rbx+8]
    call emz
    num r13
    mov rcx, [rbx+16]
    call emz
    emit 10
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; a x b: a has 2-5 digits, b 1-3
mul_one:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov ecx, 2
    mov edx, 5
    call rnd
    mov ecx, eax
    call ndig
    mov rbx, rax                ; a
    mov ecx, 1
    mov edx, 3
    call rnd
    mov ecx, eax
    call ndig
    mov r12, rax                ; b
    lea rcx, [qmul]
    mov edx, NQMUL
    mov r8, rbx
    mov r9, r12
    call ask
    emit "assistant: "
    mov rcx, rbx
    mov rdx, r12
    call mulwork
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = a, rdx = b: long multiplication, down to "a × b = p". rax = p
mulwork:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    mov rbx, rcx
    mov r12, rdx
    lea rdx, [adig]
    call digits
    mov [na], rax
    mov rcx, r12
    lea rdx, [bdig]
    call digits
    mov [nb], rax
    emit "Multiply "
    num rbx
    cmp qword [nb], 1
    jne .many
    emit " by "
    num r12
    emit ", one digit at a time from the right.", 10
    mov rcx, r12
    call mulrow
    jmp .total
.many:
    emit " by each digit of "
    num r12
    emit ", then add up the rows.", 10
    xor r13d, r13d              ; which digit of b
.row:
    cmp r13, [nb]
    jae .add
    lea rax, [bdig]
    movzx r14d, byte [rax+r13]
    num rbx
    emit " × "
    num r14
    cmp r13, 1
    jb .colon
    je .one
    emit ", two places over"
    jmp .colon
.one:
    emit ", one place over"
.colon:
    emit ":", 10
    mov rcx, r14
    call mulrow
    mov r15, rbx
    imul r15, r14               ; the row
    emit "row: "
    num r15
    lea rax, [pow10]
    imul r15, [rax+r13*8]
    test r13, r13
    jz .put
    cmp r13, 1
    je .one2
    emit ", two places over: "
    jmp .shifted
.one2:
    emit ", one place over: "
.shifted:
    num r15
.put:
    emit 10
    lea rax, [rows]
    mov [rax+r13*8], r15
    inc r13
    jmp .row
.add:
    ; a row of 0s adds nothing, so it doesn't get added
    xor r14d, r14d              ; the sum so far, 0 = no row yet
    xor r13d, r13d
    mov qword [rsp+32], 0       ; "add the rows" said
.sum:
    cmp r13, [nb]
    jae .total
    lea rax, [rows]
    mov rdx, [rax+r13*8]
    inc r13
    test rdx, rdx
    jz .sum
    test r14, r14
    jnz .plus
    mov r14, rdx
    jmp .sum
.plus:
    cmp qword [rsp+32], 0
    jne .said
    mov [rsp+40], rdx           ; (emit uses rcx and rsi, not rdx, but num does)
    emit "Add the rows:", 10
    mov qword [rsp+32], 1
    mov rdx, [rsp+40]
.said:
    mov rcx, r14
    call addcols
    mov r14, rax
    jmp .sum
.total:
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
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = one digit of b. a's digits times it, a line each: "8 × 6 + 1 = 49, write 9, carry 4"
mulrow:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    sub rsp, 32
    mov r12, rcx
    test r12, r12
    jnz .go
    emit "anything × 0 = 0, so this row is 0", 10
    jmp .r
.go:
    xor r13d, r13d              ; which digit of a
    xor r14d, r14d              ; carry
.l:
    lea rax, [adig]
    movzx ebx, byte [rax+r13]
    num rbx
    emit " × "
    num r12
    test r14, r14
    jz .nc
    emit " + "
    num r14
.nc:
    imul rbx, r12
    add rbx, r14                ; this digit's product
    emit " = "
    num rbx
    emit ", write "
    lea rax, [r13+1]
    cmp rax, [na]
    jae .last
    mov rax, rbx
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r14, rax
    num rdx
    test r14, r14
    jz .eol
    emit ", carry "
    num r14
.eol:
    emit 10
    inc r13
    jmp .l
.last:
    num rbx                     ; the last digit writes all of it
    emit 10
.r:
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = x, rdx = y. column addition, a line a digit. rax = x + y
addcols:
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
    emit " + "
    num r12
    emit ":", 10
    mov r14, rbx
    mov r15, r12
    xor r13d, r13d              ; carry
.c:
    mov rax, r14
    or rax, r15
    jz .end
    mov rax, r14
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r14, rax
    mov [rsp+32], rdx           ; x's digit
    mov rax, r15
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r15, rax
    mov rsi, [rsp+32]
    lea rax, [rsi+rdx]
    add rax, r13
    mov [rsp+32], rax           ; the column's total
    mov [rsp+40], rdx
    num rsi
    emit " + "
    num [rsp+40]
    test r13, r13
    jz .nc
    emit " + 1"
.nc:
    emit " = "
    num [rsp+32]
    emit ", write "
    mov rax, [rsp+32]
    xor r13d, r13d
    cmp rax, 10
    jb .w
    sub rax, 10
    mov r13d, 1
.w:
    num rax
    test r13, r13
    jz .eol
    emit ", carry 1"
.eol:
    emit 10
    jmp .c
.end:
    test r13, r13
    jz .sum
    emit "carry 1, write 1", 10
.sum:
    num rbx
    emit " + "
    num r12
    emit " = "
    lea rax, [rbx+r12]
    num rax
    emit 10
    lea rax, [rbx+r12]
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; a ÷ b: a has 2-7 digits, b is 2-9 or 10-99
div_one:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    xor ecx, ecx
    mov edx, 1
    call rnd
    mov ecx, 2
    mov edx, 9
    test eax, eax
    jz .small
    mov ecx, 10
    mov edx, 99
.small:
    call rnd
    mov r12, rax                ; b
    mov ecx, 2
    mov edx, 7
    call rnd
    mov ecx, eax
    call ndig
    mov rbx, rax                ; a
    lea rcx, [qdiv]
    mov edx, NQDIV
    mov r8, rbx
    mov r9, r12
    call ask
    emit "assistant: "
    mov rcx, rbx
    mov rdx, r12
    call divwork
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = a, rdx = b (under 100): long division, down to "a ÷ b = q remainder r".
; rax = q, rdx = r
divwork:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    cmp rbx, r12
    jae .long
    num rbx
    emit " is smaller than "
    num r12
    emit ", so it goes in 0 times.", 10
    jmp .total
.long:
    mov rcx, rbx
    lea rdx, [adig]
    call digits
    mov [na], rax
    emit "Long division, one digit of "
    num rbx
    emit " at a time.", 10
    mov r13, [na]               ; digits left, from the top
    xor r14d, r14d              ; what's being divided
    mov qword [nq], 0
.d:
    test r13, r13
    jz .fin
    dec r13
    lea rax, [adig]
    movzx r15d, byte [rax+r13]  ; the next digit
    imul r14, r14, 10
    add r14, r15
    cmp qword [nq], 0
    jne .step
    cmp r14, r12
    jb .d                       ; not enough to divide yet: take another digit
    jmp .div
.step:
    emit "bring down "
    num r15
    emit ": "
.div:
    mov rax, r14
    xor edx, edx
    div r12
    mov r15, rax                ; this quotient digit
    lea rax, [qdig]
    mov rcx, [nq]
    mov [rax+rcx], r15b
    inc qword [nq]
    num r14
    emit " ÷ "
    num r12
    emit " = "
    num r15
    emit ", "
    num r15
    emit " × "
    num r12
    emit " = "
    mov rax, r15
    imul rax, r12
    mov [rsp+32], rax
    num rax
    emit ", "
    num r14
    emit " - "
    num [rsp+32]
    emit " = "
    sub r14, [rsp+32]
    num r14
    emit 10
    jmp .d
.fin:
    emit "quotient digits:"
    xor r13d, r13d
.q:
    cmp r13, [nq]
    jae .qd
    emit " "
    lea rax, [qdig]
    movzx eax, byte [rax+r13]
    num rax
    inc r13
    jmp .q
.qd:
    emit 10
.total:
    num rbx
    emit " ÷ "
    num r12
    emit " = "
    mov rax, rbx
    xor edx, edx
    div r12
    mov [rsp+32], rdx
    num rax
    cmp qword [rsp+32], 0
    je .exact
    emit " remainder "
    num [rsp+32]
.exact:
    emit 10
    mov rax, rbx
    xor edx, edx
    div r12
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; ---- algebra

; the primes under 1000, by trial division
mkprimes:
    xor r8d, r8d
    mov r9d, 2
.c:
    cmp r9, 1000
    jae .done
    xor r10d, r10d
.t:
    cmp r10, r8
    jae .yes
    lea rax, [primes]
    mov r11, [rax+r10*8]
    mov rax, r11
    imul rax, r11
    cmp rax, r9
    ja .yes
    mov rax, r9
    xor edx, edx
    div r11
    test rdx, rdx
    jz .no
    inc r10
    jmp .t
.yes:
    lea rax, [primes]
    mov [rax+r8*8], r9
    inc r8
.no:
    inc r9
    jmp .c
.done:
    mov [nprimes], r8
    ret

; rcx = question table (before, after), edx = how many. "user: " and the before part
; at rdi, rax = the after part
askpre:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    lea rdx, [rdx-1]
    xor ecx, ecx
    call rnd
    shl rax, 4
    add rbx, rax
    emit "user: "
    mov rcx, [rbx]
    call emz
    mov rax, [rbx+8]
    add rsp, 40
    pop rsi
    pop rbx
    ret

; the same for (before, between, after): rax = between, rdx = after
askpre3:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    lea rdx, [rdx-1]
    xor ecx, ecx
    call rnd
    imul rax, rax, 24
    add rbx, rax
    emit "user: "
    mov rcx, [rbx]
    call emz
    mov rax, [rbx+8]
    mov rdx, [rbx+16]
    add rsp, 40
    pop rsi
    pop rbx
    ret

; the variable at rdi
letr:
    mov al, [letter]
    mov [rdi], al
    inc rdi
    ret

; rcx = coefficient, rdx = power. the term on its own: 3x^2, -x, x, 7, 0x
mono:
    push rbx
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    test r12, r12
    jnz .var
    sint rbx
    jmp .r
.var:
    cmp rbx, 1
    je .x
    cmp rbx, -1
    jne .c
    mov byte [rdi], '-'
    inc rdi
    jmp .x
.c:
    sint rbx
.x:
    call letr
    cmp r12, 2
    jb .r
    mov byte [rdi], '^'
    inc rdi
    num r12
.r:
    add rsp, 40
    pop r12
    pop rbx
    ret

; the same, in brackets if it's negative: (-8x)
pmono:
    test rcx, rcx
    jns mono
    sub rsp, 40
    mov byte [rdi], '('
    inc rdi
    call mono
    mov byte [rdi], ')'
    inc rdi
    add rsp, 40
    ret

; rcx = coefficient, rdx = power: " + 3x^2" or " - 3x^2", for after the first term
sterm:
    sub rsp, 40
    mov byte [rdi], ' '
    mov byte [rdi+1], '+'
    mov byte [rdi+2], ' '
    test rcx, rcx
    jns .go
    mov byte [rdi+1], '-'
    neg rcx
.go:
    add rdi, 3
    call mono
    add rsp, 40
    ret

; rcx = coefficients, highest power first, rdx = the degree. zero terms are left out
poly:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    xor r13d, r13d
    xor r14d, r14d              ; terms written
.t:
    cmp r13, r12
    ja .end
    mov rcx, [rbx+r13*8]
    test rcx, rcx
    jz .n
    mov rdx, r12
    sub rdx, r13
    test r14, r14
    jnz .more
    call mono
    jmp .w
.more:
    call sterm
.w:
    inc r14
.n:
    inc r13
    jmp .t
.end:
    test r14, r14
    jnz .r
    mov byte [rdi], '0'
    inc rdi
.r:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rcx = a, rdx = b: ax + b
lin:
    sub rsp, 40
    mov [cf], rcx
    mov [cf+8], rdx
    lea rcx, [cf]
    mov edx, 1
    call poly
    add rsp, 40
    ret

; r13 = b, r14 = c: x^2 + bx + c
quadp:
    sub rsp, 40
    mov qword [cf], 1
    mov [cf+8], r13
    mov [cf+16], r14
    lea rcx, [cf]
    mov edx, 2
    call poly
    add rsp, 40
    ret

; rcx = u: (x + u) or (x - |u|)
binom:
    sub rsp, 40
    mov byte [rdi], '('
    mov byte [rdi+1], 'x'
    add rdi, 2
    xor edx, edx
    call sterm
    mov byte [rdi], ')'
    inc rdi
    add rsp, 40
    ret

; rcx = u, rdx = v: (x + u)(x + v), or (x + u)^2
twobin:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    call binom
    cmp rbx, r12
    jne .two
    emit "^2"
    jmp .r
.two:
    mov rcx, r12
    call binom
.r:
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = a prime that just went in: on the end of the factorization, or one more power
addfac:
    mov rax, [nf]
    test rax, rax
    jz .new
    lea rdx, [fp]
    cmp [rdx+rax*8-8], rcx
    jne .new
    lea rdx, [fe]
    inc qword [rdx+rax*8-8]
    ret
.new:
    lea rdx, [fp]
    mov [rdx+rax*8], rcx
    lea rdx, [fe]
    mov qword [rdx+rax*8], 1
    inc qword [nf]
    ret

; the prime factorization of a number made of 2-5 primes under 100, a quarter of them
; with one between 100 and 1000 as well
factor_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    sub rsp, 32
    mov r12d, 1
    mov ecx, 2
    mov edx, 5
    call rnd
    mov r13, rax
.pick:
    test r13, r13
    jz .big
    dec r13
    xor ecx, ecx
    mov edx, 24
    call rnd
    mov r14, rax
    xor ecx, ecx
    mov edx, 24
    call rnd
    cmp rax, r14
    cmovb r14, rax              ; the smaller of two picks: small primes come up more
    lea rax, [primes]
    mov rax, [rax+r14*8]
    imul rax, r12
    cmp rax, 99999
    ja .pick
    mov r12, rax
    jmp .pick
.big:
    xor ecx, ecx
    mov edx, 3
    call rnd
    test eax, eax
    jnz .ask
    mov ecx, 25
    mov rdx, [nprimes]
    dec rdx
    call rnd
    lea rcx, [primes]
    mov rax, [rcx+rax*8]
    imul rax, r12
    cmp rax, 999999
    ja .ask
    mov r12, rax
.ask:
    lea rcx, [qfac]
    mov edx, NQFAC
    call askpre
    mov rbx, rax
    num r12
    mov rcx, rbx
    call emz
    emit 10
    emit "assistant: Divide by the smallest prime that goes in, again and again.", 10
    mov rcx, r12
    call factwork
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = n: trial division down to "n = 2^3 × 3^2 × 5", the primes in fp/fe/nf
factwork:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    mov r12, rcx
    mov r13, r12                ; what's left
    xor r14d, r14d              ; which prime
    mov qword [nf], 0
.l:
    lea rax, [primes]
    mov r15, [rax+r14*8]
    mov rax, r15
    imul rax, r15
    cmp rax, r13
    jbe .try
    ; nothing up to its square root goes in, so it's prime
    mov [rsp+32], rax
    num r13
    emit " is prime, since "
    num r15
    emit " × "
    num r15
    emit " = "
    num [rsp+32]
    emit " is more than "
    num r13
    emit ".", 10
    mov rcx, r13
    call addfac
    jmp .all
.try:
    mov rax, r13
    xor edx, edx
    div r15
    mov [rsp+32], rax
    mov [rsp+40], rdx
    num r13
    emit " ÷ "
    num r15
    emit " = "
    num [rsp+32]
    cmp qword [rsp+40], 0
    jne .no
    emit 10
    mov rcx, r15
    call addfac
    mov r13, [rsp+32]
    jmp .l
.no:
    emit " remainder "
    num [rsp+40]
    emit ", no", 10
    inc r14
    jmp .l
.all:
    num r12
    emit " = "
    xor r13d, r13d
.f:
    cmp r13, [nf]
    jae .end
    test r13, r13
    jz .first
    emit " × "
.first:
    lea rax, [fp]
    num [rax+r13*8]
    lea rax, [fe]
    mov rax, [rax+r13*8]
    cmp rax, 1
    je .e1
    mov [rsp+32], rax
    emit "^"
    num [rsp+32]
.e1:
    inc r13
    jmp .f
.end:
    emit 10
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = a, rdx = b, r8 = the answer: "a × (x) + b = ax + b = the value"
check1:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    mov r13, r8
    sint rbx
    emit " × "
    pint r13
    mov rcx, r12
    xor edx, edx
    call sterm
    emit " = "
    mov rax, rbx
    imul rax, r13
    mov [rsp+32], rax
    sint rax
    mov rcx, r12
    xor edx, edx
    call sterm
    emit " = "
    mov rax, [rsp+32]
    add rax, r12
    sint rax
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; solve ax + b = c, or ax + b = cx + d, for a whole number, in one of a few letters
lin_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72
    xor ecx, ecx
    mov edx, 3
    call rnd
    lea rcx, [letters]
    mov al, [rcx+rax]
    mov [letter], al
    mov rcx, -15
    mov edx, 15
    call rnd
    mov rbx, rax                ; the answer
    mov ecx, 2
    mov edx, 12
    call rnd
    mov r12, rax                ; a
    xor ecx, ecx
    mov edx, 3
    call rnd
    test eax, eax
    jnz .b
    neg r12
.b:
    mov rcx, -40
    mov edx, 40
    call rnd
    test rax, rax
    jz .b
    mov r13, rax                ; b
    xor r14d, r14d              ; c, the right side's own x (0 = none)
    xor ecx, ecx
    mov edx, 1
    call rnd
    test eax, eax
    jz .rhs
.cc:
    mov rcx, -9
    mov edx, 9
    call rnd
    test rax, rax
    jz .cc
    mov rdx, r12
    sub rdx, rax
    cmp rdx, 2
    jge .ccok
    cmp rdx, -2
    jg .cc                      ; a - c is at least 2 either way
.ccok:
    mov r14, rax
.rhs:
    mov r15, r12
    sub r15, r14
    imul r15, rbx
    add r15, r13                ; the right side's number
    ; the question, four ways
    xor ecx, ecx
    mov edx, 3
    call rnd
    mov [rsp+32], rax
    emit "user: "
    mov rax, [rsp+32]
    cmp rax, 1
    jb .q0
    je .q1
    cmp rax, 2
    je .q2
    emit "What is "
    call letr
    emit " when "
    jmp .eq
.q0:
    emit "Solve "
    jmp .eq
.q1:
    emit "Solve for "
    call letr
    emit ": "
    jmp .eq
.q2:
    emit "Find "
    call letr
    emit " if "
.eq:
    mov rcx, r12
    mov rdx, r13
    call lin
    emit " = "
    mov rcx, r14
    mov rdx, r15
    call lin
    mov rax, [rsp+32]
    cmp rax, 1
    je .s1
    cmp rax, 3
    je .s3
    emit "."
    jmp .s1
.s3:
    emit "?"
.s1:
    emit 10
    emit "assistant: Get "
    call letr
    emit " by itself.", 10
    mov [rsp+40], r12           ; the left side's x
    test r14, r14
    jz .one
    js .addx
    emit "Subtract "
    mov rcx, r14
    xor edx, edx
    call lin
    emit " from both sides: "
    jmp .moved
.addx:
    emit "Add "
    mov rcx, r14
    neg rcx
    xor edx, edx
    call lin
    emit " to both sides: "
.moved:
    mov rcx, r12
    sub rcx, r14
    mov [rsp+40], rcx
    mov rdx, r13
    call lin
    emit " = "
    sint r15
    emit 10
.one:
    mov rax, r15
    sub rax, r13
    mov [rsp+48], rax           ; what the x's equal
    test r13, r13
    js .addb
    emit "Subtract "
    num r13
    emit " from both sides: "
    mov rcx, [rsp+40]
    xor edx, edx
    call lin
    emit " = "
    sint r15
    emit " - "
    num r13
    jmp .bdone
.addb:
    emit "Add "
    mov rax, r13
    neg rax
    mov [rsp+56], rax
    num rax
    emit " to both sides: "
    mov rcx, [rsp+40]
    xor edx, edx
    call lin
    emit " = "
    sint r15
    emit " + "
    num [rsp+56]
.bdone:
    emit " = "
    sint [rsp+48]
    emit 10
    emit "Divide both sides by "
    sint [rsp+40]
    emit ": "
    call letr
    emit " = "
    sint [rsp+48]
    emit " ÷ "
    pint [rsp+40]
    emit " = "
    sint rbx
    emit 10
    ; check it in the equation as it was asked
    emit "Check: "
    mov rcx, r12
    mov rdx, r13
    mov r8, rbx
    call check1
    test r14, r14
    jz .chk
    emit ", and "
    mov rcx, r14
    mov rdx, r15
    mov r8, rbx
    call check1
.chk:
    emit 10
    call letr
    emit " = "
    sint rbx
    emit 10
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; factor x^2 + bx + c = (x + p)(x + q), p and q whole numbers from -12 to 12
quad_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    sub rsp, 48
    mov byte [letter], 'x'
.p:
    mov rcx, -12
    mov edx, 12
    call rnd
    test rax, rax
    jz .p
    mov rbx, rax
.q:
    mov rcx, -12
    mov edx, 12
    call rnd
    test rax, rax
    jz .q
    mov r12, rax
    lea r13, [rbx+r12]          ; b
    mov r14, rbx
    imul r14, r12               ; c
    lea rcx, [qquad]
    mov edx, NQQUAD
    call askpre
    mov [rsp+32], rax
    call quadp
    mov rcx, [rsp+32]
    call emz
    emit 10
    emit "assistant: "
    mov rcx, r13
    mov rdx, r14
    call quadwork
    add rsp, 48
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = b, rdx = c: x^2 + bx + c factored by trying the factor pairs of c, down to
; "x^2 + bx + c = (x + u)(x + v)". rax = u, rdx = v
quadwork:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72
    mov r13, rcx
    mov r14, rdx
    emit "Find two numbers that multiply to "
    sint r14
    emit " and add to "
    sint r13
    emit ".", 10
    mov r15, r14
    test r15, r15
    jns .abs
    neg r15                     ; |c|
.abs:
    mov qword [rsp+40], 1       ; d, from 1 up to the square root of |c|
.d:
    mov rax, r15
    xor edx, edx
    div qword [rsp+40]
    test rdx, rdx
    jnz .dn
    mov r8, [rsp+40]
    mov r9, rax
    ; c > 0: both have b's sign. c < 0: the bigger one does
    test r14, r14
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
    mov [rsp+48], r8
    mov [rsp+56], r9
    sint [rsp+48]
    emit " × "
    pint [rsp+56]
    emit " = "
    sint r14
    emit ", "
    sint [rsp+48]
    emit " + "
    pint [rsp+56]
    emit " = "
    mov rax, [rsp+48]
    add rax, [rsp+56]
    mov [rsp+64], rax
    sint rax
    cmp [rsp+64], r13
    je .found
    emit 10
.dn:
    inc qword [rsp+40]
    mov rax, [rsp+40]
    imul rax, rax
    cmp rax, r15
    jbe .d
.found:
    emit ", that's it", 10
    emit "Check: "
    mov rcx, [rsp+48]
    mov rdx, [rsp+56]
    call twobin
    emit " = x^2"
    mov rcx, [rsp+56]
    mov edx, 1
    call sterm
    mov rcx, [rsp+48]
    mov edx, 1
    call sterm
    mov rcx, r14
    xor edx, edx
    call sterm
    emit " = "
    call quadp
    emit 10
    call quadp
    emit " = "
    mov rcx, [rsp+48]
    mov rdx, [rsp+56]
    call twobin
    emit 10
    mov rax, [rsp+48]
    mov rdx, [rsp+56]
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; (a polynomial) ÷ (x - r) by long division: the quotient has degree 1-2 and no zero
; terms, r is -6 to 6, half have a remainder
pdiv_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72
    mov byte [letter], 'x'
.r:
    mov rcx, -6
    mov edx, 6
    call rnd
    test rax, rax
    jz .r
    mov rbx, rax                ; r
    mov ecx, 1
    mov edx, 2
    call rnd
    mov r12, rax                ; the quotient's degree
    mov ecx, 1
    mov edx, 4
    call rnd
    mov [qc], rax
    mov r13d, 1
.qc:
    cmp r13, r12
    ja .rem
    mov rcx, -9
    mov edx, 9
    call rnd
    test rax, rax
    jz .qc
    lea rcx, [qc]
    mov [rcx+r13*8], rax
    inc r13
    jmp .qc
.rem:
    xor r14d, r14d              ; the remainder
    xor ecx, ecx
    mov edx, 1
    call rnd
    test eax, eax
    jz .p
    mov rcx, -9
    mov edx, 9
    call rnd
    mov r14, rax
.p:
    ; the dividend: (x - r) times the quotient, plus the remainder
    mov rax, [qc]
    mov [pc], rax
    mov r13d, 1
.pc:
    cmp r13, r12
    ja .last
    lea rcx, [qc]
    mov rax, [rcx+r13*8-8]
    imul rax, rbx
    neg rax
    add rax, [rcx+r13*8]
    lea rcx, [pc]
    mov [rcx+r13*8], rax
    inc r13
    jmp .pc
.last:
    lea rcx, [qc]
    mov rax, [rcx+r12*8]
    imul rax, rbx
    neg rax
    add rax, r14
    lea rcx, [pc]
    mov [rcx+r13*8], rax
    lea rcx, [qpdiv]
    mov edx, NQPDIV
    call askpre3
    mov [rsp+32], rax
    mov [rsp+40], rdx
    lea rcx, [pc]
    lea rdx, [r12+1]
    call poly
    mov rcx, [rsp+32]
    call emz
    mov ecx, 1
    mov rdx, rbx
    neg rdx
    call lin
    mov rcx, [rsp+40]
    call emz
    emit 10
    emit "assistant: Long division, highest power first.", 10
    mov r13, [pc]               ; the leading term's coefficient
    xor r15d, r15d              ; step
.s:
    lea rax, [r12+1]
    sub rax, r15
    mov [rsp+48], rax           ; its power
    ; 4x^2 ÷ x = 4x
    mov rcx, r13
    mov rdx, rax
    call mono
    emit " ÷ x = "
    mov rcx, r13
    mov rdx, [rsp+48]
    dec rdx
    call mono
    emit 10
    ; 4x × (x - 2) = 4x^2 - 8x
    mov rcx, r13
    mov rdx, [rsp+48]
    dec rdx
    call mono
    emit " × ("
    mov ecx, 1
    mov rdx, rbx
    neg rdx
    call lin
    emit ") = "
    mov rcx, r13
    mov rdx, [rsp+48]
    call mono
    mov rax, r13
    imul rax, rbx
    neg rax
    mov [rsp+56], rax           ; what that puts on the next power
    mov rcx, rax
    mov rdx, [rsp+48]
    dec rdx
    call sterm
    emit 10
    ; subtract: -5x - (-8x) = 3x
    lea rcx, [pc]
    mov rax, [rcx+r15*8+8]
    mov [rsp+64], rax
    emit "subtract: "
    mov rcx, [rsp+64]
    mov rdx, [rsp+48]
    dec rdx
    call mono
    emit " - "
    mov rcx, [rsp+56]
    mov rdx, [rsp+48]
    dec rdx
    call pmono
    emit " = "
    mov r13, [rsp+64]
    sub r13, [rsp+56]
    mov rcx, r13
    mov rdx, [rsp+48]
    dec rdx
    call mono
    inc r15
    cmp r15, r12
    ja .done                    ; that was the last step, r13 is the remainder
    emit ", bring down "
    lea rcx, [pc]
    mov rcx, [rcx+r15*8+8]
    mov rdx, [rsp+48]
    sub rdx, 2
    call mono
    emit 10
    jmp .s
.done:
    emit 10
    emit "quotient "
    lea rcx, [qc]
    mov rdx, r12
    call poly
    emit ", remainder "
    sint r13
    emit 10
    emit "("
    lea rcx, [pc]
    lea rdx, [r12+1]
    call poly
    emit ") ÷ ("
    mov ecx, 1
    mov rdx, rbx
    neg rdx
    call lin
    emit ") = "
    lea rcx, [qc]
    mov rdx, r12
    call poly
    test r13, r13
    jz .exact
    emit ", remainder "
    sint r13
.exact:
    emit 10
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret
