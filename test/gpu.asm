; stage 4 test: every kernel against the cpu or against the reference kernel.
; vadd and f2bf have to match the cpu bit for bit, gemm_ref too (same fma, same
; order), and the tensor core gemms have to match gemm_ref to fp32 accuracy
; uses: gpu\cuda gpu\kernels
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"
%include "test/check.inc"

extern ptx_basic, ptx_basic_end, ptx_gemm, ptx_gemm_end

NV    equ 1000003               ; vadd / f2bf size, not a multiple of anything
CPYB  equ 64 << 20              ; copy test bytes
GMAX  equ 1024                  ; biggest gemm side here

section .rdata
k_vadd   db "vadd", 0
k_copy16 db "copy16", 0
k_f2bf   db "f2bf", 0
k_ref    db "gemm_ref", 0
k_mma1   db "gemm_mma1", 0
k_tc     db "gemm_tc", 0
align 8
c_half   dq 0.5
c_quart  dq 0.25
c_three  dq 3.0
c_tol    dq 1e-4
specials dd 0x00000000, 0x80000000, 0x7f800000, 0xff800000, 0x7f7fffff, 0x00000001
         dd 0x3f808000, 0x3f818000, 0x3f80ffff, 0xbf808001  ; ties and near-ties

section .bss
alignb 8
kl       resb KL_SIZE
f_vadd   resq 1
f_copy   resq 1
f_f2bf   resq 1
f_ref    resq 1
f_mma1   resq 1
f_tc     resq 1
ha       resq 1
hb       resq 1
hc       resq 1
hd       resq 1
d_a      resq 1
d_b      resq 1
d_c      resq 1
d_r      resq 1
rng      resb RNG_SIZE
maxd     resq 1
maxr     resq 1

section .text

; rcx = module name, the function goes in [rdx]
%macro getf 3
    mov rcx, %1
    lea rdx, [%2]
    call gpu_func
    mov [%3], rax
%endmacro

global start
start:
    sub rsp, 40
    call lib_init
    call gpu_init
    say "  "
    lea rcx, [gpu_name]
    call print_z
    say ", "
    lea rcx, [gpu_target]
    call print_z
    say 13, 10
    lea rcx, [ptx_basic]
    lea rdx, [ptx_basic_end]
    sub rdx, rcx
    call gpu_module
    mov r12, rax
    getf r12, k_vadd, f_vadd
    getf r12, k_copy16, f_copy
    getf r12, k_f2bf, f_f2bf
    lea rcx, [ptx_gemm]
    lea rdx, [ptx_gemm_end]
    sub rdx, rcx
    call gpu_module
    mov r12, rax
    getf r12, k_ref, f_ref
    getf r12, k_mma1, f_mma1
    getf r12, k_tc, f_tc
    lea rcx, [rng]
    mov edx, 4
    call rng_seed

    ; host and device buffers, big enough for everything below
    mov ecx, CPYB
    call mem_alloc
    mov [ha], rax
    mov ecx, CPYB
    call mem_alloc
    mov [hb], rax
    mov ecx, GMAX * GMAX * 4
    call mem_alloc
    mov [hc], rax
    mov ecx, GMAX * GMAX * 4
    call mem_alloc
    mov [hd], rax
    mov ecx, CPYB
    call gpu_alloc
    mov [d_a], rax
    mov ecx, CPYB
    call gpu_alloc
    mov [d_b], rax
    mov ecx, GMAX * GMAX * 4
    call gpu_alloc
    mov [d_c], rax
    mov ecx, GMAX * GMAX * 4
    call gpu_alloc
    mov [d_r], rax

    say "basics", 13, 10
    call t_vadd
    call t_copy
    call t_f2bf
    say "matmul", 13, 10
    call t_ref
    ; tensor cores against the reference
    mov ecx, 1
    mov edx, 256
    mov r8d, 128
    mov r9d, 512
    lea rax, [m_mma1]
    call t_gemm
    mov ecx, 2
    mov edx, 128
    mov r8d, 128
    mov r9d, 32
    lea rax, [m_tc1]
    call t_gemm
    mov ecx, 2
    mov edx, 256
    mov r8d, 384
    mov r9d, 256
    lea rax, [m_tc2]
    call t_gemm
    mov ecx, 2
    mov edx, 1024
    mov r8d, 1024
    mov r9d, 1024
    lea rax, [m_tc3]
    call t_gemm
    mov ecx, 2
    mov edx, 384
    mov r8d, 1024
    mov r9d, 4096
    lea rax, [m_tc4]
    call t_gemm
    jmp t_done

