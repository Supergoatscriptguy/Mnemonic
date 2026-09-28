; stage 1 test: thread pool and par_for
default rel
bits 64
%include "lib.inc"
%include "test/check.inc"

WORK  equ 1 << 30
CHUNK equ 1 << 20

section .rdata
align 8
c_two  dq 2.0

section .bss
alignb 8
total  resq 1
counts resq 64
t1     resq 1

section .text

; par_for callbacks: rcx = ctx, rdx = start, r8 = end, r9 = thread index

; adds up the indices into [ctx]
sum_fn:
    xor eax, eax
.l:
    cmp rdx, r8
    jae .d
    add rax, rdx
    inc rdx
    jmp .l
.d:
    lock add [rcx], rax
    ret

; pure alu busywork, plus a tally of how many items each thread did
work_fn:
    mov [rsp+8], rcx
    xor eax, eax
    mov r10, 0x9e3779b97f4a7c15
    mov r11, r8
    sub r11, rdx
.l:
    cmp rdx, r8
    jae .d
    mov rcx, rdx
    imul rcx, r10
    popcnt rcx, rcx
    add rax, rcx
    inc rdx
    jmp .l
.d:
    mov rcx, [rsp+8]
    lock add [rcx], rax
    lea rcx, [counts]
    lock add [rcx+r9*8], r11
    ret

%macro sumtest 3+               ; n, chunk, name
    mov qword [total], 0
    lea rcx, [sum_fn]
    lea rdx, [total]
    mov r8, %1
    mov r9, %2
    call par_for
    mov rax, (%1) * ((%1) - 1) / 2
    cmp [total], rax
    check e, %3
%endmacro

global start
start:
    sub rsp, 40
    call lib_init
    xor ecx, ecx
    call pool_init
    say "  threads: "
    mov rcx, [nthreads]
    call print_dec
    say 13, 10

    sumtest 0, 16, "par_for n=0"
    sumtest 1, 16, "par_for n=1"
    sumtest 7, 1, "par_for n=7, fewer items than threads"
    sumtest 1000003, 1000, "par_for n=1000003, ragged last chunk"
    sumtest 100000000, 65536, "par_for n=100M"

    ; same work on one thread, then on the pool
    mov qword [total], 0
    call time_now
    mov r12, rax
    lea rcx, [total]
    xor edx, edx
    mov r8, WORK
    xor r9d, r9d
    call work_fn
    mov rcx, r12
    call time_since
    movsd [t1], xmm0
    mov r13, [total]

    lea rdi, [counts]
    xor eax, eax
    mov ecx, 64
    rep stosq
    mov qword [total], 0
    call time_now
    mov r12, rax
    lea rcx, [work_fn]
    lea rdx, [total]
    mov r8, WORK
    mov r9, CHUNK
    call par_for
    mov rcx, r12
    call time_since
    movapd xmm6, xmm0
    cmp [total], r13
    check e, "pool gives the same answer as one thread"

    say "  1 thread  "
    movsd xmm0, [t1]
    mov edx, 3
    call print_fixed
    say "s    pool  "
    movapd xmm0, xmm6
    mov edx, 3
    call print_fixed
    say "s    speedup "
    movsd xmm0, [t1]
    divsd xmm0, xmm6
    movapd xmm7, xmm0
    mov edx, 1
    call print_fixed
    say "x", 13, 10
    comisd xmm7, [c_two]
    check a, "speedup over 2x"

    ; P cores should end up with more chunks than E cores
    say "  chunks per thread:"
    xor ebx, ebx
.show:
    cmp rbx, [nthreads]
    jae .shown
    say " "
    lea rax, [counts]
    mov rcx, [rax+rbx*8]
    shr rcx, 20
    call print_dec
    inc ebx
    jmp .show
.shown:
    say 13, 10

    jmp t_done
