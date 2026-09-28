; stage 5 test: the fast kernels against the naive ones.
;  - gemm_tc in every layout the model uses, against mm_ref. a transposed operand
;    has to give exactly the same bits as the plain one: same values, same
;    fragments, same order of adds
; uses: gpu\cuda gpu\kernels
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"
%include "model/model.inc"
%include "test/check.inc"

extern ptx_gemm, ptx_gemm_end

GM equ 640                      ; like a qkv weight gradient: 640 x 384, k over tokens
GN equ 384
GK equ 2048

section .rdata
kn_ref  db "mm_ref", 0
kn_tc   db "gemm_tc", 0
align 8
c_tol   dq 1e-4
c_one   dq 1.0

section .bss
alignb 8
kl      resb KL_SIZE
f_ref   resq 1
f_tc    resq 1
rng     resb RNG_SIZE
ha      resq 1                  ; A [M][K]
hat     resq 1                  ; A^T [K][M]
hb      resq 1                  ; B [N][K]
hbt     resq 1                  ; B^T [K][N]
hr      resq 1                  ; R [M][N] f32
hc      resq 1
hd      resq 1
da      resq 1
dat     resq 1
db_     resq 1
dbt     resq 1
dr      resq 1
dc      resq 1
dd_     resq 1

section .text

global start
start:
    sub rsp, 40
    call lib_init
    call gpu_init
    lea rcx, [ptx_gemm]
    lea rdx, [ptx_gemm_end]
    sub rdx, rcx
    call gpu_module
    mov rbx, rax
    mov rcx, rbx
    lea rdx, [kn_ref]
    call gpu_func
    mov [f_ref], rax
    mov rcx, rbx
    lea rdx, [kn_tc]
    call gpu_func
    mov [f_tc], rax
    lea rcx, [rng]
    mov edx, 5
    call rng_seed
    call t_gemm
    jmp t_done

; rcx = kernel, rdx = a, r8 = b, r9 = c, then on the stack r, flags. GM x GN x GK
mm:
    push rbx
    sub rsp, 32
    lea rbx, [kl]
    mov [rbx+KL_FUNC], rcx
    mov [rbx+KL_ARGS], rdx
    mov [rbx+KL_ARGS+8], r8
    mov [rbx+KL_ARGS+16], r9
    mov qword [rbx+KL_ARGS+24], GM
    mov qword [rbx+KL_ARGS+32], GN
    mov qword [rbx+KL_ARGS+40], GK
    mov rax, [rsp+80]
    mov [rbx+KL_ARGS+48], rax
    mov rax, [rsp+88]
    mov [rbx+KL_ARGS+56], rax
    cmp rcx, [f_tc]
    je .tc
    grid GN / 16, GM / 16, 16, 16
    jmp .go
.tc:
    grid GN / 128, GM / 128, 256, 1
.go:
    mov rcx, rbx
    call gpu_launch
    call gpu_sync
    add rsp, 32
    pop rbx
    ret

; same bytes in both device buffers? rcx = one, rdx = other, r8 = bytes. zf set if so
same:
    push rsi
    push rdi
    push rbx
    sub rsp, 32
    mov rbx, r8
    mov rsi, rdx
    mov rdx, rcx
    mov rcx, [hc]
    mov r8, rbx
    call gpu_down
    mov rcx, [hd]
    mov rdx, rsi
    mov r8, rbx
    call gpu_down
    mov rsi, [hc]
    mov rdi, [hd]
    mov rcx, rbx
    repe cmpsb
    lea rsp, [rsp+32]           ; add would clobber zf
    pop rbx
    pop rdi
    pop rsi
    ret

; max |c - d| / max |d| over n floats of hc, hd -> xmm0
relerr:
    vxorps xmm2, xmm2, xmm2
    vxorps xmm3, xmm3, xmm3
    mov eax, 0x7fffffff
    vmovd xmm5, eax
    mov r8, [hc]
    mov r9, [hd]
    xor eax, eax