section .rdata
m_mma1 db "gemm_mma1 256x128x512 matches gemm_ref", 0
m_tc1  db "gemm_tc 128x128x32 (one tile) matches gemm_ref", 0
m_tc2  db "gemm_tc 256x384x256 matches gemm_ref", 0
m_tc3  db "gemm_tc 1024x1024x1024 matches gemm_ref", 0
m_tc4  db "gemm_tc 384x1024x4096 (long k) matches gemm_ref", 0
section .text

; ---- vadd: a[i] = i/2, b[i] = 3 - i/4, compared exactly with the cpu's addss
t_vadd:
    push rbx
    sub rsp, 32
    mov rcx, [ha]
    mov rdx, [hb]
    xor eax, eax
.fill:
    cvtsi2ss xmm0, eax
    movss xmm1, xmm0
    mulss xmm0, [f_half]
    mulss xmm1, [f_quart]
    movss xmm2, [f_three]
    subss xmm2, xmm1
    movss [rcx+rax*4], xmm0
    movss [rdx+rax*4], xmm2
    inc eax
    cmp eax, NV
    jb .fill
    mov rcx, [d_a]
    mov rdx, [ha]
    mov r8d, NV * 4
    call gpu_up
    mov rcx, [d_b]
    mov rdx, [hb]
    mov r8d, NV * 4
    call gpu_up
    lea rbx, [kl]
    mov rax, [f_vadd]
    mov [rbx+KL_FUNC], rax
    grid 512, 1, 256, 1
    mov rax, [d_a]
    mov [rbx+KL_ARGS], rax
    mov rax, [d_b]
    mov [rbx+KL_ARGS+8], rax
    mov rax, [d_c]
    mov [rbx+KL_ARGS+16], rax
    mov qword [rbx+KL_ARGS+24], NV
    mov rcx, rbx
    call gpu_launch
    call gpu_sync
    mov rcx, [hc]
    mov rdx, [d_c]
    mov r8d, NV * 4
    call gpu_down
    mov rcx, [ha]
    mov rdx, [hb]
    mov r8, [hc]
    xor eax, eax
    xor r9d, r9d                ; mismatches
.chk:
    movss xmm0, [rcx+rax*4]
    addss xmm0, [rdx+rax*4]
    movd r10d, xmm0
    cmp r10d, [r8+rax*4]
    je .ok
    inc r9d
.ok:
    inc eax
    cmp eax, NV
    jb .chk
    test r9d, r9d
    check z, "vadd, 1000003 floats, same bits as the cpu"
    add rsp, 32
    pop rbx
    ret

; ---- copy16: 64 MB of random bytes through the gpu and back
t_copy:
    push rbx
    sub rsp, 32
    mov rbx, [ha]
    xor esi, esi
.fill:
    lea rcx, [rng]
    call rng_next
    mov [rbx+rsi*8], rax
    inc esi
    cmp esi, CPYB / 8
    jb .fill
    mov rcx, [d_a]
    mov rdx, [ha]
    mov r8d, CPYB
    call gpu_up
    lea rbx, [kl]
    mov rax, [f_copy]
    mov [rbx+KL_FUNC], rax
    grid 1024, 1, 256, 1
    mov rax, [d_b]
    mov [rbx+KL_ARGS], rax
    mov rax, [d_a]
    mov [rbx+KL_ARGS+8], rax
    mov qword [rbx+KL_ARGS+16], CPYB / 16
    mov rcx, rbx
    call gpu_launch
    mov rcx, [hb]
    mov rdx, [d_b]
    mov r8d, CPYB
    call gpu_down
    mov rsi, [ha]
    mov rdi, [hb]
    mov ecx, CPYB / 8
    repe cmpsq
    check e, "copy16, 64 MB there and back"
    add rsp, 32
    pop rbx
    ret

; ---- f2bf: round to nearest even, same bits as the cpu's version of it
t_f2bf:
    push rbx
    sub rsp, 32
    mov rbx, [ha]
    xor esi, esi
.fill:
    lea rcx, [rng]
    call rng_normal
    mulsd xmm0, [c_three]
    cvtsd2ss xmm0, xmm0
    movss [rbx+rsi*4], xmm0
    inc esi
    cmp esi, NV
    jb .fill
    lea rdx, [specials]         ; plus the awkward ones
    xor ecx, ecx
