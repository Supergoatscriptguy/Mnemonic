; xoshiro256** random numbers. the state is 32 bytes the caller owns,
; so there can be several streams and each one can be saved in a checkpoint
default rel
bits 64
%include "lib.inc"

section .rdata
align 8
sm_m1    dq 0xbf58476d1ce4e5b9
sm_m2    dq 0x94d049bb133111eb
two_m53  dq 1.1102230246251565e-16  ; 2^-53
one      dq 1.0
minus2   dq -2.0
twopi    dq 6.283185307179586

section .text

; rcx = state, rdx = seed. fills the state with splitmix64 so similar seeds
; still give unrelated streams
global rng_seed
rng_seed:
    lea r8, [rcx+32]
    mov r9, 0x9e3779b97f4a7c15
.next:
    add rdx, r9
    mov rax, rdx
    mov r10, rax
    shr r10, 30
    xor rax, r10
    imul rax, [sm_m1]
    mov r10, rax
    shr r10, 27
    xor rax, r10
    imul rax, [sm_m2]
    mov r10, rax
    shr r10, 31
    xor rax, r10
    mov [rcx], rax
    add rcx, 8
    cmp rcx, r8
    jb .next
    ret

; rcx = state. rax = next 64 random bits
global rng_next
rng_next:
    mov rdx, [rcx+8]            ; s1
    lea rax, [rdx+rdx*4]
    rol rax, 7
    lea rax, [rax+rax*8]        ; rotl(s1 * 5, 7) * 9
    mov r8, [rcx]
    mov r9, [rcx+16]
    mov r10, [rcx+24]
    mov r11, rdx
    shl r11, 17
    xor r9, r8                  ; s2 ^= s0
    xor r10, rdx                ; s3 ^= s1
    xor rdx, r9                 ; s1 ^= s2
    xor r8, r10                 ; s0 ^= s3
    xor r9, r11                 ; s2 ^= t
    rol r10, 45
    mov [rcx], r8
    mov [rcx+8], rdx
    mov [rcx+16], r9
    mov [rcx+24], r10
    ret

; rcx = state. xmm0 = uniform in [0, 1)
global rng_float
rng_float:
    sub rsp, 40
    call rng_next
    shr rax, 11                 ; 53 bits, exactly what a double holds
    cvtsi2sd xmm0, rax
    mulsd xmm0, [two_m53]
    add rsp, 40
    ret

; rcx = state. xmm0 = standard normal, Box-Muller. always uses 2 draws
global rng_normal
rng_normal:
    push rbx
    sub rsp, 48
    mov rbx, rcx
    call rng_float
    movsd xmm1, [one]
    subsd xmm1, xmm0            ; (0, 1], keeps log away from 0
    movapd xmm0, xmm1
    call math_log
    mulsd xmm0, [minus2]
    sqrtsd xmm0, xmm0
    movsd [rsp+32], xmm0
    mov rcx, rbx
    call rng_float
    mulsd xmm0, [twopi]
    call math_cos
    mulsd xmm0, [rsp+32]
    add rsp, 48
    pop rbx
    ret
