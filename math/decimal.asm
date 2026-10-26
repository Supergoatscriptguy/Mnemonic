; mathgen's decimals, averages and ratios: + - × ÷ with decimal points, fractions to
; decimals and back, rounding, mean / median / mode / range, ratios and proportions.
; a decimal here is a whole number v and how many places it has, d: v / 10^d
default rel
bits 64
%include "lib.inc"
%include "math/math.inc"

section .rdata
qa0 db "What is ", 0
qa1 db "Compute ", 0
qa2 db "Work out ", 0
qa3 db "What's ", 0
sq   db "?", 0
sdot db ".", 0
seq  db " = ?", 0
align 8
qdec dq qa0, sq,  qa1, sdot,  empty, seq,  qa2, sdot,  qa3, sq
NQDEC equ 5
s_plus  db " + ", 0
s_minus db " - ", 0
s_times db " × ", 0
s_div   db " ÷ ", 0
align 8
dops dq s_plus, s_minus, s_times, s_div
tdiv dq 2, 4, 5, 8, 10, 16, 20, 25, 40, 50   ; they all make decimals that end
NTDIV equ 10

cv0  db "Write ", 0
cv1  db "Convert ", 0
cvd0 db " as a decimal.", 0
cvd1 db " as a decimal?", 0
cvd2 db " to a decimal.", 0
cvf0 db " as a fraction.", 0
cvf1 db " as a fraction?", 0
cvf2 db " to a fraction in lowest terms.", 0
align 8
qtodec  dq cv0, cvd0,  qa0, cvd1,  cv1, cvd2
qtofrac dq cv0, cvf0,  qa0, cvf1,  cv1, cvf2
NQCV equ 3

s_whole db "the nearest whole number", 0
rn1 db "ten", 0
rn2 db "hundred", 0
rn3 db "thousand", 0
rd1 db "ones", 0
rd2 db "tens", 0
rd3 db "hundreds", 0
rp3 db "thousands", 0
align 8
rnames dq rn1, rn2, rn3         ; the nearest ...
rdig   dq rd1, rd2, rd3         ; the digit that decides it
rplu   dq rd2, rd3, rp3         ; what's kept, counted in these

sm0 db "Find the mean of ", 0
sm1 db "What is the average of ", 0
sd0 db "Find the median of ", 0
sd1 db "What is the median of ", 0
so0 db "What is the mode of ", 0
so1 db "Find the mode of ", 0
sr0 db "Find the range of ", 0
sr1 db "What is the range of ", 0
sm2 db "mean of ", 0
sd2 db "median of ", 0
so2 db "mode of ", 0
sr2 db "range of ", 0
align 8
qstat dq sm0, sdot, sm1, sq, sm2, empty,  sd0, sdot, sd1, sq, sd2, empty
      dq so0, sq, so1, sdot, so2, empty,  sr0, sdot, sr1, sq, sr2, empty

ra0  db "Simplify the ratio ", 0
ra1  db "Write the ratio ", 0
ras1 db " in its simplest form.", 0
align 8
qrat dq ra0, sdot,  ra1, ras1
sh0  db "Share ", 0
sh1  db "Divide ", 0
shs  db " in the ratio ", 0
align 8
qshare dq sh0, shs,  sh1, shs
pr0 db "Solve ", 0
pr1 db "Find x if ", 0
pr2 db "Solve for x: ", 0
align 8
qprop dq pr0, sdot,  pr1, sdot,  pr2, sdot
NQPROP equ 3
ut0 db "notebooks", 0
ut1 db "pens", 0
ut2 db "apples", 0
ut3 db "tickets", 0
ut4 db "bottles of water", 0
ut5 db "candles", 0
align 8
uthing dq ut0, ut1, ut2, ut3, ut4, ut5
NUTHING equ 6

section .bss
alignb 8
ddig  resq 12                   ; digits after the point, from ddivw
lst   resq 12                   ; a list for the averages
srt   resq 12

section .text

global dec_one, stats_one, ratio_one, pdec, pdecs, ddivw

; rcx = v, rdx = d: v / 10^d with exactly d places, 3.50 or 0.05, or just v for d = 0
pdec:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    lea rax, [pow10]
    mov rcx, [rax+r12*8]
    mov rax, rbx
    xor edx, edx
    div rcx
    mov rbx, rdx                ; what goes after the point
    num rax
    test r12, r12
    jz .r
    mov byte [rdi], '.'
    inc rdi
    mov rdx, rbx
    mov r8, r12
    mov rcx, rdi
    call fmt_dec0
    mov rdi, rax
.r:
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = v, rdx = d: the same decimal without trailing zeros after the point.
; rax = v, rdx = d
canon:
    mov rax, rcx
    mov r8, rdx
.l:
    test r8, r8
    jz .r
    mov r10, rax
    xor edx, edx
    mov r9d, 10
    div r9
    test rdx, rdx
    jnz .back
    dec r8
    jmp .l
.back:
    mov rax, r10
.r:
    mov rdx, r8
    ret

; pdec of the canonical form: 8.40 -> 8.4, 2.00 -> 2
pdecs:
    call canon
    mov rcx, rax
    jmp pdec

; rcx = v, rdx = d: pdec, then " = " and pdecs when they differ
pdec2:
    push rbx
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    call pdec
    mov rcx, rbx
    mov rdx, r12
    call canon
    cmp rdx, r12
    je .r
    mov rbx, rax
    mov r12, rdx
    mov byte [rdi], ' '
    mov byte [rdi+1], '='
    mov byte [rdi+2], ' '
    add rdi, 3
    mov rcx, rbx
    mov rdx, r12
    call pdec
.r:
    add rsp, 40
    pop r12
    pop rbx
    ret

; rcx = whole digits at most, rdx = places at most: a random decimal with 1 or more
; places, its last one not 0. the whole part is 0 a quarter of the time. rax = v, rdx = d
rdec:
    push rbx
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    mov ecx, 1
    call rnd
    mov r12, rax
    xor r13d, r13d
    xor ecx, ecx
    mov edx, 3
    call rnd
    test eax, eax
    jz .f
    mov rcx, rbx
    call upto
    mov r13, rax
.f:
    lea rax, [pow10]
    mov rdx, [rax+r12*8]
    dec rdx
    mov ecx, 1
    call rnd
    mov r8, rax
    xor edx, edx
    mov ecx, 10
    div rcx
    test rdx, rdx
    jz .f
    lea rax, [pow10]
    mov rax, [rax+r12*8]
    imul rax, r13
    add rax, r8
    mov rdx, r12
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret

; rcx = v, rdx = d, r8 = n (a 2-and-5s number): v/10^d ÷ n, the whole part by divstep,
; then a line a digit after the point, bringing down 0s once v's digits run out.
; rax = the answer's v, rdx = its d (canonical)
ddivw:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72
    mov r12, rdx                ; d
    mov r13, r8                 ; n
    lea rax, [pow10]
    mov r8, [rax+r12*8]
    mov rax, rcx
    xor edx, edx
    div r8
    mov rbx, rdx                ; the digits after the point, as a number
    mov [rsp+32], rax           ; the whole part
    emit "Divide the whole number part first, then keep going past the point, bringing down 0s when the digits run out.", 10
    mov rcx, [rsp+32]
    mov rdx, r13
    call divstep
    mov [rsp+40], rax           ; q, the whole part of the answer
    mov r14, rdx                ; what's left
    emit "After the point:", 10
    xor r15d, r15d              ; digits so far
.d:
    xor eax, eax                ; the next digit down, or 0
    cmp r15, r12
    jae .z
    mov rcx, r12
    sub rcx, r15
    dec rcx
    lea rax, [pow10]
    mov rcx, [rax+rcx*8]
    mov rax, rbx
    xor edx, edx
    div rcx
    xor edx, edx
    mov ecx, 10
    div rcx
    mov rax, rdx
.z:
    mov [rsp+48], rax
    imul r14, r14, 10
    add r14, rax                ; now dividing this
    mov rax, r14
    xor edx, edx
    div r13
    mov [rsp+56], rax           ; the digit
    mov [rsp+64], rdx
    lea rcx, [ddig]
    mov [rcx+r15*8], rax
    inc r15
    emit "bring down "
    num [rsp+48]
    emit ": "
    num r14
    emit " ÷ "
    num r13
    emit " = "
    num [rsp+56]
    emit ", "
    num [rsp+56]
    emit " × "
    num r13
    emit " = "
    mov rax, [rsp+56]
    imul rax, r13
    num rax
    emit ", "
    num r14
    emit " - "
    mov rax, [rsp+56]
    imul rax, r13
    num rax
    emit " = "
    num [rsp+64]
    emit 10
    mov r14, [rsp+64]
    cmp r15, 10
    jae .done                   ; (never, they all end)
    test r14, r14
    jnz .d
    cmp r15, r12
    jb .d