.c:
    vmovss xmm0, [r8+rax*4]
    vmovss xmm1, [r9+rax*4]
    vsubss xmm0, xmm0, xmm1
    vandps xmm0, xmm0, xmm5
    vandps xmm1, xmm1, xmm5
    vmaxss xmm2, xmm2, xmm0
    vmaxss xmm3, xmm3, xmm1
    inc rax
    cmp rax, rcx
    jb .c
    vcvtss2sd xmm2, xmm2, xmm2
    vcvtss2sd xmm3, xmm3, xmm3
    vdivsd xmm0, xmm2, xmm3
    ret

; r8d = f32 bits -> r8w = bf16, nearest even
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

; rcx = src [rows][cols] u16, rdx = dst [cols][rows], r8d = rows, r9d = cols
transpose:
    push rbx
    xor r10d, r10d
.r:
    cmp r10d, r8d
    jae .done
    xor r11d, r11d
.c:
    cmp r11d, r9d
    jae .rn
    mov eax, r10d
    imul eax, r9d
    add eax, r11d
    movzx ebx, word [rcx+rax*2]
    mov eax, r11d
    imul eax, r8d
    add eax, r10d
    mov [rdx+rax*2], bx
    inc r11d
    jmp .c
.rn:
    inc r10d
    jmp .r
.done:
    pop rbx
    ret

%macro dup 3                    ; device dst, host src, bytes
    mov rcx, %3
    call gpu_alloc
    mov [%1], rax
    mov rcx, rax
    mov rdx, [%2]
    mov r8, %3
    call gpu_up
%endmacro

; a gemm call with the two stack args: kernel, a, b, c, r, flags
%macro MMT 6
    mov rax, %5
    mov [rsp+32], rax
    mov qword [rsp+40], %6
    mov rcx, [%1]
    mov rdx, [%2]
    mov r8, [%3]
    mov r9, [%4]
    call mm
%endmacro

t_gemm:
    push rbx
    push rsi
    sub rsp, 56
    say "matmul layouts, ", "640x384x2048", 13, 10
    mov ecx, GM * GK * 2
    call mem_alloc
    mov [ha], rax
    mov ecx, GM * GK * 2
    call mem_alloc
    mov [hat], rax
    mov ecx, GN * GK * 2
    call mem_alloc
    mov [hb], rax
    mov ecx, GN * GK * 2
    call mem_alloc
    mov [hbt], rax
    mov ecx, GM * GN * 4
    call mem_alloc
    mov [hr], rax
    mov ecx, GM * GN * 4
    call mem_alloc
    mov [hc], rax
    mov ecx, GM * GN * 4
    call mem_alloc
    mov [hd], rax
    mov rcx, [ha]
    mov edx, GM * GK
    call rand_bf16
    mov rcx, [hb]
    mov edx, GN * GK
    call rand_bf16
    mov rcx, [ha]
    mov rdx, [hat]
    mov r8d, GM
    mov r9d, GK
    call transpose
    mov rcx, [hb]
    mov rdx, [hbt]
    mov r8d, GN
    mov r9d, GK
    call transpose
    ; R: random f32
    xor ebx, ebx
.rr:
    lea rcx, [rng]
    call rng_float
    cvtsd2ss xmm0, xmm0
    mov rax, [hr]
    movss [rax+rbx*4], xmm0
    inc ebx
    cmp ebx, GM * GN
    jb .rr
    dup da, ha, GM * GK * 2
    dup dat, hat, GM * GK * 2
    dup db_, hb, GN * GK * 2
    dup dbt, hbt, GN * GK * 2
    dup dr, hr, GM * GN * 4
    mov ecx, GM * GN * 4
    call gpu_alloc
    mov [dc], rax
    mov ecx, GM * GN * 4
    call gpu_alloc
    mov [dd_], rax

    ; the reference, plain layout, into dd. then the tensor cores into dc
    MMT f_ref, da, db_, dd_, 0, 0
    MMT f_tc, da, db_, dc, 0, 0
    mov rcx, [hc]
    mov rdx, [dc]
    mov r8d, GM * GN * 4
    call gpu_down
    mov rcx, [hd]
    mov rdx, [dd_]
    mov r8d, GM * GN * 4
    call gpu_down
    mov ecx, GM * GN
    call relerr
    movsd [rsp+48], xmm0
    comisd xmm0, [c_tol]
    setb cl
    movzx ecx, cl
    lea rdx, [m_nt]
    movsd xmm2, [rsp+48]
    call t_okf

    ; every other layout has to match the plain one exactly. dc = plain, dd = test
    MMT f_tc, da, dbt, dd_, 0, MM_TB
    mov rcx, [dc]
    mov rdx, [dd_]
    mov r8d, GM * GN * 4
    call same
    check e, "gemm_tc, B stored [K][N] (dx = dy W): same bits as the plain layout"
    MMT f_tc, dat, dbt, dd_, 0, MM_TA | MM_TB
    mov rcx, [dc]
    mov rdx, [dd_]
    mov r8d, GM * GN * 4
    call same
    check e, "gemm_tc, both stored [K][..] (dW = dy^T x): same bits"
    MMT f_tc, dat, db_, dd_, 0, MM_TA
    mov rcx, [dc]
    mov rdx, [dd_]
    mov r8d, GM * GN * 4
    call same
    check e, "gemm_tc, A stored [K][M]: same bits"
    ; mm_ref reads the transposed layouts in the same k order, so it can't change either
    MMT f_ref, da, db_, dc, 0, 0
    MMT f_ref, dat, dbt, dd_, 0, MM_TA | MM_TB
    mov rcx, [dc]
    mov rdx, [dd_]
    mov r8d, GM * GN * 4
    call same
    check e, "mm_ref, transposed layouts: same bits"

    ; C = R + A B^T, against mm_ref doing the same
    MMT f_ref, da, db_, dd_, [dr], 0
    MMT f_tc, da, db_, dc, [dr], 0
    mov rcx, [hc]
    mov rdx, [dc]
    mov r8d, GM * GN * 4
    call gpu_down
    mov rcx, [hd]
    mov rdx, [dd_]
    mov r8d, GM * GN * 4
    call gpu_down
    mov ecx, GM * GN
    call relerr
    movsd [rsp+48], xmm0
    comisd xmm0, [c_tol]
    setb cl
    movzx ecx, cl
    lea rdx, [m_r]
    movsd xmm2, [rsp+48]
    call t_okf
    ; in place: dd = R, then dd += A B^T. same as with R separate
    mov rcx, [dd_]
    mov rdx, [hr]
    mov r8d, GM * GN * 4
    call gpu_up
    MMT f_tc, da, db_, dd_, [dd_], 0
    mov rcx, [dc]
    mov rdx, [dd_]
    mov r8d, GM * GN * 4
    call same
    check e, "gemm_tc accumulating in place (R = C): same bits as R separate"

    ; bf16 out = the f32 result rounded
    MMT f_tc, da, db_, dc, 0, 0
    MMT f_tc, da, db_, dd_, 0, MM_BF
    mov rcx, [hc]
    mov rdx, [dc]
    mov r8d, GM * GN * 4
    call gpu_down
    mov rcx, [hd]
    mov rdx, [dd_]
    mov r8d, GM * GN * 2
    call gpu_down
    mov rsi, [hc]
    mov rdi, [hd]
    xor ecx, ecx
    xor ebx, ebx                ; mismatches
.bf:
    mov r8d, [rsi+rcx*4]
    call bf16
    cmp r8w, [rdi+rcx*2]
    je .bfok
    inc ebx
.bfok:
    inc ecx
    cmp ecx, GM * GN
    jb .bf
    test ebx, ebx
    check z, "gemm_tc bf16 out = its f32 out rounded, bit for bit"
    add rsp, 56
    pop rsi
    pop rbx
    ret

section .rdata
m_nt db "gemm_tc 640x384x2048 matches mm_ref", 0
m_r  db "gemm_tc with R (C = R + A B^T) matches mm_ref", 0
