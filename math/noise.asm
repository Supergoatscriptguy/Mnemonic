; mathgen's questions the way people type them: lowercase, no full stop, no spaces
; around the signs, * or x for ×, / for ÷, ² and ³, commas in big numbers, "whats",
; a "pls" in front, no "What is the", log 1000 for log(1000). only the question changes. the answers restate the problem the
; tidy way, so the model learns to read the messy one and write the clean one.
; it has its own random numbers, so noise=0 and noise=1 make the same problems
default rel
bits 64
%include "lib.inc"
%include "math/math.inc"

N_LOWER equ 1 << 0
N_PUNCT equ 1 << 1
N_SQ    equ 1 << 2              ; squeeze the spaces out around signs
N_STAR  equ 1 << 3              ; × as *
N_X     equ 1 << 4              ; × as x (only where there's no x to mix it up with)
N_DIV   equ 1 << 5              ; ÷ as /
N_SUP   equ 1 << 6              ; ^2 ^3 as ² ³
N_COMMA equ 1 << 7              ; 12,345
N_CHAT  equ 1 << 8
N_WHATS equ 1 << 9
N_TERSE equ 1 << 10             ; no "What is the" in front
N_LOGB  equ 1 << 11             ; log 1000, log_2 x

section .rdata
c0 db "pls ", 0
c1 db "quick one: ", 0
c2 db "hey, ", 0
c3 db "hi! ", 0
c4 db "question: ", 0
align 8
chat dq c0, c1, c2, c3, c4
NCHAT equ 5
s_whats  db "whats ", 0
s_whats2 db "what's ", 0
ld0 db "What is the ", 0
ld1 db "What's the ", 0
ld2 db "What are the ", 0
ld3 db "Find the ", 0
align 8
leads dq ld0, ld1, ld2, ld3
NLEAD equ 4

section .bss
alignb 8
nrng  resb RNG_SIZE
nq    resb 4096                 ; the question being rewritten
nrest resb 65536                ; and what comes after it

section .text

global noise_seed, noisify

; rcx = seed
noise_seed:
    lea rdx, [rcx+0x5eed]
    lea rcx, [nrng]
    jmp rng_seed

; rax = 1 with chance ecx in 100
chance:
    push rbx
    sub rsp, 32
    mov ebx, ecx
    lea rcx, [nrng]
    call rng_next
    xor edx, edx
    mov ecx, 100
    div rcx
    xor eax, eax
    cmp edx, ebx
    setb al
    add rsp, 32
    pop rbx
    ret

; ecx = n: rax = 0..n-1
pickn:
    push rbx
    sub rsp, 32
    mov ebx, ecx
    lea rcx, [nrng]
    call rng_next
    xor edx, edx
    div rbx
    mov rax, rdx
    add rsp, 32
    pop rbx
    ret

; the flags for one question. ecx = 1 if the problem has no letter x in it
pickflags:
    push rbx
    push r12
    sub rsp, 40
    mov r12d, ecx
    xor ebx, ebx
    mov ecx, 50
    call chance
    test eax, eax
    jz .1
    or ebx, N_LOWER
.1:
    mov ecx, 40
    call chance
    test eax, eax
    jz .2
    or ebx, N_PUNCT
.2:
    mov ecx, 35
    call chance
    test eax, eax
    jz .3
    or ebx, N_SQ
.3:
    mov ecx, 5                  ; × stays, *, or x
    call pickn
    cmp eax, 2
    jb .4
    cmp eax, 4
    jb .star
    test r12d, r12d
    jz .star
    or ebx, N_X
    jmp .4
.star:
    or ebx, N_STAR
.4:
    mov ecx, 40
    call chance
    test eax, eax
    jz .5
    or ebx, N_DIV
.5:
    mov ecx, 30
    call chance
    test eax, eax
    jz .6
    or ebx, N_SUP
.6:
    mov ecx, 30
    call chance
    test eax, eax
    jz .7
    or ebx, N_COMMA
.7:
    mov ecx, 10
    call chance
    test eax, eax
    jz .8
    or ebx, N_CHAT
.8:
    mov ecx, 30
    call chance
    test eax, eax
    jz .9
    or ebx, N_WHATS
.9:
    mov ecx, 20
    call chance
    test eax, eax
    jz .10
    or ebx, N_TERSE
.10:
    mov ecx, 40
    call chance
    test eax, eax
    jz .11
    or ebx, N_LOGB
.11:
    mov eax, ebx
    add rsp, 40
    pop r12
    pop rbx
    ret

; rsi = text: the length of the operator that starts there (+ - = < > * / or × ÷ ≤ ≥
; in utf-8), 0 if it isn't one
oplen:
    movzx eax, byte [rsi]
    cmp al, '+'
    je .one
    cmp al, '-'
    je .one
    cmp al, '='
    je .one
    cmp al, '<'
    je .one
    cmp al, '>'
    je .one
    cmp al, 0xc3                ; × c3 97, ÷ c3 b7
    jne .le
    cmp byte [rsi+1], 0x97
    je .two
    cmp byte [rsi+1], 0xb7
    je .two
    jmp .no
.le:
    cmp al, 0xe2                ; ≤ e2 89 a4, ≥ e2 89 a5
    jne .no
    cmp byte [rsi+1], 0x89
    jne .no
    cmp byte [rsi+2], 0xa4
    je .three
    cmp byte [rsi+2], 0xa5
    je .three
.no:
    xor eax, eax
    ret
.one:
    mov eax, 1
    ret
.two:
    mov eax, 2
    ret
.three:
    mov eax, 3
    ret

; rsi = text, rcx = a string: rax = its length if the text starts with it, else 0
starts:
    xor eax, eax
.l:
    movzx edx, byte [rcx+rax]
    test edx, edx
    jz .r
    cmp dl, [rsi+rax]
    jne .no
    inc eax
    jmp .l
.no:
    xor eax, eax
.r:
    ret

; rsi = a ( in the question, rdi = what's written so far: rax = the ) that closes it
; if it's log(n) or log_b(n) with n just digits or x, else 0
logbr:
    lea r8, [nq]
    lea rdx, [rdi-1]
    mov r9, rdx
.bd:
    cmp rdx, r8
    jb .no
    movzx eax, byte [rdx]
    sub eax, '0'
    cmp eax, 9
    ja .bu
    dec rdx
    jmp .bd
.bu:
    cmp rdx, r9
    je .g                       ; log(
    cmp byte [rdx], '_'
    jne .no
    dec rdx
.g:
    lea rax, [r8+2]
    cmp rdx, rax
    jb .no
    cmp byte [rdx], 'g'
    jne .no
    cmp word [rdx-2], 'lo'
    jne .no
    lea rax, [rsi+1]
.f:
    movzx edx, byte [rax]
    cmp dl, ')'
    je .fe
    cmp dl, 'x'
    je .fn
    sub edx, '0'
    cmp edx, 9
    ja .no
.fn:
    inc rax
    jmp .f
.fe:
    lea rdx, [rsi+1]
    cmp rax, rdx
    je .no
    ret
.no:
    xor eax, eax
    ret

; rsi = an operator, ecx = its length: it at rdi, × and ÷ the way the flags say (r15)
putop:
    cmp ecx, 2
    jne .copy
    cmp byte [rsi+1], 0x97
    jne .div
    test r15d, N_STAR
    jz .x
    mov byte [rdi], '*'
    inc rdi
    ret
.x:
    test r15d, N_X
    jz .copy
    mov byte [rdi], 'x'
    inc rdi
    ret
.div:
    test r15d, N_DIV
    jz .copy
    mov byte [rdi], '/'
    inc rdi
    ret
.copy:
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    dec ecx
    jz .r
    inc rsi
    jmp .copy
.r:
    ret

; rcx = where the problem starts, rdi = its end: its question rewritten in place,
; rdi moved to match
noisify:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72
    mov [rsp+32], rdi           ; the end
    mov qword [rsp+48], 0       ; bracket depth
    mov qword [rsp+56], 0       ; a log's ) to leave out
    mov rsi, rcx
.t:
    cmp byte [rsi], 10          ; past "# topic"
    je .tq
    inc rsi
    jmp .t
.tq:
    lea r12, [rsi+7]            ; past "user: "
    mov r13, r12
    xor ecx, ecx                ; does it have an x in it
.e:
    cmp byte [r13], 10
    je .ed
    cmp byte [r13], 'x'
    jne .en
    mov ecx, 1
.en:
    inc r13
    jmp .e
.ed:
    xor ecx, 1                  ; 1 = no x, so x can mean times
    call pickflags
    mov r15d, eax
    lea rdi, [nq]
    mov rsi, r12
    test r15d, N_CHAT
    jz .te
    mov ecx, NCHAT
    call pickn
    lea rcx, [chat]
    mov rcx, [rcx+rax*8]
    call emz
    or r15d, N_LOWER            ; "pls What is" reads wrong
.te:
    test r15d, N_TERSE
    jz .wh
    xor ebx, ebx
.ld:
    lea rcx, [leads]
    mov rcx, [rcx+rbx*8]
    call starts
    test eax, eax
    jnz .cut
    inc ebx
    cmp ebx, NLEAD
    jb .ld
    jmp .wh
.cut:
    add rsi, rax                ; what's left is lowercase already, or LCM
    jmp .body
.wh:
    test r15d, N_WHATS
    jz .lo
    cmp dword [rsi], 'What'
    jne .lo
    cmp dword [rsi+4], ' is '
    jne .lo
    add rsi, 8
    mov ecx, 2
    call pickn
    lea rcx, [s_whats]
    test eax, eax
    jz .wq
    lea rcx, [s_whats2]
.wq:
    call emz
    jmp .body
.lo:
    test r15d, N_LOWER
    jz .body
    movzx eax, byte [rsi]
    cmp al, 'A'
    jb .body
    cmp al, 'Z'
    ja .body
    add al, 32
    mov [rdi], al
    inc rdi
    inc rsi
.body:
    cmp rsi, r13
    jae .end
    movzx eax, byte [rsi]
    cmp rsi, [rsp+56]
    jne .lb
    inc rsi
    jmp .body
.lb:
    test r15d, N_LOGB
    jz .sq0
    cmp al, '('
    jne .sq0
    call logbr
    test rax, rax
    jz .sq0
    mov [rsp+56], rax
    mov byte [rdi], ' '
    inc rdi
    inc rsi
    jmp .body
.sq0:
    movzx eax, byte [rsi]
    ; " op " squeezed to "op", and (1, 2) to (1,2)
    test r15d, N_SQ
    jz .nsq
    cmp al, ','
    jne .sp
    cmp qword [rsp+48], 0
    je .nsq
    cmp byte [rsi+1], ' '
    jne .nsq
    mov byte [rdi], ','
    inc rdi
    add rsi, 2
    jmp .body
.sp:
    cmp al, ' '
    jne .nsq
    inc rsi
    call oplen
    dec rsi
    test eax, eax
    jz .nsq
    lea rdx, [rsi+1+rax]
    cmp rdx, r13
    jae .nsq
    cmp byte [rdx], ' '
    jne .nsq
    mov r14, rdx
    mov ecx, eax
    inc rsi
    call putop
    lea rsi, [r14+1]
    jmp .body
.nsq:
    call oplen
    test eax, eax
    jz .sup
    cmp eax, 2
    jne .sup
    mov ecx, eax
    lea r14, [rsi+2]
    call putop
    mov rsi, r14
    jmp .body
.sup:
    movzx eax, byte [rsi]
    test r15d, N_SUP
    jz .com
    cmp al, '^'
    jne .com
    movzx edx, byte [rsi+1]
    cmp dl, '2'
    je .s2
    cmp dl, '3'
    jne .com
.s2:
    lea rcx, [rsi+2]            ; ^25 stays as it is
    cmp rcx, r13
    jae .sok
    movzx ecx, byte [rsi+2]
    sub ecx, '0'
    cmp ecx, 9
    jbe .com
.sok:
    mov byte [rdi], 0xc2        ; ² c2 b2, ³ c2 b3
    mov al, 0xb2
    cmp dl, '2'
    je .s3
    mov al, 0xb3
.s3:
    mov [rdi+1], al
    add rdi, 2
    add rsi, 2
    jmp .body
.com:
    test r15d, N_COMMA
    jz .copy
    sub eax, '0'
    cmp eax, 9
    ja .copy
    cmp rsi, r12                ; the start of a whole number, not after . / ^ or a digit
    je .cs
    movzx eax, byte [rsi-1]
    cmp al, '.'
    je .copy
    cmp al, '/'
    je .copy
    cmp al, '^'
    je .copy
    sub eax, '0'
    cmp eax, 9
    jbe .copy
.cs:
    mov rdx, rsi                ; how many digits
.cd:
    cmp rdx, r13
    jae .cl
    movzx eax, byte [rdx]
    sub eax, '0'
    cmp eax, 9
    ja .cl
    inc rdx
    jmp .cd
.cl:
    mov rcx, rdx
    sub rcx, rsi
    cmp rcx, 4
    jb .copy
    cmp rdx, r13
    jae .cw
    cmp byte [rdx], '.'         ; not a decimal's whole part, or a fraction's top
    je .copy
    cmp byte [rdx], '/'
    je .copy
.cw:
    ; digits, with a comma before each group of three from the right
    mov rax, rcx
    xor edx, edx
    mov r8d, 3
    div r8
    mov r9, rdx                 ; digits before the first comma
    test r9, r9
    jnz .cg
    mov r9d, 3
.cg:
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    dec rcx
    jz .body
    dec r9
    jnz .cg
    mov byte [rdi], ','
    inc rdi
    mov r9d, 3
    jmp .cg
.copy:
    mov al, [rsi]
    cmp al, '('                 ; how deep in brackets, for the commas
    jne .c1
    inc qword [rsp+48]
.c1:
    cmp al, ')'
    jne .c2
    dec qword [rsp+48]
.c2:
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .body
.end:
    test r15d, N_PUNCT
    jz .put
    lea rax, [nq]
    cmp rdi, rax
    je .put
    cmp byte [rdi-2], ' '       ; "12 × 3 = ?" keeps its ?
    je .put
    cmp byte [rdi-1], '?'
    je .drop
    cmp byte [rdi-1], '.'
    jne .put
.drop:
    dec rdi
.put:
    ; the rest of the problem goes after the new question
    lea rax, [nq]
    mov rbx, rdi
    sub rbx, rax                ; its length
    mov rcx, [rsp+32]
    sub rcx, r13
    mov [rsp+40], rcx
    mov rsi, r13
    lea rdi, [nrest]
    rep movsb
    lea rsi, [nq]
    mov rdi, r12
    mov rcx, rbx
    rep movsb
    lea rsi, [nrest]
    mov rcx, [rsp+40]
    rep movsb
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret
