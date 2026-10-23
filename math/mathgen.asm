; mathgen [n=1000] [seed=1] [out=datasets\math\arith.txt]: arithmetic problems worked
; out step by step, as conversations in chatdocs' text format. long multiplication and
; long division for now. every digit step gets a line of its own, so the numbers in it
; stay small (under 100 is one token) and the steps always look the same
default rel
bits 64
%include "lib.inc"

extern ExitProcess

BUFSZ equ 64 << 20

section .rdata
k_n      db "n", 0
k_seed   db "seed", 0
k_out    db "out", 0
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

section .bss
alignb 8
rng      resb RNG_SIZE
buf      resq 1
fh       resq 1
outp     resq 1
nprob    resq 1
na       resq 1
nb       resq 1
nq       resq 1
rows     resq 4
adig     resb 24                ; digits, the ones first
bdig     resb 24
qdig     resb 24

section .text

; the number in %1 at rdi
%macro num 1
    mov rdx, %1
    mov rcx, rdi
    call fmt_dec
    mov rdi, rax
%endmacro

global start
start:
    sub rsp, 40
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
    emit "# made by bin\mathgen, don't edit", 10, 10
    xor ebx, ebx
.p:
    cmp rbx, [nprob]
    jae .done
    xor ecx, ecx
    mov edx, 1
    call rnd
    test eax, eax
    jz .div
    call mul_one
    jmp .next
.div:
    call div_one
.next:
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
    push r13
    push r14
    push r15
    sub rsp, 56
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
    mov rcx, rbx
    lea rdx, [adig]
    call digits
    mov [na], rax
    mov rcx, r12
    lea rdx, [bdig]
    call digits
    mov [nb], rax
    emit "assistant: Multiply "
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
    push r13
    push r14
    push r15
    sub rsp, 40
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
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret
