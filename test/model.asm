; stage 5 test: the fast kernels against the naive ones.
;  - gemm_tc in every layout the model uses, against mm_ref. a transposed operand
;    has to give exactly the same bits as the plain one: same values, same
;    fragments, same order of adds
;  - flash attention forward and backward against the naive attention kernels
;  - a whole small model, fast path against naive path, and the fast path twice
; uses: gpu\cuda gpu\kernels model\model
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"
%include "model/model.inc"
%include "test/check.inc"

extern ptx_gemm, ptx_gemm_end, ptx_attn, ptx_attn_end, ptx_ops, ptx_ops_end

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
dpart   resq 1
f_split resq 1

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
    call t_attn
    call t_whole
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

    ; split k: 4 slices of the k tiles into partials, splitsum adds them and R
    lea rcx, [ptx_ops]
    lea rdx, [ptx_ops_end]
    sub rdx, rcx
    call gpu_module
    mov rcx, rax
    lea rdx, [kn_split]
    call gpu_func
    mov [f_split], rax
    mov ecx, 4 * GM * GN * 4
    call gpu_alloc
    mov [dpart], rax
    lea rbx, [kl]
    mov rax, [f_tc]
    mov [rbx+KL_FUNC], rax
    mov rax, [dat]
    mov [rbx+KL_ARGS], rax
    mov rax, [dbt]
    mov [rbx+KL_ARGS+8], rax
    mov rax, [dpart]
    mov [rbx+KL_ARGS+16], rax
    mov qword [rbx+KL_ARGS+24], GM
    mov qword [rbx+KL_ARGS+32], GN
    mov qword [rbx+KL_ARGS+40], GK
    mov qword [rbx+KL_ARGS+48], 0
    mov qword [rbx+KL_ARGS+56], MM_TA | MM_TB
    grid GN / 128, GM / 128, 256, 1
    mov dword [rbx+KL_GZ], 4
    mov rcx, rbx
    call gpu_launch
    mov rax, [f_split]
    mov [rbx+KL_FUNC], rax
    mov rax, [dc]
    mov [rbx+KL_ARGS], rax
    mov rax, [dr]
    mov [rbx+KL_ARGS+8], rax
    mov rax, [dpart]
    mov [rbx+KL_ARGS+16], rax
    mov qword [rbx+KL_ARGS+24], GM * GN
    mov qword [rbx+KL_ARGS+32], 4
    grid GM * GN / 256, 1, 256, 1
    mov rcx, rbx
    call gpu_launch
    call gpu_sync
    MMT f_ref, da, db_, dd_, [dr], 0
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
    lea rdx, [m_split]
    movsd xmm2, [rsp+48]
    call t_okf
    add rsp, 56
    pop rsi
    pop rbx
    ret

section .rdata
m_nt db "gemm_tc 640x384x2048 matches mm_ref", 0
m_r  db "gemm_tc with R (C = R + A B^T) matches mm_ref", 0
m_split db "gemm_tc split k in 4 (dW layout) + splitsum with R matches mm_ref", 0
kn_split db "splitsum", 0

; ---- flash attention against the naive kernels, same bf16 q, k, v and dy
XB  equ 2
XT  equ 256
XH  equ 6
XKV equ 2
XQD equ XH * 64
XKD equ XKV * 64
XQKV equ XQD + 2 * XKD
XM  equ XB * XT

section .rdata
kn_dot  db "att_dot", 0
kn_sm   db "att_softmax", 0
kn_mix  db "att_mix", 0
kn_ds   db "att_ds", 0
kn_dkv  db "att_dkv", 0
kn_ffwd db "flash_fwd", 0
kn_d    db "attn_d", 0
kn_fdq  db "flash_dq", 0
kn_fdkv db "flash_dkv", 0
align 8
c_ascale dd 0.125               ; 1/sqrt(64)
c_one32  dd 1.0
c_atol   dq 2e-2
c_ltol   dq 1e-3