.done:
    emit "digits after the point:"
    xor ebx, ebx
    mov rsi, [rsp+40]           ; the answer, built up
.dl:
    cmp rbx, r15
    jae .dd
    mov [rsp+32], rsi
    emit " "
    lea rax, [ddig]
    num [rax+rbx*8]
    mov rsi, [rsp+32]
    imul rsi, rsi, 10
    lea rax, [ddig]
    add rsi, [rax+rbx*8]
    inc rbx
    jmp .dl
.dd:
    mov rbx, rsi
    emit 10
    mov rcx, rbx
    mov rdx, r15
    call canon
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; place names: rcx = 1 -> "1 decimal place", else "n decimal places"
places:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    num rbx
    emit " decimal place"
    cmp rbx, 1
    je .r
    mov byte [rdi], 's'
    inc rdi
.r:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; + - × ÷ with decimals, fractions to decimals and back, rounding
dec_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88
    xor ecx, ecx
    mov edx, 5
    call rnd
    mov r15, rax
    cmp r15, 2
    jb .as
    je .mul
    cmp r15, 4
    jb .div
    je .conv
    jmp .round
; ---- + and -
.as:
    mov ecx, 3
    mov edx, 3
    call rdec
    mov rbx, rax
    mov r12, rdx
    mov ecx, 3
    mov edx, 3
    call rdec
    mov r13, rax
    mov r14, rdx
    mov rax, r12                ; D, both lined up to it
    cmp rax, r14
    jae .dm
    mov rax, r14
.dm:
    mov [rsp+32], rax
    mov rcx, rax
    sub rcx, r12
    lea rax, [pow10]
    mov rdx, [rax+rcx*8]
    imul rdx, rbx
    mov [rsp+40], rdx           ; a, as a whole number of D places
    mov rcx, [rsp+32]
    sub rcx, r14
    mov rdx, [rax+rcx*8]
    imul rdx, r13
    mov [rsp+48], rdx           ; b
    test r15, r15
    jz .asq
    mov rax, [rsp+40]           ; a - b stays above 0
    cmp rax, [rsp+48]
    je .as
    ja .asq
    xchg rbx, r13
    xchg r12, r14
    mov rax, [rsp+40]
    xchg rax, [rsp+48]
    mov [rsp+40], rax
.asq:
    call dask
    emit "assistant: "
    cmp r12, r14
    jne .line
    emit "Both have "
    mov rcx, r12
    call places
    emit " already, so "
    jmp .whole
.line:
    emit "Give both "
    mov rcx, [rsp+32]
    call places
    emit " so the points line up: "
    cmp r12, [rsp+32]
    je .lb
    mov rcx, rbx                ; a was the shorter one
    mov rdx, r12
    call pdec
    emit " = "
    mov rcx, [rsp+40]
    mov rdx, [rsp+32]
    call pdec
    jmp .lp
.lb:
    mov rcx, r13
    mov rdx, r14
    call pdec
    emit " = "
    mov rcx, [rsp+48]
    mov rdx, [rsp+32]
    call pdec
.lp:
    emit ". Then "
.whole:
    test r15, r15
    jnz .wsub
    emit "add them as whole numbers and put the point back "
    jmp .wpl
.wsub:
    emit "subtract them as whole numbers and put the point back "
.wpl:
    num [rsp+32]
    emit " place"
    cmp qword [rsp+32], 1
    je .w1
    mov byte [rdi], 's'
    inc rdi
.w1:
    emit " from the right.", 10
    mov rcx, [rsp+40]
    mov rdx, [rsp+48]
    test r15, r15
    jnz .ws
    call addstep
    jmp .wd
.ws:
    call substep
.wd:
    mov [rsp+56], rax
    emit "That's "
    mov rcx, [rsp+56]
    mov rdx, [rsp+32]
    call pdec2
    emit ".", 10
    mov rax, [rsp+56]
    mov rdx, [rsp+32]
    jmp .fin
; ---- ×
.mul:
    mov ecx, 2
    mov edx, 2
    call rdec
    mov rbx, rax
    mov r12, rdx
    call coin
    test eax, eax
    jz .mi
    mov ecx, 2
    mov edx, 2
    call rdec
    mov r13, rax
    mov r14, rdx
    jmp .mq
.mi:
    mov ecx, 2                  ; times a whole number
    mov edx, 12
    call rnd
    mov r13, rax
    xor r14d, r14d
.mq:
    call dask
    emit "assistant: Multiply them without the decimal points: "
    num rbx
    emit " × "
    num r13
    emit ".", 10
    mov rcx, rbx
    mov rdx, r13
    call mulstep
    mov [rsp+40], rax
    lea rax, [r12+r14]
    mov [rsp+32], rax
    emit "The decimal places add up: "
    num r12
    emit " + "
    num r14
    emit " = "
    num [rsp+32]
    emit ", so put the point "
    num [rsp+32]
    emit " place"
    cmp qword [rsp+32], 1
    je .m1
    mov byte [rdi], 's'
    inc rdi
.m1:
    emit " from the right: "
    mov rcx, [rsp+40]
    mov rdx, [rsp+32]
    call pdec2
    emit ".", 10
    mov rax, [rsp+40]
    mov rdx, [rsp+32]
    jmp .fin
; ---- ÷
.div:
    xor ecx, ecx
    mov edx, NTDIV - 1
    call rnd
    lea rcx, [tdiv]
    mov r13, [rcx+rax*8]
    xor r14d, r14d
    call coin
    test eax, eax
    jz .dw
    mov ecx, 2
    mov edx, 1
    call rdec
    mov rbx, rax
    mov r12, rdx
    jmp .dx
.dw:
    mov ecx, 3
    call upto
    mov rbx, rax
    xor r12d, r12d
.dx:
    lea rax, [pow10]            ; a whole answer isn't a decimal one
    mov rcx, [rax+r12*8]
    imul rcx, r13
    mov rax, rbx
    xor edx, edx
    div rcx
    test rdx, rdx
    jz .div
    call dask
    emit "assistant: "
    mov rcx, rbx
    mov rdx, r12
    mov r8, r13
    call ddivw
    jmp .fin
; ---- fractions to decimals and back
.conv:
    call coin
    test eax, eax
    jz .tofrac
.todec:
    xor ecx, ecx
    mov edx, NTDIV - 1
    call rnd
    lea rcx, [tdiv]
    mov r13, [rcx+rax*8]        ; n
    mov ecx, 1
    lea rdx, [r13+r13]
    call rnd
    mov rbx, rax                ; m
    xor edx, edx
    div r13
    test rdx, rdx
    jz .todec
    lea rcx, [qtodec]
    mov edx, NQCV
    call askpre
    mov [rsp+32], rax
    num rbx
    emit "/"
    num r13
    mov rcx, [rsp+32]
    call emz
    emit 10
    emit "assistant: "
    num rbx
    emit "/"
    num r13
    emit " means "
    num rbx
    emit " ÷ "
    num r13
    emit ".", 10
    mov rcx, rbx
    xor edx, edx
    mov r8, r13
    call ddivw
    mov [rsp+40], rax
    mov [rsp+48], rdx
    num rbx
    emit "/"
    num r13
    emit " = "
    mov rcx, [rsp+40]
    mov rdx, [rsp+48]
    call pdec
    emit 10
    jmp .r
.tofrac:
    mov ecx, 1
    mov edx, 3
    call rdec
    mov rbx, rax
    mov r12, rdx
    lea rcx, [qtofrac]
    mov edx, NQCV
    call askpre
    mov [rsp+32], rax
    mov rcx, rbx
    mov rdx, r12
    call pdec
    mov rcx, [rsp+32]
    call emz
    emit 10
    emit "assistant: "
    mov rcx, rbx
    mov rdx, r12
    call pdec
    emit " has "
    mov rcx, r12
    call places
    emit ", so it's "
    num rbx
    emit "/"
    lea rax, [pow10]
    num [rax+r12*8]
    emit ".", 10
    lea rax, [pow10]
    mov rcx, rbx
    mov rdx, [rax+r12*8]
    call simp
    mov [rsp+40], rax
    mov [rsp+48], rdx
    mov rcx, rbx
    mov rdx, r12
    call pdec
    emit " = "
    mov rcx, [rsp+40]
    mov rdx, [rsp+48]
    call pfrac
    emit 10
    jmp .r
; ---- rounding
.round:
    call coin
    test eax, eax
    jz .rwhole
    mov ecx, 3
    mov edx, 5
    call rdec
    cmp rdx, 2
    jb .round
    mov rbx, rax
    mov r12, rdx
    xor ecx, ecx
    lea rdx, [r12-1]
    call rnd
    mov r13, rax                ; places to keep
    call coin
    mov [rsp+32], rax
    emit "user: "
    cmp qword [rsp+32], 0
    je .rq1
    emit "Round "
    mov rcx, rbx
    mov rdx, r12
    call pdec
    emit " to "
    call rto
    emit ".", 10
    jmp .ra
.rq1:
    emit "What is "
    mov rcx, rbx
    mov rdx, r12
    call pdec
    emit " rounded to "
    call rto
    emit "?", 10
.ra:
    mov rcx, r12                ; the digit after the ones kept
    sub rcx, r13
    dec rcx
    lea rax, [pow10]
    mov rcx, [rax+rcx*8]
    mov rax, rbx
    xor edx, edx
    div rcx
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r14, rax                ; what's kept, as a whole number
    mov r15, rdx                ; the digit that decides
    emit "assistant: "
    test r13, r13
    jnz .rn
    emit "The first digit after the point is "
    jmp .rdg
.rn:
    emit "The digit after "
    mov rcx, r13
    call places
    emit " is "
.rdg:
    num r15
    emit ". "
    cmp r15, 5
    jae .up
    emit "That's less than 5, so round down: "
    jmp .rk
.up:
    emit "That's 5 or more, so round up: "
    num r14
    emit " + 1 = "
    inc r14
    num r14
    emit ", which is "
.rk:
    mov rcx, r14
    mov rdx, r13
    call pdec
    emit ".", 10
    mov rcx, rbx
    mov rdx, r12
    call pdec
    emit " rounded to "
    call rto
    emit " is "
    mov rcx, r14
    mov rdx, r13
    call pdec
    emit 10
    jmp .r
.rwhole:
    mov ecx, 1                  ; to the nearest 10, 100 or 1000
    mov edx, 3
    call rnd
    mov r13, rax
    lea rcx, [r13+1]
    mov edx, 6
    call rnd
    mov ecx, eax
    call ndig
    mov rbx, rax
    call coin
    mov [rsp+32], rax
    emit "user: "
    cmp qword [rsp+32], 0
    je .wq1
    emit "Round "
    num rbx
    emit " to the nearest "
    call rname
    emit ".", 10
    jmp .wa
.wq1:
    emit "What is "
    num rbx
    emit " rounded to the nearest "
    call rname
    emit "?", 10
.wa:
    lea rax, [pow10]
    mov rcx, [rax+r13*8-8]
    mov rax, rbx
    xor edx, edx
    div rcx
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r14, rax                ; how many tens / hundreds / thousands
    mov r15, rdx
    emit "assistant: The "
    lea rax, [rdig]
    mov rcx, [rax+r13*8-8]
    call emz
    emit " digit is "
    num r15
    emit ". "
    cmp r15, 5
    jae .wup
    emit "That's less than 5, so round down: "
    num r14
    jmp .wk
.wup:
    emit "That's 5 or more, so round up: "
    num r14
    emit " + 1 = "
    inc r14
    num r14
.wk:
    emit " "
    lea rax, [rplu]
    mov rcx, [rax+r13*8-8]
    call emz
    emit ", which is "
    lea rax, [pow10]
    imul r14, [rax+r13*8]
    num r14
    emit ".", 10
    num rbx
    emit " rounded to the nearest "
    call rname
    emit " is "
    num r14
    emit 10
    jmp .r
.fin:
    mov [rsp+40], rax
    mov [rsp+48], rdx
    call dexpr
    emit " = "
    mov rcx, [rsp+40]
    mov rdx, [rsp+48]
    call pdecs
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

; dec_one's question, from rbx/r12 (a), r13/r14 (b), r15 (the op)
dask:
    push rsi
    sub rsp, 48
    lea rcx, [qdec]
    mov edx, NQDEC
    call askpre
    mov [rsp+32], rax
    call dexpr
    mov rcx, [rsp+32]
    call emz
    emit 10
    add rsp, 48
    pop rsi
    ret

; a op b from dec_one's registers. a whole b (d = 0) prints plainly
dexpr:
    sub rsp, 40
    mov rcx, rbx
    mov rdx, r12
    call pdecs
    lea rax, [dops]
    mov rcx, [rax+r15*8]
    call emz
    mov rcx, r13
    mov rdx, r14
    call pdecs
    add rsp, 40
    ret

; "2 decimal places" or "the nearest whole number", from r13 in dec_one
rto:
    sub rsp, 40
    test r13, r13
    jz .w
    mov rcx, r13
    call places
    jmp .r
.w:
    lea rcx, [s_whole]
    call emz
.r:
    add rsp, 40
    ret

; "ten", "hundred" or "thousand", from r13 = 1-3
rname:
    sub rsp, 40
    lea rax, [rnames]
    mov rcx, [rax+r13*8-8]
    call emz
    add rsp, 40
    ret

; ---- averages

; r12 = how many: the list at rsi as "12, 7, 23 and 9", at rdi
plist:
    push rbx
    push r13
    sub rsp, 40
    mov r13, rsi
    xor ebx, ebx
.l:
    num [r13+rbx*8]
    inc rbx
    cmp rbx, r12
    jae .r
    lea rax, [r12-1]
    cmp rbx, rax
    je .and
    mov byte [rdi], ','
    mov byte [rdi+1], ' '
    add rdi, 2
    jmp .l
.and:
    mov rax, ' and '
    mov [rdi], rax              ; (5 bytes of it)
    add rdi, 5
    jmp .l
.r:
    add rsp, 40
    pop r13
    pop rbx
    ret

; mean, median, mode or range of 5-9 whole numbers
stats_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    mov ecx, 5
    mov edx, 9
    call rnd
    mov r12, rax                ; how many
    xor ecx, ecx
    mov edx, 3
    call rnd
    mov r15, rax                ; 0 mean, 1 median, 2 mode, 3 range
.pick:
    xor ebx, ebx
.v:
    mov ecx, 1
    mov edx, 60
    call rnd
    lea rcx, [lst]
    mov [rcx+rbx*8], rax
    inc rbx
    cmp rbx, r12
    jb .v
    cmp r15, 2
    jne .nm
    ; mode: the first one 2 or 3 times, the rest all different
    mov ecx, 2
    mov edx, 3
    call rnd
    mov r13, rax
    lea rcx, [lst]
    mov rax, [rcx]
    mov r14, rax                ; the mode, before the shuffle moves it
    mov [rcx+8], rax
    cmp r13, 3
    jb .md
    mov [rcx+16], rax
.md:
    mov rbx, r13                ; the others differ from everything before them
.mu:
    cmp rbx, r12
    jae .shuf
    lea rcx, [lst]
    xor edx, edx
.mc:
    cmp rdx, rbx
    jae .mn
    mov rax, [rcx+rbx*8]
    cmp rax, [rcx+rdx*8]
    je .pick
    inc rdx
    jmp .mc
.mn:
    inc rbx
    jmp .mu
.shuf:
    lea rbx, [r12-1]            ; fisher-yates, so the repeat isn't up front
.sh:
    test rbx, rbx
    jz .nm
    xor ecx, ecx
    mov rdx, rbx
    call rnd
    lea rcx, [lst]
    mov rdx, [rcx+rbx*8]
    mov r8, [rcx+rax*8]
    mov [rcx+rbx*8], r8
    mov [rcx+rax*8], rdx
    dec rbx
    jmp .sh
.nm:
    test r15, r15
    jnz .srt
    ; mean: make the total come out even
    xor eax, eax
    xor ebx, ebx
    lea rcx, [lst]
.tot:
    add rax, [rcx+rbx*8]
    inc rbx
    cmp rbx, r12
    jb .tot
    xor edx, edx
    div r12
    test rdx, rdx
    jz .srt
    mov rax, r12
    sub rax, rdx
    add [rcx+r12*8-8], rax
.srt:
    lea rcx, [lst]              ; a sorted copy
    lea rdx, [srt]
    xor ebx, ebx
.cp:
    mov rax, [rcx+rbx*8]
    mov [rdx+rbx*8], rax
    inc rbx
    cmp rbx, r12
    jb .cp
    mov ebx, 1
.is:
    cmp rbx, r12
    jae .q
    mov rax, [rdx+rbx*8]
    mov r8, rbx
.ins:
    test r8, r8
    jz .put
    cmp [rdx+r8*8-8], rax
    jbe .put
    mov r9, [rdx+r8*8-8]
    mov [rdx+r8*8], r9
    dec r8
    jmp .ins
.put:
    mov [rdx+r8*8], rax
    inc rbx
    jmp .is
.q:
    xor ecx, ecx                ; 3 ways for each of the 4
    mov edx, 2
    call rnd
    shl rax, 4
    imul rcx, r15, 48
    add rax, rcx
    lea rcx, [qstat]
    add rax, rcx
    mov rbx, rax
    emit "user: "
    mov rcx, [rbx]
    call emz
    lea rsi, [lst]
    call plist
    mov rcx, [rbx+8]
    call emz
    emit 10
    emit "assistant: "
    cmp r15, 1
    jb .mean
    je .median
    cmp r15, 2
    je .mode
    emit "Put them in order: "
    lea rsi, [srt]
    call plist
    emit ".", 10
    lea rax, [srt]
    mov r13, [rax+r12*8-8]
    mov r14, [rax]
    emit "The range is the biggest minus the smallest: "
    num r13
    emit " - "
    num r14
    emit ".", 10
    mov rcx, r13
    mov rdx, r14
    call substep
    mov r13, rax
    emit "The range is "
    jmp .end
.mean:
    emit "Add them up, then divide by how many there are.", 10
    lea rax, [lst]
    mov r13, [rax]
    mov ebx, 1
.add:
    mov rcx, r13
    lea rax, [lst]
    mov rdx, [rax+rbx*8]
    call addstep
    mov r13, rax
    inc rbx
    cmp rbx, r12
    jb .add
    emit "There are "
    num r12
    emit " numbers, so divide by "
    num r12
    emit ".", 10
    mov rcx, r13
    mov rdx, r12
    call divstep
    mov r13, rax
    emit "The mean is "
    jmp .end
.mode:
    emit "Put them in order, so the repeats sit together: "
    lea rsi, [srt]
    call plist
    emit ".", 10
    lea rax, [lst]
    xor r13d, r13d              ; how many times it's there
    xor ebx, ebx
.mcount:
    cmp [rax+rbx*8], r14
    jne .mcn
    inc r13
.mcn:
    inc rbx
    cmp rbx, r12
    jb .mcount
    num r14
    emit " comes up "
    num r13
    emit " times, more than any other number.", 10
    mov r13, r14
    emit "The mode is "
    jmp .end
.median:
    emit "Put them in order: "
    lea rsi, [srt]
    call plist
    emit ".", 10
    test r12, 1
    jz .even
    emit "There are "
    num r12
    emit ", so the median is the middle one, number "
    lea rax, [r12+1]
    shr rax, 1
    mov rbx, rax
    num rax
    emit ": "
    lea rax, [srt]
    mov r13, [rax+rbx*8-8]
    num r13
    emit ".", 10
    emit "The median is "
    jmp .end
.even:
    emit "There are "
    num r12
    emit ", so the median is halfway between numbers "
    mov rbx, r12
    shr rbx, 1
    num rbx
    emit " and "
    lea rax, [rbx+1]
    num rax
    emit ": "
    lea rax, [srt]
    num [rax+rbx*8-8]
    emit " and "
    lea rax, [srt]
    num [rax+rbx*8]
    emit ".", 10
    lea rax, [srt]
    mov rcx, [rax+rbx*8-8]
    mov rdx, [rax+rbx*8]
    call addstep
    mov rcx, rax
    mov edx, 2
    call divstep
    mov r13, rax
    test rdx, rdx
    jz .hz
    emit "Half of the 1 left over is 0.5, so that's "
    num r13
    emit ".5.", 10
    emit "The median is "
    num r13
    emit ".5.", 10
    jmp .r
.hz:
    emit "The median is "
.end:
    num r13
    emit ".", 10
.r:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; ---- ratios

; simplify a:b, share n in the ratio a:b, a proportion x/b = c/d, or a unit price
ratio_one:
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
    mov r15, rax
    cmp r15, 2
    jb .two
    je .prop
    jmp .unit
.two:
    mov ecx, 1                  ; m:n with nothing in common
    mov edx, 9
    call rnd
    mov rbx, rax
    mov ecx, 1
    mov edx, 9
    call rnd
    mov r12, rax
    cmp rbx, r12
    je .two
    mov rcx, rbx
    mov rdx, r12
    call gcd
    cmp rax, 1
    jne .two
    test r15, r15
    jnz .share
    mov ecx, 2
    mov edx, 12
    call rnd
    mov r13, rax                ; what they share
    imul rbx, r13
    imul r12, r13
    lea rcx, [qrat]
    mov edx, 2
    call askpre
    mov [rsp+32], rax
    num rbx
    emit ":"
    num r12
    mov rcx, [rsp+32]
    call emz
    emit 10
    emit "assistant: Divide both sides by their gcd. Euclid's algorithm:", 10
    mov rcx, rbx
    mov rdx, r12
    cmp rcx, rdx
    jae .e
    xchg rcx, rdx
.e:
    call euclid
    mov r13, rax
    emit "gcd = "
    num r13
    emit ": "
    num rbx
    emit " ÷ "
    num r13
    emit " = "
    mov rax, rbx
    xor edx, edx
    div r13
    mov r14, rax
    num rax
    emit " and "
    num r12
    emit " ÷ "
    num r13
    emit " = "
    mov rax, r12
    xor edx, edx
    div r13
    mov r15, rax
    num rax
    emit ".", 10
    num rbx
    emit ":"
    num r12
    emit " = "
    num r14
    emit ":"
    num r15
    emit 10
    jmp .r
.share:
    mov ecx, 2                  ; one part
    mov edx, 50
    call rnd
    mov r13, rax
    lea r14, [rbx+r12]
    imul r14, r13               ; the total
    lea rcx, [qshare]
    mov edx, 2
    call askpre
    mov [rsp+32], rax
    num r14
    mov rcx, [rsp+32]
    call emz
    num rbx
    emit ":"
    num r12
    emit ".", 10
    emit "assistant: Count the parts: "
    num rbx
    emit " + "
    num r12
    emit " = "
    lea rax, [rbx+r12]
    num rax
    emit ". Each part is "
    num r14
    emit " ÷ "
    lea rax, [rbx+r12]
    num rax
    emit ".", 10
    mov rcx, r14
    lea rdx, [rbx+r12]
    call divstep
    mov rcx, rbx
    mov rdx, r13
    call mulstep
    mov [rsp+40], rax
    mov rcx, r12
    mov rdx, r13
    call mulstep
    mov [rsp+48], rax
    num r14
    emit " shared in the ratio "
    num rbx
    emit ":"
    num r12
    emit " is "
    num [rsp+40]
    emit " and "
    num [rsp+48]
    emit 10
    jmp .r
.prop:
    ; x/b = c/d with b = kd, so x = kc
    mov ecx, 1
    mov edx, 12
    call rnd
    mov r12, rax                ; c
    mov ecx, 2
    mov edx, 12
    call rnd
    mov r13, rax                ; d
    cmp r12, r13
    je .prop
    mov ecx, 2
    mov edx, 12
    call rnd
    mov r14, rax                ; k
    mov rbx, r13
    imul rbx, r14               ; b
    call coin
    mov r15, rax                ; 1 = the x side goes second
    lea rcx, [qprop]
    mov edx, NQPROP
    call askpre
    mov [rsp+32], rax
    call pprop
    mov rcx, [rsp+32]
    call emz
    emit 10
    emit "assistant: Multiply both sides by "
    num rbx
    emit ", so x = "
    num rbx
    emit " × "
    num r12
    emit " ÷ "
    num r13
    emit ".", 10
    mov rcx, rbx
    mov rdx, r12
    call mulstep
    mov rcx, rax
    mov rdx, r13
    call divstep
    mov [rsp+40], rax
    emit "x = "
    num [rsp+40]
    emit 10
    jmp .r
.unit:
    mov ecx, 2                  ; n things cost n × u, how much are m?
    mov edx, 9
    call rnd
    mov rbx, rax
    mov ecx, 2
    mov edx, 15
    call rnd
    mov r12, rax
    cmp r12, rbx
    je .unit
    mov ecx, 2
    mov edx, 25
    call rnd
    mov r13, rax                ; one costs this
    xor ecx, ecx
    mov edx, NUTHING - 1
    call rnd
    lea rcx, [uthing]
    mov r14, [rcx+rax*8]
    emit "user: If "
    num rbx
    emit " "
    mov rcx, r14
    call emz
    emit " cost "
    mov rax, rbx
    imul rax, r13
    num rax
    emit " dollars, how much do "
    num r12
    emit " cost?", 10
    emit "assistant: First find the price of one, then multiply.", 10
    mov rcx, rbx
    imul rcx, r13
    mov rdx, rbx
    call divstep
    mov rcx, r12
    mov rdx, r13
    call mulstep
    mov [rsp+40], rax
    emit "Answer: "
    num [rsp+40]
    emit " dollars", 10
.r:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; ratio_one's proportion: x/b = c/d, or c/d = x/b when r15 = 1
pprop:
    push rsi
    sub rsp, 32
    test r15, r15
    jnz .flip
    emit "x/"
    num rbx
    emit " = "
    num r12
    emit "/"
    num r13
    jmp .r
.flip:
    num r12
    emit "/"
    num r13
    emit " = x/"
    num rbx
.r:
    add rsp, 32
    pop rsi
    ret