.sp:
    mov eax, [rdx+rcx*4]
    mov [rbx+rcx*4], eax
    inc ecx
    cmp ecx, 10
    jb .sp
    mov rcx, [d_a]
    mov rdx, [ha]
    mov r8d, NV * 4
    call gpu_up
    lea rbx, [kl]
    mov rax, [f_f2bf]
    mov [rbx+KL_FUNC], rax
    grid 512, 1, 256, 1
    mov rax, [d_b]
    mov [rbx+KL_ARGS], rax
    mov rax, [d_a]
    mov [rbx+KL_ARGS+8], rax
    mov qword [rbx+KL_ARGS+16], NV
    mov rcx, rbx
    call gpu_launch
    mov rcx, [hb]
    mov rdx, [d_b]
    mov r8d, NV * 2
    call gpu_down
    mov rcx, [ha]
    mov rdx, [hb]
    xor eax, eax
    xor r9d, r9d
.chk:
    mov r8d, [rcx+rax*4]
    call bf16
    cmp r8w, [rdx+rax*2]
    je .ok
    inc r9d
.ok:
    inc eax
    cmp eax, NV
    jb .chk
    test r9d, r9d
    check z, "f2bf, 1000003 floats incl. inf/0/ties, same bits as the cpu"
    add rsp, 32
    pop rbx
    ret

; r8d = f32 bits -> r8w = bf16 bits, round to nearest even (no nans in here)
bf16:
    mov r10d, r8d
    shr r10d, 16
    and r10d, 1
    add r8d, 0x7fff
    add r8d, r10d
    shr r8d, 16
    ret

; rcx = host buffer, edx = count: random bf16 in [-1, 1)
rand_bf16:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov esi, edx
    xor edi, edi
.r:
    cmp edi, esi
    jae .done
    lea rcx, [rng]
    call rng_float
    addsd xmm0, xmm0
    subsd xmm0, [c_one]
    cvtsd2ss xmm0, xmm0
    movd r8d, xmm0
    call bf16
    mov [rbx+rdi*2], r8w
    inc edi
    jmp .r
.done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; ecx = which (0 ref, 1 mma1, 2 tc), edx = M, r8d = N, r9d = K. C goes to d_c
; (d_r for the reference, so they can be compared)
gemm:
    push rbx
    sub rsp, 32
    lea rbx, [kl]
    mov [rbx+KL_ARGS+32], r8    ; N
    mov [rbx+KL_ARGS+24], rdx   ; M
    mov [rbx+KL_ARGS+40], r9    ; K
    mov rax, [d_a]
    mov [rbx+KL_ARGS], rax
    mov rax, [d_b]
    mov [rbx+KL_ARGS+8], rax
    mov rax, [d_c]
    mov [rbx+KL_ARGS+16], rax
    mov dword [rbx+KL_GZ], 1
    mov dword [rbx+KL_BZ], 1
    cmp ecx, 1
    je .mma1
    ja .tc
    mov rax, [f_ref]
    mov [rbx+KL_FUNC], rax
    mov rax, [d_r]
    mov [rbx+KL_ARGS+16], rax
    lea eax, [r8+15]
    shr eax, 4
    mov [rbx+KL_GX], eax
    lea eax, [rdx+15]
    shr eax, 4
    mov [rbx+KL_GY], eax
    mov dword [rbx+KL_BX], 16
    mov dword [rbx+KL_BY], 16
    jmp .go
.mma1:
    mov rax, [f_mma1]
    mov [rbx+KL_FUNC], rax
    mov eax, r8d
    shr eax, 3
    mov [rbx+KL_GX], eax
    mov eax, edx
    shr eax, 4
    mov [rbx+KL_GY], eax
    mov dword [rbx+KL_BX], 32
    mov dword [rbx+KL_BY], 1
    jmp .go
.tc:
    mov rax, [f_tc]
    mov [rbx+KL_FUNC], rax
    mov eax, r8d
    shr eax, 7
    mov [rbx+KL_GX], eax
    mov eax, edx
    shr eax, 7
    mov [rbx+KL_GY], eax
    mov dword [rbx+KL_BX], 256
    mov dword [rbx+KL_BY], 1
.go:
    mov rcx, rbx
    call gpu_launch
    call gpu_sync
    add rsp, 32
    pop rbx
    ret