section .bss
alignb 8
f_dot   resq 1
f_sm    resq 1
f_mix   resq 1
f_ds    resq 1
f_dkv   resq 1
f_ffwd  resq 1
f_d     resq 1
f_fdq   resq 1
f_fdkv  resq 1
aqkv    resq 1                  ; device
ady     resq 1
ay1     resq 1                  ; naive
ay2     resq 1                  ; flash
alse1   resq 1
alse2   resq 1
as1     resq 1
as2     resq 1
adq1    resq 1
adq2    resq 1
aD      resq 1
hx      resq 1                  ; host scratch
hy      resq 1

section .text

%macro getk 2
    mov rcx, rbx
    lea rdx, [%1]
    call gpu_func
    mov [%2], rax
%endmacro

; launch kl as it is: ecx, edx, r8d = grid, r9d = block x
agrid:
    sub rsp, 40
    lea rax, [kl]
    mov [rax+KL_GX], ecx
    mov [rax+KL_GY], edx
    mov [rax+KL_GZ], r8d
    mov [rax+KL_BX], r9d
    mov dword [rax+KL_BY], 1
    mov dword [rax+KL_BZ], 1
    lea rcx, [kl]
    call gpu_launch
    call gpu_sync
    add rsp, 40
    ret

%macro ka 2
    mov rax, %2
    mov [kl+KL_ARGS+%1*8], rax
%endmacro
%macro kf 2
    mov eax, [%2]
    mov [kl+KL_ARGS+%1*8], rax
%endmacro
%macro kfn 1
    mov rax, [%1]
    mov [kl+KL_FUNC], rax
%endmacro

; B, T, H, KVH, hd, bf for the naive kernels, slots 3-8
nargs:
    ka 3, XB
    ka 4, XT
    ka 5, XH
    ka 6, XKV
    ka 7, 64
    ka 8, 1
    ret

; rcx = device bf16 a, rdx = device bf16 b, r8d = count. xmm0 = max |a - b| / max |b|
bferr:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov ebx, r8d
    mov rcx, [hx]
    mov rdx, rsi
    lea r8, [rbx*2]
    call gpu_down
    mov rcx, [hy]
    mov rdx, rdi
    lea r8, [rbx*2]
    call gpu_down
    mov r8, [hx]
    mov r9, [hy]
    vxorps xmm2, xmm2, xmm2
    vxorps xmm3, xmm3, xmm3
    mov eax, 0x7fffffff
    vmovd xmm5, eax
    xor ecx, ecx
.c:
    movzx eax, word [r8+rcx*2]
    shl eax, 16
    vmovd xmm0, eax
    movzx eax, word [r9+rcx*2]
    shl eax, 16
    vmovd xmm1, eax
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
    vdivsd xmm0, xmm2, xmm3
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; the same over some columns of the dqkv rows (XQKV bf16 each): rcx = a, rdx = b,
; r8d = first column, r9d = columns
secerr:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov r12d, r8d
    mov r13d, r9d
    mov rcx, [hx]
    mov rdx, rsi
    mov r8d, XM * XQKV * 2
    call gpu_down
    mov rcx, [hy]
    mov rdx, rdi
    mov r8d, XM * XQKV * 2
    call gpu_down
    mov r8, [hx]
    mov r9, [hy]
    vxorps xmm2, xmm2, xmm2
    vxorps xmm3, xmm3, xmm3
    mov eax, 0x7fffffff
    vmovd xmm5, eax
    xor ebx, ebx                ; row
.r:
    xor ecx, ecx
.c:
    mov eax, ebx
    imul eax, XQKV
    add eax, r12d
    add eax, ecx
    movzx r10d, word [r8+rax*2]
    shl r10d, 16
    vmovd xmm0, r10d
    movzx r10d, word [r9+rax*2]
    shl r10d, 16
    vmovd xmm1, r10d
    vsubss xmm0, xmm0, xmm1
    vandps xmm0, xmm0, xmm5
    vandps xmm1, xmm1, xmm5
    vmaxss xmm2, xmm2, xmm0
    vmaxss xmm3, xmm3, xmm1
    inc ecx
    cmp ecx, r13d
    jb .c
    inc ebx
    cmp ebx, XM
    jb .r
    vcvtss2sd xmm2, xmm2, xmm2
    vcvtss2sd xmm3, xmm3, xmm3
    vdivsd xmm0, xmm2, xmm3
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; xmm0 = the error, rdx = name, %1 = the bar
%macro aok 1
    movsd [rsp+32], xmm0
    comisd xmm0, [%1]
    setb cl
    movzx ecx, cl
    movsd xmm2, [rsp+32]
    call t_okf
