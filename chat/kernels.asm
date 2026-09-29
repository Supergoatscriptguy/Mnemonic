; cpu kernels for inference: matrix x vector in f32, int8 and int4, and exp for
; 8 floats at a time. the int ones quantize the vector to int8 (groups of 32) and
; take int8 dot products 32 at a time, three ways depending on the cpu:
;   2: AVX-VNNI-INT8  vpdpbssd, signed x signed, one instruction
;   1: AVX-VNNI       vpdpbusd wants unsigned x signed: |w| and x * sign(w)
;   0: AVX2           the same trick with vpmaddubsw + vpmaddwd (no overflow:
;                     both sides stay within +-127, so a pair is at most 32258)
; the int32 sums are exact, and the float work after them is the same code on
; every path, so all three give the same bits
; everything runs over the thread pool, rows split between threads
default rel
bits 64
%include "lib.inc"
%include "chat/model.inc"

MAXCOLS equ 8192

section .rdata
align 32
ones16   times 16 dw 1
nib      times 32 db 0x0f
eights   times 32 db 8
; exp: 2^n * e^r, with the cephes polynomial for e^r on [-ln2/2, ln2/2]
c_hi     dd 88.3762626647949
c_lo     dd -88.3762626647949
c_log2e  dd 1.44269504088896341
c_ln2hi  dd 0.693359375
c_ln2lo  dd -2.12194440e-4
c_p0     dd 1.9875691500E-4
c_p1     dd 1.3981999507E-3
c_p2     dd 8.3334519073E-3
c_p3     dd 4.1665795894E-2
c_p4     dd 1.6666665459E-1
c_p5     dd 5.0000001201E-1
c_one    dd 1.0
c_127i   dd 127
s_vnni8  db "avx-vnni-int8", 0
s_vnni   db "avx-vnni", 0
s_avx2   db "avx2", 0
k_kernel db "kernel", 0
e_avx2   db "this needs a cpu with AVX2 and FMA", 0

section .bss
alignb 64
mv_xq    resb MAXCOLS           ; the vector, quantized
mv_xs    resd MAXCOLS / 32      ; its group scales
mv_mx    resq 1
mv_x     resq 1
mv_y     resq 1
kpath    resq 1
mvq8     resq 1                 ; row functions for the path in use
mvq4     resq 1

section .text

; y[row] for rows [rdx, r8) of mv_mx: the par_for callback signature
; (rcx = ctx, rdx = first, r8 = end, r9 = thread)

; 32 int8 weights in %2 (a ymm) . 32 int8 activations at %3 -> 8 int32 in %1.
; path %4. scratch ymm14, ymm15, and ymm13 holds 16-bit ones on the avx2 path
%macro DOT 4
%if %4 == 2
    vpxor %1, %1, %1
    {vex} vpdpbssd %1, %2, %3
%elif %4 == 1
    vmovdqu ymm14, %3
    vpsignb ymm15, %2, %2
    vpsignb ymm14, ymm14, %2
    vpxor %1, %1, %1
    {vex} vpdpbusd %1, ymm15, ymm14
%else
    vmovdqu ymm14, %3
    vpsignb ymm15, %2, %2
    vpsignb ymm14, ymm14, %2
    vpmaddubsw ymm14, ymm15, ymm14
    vpmaddwd %1, ymm14, ymm13
%endif
%endmacro

; ymm0 -> xmm0 = the sum of its 8 floats, always in the same order
%macro HSUM 0
    vextractf128 xmm1, ymm0, 1
    vaddps xmm0, xmm0, xmm1
    vmovhlps xmm1, xmm1, xmm0
    vaddps xmm0, xmm0, xmm1
    vshufps xmm1, xmm0, xmm0, 1
    vaddss xmm0, xmm0, xmm1
%endmacro

; int8 weights, a scale per row: y = scale[row] * sum_g xs[g] * (w_g . xq_g)
%macro MVQ8 1
mvq8_%1:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov rbx, rdx
    mov r12, r8
    mov rsi, [mv_mx]
    mov r13, [rsi+MX_C]
    vmovdqu ymm13, [ones16]
.row:
    cmp rbx, r12
    jae .done
    mov rdi, rbx
    imul rdi, r13
    add rdi, [rsi+MX_Q]
    lea r9, [mv_xq]
    lea r10, [mv_xs]
    vxorps ymm0, ymm0, ymm0
    mov rcx, r13
    shr rcx, 5
