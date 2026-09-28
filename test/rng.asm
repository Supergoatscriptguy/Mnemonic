; stage 1 test: rng and scalar math
default rel
bits 64
%include "lib.inc"
%include "test/check.inc"

N equ 1000000

section .rdata
align 8
c_n      dq 1000000.0
c_zero   dq 0.0
c_one    dq 1.0
c_e      dq 2.718281828459045
c_pi     dq 3.141592653589793
c_halfpi dq 1.5707963267948966
c_m20    dq -20.0
c_100    dq 100.0

section .bss
alignb 8
ra  resb RNG_SIZE
rb  resb RNG_SIZE

section .text

%macro draw 1
    lea rcx, [%1]
    call rng_next
%endmacro

global start
start:
    sub rsp, 40
    call lib_init

    say "xoshiro256**", 13, 10
    ; published reference outputs for the state 1, 2, 3, 4
    mov qword [ra], 1
    mov qword [ra+8], 2
    mov qword [ra+16], 3
    mov qword [ra+24], 4
    draw ra
    cmp rax, 11520
    check e, "output 1 = 11520"
    draw ra
    cmp rax, 0
    check e, "output 2 = 0"
    draw ra
    cmp rax, 1509978240
    check e, "output 3 = 1509978240"
    draw ra
    mov rdx, 1215971899390074240
    cmp rax, rdx
    check e, "output 4 = 1215971899390074240"

    lea rcx, [ra]
    xor edx, edx
    call rng_seed
    mov rax, 0xe220a8397b1dcdaf
    cmp [ra], rax
    check e, "seed 0 goes through splitmix64 (first word e220a8397b1dcdaf)"

    ; save the state, draw, restore, draw again: same numbers
    movdqu xmm0, [ra]
    movdqu [rb], xmm0
    movdqu xmm0, [ra+16]
    movdqu [rb+16], xmm0
    draw ra
    mov r12, rax
    draw ra
    mov r13, rax
    draw rb
    xor r12, rax
    draw rb
    xor r13, rax
    or r12, r13
    check z, "restored state repeats the sequence"

    say "distributions, 1M samples", 13, 10
    lea rcx, [ra]
    mov edx, 42
    call rng_seed
    ; start never returns, so xmm6/7 and rbx/rsi are ours to use
    xorpd xmm6, xmm6
    xor esi, esi
    mov ebx, N
.u:
    lea rcx, [ra]
    call rng_float
    addsd xmm6, xmm0
    comisd xmm0, [c_zero]
    jb .ubad
    comisd xmm0, [c_one]
    jb .unext
.ubad:
    inc esi
.unext:
    dec ebx
    jnz .u
    divsd xmm6, [c_n]
    movapd xmm0, xmm6
    close_to 0.5, 0.002, "uniform mean"
    test esi, esi
    check z, "uniform stays in [0, 1)"

    xorpd xmm6, xmm6
    xorpd xmm7, xmm7
    mov ebx, N
.n:
    lea rcx, [ra]
    call rng_normal
    addsd xmm6, xmm0
    mulsd xmm0, xmm0
    addsd xmm7, xmm0
    dec ebx
    jnz .n
    divsd xmm6, [c_n]
    divsd xmm7, [c_n]
    movapd xmm0, xmm6
    close_to 0.0, 0.005, "normal mean"
    movapd xmm0, xmm7
    close_to 1.0, 0.01, "normal variance"

    say "x87 math", 13, 10
    movsd xmm0, [c_one]
    call math_exp
    close_to 2.718281828459045, 1e-15, "exp(1)"
    movsd xmm0, [c_m20]
    call math_exp
    close_to 2.061153622438558e-09, 1e-22, "exp(-20)"
    movsd xmm0, [c_e]
    call math_log
    close_to 1.0, 1e-15, "log(e)"
    movsd xmm0, [c_100]
    call math_log
    close_to 4.605170185988092, 1e-14, "log(100)"
    movsd xmm0, [c_pi]
    call math_cos
    close_to -1.0, 1e-15, "cos(pi)"
    movsd xmm0, [c_halfpi]
    call math_sin
    close_to 1.0, 1e-15, "sin(pi/2)"

    jmp t_done