%endmacro

; ecx = threads, launched in blocks of 256
%macro run1d 1
    mov ecx, (%1 + 255) / 256
    mov edx, 1
    mov r8d, 1
    mov r9d, 256
    call agrid
%endmacro

t_attn:
    push rbx
    push rsi
    sub rsp, 56
    say "attention, B 2 x T 256, 6 query heads over 2 kv heads", 13, 10
    lea rcx, [ptx_attn]
    lea rdx, [ptx_attn_end]
    sub rdx, rcx
    call gpu_module
    mov rbx, rax
    getk kn_dot, f_dot
    getk kn_sm, f_sm
    getk kn_mix, f_mix
    getk kn_ds, f_ds
    getk kn_dkv, f_dkv
    getk kn_ffwd, f_ffwd
    getk kn_d, f_d
    getk kn_fdq, f_fdq
    getk kn_fdkv, f_fdkv

    mov ecx, XM * XQKV * 4
    call mem_alloc
    mov [hx], rax
    mov ecx, XM * XQKV * 4
    call mem_alloc
    mov [hy], rax
%macro dal 2
    mov ecx, %2
    call gpu_alloc
    mov [%1], rax
%endmacro
    dal aqkv, XM * XQKV * 2
    dal ady, XM * XQD * 2
    dal ay1, XM * XQD * 2
    dal ay2, XM * XQD * 2
    dal alse1, XM * XH * 4
    dal alse2, XM * XH * 4
    dal as1, XB * XH * XT * XT * 4
    dal as2, XB * XH * XT * XT * 4
    dal adq1, XM * XQKV * 2
    dal adq2, XM * XQKV * 2
    dal aD, XM * XH * 4

    ; q, k, v in [-2, 2): random bf16 in [-1, 1) with the exponent bumped by one
    mov rcx, [hx]
    mov edx, XM * XQKV
    call rand_bf16
    mov rsi, [hx]
    xor ecx, ecx
.dbl:
    test word [rsi+rcx*2], 0x7fff
    jz .zero
    add word [rsi+rcx*2], 0x0080
.zero:
    inc ecx
    cmp ecx, XM * XQKV
    jb .dbl
    mov rcx, [aqkv]
    mov rdx, [hx]
    mov r8d, XM * XQKV * 2
    call gpu_up
    mov rcx, [hx]
    mov edx, XM * XQD
    call rand_bf16
    mov rcx, [ady]
    mov rdx, [hx]
    mov r8d, XM * XQD * 2
    call gpu_up

    ; naive forward
    kfn f_dot
    ka 0, [aqkv]
    ka 1, [aqkv]
    ka 2, [as1]
    call nargs
    kf 9, c_ascale
    ka 10, 0
    run1d XB * XH * XT * XT
    kfn f_sm
    ka 0, [as1]
    ka 1, [alse1]
    ka 2, XB * XH * XT
    ka 3, XT
    ka 4, 0
    run1d XB * XH * XT
    kfn f_mix
    ka 0, [as1]
    ka 1, [aqkv]
    ka 2, [ay1]
    call nargs
    kf 9, c_one32
    ka 10, 0
    run1d XM * XQD
    ; flash forward
    kfn f_ffwd
    ka 0, [aqkv]
    ka 1, [ay2]
    ka 2, [alse2]
    ka 3, XT
    ka 4, XH
    ka 5, XKV
    kf 6, c_ascale
    mov ecx, XT / 64
    mov edx, XH
    mov r8d, XB
    mov r9d, 128
    call agrid

    mov rcx, [ay2]
    mov rdx, [ay1]
    mov r8d, XM * XQD
    call bferr
    lea rdx, [m_ay]
    aok c_atol
    mov rcx, [hc]
    mov rdx, [alse2]
    mov r8d, XM * XH * 4
    call gpu_down
    mov rcx, [hd]
    mov rdx, [alse1]
    mov r8d, XM * XH * 4
    call gpu_down
    mov ecx, XM * XH
    call relerr
    lea rdx, [m_alse]
    aok c_ltol

    ; naive backward: P again, dP, dS, dq, dk, dv
    kfn f_dot
    ka 0, [aqkv]
    ka 1, [aqkv]
    ka 2, [as1]
    call nargs
    kf 9, c_ascale
    ka 10, 0
    run1d XB * XH * XT * XT
    kfn f_sm
    ka 0, [as1]
    ka 1, [alse1]
    ka 2, XB * XH * XT
    ka 3, XT
    ka 4, 1
    run1d XB * XH * XT
    kfn f_dot
    ka 0, [ady]
    ka 1, [aqkv]
    ka 2, [as2]
    call nargs
    kf 9, c_one32
    ka 10, 1
    run1d XB * XH * XT * XT
    kfn f_ds
    ka 0, [as1]
    ka 1, [as2]
    ka 2, XB * XH * XT
    ka 3, XT
    run1d XB * XH * XT
    kfn f_mix
    ka 0, [as2]
    ka 1, [aqkv]
    ka 2, [adq1]
    call nargs
    kf 9, c_ascale
    ka 10, 1
    run1d XM * XQD
    kfn f_dkv
    ka 0, [as1]
    ka 1, [as2]
    ka 2, [aqkv]
    ka 3, [ady]
    ka 4, [adq1]
    ka 5, XB
    ka 6, XT
    ka 7, XH
    ka 8, XKV
    ka 9, 64
    ka 10, 1
    kf 11, c_ascale
    run1d XM * XKD

    ; flash backward
    kfn f_d
    ka 0, [ady]
    ka 1, [ay2]
    ka 2, [aD]
    ka 3, XM
    ka 4, XT
    ka 5, XH
    run1d XM * XH
    kfn f_fdq
    ka 0, [aqkv]
    ka 1, [ady]
    ka 2, [alse2]
    ka 3, [aD]
    ka 4, [adq2]
    ka 5, XT
    ka 6, XH
    ka 7, XKV
    kf 8, c_ascale
    mov ecx, XT / 64
    mov edx, XH
    mov r8d, XB
    mov r9d, 128
    call agrid
    kfn f_fdkv
    mov ecx, XT / 64
    mov edx, XKV
    mov r8d, XB
    mov r9d, 128
    call agrid

    mov rcx, [adq2]
    mov rdx, [adq1]
    xor r8d, r8d
    mov r9d, XQD
    call secerr
    lea rdx, [m_adq]
    aok c_atol
    mov rcx, [adq2]
    mov rdx, [adq1]
    mov r8d, XQD
    mov r9d, XKD
    call secerr
    lea rdx, [m_adk]
    aok c_atol
    mov rcx, [adq2]
    mov rdx, [adq1]
    mov r8d, XQD + XKD
    mov r9d, XKD
    call secerr
    lea rdx, [m_adv]
    aok c_atol
    add rsp, 56
    pop rsi
    pop rbx
    ret

section .rdata
m_ay   db "flash_fwd y matches the naive attention (max err / max)", 0
m_alse db "flash_fwd lse matches", 0
m_adq  db "flash_dq matches the naive backward", 0
m_adk  db "flash_dkv dk matches", 0
m_adv  db "flash_dkv dv matches", 0

; ---- the whole model: fast path against the naive one, both on bf16 activations.
; same weights, same tokens. then the fast path twice: same bits (no atomics anywhere)
WB equ 2
WT equ 128
WM equ WB * WT

section .rdata
align 8
c_wgtol dq 2e-2
c_wg8   dq 0.15
m_wg    db "fast gradients vs naive, |g_fast - g_naive| / |g_naive|", 0
m_wg8   db "fp8 gradients vs bf16, |g_fp8 - g_bf16| / |g_bf16|", 0

section .bss
alignb 8
wmb     resb MB_SIZE
wtok    resq 1
wsort   resq 1
wg1     resq 1
wg2     resq 1
wloss   resq 1

section .text

; rcx = host buffer: forward + backward with whatever mdl_fast says, the gradient
; lands there, xmm0 = mean loss
wrun:
    push rbx
    sub rsp, 32
    mov rbx, rcx
    call model_zero
    lea rcx, [wmb]
    mov edx, FW_GRAD
    call model_fwd
    lea rcx, [wmb]
    call model_bwd
    mov rcx, rbx
    mov rdx, [d_grad]
    mov r8, [mdl+MD_NP]
    shl r8, 2
    call gpu_down
    call model_loss
    mov eax, WM
    cvtsi2sd xmm1, eax
    divsd xmm0, xmm1
    add rsp, 32
    pop rbx
    ret

t_whole:
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    say "whole model, 2 layers, d 128, T 128, vocab 512", 13, 10
    mov qword [mdl+MD_L], 2
    mov qword [mdl+MD_D], 128
    mov qword [mdl+MD_H], 2
    mov qword [mdl+MD_KVH], 1
    mov qword [mdl+MD_F], 384
    mov qword [mdl+MD_V], 512
    mov qword [mdl+MD_T], WT
    mov qword [mdl+MD_B], WB
    mov qword [mdl+MD_NAIVE], 1
    mov rax, __?float64?__(10000.0)
    mov [mdl+MD_ROPE], rax
    mov dword [mdl_fast], 1         ; so setup checks the shapes
    mov dword [mdl_fp8], 1          ; loads and sets up the fp8 side too, used at the end
    mov ecx, 2
    call model_setup
    mov ecx, 11
    call model_init
    mov dword [mdl_fp8], 0

    mov ecx, 65536
    call mem_alloc
    mov [wtok], rax
    mov ecx, 65536
    call mem_alloc
    mov [wsort], rax
    xor ebx, ebx
.tok:
    lea rcx, [rng]
    call rng_next
    and eax, 511
    mov rdx, [wtok]
    mov [rdx+rbx*2], ax
    inc ebx
    cmp ebx, WB * (WT + 1)
    jb .tok
    mov rcx, [wtok]
    mov edx, WB
    mov r8d, WT
    mov r9, [wsort]
    call model_sort
    mov [wmb+MB_NU], rax
    mov ecx, 65536
    call gpu_alloc
    mov [wmb+MB_TOK], rax
    mov rcx, rax
    mov rdx, [wtok]
    mov r8d, 65536
    call gpu_up
    mov ecx, 65536
    call gpu_alloc
    mov [wmb+MB_POS], rax
    lea rcx, [rax+WM*4]
    mov [wmb+MB_UTOK], rcx
    lea rcx, [rax+WM*8]
    mov [wmb+MB_UST], rcx
    mov rcx, rax
    mov rdx, [wsort]
    mov r8d, 65536
    call gpu_up
    mov qword [wmb+MB_B], WB
    mov qword [wmb+MB_T], WT
    mov eax, __?float32?__(0.00390625)      ; 1/256
    mov [wmb+MB_SCALE], eax

    mov rcx, [mdl+MD_NP]
    shl rcx, 2
    call mem_alloc
    mov [wg1], rax
    mov rcx, [mdl+MD_NP]
    shl rcx, 2
    call mem_alloc
    mov [wg2], rax

    mov dword [mdl_fast], 0
    mov rcx, [wg1]
    call wrun
    movsd [wloss], xmm0
    mov dword [mdl_fast], 1
    mov rcx, [wg2]
    call wrun
    movsd [rsp+40], xmm0
    say "  loss naive "
    movsd xmm0, [wloss]
    mov edx, 5
    call print_fixed
    say ", fast "
    movsd xmm0, [rsp+40]
    mov edx, 5
    call print_fixed
    say 13, 10
    movsd xmm0, [rsp+40]
    subsd xmm0, [wloss]
    close_to 0.0, 2e-3, "fast loss = naive loss (abs diff)"

    ; |g_fast - g_naive| / |g_naive| over every parameter
    mov rsi, [wg1]
    mov rdi, [wg2]
    xorpd xmm2, xmm2
    xorpd xmm3, xmm3
    xor ecx, ecx
.g:
    cvtss2sd xmm0, [rsi+rcx*4]
    cvtss2sd xmm1, [rdi+rcx*4]
    subsd xmm1, xmm0
    mulsd xmm1, xmm1
    addsd xmm2, xmm1
    mulsd xmm0, xmm0
    addsd xmm3, xmm0
    inc rcx
    cmp rcx, [mdl+MD_NP]
    jb .g
    divsd xmm2, xmm3
    sqrtsd xmm0, xmm2
    movsd [rsp+40], xmm0
    comisd xmm0, [c_wgtol]
    setb cl
    movzx ecx, cl
    lea rdx, [m_wg]
    movsd xmm2, [rsp+40]
    call t_okf

    ; and the fast path again: not a bit different
    mov rcx, [wg1]
    call wrun
    mov rsi, [wg1]
    mov rdi, [wg2]
    mov rcx, [mdl+MD_NP]
    shl rcx, 2
    repe cmpsb
    check e, "fast path twice: the same gradients, bit for bit"

    ; weight gradients on a second stream beside the dx chain: only the order on
    ; the gpu changes, so it has to be the same bits. a few times, a race would
    ; show up as a difference sooner or later
    mov dword [mdl_streams], 2
    mov ebx, 3
.two:
    mov rcx, [wg1]
    call wrun
    mov rsi, [wg1]
    mov rdi, [wg2]
    mov rcx, [mdl+MD_NP]
    shl rcx, 2
    repe cmpsb
    jne .twodone
    dec ebx
    jnz .two
.twodone:
    check e, "two streams, 3 runs: the same gradients, bit for bit"
    mov dword [mdl_streams], 1

    ; mxfp8: the layers' matmuls in fp8. close to bf16 (wg2 still has its gradients)
    ; but not equal, and still the same bits every time, on either stream setup
    mov dword [mdl_fp8], 1
    mov rcx, [wg1]
    call wrun
    movsd [rsp+32], xmm0
    say "  loss fp8 "
    movsd xmm0, [rsp+32]
    mov edx, 5
    call print_fixed
    say 13, 10
    movsd xmm0, [rsp+32]
    subsd xmm0, [wloss]
    close_to 0.0, 2e-2, "fp8 loss = naive loss (abs diff)"
    mov rsi, [wg2]
    mov rdi, [wg1]
    xorpd xmm2, xmm2
    xorpd xmm3, xmm3
    xor ecx, ecx
.g8:
    cvtss2sd xmm0, [rsi+rcx*4]
    cvtss2sd xmm1, [rdi+rcx*4]
    subsd xmm1, xmm0
    mulsd xmm1, xmm1
    addsd xmm2, xmm1
    mulsd xmm0, xmm0
    addsd xmm3, xmm0
    inc rcx
    cmp rcx, [mdl+MD_NP]
    jb .g8
    divsd xmm2, xmm3
    sqrtsd xmm0, xmm2
    movsd [rsp+40], xmm0
    comisd xmm0, [c_wg8]
    setb cl
    movzx ecx, cl
    lea rdx, [m_wg8]
    movsd xmm2, [rsp+40]
    call t_okf
    mov rcx, [wg2]
    call wrun
    mov rsi, [wg1]
    mov rdi, [wg2]
    mov rcx, [mdl+MD_NP]
    shl rcx, 2
    repe cmpsb
    check e, "fp8 twice: the same gradients, bit for bit"
    mov dword [mdl_streams], 2
    mov ebx, 3
.two8:
    mov rcx, [wg2]
    call wrun
    mov rsi, [wg1]
    mov rdi, [wg2]
    mov rcx, [mdl+MD_NP]
    shl rcx, 2
    repe cmpsb
    jne .two8done
    dec ebx
    jnz .two8
.two8done:
    check e, "fp8 on two streams, 3 runs: the same gradients, bit for bit"
    mov dword [mdl_streams], 1
    mov dword [mdl_fp8], 0
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret
