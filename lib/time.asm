; timing off the performance counter (10 MHz on current Windows)
default rel
bits 64
%include "lib.inc"

extern QueryPerformanceFrequency, QueryPerformanceCounter

section .bss
qpc_freq resq 1
inv_freq resq 1

section .text

global time_init
time_init:
    sub rsp, 40
    lea rcx, [qpc_freq]
    call QueryPerformanceFrequency
    mov eax, 1
    cvtsi2sd xmm0, rax
    cvtsi2sd xmm1, qword [qpc_freq]
    divsd xmm0, xmm1
    movsd [inv_freq], xmm0
    add rsp, 40
    ret

; rax = ticks
global time_now
time_now:
    sub rsp, 40
    lea rcx, [rsp+32]
    call QueryPerformanceCounter
    mov rax, [rsp+32]
    add rsp, 40
    ret

; rcx = start ticks. xmm0 = seconds since
global time_since
time_since:
    sub rsp, 40
    mov [rsp+48], rcx
    call time_now
    sub rax, [rsp+48]
    cvtsi2sd xmm0, rax
    mulsd xmm0, [inv_freq]
    add rsp, 40
    ret