; ---- gemm_ref against the cpu: odd sizes so the bounds checks get used
RM equ 70
RN equ 50
RK equ 33
t_ref:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rcx, [ha]
    mov edx, RM * RK
    call rand_bf16
    mov rcx, [hb]
    mov edx, RN * RK
    call rand_bf16
    mov rcx, [d_a]
    mov rdx, [ha]
    mov r8d, RM * RK * 2
    call gpu_up
    mov rcx, [d_b]
    mov rdx, [hb]
    mov r8d, RN * RK * 2
    call gpu_up
    xor ecx, ecx
    mov edx, RM
    mov r8d, RN
    mov r9d, RK
    call gemm
    mov rcx, [hc]
    mov rdx, [d_r]
    mov r8d, RM * RN * 4
    call gpu_down
    ; the same sum on the cpu: fma in k order, exactly like the kernel
    xor r12d, r12d              ; m
    xor r13d, r13d              ; mismatches
.m:
    cmp r12d, RM
    jae .done
    xor ebx, ebx                ; n
.n:
    cmp ebx, RN
    jae .mn
    imul esi, r12d, RK * 2
    add rsi, [ha]
    imul edi, ebx, RK * 2
    add rdi, [hb]
    vxorps xmm0, xmm0, xmm0
    xor ecx, ecx
.k:
    movzx eax, word [rsi+rcx*2]
    shl eax, 16
    vmovd xmm1, eax
    movzx eax, word [rdi+rcx*2]
    shl eax, 16
    vmovd xmm2, eax
    vfmadd231ss xmm0, xmm1, xmm2
    inc ecx
    cmp ecx, RK
    jb .k
    imul eax, r12d, RN
    add eax, ebx
    mov rdx, [hc]
    vmovd ecx, xmm0
    cmp ecx, [rdx+rax*4]
    je .same
    inc r13d
.same:
    inc ebx
    jmp .n
.mn:
    inc r12d
    jmp .m
.done:
    test r13d, r13d
    check z, "gemm_ref 70x50x33 = cpu fma loop, bit for bit"
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- a tensor core kernel against gemm_ref.
; ecx = which, edx = M, r8d = N, r9d = K, rax = name for the check
t_gemm:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov [rsp+32], rax
    mov r12d, ecx
    mov r13d, edx
    mov r14d, r8d
    mov r15d, r9d
    mov rcx, [ha]
    mov edx, r13d
    imul edx, r15d
    call rand_bf16
    mov rcx, [hb]
    mov edx, r14d
    imul edx, r15d
    call rand_bf16
    mov rcx, [d_a]
    mov rdx, [ha]
    mov r8d, r13d
    imul r8d, r15d
    shl r8d, 1
    call gpu_up
    mov rcx, [d_b]
    mov rdx, [hb]
    mov r8d, r14d
    imul r8d, r15d
    shl r8d, 1
    call gpu_up
    xor ecx, ecx                ; reference into d_r
    mov edx, r13d
    mov r8d, r14d
    mov r9d, r15d
    call gemm
    mov ecx, r12d               ; the one under test into d_c
    mov edx, r13d
    mov r8d, r14d
    mov r9d, r15d
    call gemm
    mov ebx, r13d
    imul ebx, r14d              ; outputs
    mov rcx, [hc]
    mov rdx, [d_c]
    lea r8, [rbx*4]
    call gpu_down
    mov rcx, [hd]
    mov rdx, [d_r]
    lea r8, [rbx*4]
    call gpu_down
    ; largest difference, relative to the largest value
    mov rsi, [hc]
    mov rdi, [hd]
    vxorps xmm2, xmm2, xmm2     ; max |diff|
    vxorps xmm3, xmm3, xmm3     ; max |ref|
    mov eax, 0x7fffffff
    vmovd xmm5, eax
    xor ecx, ecx
.c:
    vmovss xmm0, [rsi+rcx*4]
    vmovss xmm1, [rdi+rcx*4]
    vsubss xmm0, xmm0, xmm1
    vandps xmm0, xmm0, xmm5
    vandps xmm1, xmm1, xmm5
    vmaxss xmm2, xmm2, xmm0
    vmaxss xmm3, xmm3, xmm1
    inc ecx
    cmp ecx, ebx
    jb .c
    vcvtss2sd xmm2, xmm2, xmm2
    vcvtss2sd xmm3, xmm3, xmm3
    vmovsd [maxd], xmm2
    vmovsd [maxr], xmm3
    vdivsd xmm0, xmm2, xmm3
    vmovsd [rsp+40], xmm0
    vcomisd xmm0, [c_tol]
    setb cl
    movzx ecx, cl
    mov rdx, [rsp+32]
    movsd xmm2, [rsp+40]
    call t_okf                  ; shows the relative error it got
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

section .rdata
align 4
f_half  dd 0.5
f_quart dd 0.25
f_three dd 3.0
align 8
c_one   dq 1.0