.g:
    vmovdqu ymm1, [rdi]
    DOT ymm2, ymm1, [r9], %1
    vcvtdq2ps ymm2, ymm2
    vbroadcastss ymm3, [r10]
    vfmadd231ps ymm0, ymm2, ymm3
    add rdi, 32
    add r9, 32
    add r10, 4
    dec rcx
    jnz .g
    HSUM
    mov rax, [rsi+MX_S]
    vmulss xmm0, xmm0, [rax+rbx*4]
    mov rax, [mv_y]
    vmovss [rax+rbx*4], xmm0
    inc rbx
    jmp .row
.done:
    vzeroupper
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
%endmacro

; int4 weights, a scale per group: y = sum_g xs[g] ws[g] * (w_g . xq_g). the 16
; packed bytes of a group unpack to 32 int8: low nibbles are weights 0-15, high
; nibbles 16-31, minus the 8 they were stored with
%macro MVQ4 1
mvq4_%1:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov rbx, rdx
    mov r12, r8
    mov rsi, [mv_mx]
    mov r13, [rsi+MX_C]
    vmovdqu ymm13, [ones16]
    vmovdqu ymm12, [nib]
    vmovdqu ymm11, [eights]
.row:
    cmp rbx, r12
    jae .done
    mov rdi, rbx
    imul rdi, r13
    shr rdi, 1
    add rdi, [rsi+MX_Q]
    mov r11, rbx
    imul r11, r13
    shr r11, 3                  ; row * groups * 4 bytes
    add r11, [rsi+MX_S]
    lea r9, [mv_xq]
    lea r10, [mv_xs]
    vxorps ymm0, ymm0, ymm0
    mov rcx, r13
    shr rcx, 5
.g:
    vmovdqu xmm1, [rdi]
    vpsrlw xmm2, xmm1, 4
    vpand xmm1, xmm1, xmm12
    vpand xmm2, xmm2, xmm12
    vinserti128 ymm1, ymm1, xmm2, 1
    vpsubb ymm1, ymm1, ymm11
    DOT ymm2, ymm1, [r9], %1
    vcvtdq2ps ymm2, ymm2
    vmovss xmm4, [r10]
    vmulss xmm4, xmm4, [r11]
    vbroadcastss ymm3, xmm4
    vfmadd231ps ymm0, ymm2, ymm3
    add rdi, 16
    add r9, 32
    add r10, 4
    add r11, 4
    dec rcx
    jnz .g
    HSUM
    mov rax, [mv_y]
    vmovss [rax+rbx*4], xmm0
    inc rbx
    jmp .row
.done:
    vzeroupper
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
%endmacro

MVQ8 0
MVQ8 1
MVQ8 2
MVQ4 0
MVQ4 1
MVQ4 2

; f32 weights and vector, plain fma. the reference, and the f32 model format
mvf32:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    mov rbx, rdx
    mov r12, r8
    mov rsi, [mv_mx]
    mov r13, [rsi+MX_C]
.row:
    cmp rbx, r12
    jae .done
    mov rdi, rbx
    imul rdi, r13
    shl rdi, 2
    add rdi, [rsi+MX_Q]
    mov r9, [mv_x]
    vxorps ymm0, ymm0, ymm0
    vxorps ymm4, ymm4, ymm4
    mov rcx, r13
    shr rcx, 4
.k:
    vmovups ymm1, [rdi]
    vfmadd231ps ymm0, ymm1, [r9]
    vmovups ymm2, [rdi+32]
    vfmadd231ps ymm4, ymm2, [r9+32]
    add rdi, 64
    add r9, 64
    dec rcx
    jnz .k
    vaddps ymm0, ymm0, ymm4
    HSUM
    mov rax, [mv_y]
    vmovss [rax+rbx*4], xmm0
    inc rbx
    jmp .row
.done:
    vzeroupper
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

section .rdata
align 8
q8fns dq mvq8_0, mvq8_1, mvq8_2
q4fns dq mvq4_0, mvq4_1, mvq4_2
section .text

; picks the dot product path from cpuid, or kernel=avx2 / kernel=vnni / kernel=vnni8
; (to check the paths against each other). rax = its name
global kern_pick
kern_pick:
    sub rsp, 40
    mov eax, [cpu_feat]
    and eax, F_AVX2 | F_FMA
    cmp eax, F_AVX2 | F_FMA
    je .ok
    lea rcx, [e_avx2]
    call fatal
.ok:
    xor eax, eax
    test dword [cpu_feat], F_AVXVNNI
    jz .n
    mov eax, 1
    test dword [cpu_feat], F_VNNIINT8
    jz .n
    mov eax, 2
.n:
    mov [kpath], rax
    lea rcx, [k_kernel]
    xor edx, edx
    call cfg_str
    test rax, rax
    jz .set
    cmp dword [rax], 'avx2'
    jne .v
    mov qword [kpath], 0
    jmp .set
.v:
    cmp byte [rax+5], '8'       ; vnni8
    je .v8
    mov qword [kpath], 1
    jmp .set
.v8:
    mov qword [kpath], 2
.set:
    mov rcx, [kpath]
    call kern_set
    call kern_name
    add rsp, 40
    ret

; ecx = path (0 avx2, 1 avx-vnni, 2 avx-vnni-int8). for tests, which check them
; against each other
global kern_set
kern_set:
    mov eax, ecx
    mov [kpath], rax
    lea rcx, [q8fns]
    mov rdx, [rcx+rax*8]
    mov [mvq8], rdx
    lea rcx, [q4fns]
    mov rdx, [rcx+rax*8]
    mov [mvq4], rdx
    ret

; rax = the name of the path in use
global kern_name
kern_name:
    lea rax, [s_avx2]
    cmp qword [kpath], 1
    jb .done
    lea rax, [s_vnni]
    je .done
    lea rax, [s_vnni8]
.done:
    ret

; rcx = matrix (MX_*), rdx = x (f32, cols), r8 = y (f32, rows). y = W x, on every thread
global mv_run
mv_run:
    push rbx
    sub rsp, 32
    mov rbx, rcx
    mov [mv_mx], rcx
    mov [mv_x], rdx
    mov [mv_y], r8
    lea rcx, [mvf32]
    cmp qword [rbx+MX_T], QT_F32
    je .go
    mov rcx, rdx
    mov rdx, [rbx+MX_C]
    lea r8, [mv_xq]
    lea r9, [mv_xs]
    call qx_vec
    mov rcx, [mvq8]
    cmp qword [rbx+MX_T], QT_Q8
    je .go
    mov rcx, [mvq4]
.go:
    ; chunks of rows: about 8 per thread, at least 4 rows each
    mov rax, [rbx+MX_R]
    mov r9, [nthreads]
    shl r9, 3
    xor edx, edx
    div r9
    mov r9d, 4
    cmp rax, r9
    cmovb rax, r9
    mov r9, rax
    xor edx, edx
    mov r8, [rbx+MX_R]
    call par_for
    add rsp, 32
    pop rbx
    ret

; ymm0 = e^ymm0, for 8 floats (relative error around 1e-7). uses ymm1-5
global exp8
exp8:
    vbroadcastss ymm1, [c_hi]
    vminps ymm0, ymm0, ymm1
    vbroadcastss ymm1, [c_lo]
    vmaxps ymm0, ymm0, ymm1
    vbroadcastss ymm1, [c_log2e]
    vmulps ymm1, ymm0, ymm1
    vroundps ymm1, ymm1, 0      ; n = round(x log2 e)
    vbroadcastss ymm2, [c_ln2hi]
    vfnmadd231ps ymm0, ymm1, ymm2
    vbroadcastss ymm2, [c_ln2lo]
    vfnmadd231ps ymm0, ymm1, ymm2   ; r = x - n ln2, in two steps for precision
    vbroadcastss ymm3, [c_p0]
    vbroadcastss ymm2, [c_p1]
    vfmadd213ps ymm3, ymm0, ymm2
    vbroadcastss ymm2, [c_p2]
    vfmadd213ps ymm3, ymm0, ymm2
    vbroadcastss ymm2, [c_p3]
    vfmadd213ps ymm3, ymm0, ymm2
    vbroadcastss ymm2, [c_p4]
    vfmadd213ps ymm3, ymm0, ymm2
    vbroadcastss ymm2, [c_p5]
    vfmadd213ps ymm3, ymm0, ymm2
    vmulps ymm4, ymm0, ymm0
    vbroadcastss ymm2, [c_one]
    vaddps ymm5, ymm0, ymm2
    vfmadd231ps ymm5, ymm3, ymm4    ; 1 + r + r^2 p(r)
    vcvtps2dq ymm1, ymm1
    vpbroadcastd ymm2, [c_127i]
    vpaddd ymm1, ymm1, ymm2
    vpslld ymm1, ymm1, 23           ; 2^n
    vmulps ymm0, ymm5, ymm1
    ret
