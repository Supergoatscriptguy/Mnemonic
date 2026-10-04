; the transformer on the gpu: config, parameter layout, buffers, init, and the
; forward and backward passes as a string of kernel launches. the matmuls and
; attention go to the naive kernels or the fast ones depending on mdl_fast
; uses: gpu\cuda gpu\kernels
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"
%include "model/model.inc"

extern ptx_basic, ptx_basic_end, ptx_gemm, ptx_gemm_end, ptx_ops, ptx_ops_end
extern ptx_attn, ptx_attn_end, ptx_mx, ptx_mx_end

NCH     equ 64                  ; row chunks for the rmsnorm weight gradient
NSQ     equ 256                 ; blocks for the gradient norm

; model_init's work, per tensor
IC_PTR  equ 0
IC_STD  equ 8
IC_SEED equ 16


section .rdata
kn_embed   db "embed", 0
kn_embedb  db "embed_bwd", 0
kn_rms     db "rmsnorm", 0
kn_rmsb    db "rmsnorm_bwd", 0
kn_rmsdw   db "rms_dw", 0
kn_colsum  db "colsum", 0
kn_rope    db "rope", 0
kn_swi     db "swiglu", 0
kn_swib    db "swiglu_bwd", 0
kn_xent    db "xent", 0
kn_adamw   db "adamw", 0
kn_sumsq   db "sumsq", 0
kn_split   db "splitsum", 0
kn_attdot  db "att_dot", 0
kn_attsm   db "att_softmax", 0
kn_attmix  db "att_mix", 0
kn_attds   db "att_ds", 0
kn_attdkv  db "att_dkv", 0
kn_ffwd    db "flash_fwd", 0
kn_attnd   db "attn_d", 0
kn_fdq     db "flash_dq", 0
kn_fdkv    db "flash_dkv", 0
kn_mmref   db "mm_ref", 0
kn_gemmtc  db "gemm_tc", 0
kn_f2bf    db "f2bf", 0
kn_mxq     db "mxq", 0
kn_mxqt    db "mxqt", 0
kn_gmx     db "gemm_mx", 0

ck_layer   db "n_layer", 0
ck_d       db "d_model", 0
ck_head    db "n_head", 0
ck_kvh     db "n_kv_head", 0
ck_ffn     db "ffn", 0
ck_vocab   db "vocab", 0
ck_ctx     db "ctx", 0
ck_micro   db "micro", 0
ck_rope    db "rope_base", 0
ck_streams db "streams", 0
ck_fp8     db "fp8", 0
e_heads    db "n_head has to be a multiple of n_kv_head, and d_model of n_head", 0
e_fp8      db "fp8=1 needs the fast kernels", 0
e_fast     db "the fast kernels need head dim 64, ctx a multiple of 64, and d_model, ffn, vocab, heads*64 and micro*ctx multiples of 128", 0

align 8
c_rope     dq 10000.0
c_std      dq 0.02
c_one      dq 1.0
c_two      dq 2.0
c_three    dq 3.0
c_onef     dd 1.0

section .bss
alignb 8
global mdl, mdl_fast, mdl_streams, mdl_fp8, lp, d_params, d_bf, d_grad, d_adm, d_adv, d_logits, d_loss, d_gn
global k_f2bf, mm_ref_f, mm_tc_f
mdl        resb MD_SIZE
mdl_fast   resd 1
mdl_streams resd 1              ; 2 = weight gradients on a second stream in the backward
mdl_fp8    resd 1               ; 1 = the layers' matmuls in mxfp8 (MM_X8 ones)
mmbfx      resq 1               ; mmbf, mmbftb plus MM_X8
mmbftbx    resq 1
d_wq       resq 1               ; fp8 copies of the matrices, at their param offsets:
d_ws       resq 1               ;   as they are (and their scales, offset/32)
d_wqt      resq 1               ;   transposed
d_wst      resq 1
mxs0       resq 4               ; fp8 scratch for stream 0: A values, scales, B values, scales
mxs2       resq 4               ; and for s2
k_mxq      resq 1
k_mxqt     resq 1
k_gmx      resq 1
s2         resq 1               ; that stream
ev_fork    resq 1               ; stream 0 up to here, for s2 to wait on
ev_drest   resq 1               ; after the last s2 op that reads drest, dh, dxn, dqkv
ev_dh      resq 1
ev_dxn     resq 1
ev_dqkv    resq 1
ev_end     resq 1
mdl_bf     resd 1               ; 1 if activations are bf16
mmbf       resq 1               ; MM_BF, or 0 when activations are f32
mmbftb     resq 1               ; same plus MM_TB
lp         resq 1               ; host array of per-layer pointers (LP_*)
kl         resb KL_SIZE
cur_b      resq 1
cur_t      resq 1
cur_m      resq 1
scale      resd 1               ; 1/sqrt(hd)
cnt        resd 32768           ; model_sort's buckets
losshost   resq 1

d_params   resq 1               ; f32 master weights
d_bf       resq 1               ; bf16 copy for the matmuls
d_grad     resq 1
d_adm      resq 1               ; adam moments
d_adv      resq 1
d_act      resq 1               ; saved activations, L+1 blocks of ACTL
d_logits   resq 1
d_dlogits  resq 1
d_dres     resq 1               ; gradient of the residual stream, f32
d_drest    resq 1               ; ...and as T for the matmuls
d_dxn      resq 1
d_dy       resq 1
d_dqkv     resq 1
d_dh       resq 1
d_dg       resq 1
d_loss     resq 1               ; per row losses, summed over a step's micro-batches
d_parts    resq 1
d_sq       resq 1
d_gn       resq 1               ; squared gradient norm
d_split    resq 1               ; split-k partials
d_rope     resq 1
d_s1       resq 1               ; naive attention scratch, B*H*T*T f32 each
d_s2       resq 1
d_attd     resq 1               ; flash backward: dy . y per query and head
e_op       resq 1               ; the embedding as a matmul operand
vram       resq 1               ; bytes we allocated

; kernels
k_embed    resq 1
k_embedb   resq 1
k_rms      resq 1
k_rmsb     resq 1
k_rmsdw    resq 1
k_colsum   resq 1
k_rope     resq 1
k_swi      resq 1
k_swib     resq 1
k_xent     resq 1
k_adamw    resq 1
k_sumsq    resq 1
k_splitsum resq 1
k_attdot   resq 1
k_attsm    resq 1
k_attmix   resq 1
k_attds    resq 1
k_attdkv   resq 1
k_ffwd     resq 1
k_attnd    resq 1
k_fdq      resq 1
k_fdkv     resq 1
mm_ref_f   resq 1
mm_tc_f    resq 1
k_f2bf     resq 1

section .text

%macro KF 1
    mov rax, [%1]
    mov [kl+KL_FUNC], rax
%endmacro

; kernel argument n = anything mov rax can take (don't use rax in it)
%macro karg 2
    mov rax, %2
    mov [kl+KL_ARGS+%1*8], rax
%endmacro

; the same through rax, so rax itself can't be %2 either way
%macro kargf 2                  ; f32 from a dword in memory
    mov eax, %2
    mov [kl+KL_ARGS+%1*8], eax
%endmacro

; C = R + A B^T through whichever matmul is active: a, b, c, r, m, n, k, flags
%macro MM 8
    karg 0, %1
    karg 1, %2
    karg 2, %3
    karg 3, %5
    karg 4, %6
    karg 5, %7
    karg 6, %4
    karg 7, %8
    call mm_go
%endmacro

; ecx = threads, 256 per block, 1-D
lin:
    lea eax, [rcx+255]
    shr eax, 8
    mov edx, 1
    mov r8d, 256
    mov r9d, 1
    mov ecx, eax
    ; fall through
; ecx = grid x, edx = grid y, r8d = block x, r9d = block y
launch:
    mov [kl+KL_GX], ecx
    mov [kl+KL_GY], edx
    mov dword [kl+KL_GZ], 1
    mov [kl+KL_BX], r8d
    mov [kl+KL_BY], r9d
    mov dword [kl+KL_BZ], 1
    lea rcx, [kl]
    jmp gpu_launch

; one warp per row, 8 rows a block
rows8:
    lea ecx, [rcx+7]
    shr ecx, 3
    mov edx, 1
    mov r8d, 256
    mov r9d, 1
    jmp launch

; the matmul whose args are in kl
mm_go:
    sub rsp, 56                 ; C, R and the split count live at 32-48
    cmp dword [mdl_fast], 0
    jne .fast
    cmp qword [mdl+MD_ES], 4
    jne .ref
    or dword [kl+KL_ARGS+56], MM_F32
.ref:
    KF mm_ref_f
    mov ecx, [kl+KL_ARGS+32]    ; N
    add ecx, 15
    shr ecx, 4
    mov edx, [kl+KL_ARGS+24]    ; M
    add edx, 15
    shr edx, 4
    mov r8d, 16
    mov r9d, 16
    call launch
    add rsp, 56
    ret
.fast:
    test dword [kl+KL_ARGS+56], MM_X8
    jz .tc
    cmp dword [mdl_fp8], 0
    je .tc
    add rsp, 56
    jmp mx_mm
.tc:
    KF mm_tc_f
    mov ecx, [kl+KL_ARGS+32]
    shr ecx, 7
    mov edx, [kl+KL_ARGS+24]
    shr edx, 7
    ; a weight gradient (A transposed) with too few output tiles to fill the gpu
    ; twice over splits its k (the tokens) into up to 8 slices
    test dword [kl+KL_ARGS+56], MM_TA
    jz .one
    mov eax, ecx
    imul eax, edx               ; tiles
    mov r8d, [gpu_nsm]
    add r8d, r8d
    mov r9d, [kl+KL_ARGS+40]
    shr r9d, 5                  ; k tiles
    mov r10d, 1                 ; splits, a power of 2
.more:
    cmp r10d, 8
    jae .split
    mov r11d, eax
    imul r11d, r10d
    cmp r11d, r8d
    jae .split
    lea r11d, [r10d*2-1]
    test r9d, r11d              ; twice as many still has to divide the k tiles
    jnz .split
    add r10d, r10d
    jmp .more
.split:
    cmp r10d, 1
    je .one
    ; the partials go to d_split, then splitsum puts them together with R into C
    mov rax, [kl+KL_ARGS+16]
    mov [rsp+32], rax           ; C
    mov rax, [kl+KL_ARGS+48]
    mov [rsp+40], rax           ; R
    mov rax, [d_split]
    mov [kl+KL_ARGS+16], rax
    mov qword [kl+KL_ARGS+48], 0
    mov [rsp+48], r10
    mov [kl+KL_GX], ecx
    mov [kl+KL_GY], edx
    mov [kl+KL_GZ], r10d
    mov dword [kl+KL_BX], 256
    mov dword [kl+KL_BY], 1
    mov dword [kl+KL_BZ], 1
    lea rcx, [kl]
    call gpu_launch
    mov rcx, [kl+KL_ARGS+24]
    imul rcx, [kl+KL_ARGS+32]   ; M*N
    KF k_splitsum
    karg 0, [rsp+32]
    karg 1, [rsp+40]
    karg 2, [d_split]
    mov [kl+KL_ARGS+24], rcx
    karg 4, [rsp+48]
    cmp ecx, 1 << 20
    jbe .lin
    mov ecx, 1 << 20            ; it strides over the rest
.lin:
    call lin
    add rsp, 56
    ret
.one:
    mov r8d, 256
    mov r9d, 1
    call launch
    add rsp, 56
    ret

; the matmul in kl (gemm_tc's args: a b c m n k r flags) in mxfp8. A is an activation
; or a gradient and gets quantized here, along k. B is a weight, whose fp8 copies
; quantw keeps (transposed for MM_TB), or for a weight gradient an activation stored
; [K][N]. each stream quantizes into its own scratch
mx_mm:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov rsi, [kl+KL_ARGS]
    mov rdi, [kl+KL_ARGS+8]
    mov rax, [kl+KL_ARGS+16]
    mov [rsp+40], rax           ; C
    mov r12, [kl+KL_ARGS+24]    ; M
    mov r13, [kl+KL_ARGS+32]    ; N
    mov r14, [kl+KL_ARGS+40]    ; K
    mov rax, [kl+KL_ARGS+48]
    mov [rsp+48], rax           ; R
    mov r15, [kl+KL_ARGS+56]
    lea rbx, [mxs0]
    cmp qword [kl+KL_STREAM], 0
    je .a
    lea rbx, [mxs2]
.a:
    test r15d, MM_TA
    jnz .at
    mov rcx, rsi                ; [M][K]
    mov rdx, r12
    imul rdx, r14
    mov r8, [rbx]
    mov r9, [rbx+8]
    call qrows
    jmp .b
.at:
    mov rcx, rsi                ; stored [K][M]
    mov rdx, r14
    mov r8, r12
    mov r9, [rbx]
    mov rax, [rbx+8]
    mov [rsp+32], rax
    call qcols
.b:
    mov rax, rdi
    sub rax, [d_bf]
    jb .bact
    shr rax, 1                  ; its param offset
    cmp rax, [mdl+MD_NP]
    jae .bact
    mov rcx, rax
    shr rcx, 5
    test r15d, MM_TB
    jnz .bt
    mov rdi, [d_wq]
    add rdi, rax
    mov rsi, [d_ws]
    add rsi, rcx
    jmp .run
.bt:
    mov rdi, [d_wqt]
    add rdi, rax
    mov rsi, [d_wst]
    add rsi, rcx
    jmp .run
.bact:
    mov rcx, rdi                ; stored [K][N]
    mov rdx, r14
    mov r8, r13
    mov r9, [rbx+16]
    mov rax, [rbx+24]
    mov [rsp+32], rax
    call qcols
    mov rdi, [rbx+16]
    mov rsi, [rbx+24]
.run:
    KF k_gmx
    mov rax, [rbx]
    mov [kl+KL_ARGS], rax
    mov rax, [rbx+8]
    mov [kl+KL_ARGS+8], rax
    mov [kl+KL_ARGS+16], rdi
    mov [kl+KL_ARGS+24], rsi
    mov rax, [rsp+40]
    mov [kl+KL_ARGS+32], rax
    mov [kl+KL_ARGS+40], r12
    mov [kl+KL_ARGS+48], r13
    mov [kl+KL_ARGS+56], r14
    mov rax, [rsp+48]
    mov [kl+KL_ARGS+64], rax
    mov eax, r15d
    and eax, MM_BF
    mov [kl+KL_ARGS+72], rax
    mov ecx, r13d
    shr ecx, 7
    mov edx, r12d
    shr edx, 7
    ; a weight gradient with few output tiles splits its k, the way mm_go does it
    test r15d, MM_TA
    jz .one
    mov eax, ecx
    imul eax, edx               ; tiles
    mov r8d, [gpu_nsm]
    add r8d, r8d
    mov r9d, r14d
    shr r9d, 6                  ; k tiles
    mov r10d, 1
.more:
    cmp r10d, 8
    jae .split
    mov r11d, eax
    imul r11d, r10d
    cmp r11d, r8d
    jae .split
    lea r11d, [r10d*2-1]
    test r9d, r11d
    jnz .split
    add r10d, r10d
    jmp .more
.split:
    cmp r10d, 1
    je .one
    mov rax, [d_split]
    mov [kl+KL_ARGS+32], rax
    mov qword [kl+KL_ARGS+64], 0
    mov [rsp+56], r10
    mov [kl+KL_GX], ecx
    mov [kl+KL_GY], edx
    mov [kl+KL_GZ], r10d
    mov dword [kl+KL_BX], 256
    mov dword [kl+KL_BY], 1
    mov dword [kl+KL_BZ], 1
    lea rcx, [kl]
    call gpu_launch
    mov rcx, r12
    imul rcx, r13
    KF k_splitsum
    karg 0, [rsp+40]
    karg 1, [rsp+48]
    karg 2, [d_split]
    mov [kl+KL_ARGS+24], rcx
    karg 4, [rsp+56]
    cmp ecx, 1 << 20
    jbe .lin
    mov ecx, 1 << 20
.lin:
    call lin
    jmp .out
.one:
    mov r8d, 256
    mov r9d, 1
    call launch
.out:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = bf16 x, rdx = values, r8 = q, r9 = scales: mxq, blocks along the rows
qrows:
    sub rsp, 40
    KF k_mxq
    karg 0, rcx
    karg 1, r8
    karg 2, r9
    shr rdx, 5
    karg 3, rdx
    karg 4, 0
    mov rcx, rdx
    call lin
    add rsp, 40
    ret

; rcx = bf16 x [rows][cols], rdx = rows, r8 = cols, r9 = q, 5th = scales: mxqt,
; into [cols][rows] with blocks down the columns
qcols:
    sub rsp, 40
    KF k_mxqt
    karg 0, rcx
    karg 1, r9
    mov rax, [rsp+80]
    mov [kl+KL_ARGS+16], rax
    karg 3, rdx
    karg 4, r8
    karg 5, 0
    mov rcx, rdx
    shr rcx, 5
    imul rcx, r8
    call lin
    add rsp, 40
    ret

; the fp8 copies of every layer's matrices, from the f32 masters
quantw:
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, [lp]
    xor ebx, ebx
.l:
    cmp rbx, [mdl+MD_L]
    jae .done
    mov rcx, [rsi+LP_WQKV]
    mov rdx, [mdl+MD_QKV]
    mov r8, [mdl+MD_D]
    call quant1
    mov rcx, [rsi+LP_WO]
    mov rdx, [mdl+MD_D]
    mov r8, [mdl+MD_QD]
    call quant1
    mov rcx, [rsi+LP_W13]
    mov rdx, [mdl+MD_F]
    add rdx, rdx
    mov r8, [mdl+MD_D]
    call quant1
    mov rcx, [rsi+LP_W2]
    mov rdx, [mdl+MD_D]
    mov r8, [mdl+MD_F]
    call quant1
    add rsi, LP_SIZE
    inc rbx
    jmp .l
.done:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = a matrix's operand pointer (into d_bf), rdx = rows (N), r8 = cols (K).
; quantizes its f32 master as it is (for the forward) and transposed (for dx)
quant1:
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    sub rcx, [d_bf]
    shr rcx, 1
    mov rbx, rcx                ; param offset
    mov rsi, rdx
    mov rdi, r8
    KF k_mxq
    mov rax, [d_params]
    lea rax, [rax+rbx*4]
    mov [kl+KL_ARGS], rax
    mov rax, [d_wq]
    add rax, rbx
    mov [kl+KL_ARGS+8], rax
    mov rax, rbx
    shr rax, 5
    add rax, [d_ws]
    mov [kl+KL_ARGS+16], rax
    mov rcx, rsi
    imul rcx, rdi
    shr rcx, 5
    mov [kl+KL_ARGS+24], rcx
    mov qword [kl+KL_ARGS+32], 8    ; f32 in
    call lin
    KF k_mxqt
    mov rax, [d_params]
    lea rax, [rax+rbx*4]
    mov [kl+KL_ARGS], rax
    mov rax, [d_wqt]
    add rax, rbx
    mov [kl+KL_ARGS+8], rax
    mov rax, rbx
    shr rax, 5
    add rax, [d_wst]
    mov [kl+KL_ARGS+16], rax
    mov [kl+KL_ARGS+24], rsi
    mov [kl+KL_ARGS+32], rdi
    mov qword [kl+KL_ARGS+40], 8
    mov rcx, rsi
    shr rcx, 5
    imul rcx, rdi
    call lin
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret

; reads the model's shape from the config (cfg_load/cfg_args first)
%macro cfgi 3                   ; field, key, default
    lea rcx, [%2]
    mov edx, %3
    call cfg_int
    mov [mdl+%1], rax
%endmacro

global model_config
model_config:
    sub rsp, 40
    cfgi MD_L, ck_layer, 6
    cfgi MD_D, ck_d, 384
    cfgi MD_H, ck_head, 6
    cfgi MD_KVH, ck_kvh, 2
    cfgi MD_F, ck_ffn, 1024
    cfgi MD_V, ck_vocab, 32768
    cfgi MD_T, ck_ctx, 512
    cfgi MD_B, ck_micro, 32
    lea rcx, [ck_rope]
    movsd xmm1, [c_rope]
    call cfg_float
    movsd [mdl+MD_ROPE], xmm0
    lea rcx, [ck_streams]
    mov edx, 1
    call cfg_int
    mov [mdl_streams], eax
    lea rcx, [ck_fp8]
    xor edx, edx
    call cfg_int
    mov [mdl_fp8], eax
    add rsp, 40
    ret

; rcx = module ptx, rdx = its end, r8 = list of (name, slot) pairs ending in 0
getfuncs:
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, r8
    sub rdx, rcx
    call gpu_module
    mov rbx, rax
.f:
    mov rdx, [rsi]
    test rdx, rdx
    jz .done
    mov rcx, rbx
    call gpu_func
    mov rdx, [rsi+8]
    mov [rdx], rax
    add rsi, 16
    jmp .f
.done:
    add rsp, 40
    pop rsi
    pop rbx
    ret

section .rdata
align 8
fl_ops  dq kn_embed, k_embed, kn_embedb, k_embedb, kn_rms, k_rms, kn_rmsb, k_rmsb
        dq kn_rmsdw, k_rmsdw, kn_colsum, k_colsum, kn_rope, k_rope, kn_swi, k_swi
        dq kn_swib, k_swib, kn_xent, k_xent, kn_adamw, k_adamw, kn_sumsq, k_sumsq
        dq kn_split, k_splitsum, 0
fl_attn dq kn_attdot, k_attdot, kn_attsm, k_attsm, kn_attmix, k_attmix
        dq kn_attds, k_attds, kn_attdkv, k_attdkv
        dq kn_ffwd, k_ffwd, kn_attnd, k_attnd, kn_fdq, k_fdq, kn_fdkv, k_fdkv, 0
fl_gemm dq kn_mmref, mm_ref_f, kn_gemmtc, mm_tc_f, 0
fl_basic dq kn_f2bf, k_f2bf, 0
fl_mx   dq kn_mxq, k_mxq, kn_mxqt, k_mxqt, kn_gmx, k_gmx, 0
section .text

; rcx = bytes. device memory, counted in vram
dalloc:
    sub rsp, 40
    add [vram], rcx
    call gpu_alloc
    add rsp, 40
    ret

; round rax up to 256
%macro up256 0
    add rax, 255
    and rax, -256
%endmacro

; ecx = bytes per activation (2 = bf16, 4 = f32). works out every size from the
; config in mdl, loads the kernels and allocates everything on the gpu
global model_setup
model_setup:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov [mdl+MD_ES], rcx
    xor eax, eax
    cmp ecx, 2
    sete al
    mov [mdl_bf], eax
    shl eax, 2                  ; MM_BF
    mov [mmbf], rax
    or eax, MM_TB
    mov [mmbftb], rax
    or eax, MM_X8
    mov [mmbftbx], rax
    and eax, ~MM_TB
    mov [mmbfx], rax

    ; shapes
    mov rax, [mdl+MD_D]
    xor edx, edx
    div qword [mdl+MD_H]
    test rdx, rdx
    jnz .badheads
    mov [mdl+MD_HD], rax
    mov rax, [mdl+MD_H]
    xor edx, edx
    div qword [mdl+MD_KVH]
    test rdx, rdx
    jnz .badheads
    mov rax, [mdl+MD_H]
    imul rax, [mdl+MD_HD]
    mov [mdl+MD_QD], rax
    mov rcx, [mdl+MD_KVH]
    imul rcx, [mdl+MD_HD]
    mov [mdl+MD_KVD], rcx
    lea rax, [rax+rcx*2]
    mov [mdl+MD_QKV], rax
    mov rax, [mdl+MD_B]
    imul rax, [mdl+MD_T]
    mov [mdl+MD_M], rax
    cmp dword [mdl_fast], 0
    je .shapes
    ; the fast kernels work in whole tiles: 64 wide heads, 64 rows of attention,
    ; 128 x 128 matmul tiles, bf16 activations
    cmp qword [mdl+MD_HD], 64
    jne .badfast
    test qword [mdl+MD_T], 63
    jnz .badfast
    cmp qword [mdl+MD_ES], 2
    jne .badfast
    mov eax, 127
    test [mdl+MD_D], rax
    jnz .badfast
    test [mdl+MD_QD], rax
    jnz .badfast
    test [mdl+MD_QKV], rax
    jnz .badfast
    test [mdl+MD_F], rax
    jnz .badfast
    test [mdl+MD_V], rax
    jnz .badfast
    test [mdl+MD_M], rax
    jnz .badfast
.shapes:
    cvtsi2sd xmm0, qword [mdl+MD_HD]
    sqrtsd xmm0, xmm0
    movsd xmm1, [c_one]
    divsd xmm1, xmm0
    cvtsd2ss xmm1, xmm1
    movd [scale], xmm1

    ; parameters: E, then each layer's matrices, then all the norm weights
    mov rbx, [mdl+MD_D]
    mov rax, [mdl+MD_QKV]
    imul rax, rbx
    mov rcx, [mdl+MD_QD]
    imul rcx, rbx
    add rax, rcx
    mov rcx, [mdl+MD_F]
    imul rcx, rbx
    lea rax, [rax+rcx*2]
    add rax, rcx
    mov [mdl+MD_LSIZE], rax
    imul rax, [mdl+MD_L]
    mov rcx, [mdl+MD_V]
    imul rcx, rbx
    add rax, rcx
    mov [mdl+MD_NDEC], rax
    mov rcx, [mdl+MD_L]
    lea rcx, [rcx*2+1]
    imul rcx, rbx
    add rax, rcx
    mov [mdl+MD_NP], rax

    ; flops per token: 2 per weight in a matmul forward, attention at full context
    ; (2 T QD per layer with the causal half), and backward is twice the forward
    mov rax, [mdl+MD_LSIZE]
    imul rax, [mdl+MD_L]
    mov rcx, [mdl+MD_V]
    imul rcx, [mdl+MD_D]
    add rax, rcx
    mov rcx, [mdl+MD_T]
    imul rcx, [mdl+MD_QD]
    imul rcx, [mdl+MD_L]
    add rax, rcx
    cvtsi2sd xmm0, rax
    mulsd xmm0, [c_two]
    mulsd xmm0, [c_three]
    movsd [mdl+MD_FLOPS], xmm0

    ; kernels
    lea rcx, [ptx_ops]
    lea rdx, [ptx_ops_end]
    lea r8, [fl_ops]
    call getfuncs
    lea rcx, [ptx_attn]
    lea rdx, [ptx_attn_end]
    lea r8, [fl_attn]
    call getfuncs
    lea rcx, [ptx_gemm]
    lea rdx, [ptx_gemm_end]
    lea r8, [fl_gemm]
    call getfuncs
    lea rcx, [ptx_basic]
    lea rdx, [ptx_basic_end]
    lea r8, [fl_basic]
    call getfuncs
    cmp dword [mdl_fp8], 0
    je .nomx
    cmp dword [mdl_fast], 0
    jne .mx
    lea rcx, [e_fp8]
    call fatal
.mx:
    mov dword [gpu_arch], 1     ; block-scaled mma, sm_120a
    lea rcx, [ptx_mx]
    lea rdx, [ptx_mx_end]
    lea r8, [fl_mx]
    call getfuncs
    mov dword [gpu_arch], 0
.nomx:

    ; parameter buffers
    mov rbx, [mdl+MD_NP]
    lea rcx, [rbx*4]
    call dalloc
    mov [d_params], rax
    lea rcx, [rbx*2]
    call dalloc
    mov [d_bf], rax
    lea rcx, [rbx*4]
    call dalloc
    mov [d_grad], rax
    lea rcx, [rbx*4]
    call dalloc
    mov [d_adm], rax
    lea rcx, [rbx*4]
    call dalloc
    mov [d_adv], rax

    ; activations per layer: offsets into a block, r12 = M, r13 = es
    mov r12, [mdl+MD_M]
    mov r13, [mdl+MD_ES]
    xor r14d, r14d
%macro blk 1                    ; slot in offs, rax = bytes
    mov [offs+%1], r14
    up256
    add r14, rax
%endmacro
    mov rbx, r12
    imul rbx, [mdl+MD_D]        ; M*D
    mov rcx, rbx
    imul rcx, r13               ; M*D*es
    lea rax, [rbx*4]
    blk LP_X
    mov rax, rcx
    blk LP_XN1
    lea rax, [r12*4]
    blk LP_RS1
    mov rax, r12
    imul rax, [mdl+MD_QKV]
    imul rax, r13
    blk LP_QKV
    mov rax, r12
    imul rax, [mdl+MD_QD]
    imul rax, r13
    blk LP_Y
    mov rax, r12
    imul rax, [mdl+MD_H]
    shl rax, 2
    blk LP_LSE
    lea rax, [rbx*4]
    blk LP_X2
    mov rax, rcx
    blk LP_XN2
    lea rax, [r12*4]
    blk LP_RS2
    mov rax, r12
    imul rax, [mdl+MD_F]
    imul rax, r13
    mov rdx, rax
    shl rax, 1
    blk LP_H
    mov rax, rdx
    blk LP_G
    mov [mdl+MD_ACTL], r14
    mov rcx, [mdl+MD_L]
    inc rcx
    imul rcx, r14
    call dalloc
    mov [d_act], rax

    ; everything that's only needed one micro-batch at a time
    mov rcx, r12
    imul rcx, [mdl+MD_V]
    shl rcx, 2
    call dalloc
    mov [d_logits], rax
    mov rcx, r12
    imul rcx, [mdl+MD_V]
    imul rcx, r13
    call dalloc
    mov [d_dlogits], rax
    lea rcx, [rbx*4]
    call dalloc
    mov [d_dres], rax
    mov rcx, rbx
    imul rcx, r13
    call dalloc
    mov [d_drest], rax
    lea rcx, [rbx*4]
    call dalloc
    mov [d_dxn], rax
    mov rcx, r12
    imul rcx, [mdl+MD_QD]
    imul rcx, r13
    call dalloc
    mov [d_dy], rax
    mov rcx, r12
    imul rcx, [mdl+MD_QKV]
    imul rcx, r13
    call dalloc
    mov [d_dqkv], rax
    mov rcx, r12
    imul rcx, [mdl+MD_F]
    imul rcx, r13
    shl rcx, 1
    call dalloc
    mov [d_dh], rax
    mov rcx, r12
    imul rcx, [mdl+MD_F]
    imul rcx, r13
    call dalloc
    mov [d_dg], rax
    lea rcx, [r12*4]
    call dalloc
    mov [d_loss], rax
    mov rcx, [mdl+MD_D]
    imul rcx, NCH*4
    call dalloc
    mov [d_parts], rax
    mov ecx, NSQ*4
    call dalloc
    mov [d_sq], rax
    mov ecx, 256
    call dalloc
    mov [d_gn], rax
    mov rcx, r12
    imul rcx, [mdl+MD_H]
    shl rcx, 2
    call dalloc
    mov [d_attd], rax
    ; split k only happens under two waves of 128x128 tiles, 8 slices at most
    mov ecx, [gpu_nsm]
    imul ecx, 2 * 8 * 128 * 128 * 4
    call dalloc
    mov [d_split], rax
    mov rcx, [mdl+MD_T]
    imul rcx, [mdl+MD_HD]
    shl rcx, 2                  ; T * hd/2 * (cos, sin) f32
    call dalloc
    mov [d_rope], rax
    cmp qword [mdl+MD_NAIVE], 0
    je .nonaive
    mov rcx, r12
    imul rcx, [mdl+MD_H]
    imul rcx, [mdl+MD_T]
    shl rcx, 2
    mov r15, rcx
    call dalloc
    mov [d_s1], rax
    mov rcx, r15
    call dalloc
    mov [d_s2], rax
.nonaive:
    cmp dword [mdl_fp8], 0
    je .nomxbuf
    ; fp8 weights (a byte a param, a scale per 32), both ways round
    mov rcx, [mdl+MD_NP]
    call dalloc
    mov [d_wq], rax
    mov rcx, [mdl+MD_NP]
    call dalloc
    mov [d_wqt], rax
    mov rcx, [mdl+MD_NP]
    shr rcx, 5
    call dalloc
    mov [d_ws], rax
    mov rcx, [mdl+MD_NP]
    shr rcx, 5
    call dalloc
    mov [d_wst], rax
    ; scratch for quantized activations: M times the widest operand, per stream
    mov r15, [mdl+MD_D]
    mov rax, [mdl+MD_QD]
    cmp rax, r15
    cmova r15, rax
    mov rax, [mdl+MD_QKV]
    cmp rax, r15
    cmova r15, rax
    mov rax, [mdl+MD_F]
    add rax, rax
    cmp rax, r15
    cmova r15, rax
    imul r15, [mdl+MD_M]
    xor esi, esi
.mxb:
    mov rcx, r15
    test esi, 1
    jz .mxq
    shr rcx, 5
.mxq:
    call dalloc
    lea rdx, [mxs0]             ; mxs2 follows it
    mov [rdx+rsi*8], rax
    inc esi
    cmp esi, 8
    jb .mxb
.nomxbuf:

    ; pointer table, one entry per layer plus the final norm
    mov rcx, [mdl+MD_L]
    inc rcx
    imul rcx, LP_SIZE
    call mem_alloc
    mov [lp], rax
    mov rdi, rax
    mov rax, [mdl+MD_V]
    imul rax, [mdl+MD_D]
    mov r12, rax                ; matrix params so far
    mov rax, [mdl+MD_NDEC]
    mov r13, rax                ; norm params so far
    mov r14, [d_act]
    xor r15d, r15d              ; layer
.lp:
    ; activations
    mov rsi, LP_X
.act:
    lea rax, [offs]
    mov rax, [rax+rsi]
    add rax, r14
    mov [rdi+rsi], rax
    add rsi, 8
    cmp rsi, LP_G
    jbe .act
    add r14, [mdl+MD_ACTL]
    ; norm weights
    mov rax, [d_params]
    lea rax, [rax+r13*4]
    mov [rdi+LP_N1], rax
    mov rcx, [mdl+MD_D]
    lea rax, [rax+rcx*4]
    mov [rdi+LP_N2], rax
    mov rax, [d_grad]
    lea rax, [rax+r13*4]
    mov [rdi+LP_GN1], rax
    lea rax, [rax+rcx*4]
    mov [rdi+LP_GN2], rax
    add r13, rcx
    add r13, rcx
    cmp r15, [mdl+MD_L]
    je .lpdone
    ; matrices: qkv, o, gate+up, down
    mov rbx, [mdl+MD_D]
    mov rcx, r12
    mov rdx, LP_WQKV
    call wptr
    mov rax, [mdl+MD_QKV]
    imul rax, rbx
    add rcx, rax
    mov rdx, LP_WO
    call wptr
    mov rax, [mdl+MD_QD]
    imul rax, rbx
    add rcx, rax
    mov rdx, LP_W13
    call wptr
    mov rax, [mdl+MD_F]
    imul rax, rbx
    lea rcx, [rcx+rax*2]
    mov rdx, LP_W2
    call wptr
    add r12, [mdl+MD_LSIZE]
    add rdi, LP_SIZE
    inc r15
    jmp .lp
.lpdone:
    ; the embedding as a matmul operand
    mov rax, [d_params]
    cmp qword [mdl+MD_ES], 2
    jne .eop
    mov rax, [d_bf]
.eop:
    mov [e_op], rax

    ; the second stream (non-blocking, so it doesn't sync with stream 0 behind our
    ; back) and its events. cheap, so always, whether streams=2 or not
    lea rcx, [s2]
    mov edx, 1                  ; CU_STREAM_NON_BLOCKING
    CU cuStreamCreate
    lea rbx, [ev_fork]
.ev:
    mov rcx, rbx
    mov edx, 2                  ; CU_EVENT_DISABLE_TIMING
    CU cuEventCreate
    add rbx, 8
    lea rax, [ev_end]
    cmp rbx, rax
    jbe .ev

    call rope_table
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.badheads:
    lea rcx, [e_heads]
    call fatal
.badfast:
    lea rcx, [e_fast]
    call fatal

; rcx = param offset, rdx = LP slot, rdi = this layer's entry. the matmul operand
; (bf16 copy, or the f32 master for the f32 path) and the gradient. keeps rcx
wptr:
    mov rax, [d_bf]
    lea rax, [rax+rcx*2]
    cmp qword [mdl+MD_ES], 2
    je .op
    mov rax, [d_params]
    lea rax, [rax+rcx*4]
.op:
    mov [rdi+rdx], rax
    mov rax, [d_grad]
    lea rax, [rax+rcx*4]
    mov [rdi+rdx+LP_GQKV-LP_WQKV], rax
    ret

section .bss
offs    resq LP_SIZE / 8
section .text

; cos/sin table for rope: [t][i] = (cos, sin) of t * base^(-2i/hd), in f64 then f32
rope_table:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    mov rcx, [mdl+MD_T]
    imul rcx, [mdl+MD_HD]
    shl rcx, 2
    mov r12, rcx
    call mem_alloc
    mov rdi, rax
    xor ebx, ebx                ; t
.t:
    cmp rbx, [mdl+MD_T]
    jae .up
    xor esi, esi                ; i
.i:
    mov rax, [mdl+MD_HD]
    shr rax, 1
    cmp rsi, rax
    jae .tn
    movsd xmm0, [mdl+MD_ROPE]
    call math_log
    lea rax, [rsi*2]
    cvtsi2sd xmm1, rax
    cvtsi2sd xmm2, qword [mdl+MD_HD]
    divsd xmm1, xmm2
    mulsd xmm0, xmm1
    xorpd xmm1, xmm1
    subsd xmm1, xmm0
    movapd xmm0, xmm1
    call math_exp               ; base^(-2i/hd)
    cvtsi2sd xmm1, rbx
    mulsd xmm0, xmm1
    movsd [rsp+32], xmm0
    call math_cos
    cvtsd2ss xmm0, xmm0
    mov rax, rbx
    imul rax, [mdl+MD_HD]
    lea rax, [rax+rsi*2]        ; (t*hd/2 + i) * 2 floats
    movss [rdi+rax*4], xmm0
    mov [rsp+40], rax
    movsd xmm0, [rsp+32]
    call math_sin
    cvtsd2ss xmm0, xmm0
    mov rax, [rsp+40]
    movss [rdi+rax*4+4], xmm0
    inc rsi
    jmp .i
.tn:
    inc rbx
    jmp .t
.up:
    mov rcx, [d_rope]
    mov rdx, rdi
    mov r8, r12
    call gpu_up
    mov rcx, rdi
    call mem_free
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = ctx (IC_*), rdx = start, r8 = end. normal(0, std) per element, from a
; stream seeded by the element's index, so it doesn't matter who does which chunk
init_chunk:
    push rbx
    push rsi
    push rdi
    sub rsp, 64
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    lea rcx, [rsp+32]
    mov rdx, [rbx+IC_SEED]
    add rdx, rsi
    call rng_seed
.l:
    cmp rsi, rdi
    jae .done
    lea rcx, [rsp+32]
    call rng_normal
    mulsd xmm0, [rbx+IC_STD]
    cvtsd2ss xmm0, xmm0
    mov rax, [rbx+IC_PTR]
    movss [rax+rsi*4], xmm0
    inc rsi
    jmp .l
.done:
    add rsp, 64
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = host params, rdx = offset, r8 = count, xmm0 = std, r9 = seed
init_range:
    sub rsp, 72
    lea rax, [rcx+rdx*4]
    mov [rsp+32], rax
    movsd [rsp+40], xmm0
    mov rax, 0x9e3779b97f4a7c15
    imul rdx, rax
    add rdx, r9
    mov [rsp+48], rdx
    lea rcx, [init_chunk]
    lea rdx, [rsp+32]
    mov r9d, 65536
    call par_for
    add rsp, 72
    ret

; rcx = seed. fresh weights: normal(0, 0.02), the two projections into the
; residual stream scaled down by sqrt(2L), norms at 1. then onto the gpu
global model_init
model_init:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov r13, rcx
    mov rcx, [mdl+MD_NP]
    shl rcx, 2
    call mem_alloc
    mov rbx, rax
    cvtsi2sd xmm0, qword [mdl+MD_L]
    addsd xmm0, xmm0
    sqrtsd xmm0, xmm0
    movsd xmm1, [c_std]
    divsd xmm1, xmm0
    movsd [rsp+32], xmm1        ; residual std

    mov rcx, rbx
    xor edx, edx
    mov r8, [mdl+MD_V]
    imul r8, [mdl+MD_D]
    movsd xmm0, [c_std]
    mov r9, r13
    call init_range
    mov r12, [mdl+MD_V]
    imul r12, [mdl+MD_D]        ; offset
    xor esi, esi
.layer:
    cmp rsi, [mdl+MD_L]
    jae .norms
    mov rdi, [mdl+MD_QKV]
    imul rdi, [mdl+MD_D]
    mov rcx, rbx
    mov rdx, r12
    mov r8, rdi
    movsd xmm0, [c_std]
    mov r9, r13
    call init_range
    add r12, rdi
    mov rdi, [mdl+MD_QD]
    imul rdi, [mdl+MD_D]
    mov rcx, rbx
    mov rdx, r12
    mov r8, rdi
    movsd xmm0, [rsp+32]
    mov r9, r13
    call init_range
    add r12, rdi
    mov rdi, [mdl+MD_F]
    imul rdi, [mdl+MD_D]
    add rdi, rdi
    mov rcx, rbx
    mov rdx, r12
    mov r8, rdi
    movsd xmm0, [c_std]
    mov r9, r13
    call init_range
    add r12, rdi
    mov rdi, [mdl+MD_F]
    imul rdi, [mdl+MD_D]
    mov rcx, rbx
    mov rdx, r12
    mov r8, rdi
    movsd xmm0, [rsp+32]
    mov r9, r13
    call init_range
    add r12, rdi
    inc rsi
    jmp .layer
.norms:
    mov eax, [c_onef]
.one:
    cmp r12, [mdl+MD_NP]
    jae .up
    mov [rbx+r12*4], eax
    inc r12
    jmp .one
.up:
    mov rcx, [d_params]
    mov rdx, rbx
    mov r8, [mdl+MD_NP]
    shl r8, 2
    call gpu_up
    mov rcx, rbx
    call mem_free
    ; adam starts from zero
    mov rcx, [d_adm]
    xor edx, edx
    mov r8, [mdl+MD_NP]
    CU cuMemsetD32
    mov rcx, [d_adv]
    xor edx, edx
    mov r8, [mdl+MD_NP]
    CU cuMemsetD32
    call model_cast
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; bf16 copy of the master weights
global model_cast
model_cast:
    sub rsp, 40
    KF k_f2bf
    karg 0, [d_bf]
    karg 1, [d_params]
    karg 2, [mdl+MD_NP]
    mov ecx, 4096               ; grid-stride
    shl ecx, 8
    call lin
    cmp dword [mdl_fp8], 0
    je .done
    call quantw
.done:
    add rsp, 40
    ret

; gradients and the loss sums back to zero, before a step's first micro-batch
global model_zero
model_zero:
    sub rsp, 40
    mov rcx, [d_grad]
    xor edx, edx
    mov r8, [mdl+MD_NP]
    CU cuMemsetD32
    mov rcx, [d_loss]
    xor edx, edx
    mov r8, [mdl+MD_M]
    CU cuMemsetD32
    add rsp, 40
    ret

; rcx = rmsnorm's x, rdx = w, r8 = out, r9 = rstd
rmsnorm:
    sub rsp, 40
    KF k_rms
    karg 0, rcx
    karg 1, rdx
    karg 2, r8
    karg 3, r9
    karg 4, [cur_m]
    karg 5, [mdl+MD_D]
    mov eax, [mdl_bf]
    karg 6, rax
    mov rcx, [cur_m]
    call rows8
    add rsp, 40
    ret

; streams=2: in the backward the weight gradients (dW = dy^T x and the norm weights')
; go on a second stream, beside the chain that carries dx down the layers. they only
; read, and the scratch buffers they read (drest, dh, dxn, dqkv) get rewritten by
; stream 0 a bit later, so each read ends with an event, and stream 0 waits on it
; before it writes that buffer again. with streams=1 all of these do nothing and the
; launches are exactly what they always were.
;   fork: s2 waits for what stream 0 has queued so far (call it right after the producer)
;   on2: launches go to s2 from here    back: rcx = event to record on s2, then stream 0
;   waitfor: rcx = event, stream 0 waits on it    join: stream 0 waits for all of s2
fork:
    cmp dword [mdl_streams], 2
    jne .no
    sub rsp, 40
    mov rcx, [ev_fork]
    xor edx, edx
    CU cuEventRecord
    mov rcx, [s2]
    mov rdx, [ev_fork]
    xor r8d, r8d
    CU cuStreamWaitEvent
    add rsp, 40
.no:
    ret

on2:
    cmp dword [mdl_streams], 2
    jne .no
    mov rax, [s2]
    mov [kl+KL_STREAM], rax
.no:
    ret

back:
    cmp dword [mdl_streams], 2
    jne .no
    sub rsp, 40
    mov rcx, [rcx]
    mov rdx, [s2]
    CU cuEventRecord
    mov qword [kl+KL_STREAM], 0
    add rsp, 40
.no:
    ret

waitfor:
    cmp dword [mdl_streams], 2
    jne .no
    sub rsp, 40
    mov rdx, [rcx]
    xor ecx, ecx
    xor r8d, r8d
    CU cuStreamWaitEvent
    add rsp, 40
.no:
    ret

join:
    sub rsp, 40
    lea rcx, [ev_end]
    call back
    lea rcx, [ev_end]
    call waitfor
    add rsp, 40
    ret

; rcx = dy (dxn), rdx = x, r8 = rstd, r9 = w, [rsp+40] = the weight's gradient,
; [rsp+48] = add into dres (0 for the first one). updates dres and drest.
; with streams=2 the caller has forked already and made sure drest is free, and the
; weight gradient goes on s2
rmsnorm_bwd:
    push rbx
    sub rsp, 32
    mov rbx, rcx
    KF k_rmsb
    karg 0, rcx
    karg 1, rdx
    karg 2, r8
    karg 3, r9
    karg 4, [d_dres]
    karg 5, [d_drest]
    karg 6, [cur_m]
    karg 7, [mdl+MD_D]
    mov eax, [mdl_bf]
    karg 8, rax
    karg 9, [rsp+88]
    mov rcx, [cur_m]
    call rows8
    ; weight gradient: partial sums per row chunk, then add them up.
    ; dy, x, rstd are already in args 0-2
    call on2
    KF k_rmsdw
    karg 3, [d_parts]
    karg 4, [cur_m]
    karg 5, [mdl+MD_D]
    mov rcx, [mdl+MD_D]
    add ecx, 31
    shr ecx, 5
    mov edx, NCH
    mov r8d, 32
    mov r9d, 8
    call launch
    KF k_colsum
    karg 0, [d_parts]
    karg 1, [rsp+80]
    karg 2, [mdl+MD_D]
    karg 3, NCH
    mov rcx, [mdl+MD_D]
    call lin
    lea rcx, [ev_dxn]
    call back
    add rsp, 32
    pop rbx
    ret

; rcx = qkv (or dqkv), edx = 1 for the backward rotation
rope:
    sub rsp, 40
    mov [rsp+32], rdx
    KF k_rope
    karg 0, rcx
    karg 1, [d_rope]
    karg 2, [cur_m]
    karg 3, [cur_t]
    karg 4, [mdl+MD_HD]
    mov rax, [mdl+MD_H]
    add rax, [mdl+MD_KVH]
    mov [kl+KL_ARGS+40], rax
    karg 6, [mdl+MD_QKV]
    mov eax, [mdl_bf]
    karg 7, rax
    karg 8, [rsp+32]
    mov rcx, [cur_m]
    imul rcx, [kl+KL_ARGS+40]
    mov rax, [mdl+MD_HD]
    shr rax, 1
    imul rcx, rax
    call lin
    add rsp, 40
    ret

; the shared head of the attention kernels' args: B, T, H, KVH, hd, bf in slots 3..8
att_args:
    karg 3, [cur_b]
    karg 4, [cur_t]
    karg 5, [mdl+MD_H]
    karg 6, [mdl+MD_KVH]
    karg 7, [mdl+MD_HD]
    mov eax, [mdl_bf]
    karg 8, rax
    ret

; B*H*T*T, the size of the naive score matrices
%macro nscores 0
    mov rcx, [cur_m]
    imul rcx, [mdl+MD_H]
    imul rcx, [cur_t]
%endmacro

; grid for the flash kernels: (T/64, heads, B), blocks of 128. ecx = heads
flashgrid:
    mov eax, [cur_t]
    shr eax, 6
    mov [kl+KL_GX], eax
    mov [kl+KL_GY], ecx
    mov eax, [cur_b]
    mov [kl+KL_GZ], eax
    mov dword [kl+KL_BX], 128
    mov dword [kl+KL_BY], 1
    mov dword [kl+KL_BZ], 1
    lea rcx, [kl]
    jmp gpu_launch

; rsi = layer. y and lse from the qkv
attn_fwd:
    sub rsp, 40
    cmp dword [mdl_fast], 0
    je .naive
    KF k_ffwd
    karg 0, [rsi+LP_QKV]
    karg 1, [rsi+LP_Y]
    karg 2, [rsi+LP_LSE]
    karg 3, [cur_t]
    karg 4, [mdl+MD_H]
    karg 5, [mdl+MD_KVH]
    kargf 6, [scale]
    mov ecx, [mdl+MD_H]
    call flashgrid
    add rsp, 40
    ret
.naive:
    KF k_attdot
    mov rax, [rsi+LP_QKV]
    karg 0, rax
    karg 1, rax
    karg 2, [d_s1]
    call att_args
    kargf 9, [scale]
    karg 10, 0
    nscores
    call lin
    KF k_attsm
    karg 0, [d_s1]
    karg 1, [rsi+LP_LSE]
    mov rax, [cur_m]
    imul rax, [mdl+MD_H]
    mov [kl+KL_ARGS+16], rax
    karg 3, [cur_t]
    karg 4, 0
    mov rcx, [kl+KL_ARGS+16]
    call lin
    KF k_attmix
    karg 0, [d_s1]
    karg 1, [rsi+LP_QKV]
    karg 2, [rsi+LP_Y]
    call att_args
    kargf 9, [c_onef]
    karg 10, 0
    mov rcx, [cur_m]
    imul rcx, [mdl+MD_QD]
    call lin
    add rsp, 40
    ret

; rsi = layer. dqkv from dy
attn_bwd:
    sub rsp, 40
    cmp dword [mdl_fast], 0
    je .naive
    KF k_attnd
    karg 0, [d_dy]
    karg 1, [rsi+LP_Y]
    karg 2, [d_attd]
    karg 3, [cur_m]
    karg 4, [cur_t]
    karg 5, [mdl+MD_H]
    mov rcx, [cur_m]
    imul rcx, [mdl+MD_H]
    call lin
    ; dq, then dk and dv. same arguments for both
    KF k_fdq
    karg 0, [rsi+LP_QKV]
    karg 1, [d_dy]
    karg 2, [rsi+LP_LSE]
    karg 3, [d_attd]
    karg 4, [d_dqkv]
    karg 5, [cur_t]
    karg 6, [mdl+MD_H]
    karg 7, [mdl+MD_KVH]
    kargf 8, [scale]
    mov ecx, [mdl+MD_H]
    call flashgrid
    KF k_fdkv
    mov ecx, [mdl+MD_KVH]
    call flashgrid
    add rsp, 40
    ret
.naive:
    ; P again: scores, then softmax against the saved lse
    KF k_attdot
    mov rax, [rsi+LP_QKV]
    karg 0, rax
    karg 1, rax
    karg 2, [d_s1]
    call att_args
    kargf 9, [scale]
    karg 10, 0
    nscores
    call lin
    KF k_attsm
    karg 0, [d_s1]
    karg 1, [rsi+LP_LSE]
    mov rax, [cur_m]
    imul rax, [mdl+MD_H]
    mov [kl+KL_ARGS+16], rax
    karg 3, [cur_t]
    karg 4, 1
    mov rcx, [kl+KL_ARGS+16]
    call lin
    ; dP = dy v, then dS
    KF k_attdot
    karg 0, [d_dy]
    karg 1, [rsi+LP_QKV]
    karg 2, [d_s2]
    call att_args
    kargf 9, [c_onef]
    karg 10, 1
    nscores
    call lin
    KF k_attds
    karg 0, [d_s1]
    karg 1, [d_s2]
    mov rax, [cur_m]
    imul rax, [mdl+MD_H]
    mov [kl+KL_ARGS+16], rax
    karg 3, [cur_t]
    mov rcx, [kl+KL_ARGS+16]
    call lin
    ; dq
    KF k_attmix
    karg 0, [d_s2]
    karg 1, [rsi+LP_QKV]
    karg 2, [d_dqkv]
    call att_args
    kargf 9, [scale]
    karg 10, 1
    mov rcx, [cur_m]
    imul rcx, [mdl+MD_QD]
    call lin
    ; dk, dv
    KF k_attdkv
    karg 0, [d_s1]
    karg 1, [d_s2]
    karg 2, [rsi+LP_QKV]
    karg 3, [d_dy]
    karg 4, [d_dqkv]
    karg 5, [cur_b]
    karg 6, [cur_t]
    karg 7, [mdl+MD_H]
    karg 8, [mdl+MD_KVH]
    karg 9, [mdl+MD_HD]
    mov eax, [mdl_bf]
    karg 10, rax
    kargf 11, [scale]
    mov rcx, [cur_m]
    imul rcx, [mdl+MD_KVD]
    call lin
    add rsp, 40
    ret

; rcx = micro-batch (MB_*), edx = FW_LOGITS / FW_LOSS / FW_GRAD
global model_fwd
model_fwd:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    mov r12d, edx
    mov rax, [rbx+MB_B]
    mov [cur_b], rax
    mov rcx, [rbx+MB_T]
    mov [cur_t], rcx
    imul rax, rcx
    mov [cur_m], rax

    mov rsi, [lp]
    KF k_embed
    karg 0, [rsi+LP_X]
    karg 1, [d_params]
    karg 2, [rbx+MB_TOK]
    karg 3, [cur_m]
    karg 4, [cur_t]
    karg 5, [mdl+MD_D]
    mov rcx, [cur_m]
    imul rcx, [mdl+MD_D]
    call lin

    xor r13d, r13d
.layer:
    cmp r13, [mdl+MD_L]
    jae .final
    mov rcx, [rsi+LP_X]
    mov rdx, [rsi+LP_N1]
    mov r8, [rsi+LP_XN1]
    mov r9, [rsi+LP_RS1]
    call rmsnorm
    MM [rsi+LP_XN1], [rsi+LP_WQKV], [rsi+LP_QKV], 0, [cur_m], [mdl+MD_QKV], [mdl+MD_D], [mmbfx]
    mov rcx, [rsi+LP_QKV]
    xor edx, edx
    call rope
    call attn_fwd
    MM [rsi+LP_Y], [rsi+LP_WO], [rsi+LP_X2], [rsi+LP_X], [cur_m], [mdl+MD_D], [mdl+MD_QD], MM_X8
    mov rcx, [rsi+LP_X2]
    mov rdx, [rsi+LP_N2]
    mov r8, [rsi+LP_XN2]
    mov r9, [rsi+LP_RS2]
    call rmsnorm
    mov rdi, [mdl+MD_F]
    add rdi, rdi
    MM [rsi+LP_XN2], [rsi+LP_W13], [rsi+LP_H], 0, [cur_m], rdi, [mdl+MD_D], [mmbfx]
    KF k_swi
    karg 0, [rsi+LP_H]
    karg 1, [rsi+LP_G]
    karg 2, [cur_m]
    karg 3, [mdl+MD_F]
    mov eax, [mdl_bf]
    karg 4, rax
    mov rcx, [cur_m]
    imul rcx, [mdl+MD_F]
    call lin
    MM [rsi+LP_G], [rsi+LP_W2], [rsi+LP_SIZE+LP_X], [rsi+LP_X2], [cur_m], [mdl+MD_D], [mdl+MD_F], MM_X8
    add rsi, LP_SIZE
    inc r13
    jmp .layer

.final:
    mov rcx, [rsi+LP_X]
    mov rdx, [rsi+LP_N1]
    mov r8, [rsi+LP_XN1]
    mov r9, [rsi+LP_RS1]
    call rmsnorm
    MM [rsi+LP_XN1], [e_op], [d_logits], 0, [cur_m], [mdl+MD_V], [mdl+MD_D], 0
    cmp r12d, FW_LOGITS
    je .done
    KF k_xent
    karg 0, [d_logits]
    karg 1, [d_dlogits]
    karg 2, [rbx+MB_TOK]
    karg 3, [d_loss]
    karg 4, [cur_t]
    karg 5, [mdl+MD_V]
    kargf 6, [rbx+MB_SCALE]
    mov eax, [mdl_bf]
    karg 7, rax
    mov eax, [rbx+MB_FLAGS]
    and eax, 1
    cmp r12d, FW_LOSS
    jne .flags
    or eax, 2                   ; no gradient
.flags:
    karg 8, rax
    mov rcx, [cur_m]
    mov edx, 1
    mov r8d, 256
    mov r9d, 1
    call launch
.done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = micro-batch, after model_fwd with FW_GRAD. adds this micro-batch's
; gradients into d_grad
global model_bwd
model_bwd:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 56
    mov rbx, rcx
    mov rax, [lp]
    mov rsi, [mdl+MD_L]
    imul rsi, LP_SIZE
    add rsi, rax                ; the final norm's entry
    mov r12, [d_grad]           ; dE is at the start of the gradients
    mov r14, [mdl+MD_F]
    add r14, r14                ; 2F

    ; logits = xnf E^T. dE only needs dlogits, from the forward
    call fork
    lea rcx, [ev_dxn]
    call waitfor
    MM [d_dlogits], [e_op], [d_dxn], 0, [cur_m], [mdl+MD_D], [mdl+MD_V], MM_TB
    call on2
    MM [d_dlogits], [rsi+LP_XN1], r12, r12, [mdl+MD_V], [mdl+MD_D], [cur_m], MM_TA|MM_TB
    lea rcx, [ev_end]
    call back
    call fork
    lea rcx, [ev_drest]
    call waitfor
    mov rax, [rsi+LP_GN1]
    mov [rsp+32], rax
    mov qword [rsp+40], 0
    mov rcx, [d_dxn]
    mov rdx, [rsi+LP_X]
    mov r8, [rsi+LP_RS1]
    mov r9, [rsi+LP_N1]
    call rmsnorm_bwd

    mov r13, [mdl+MD_L]
.layer:
    sub rsi, LP_SIZE
    dec r13
    js .embed
    ; mlp: x' = x2 + swiglu(norm(x2) W13^T) W2^T
    call fork
    MM [d_drest], [rsi+LP_W2], [d_dg], 0, [cur_m], [mdl+MD_F], [mdl+MD_D], [mmbftbx]
    call on2
    MM [d_drest], [rsi+LP_G], [rsi+LP_G2], [rsi+LP_G2], [mdl+MD_D], [mdl+MD_F], [cur_m], MM_TA|MM_TB|MM_X8
    lea rcx, [ev_drest]
    call back
    lea rcx, [ev_dh]
    call waitfor
    KF k_swib
    karg 0, [rsi+LP_H]
    karg 1, [d_dg]
    karg 2, [d_dh]
    karg 3, [cur_m]
    karg 4, [mdl+MD_F]
    mov eax, [mdl_bf]
    karg 5, rax
    mov rcx, [cur_m]
    imul rcx, [mdl+MD_F]
    call lin
    call fork
    lea rcx, [ev_dxn]
    call waitfor
    MM [d_dh], [rsi+LP_W13], [d_dxn], 0, [cur_m], [mdl+MD_D], r14, MM_TB|MM_X8
    call on2
    MM [d_dh], [rsi+LP_XN2], [rsi+LP_G13], [rsi+LP_G13], r14, [mdl+MD_D], [cur_m], MM_TA|MM_TB|MM_X8
    lea rcx, [ev_dh]
    call back
    call fork
    lea rcx, [ev_drest]
    call waitfor
    mov rax, [rsi+LP_GN2]
    mov [rsp+32], rax
    mov qword [rsp+40], 1
    mov rcx, [d_dxn]
    mov rdx, [rsi+LP_X2]
    mov r8, [rsi+LP_RS2]
    mov r9, [rsi+LP_N2]
    call rmsnorm_bwd

    ; attention: x2 = x + attn(norm(x)) Wo^T
    call fork
    MM [d_drest], [rsi+LP_WO], [d_dy], 0, [cur_m], [mdl+MD_QD], [mdl+MD_D], [mmbftbx]
    call on2
    MM [d_drest], [rsi+LP_Y], [rsi+LP_GO], [rsi+LP_GO], [mdl+MD_D], [mdl+MD_QD], [cur_m], MM_TA|MM_TB|MM_X8
    lea rcx, [ev_drest]
    call back
    lea rcx, [ev_dqkv]
    call waitfor
    call attn_bwd
    mov rcx, [d_dqkv]
    mov edx, 1
    call rope
    call fork
    lea rcx, [ev_dxn]
    call waitfor
    MM [d_dqkv], [rsi+LP_WQKV], [d_dxn], 0, [cur_m], [mdl+MD_D], [mdl+MD_QKV], MM_TB|MM_X8
    call on2
    MM [d_dqkv], [rsi+LP_XN1], [rsi+LP_GQKV], [rsi+LP_GQKV], [mdl+MD_QKV], [mdl+MD_D], [cur_m], MM_TA|MM_TB|MM_X8
    lea rcx, [ev_dqkv]
    call back
    call fork
    lea rcx, [ev_drest]
    call waitfor
    mov rax, [rsi+LP_GN1]
    mov [rsp+32], rax
    mov qword [rsp+40], 1
    mov rcx, [d_dxn]
    mov rdx, [rsi+LP_X]
    mov r8, [rsi+LP_RS1]
    mov r9, [rsi+LP_N1]
    call rmsnorm_bwd
    jmp .layer

.embed:
    ; both streams add into dE, and the next forward overwrites what s2 reads,
    ; so everything on s2 has to be done here
    call join
    KF k_embedb
    karg 0, r12
    karg 1, [d_dres]
    karg 2, [rbx+MB_UTOK]
    karg 3, [rbx+MB_UST]
    karg 4, [rbx+MB_POS]
    karg 5, [rbx+MB_NU]
    karg 6, [mdl+MD_D]
    mov rcx, [rbx+MB_NU]
    call rows8
    add rsp, 56
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = settings (OP_*, f64), rdx = step number from 1 (for adam's bias correction).
; gradient norm, then adamw on everything. the norm stays on the gpu at d_gn
global model_step
model_step:
    push rbx
    push rsi
    sub rsp, 56
    mov rbx, rcx
    mov rsi, rdx
    mov rcx, [d_gn]
    xor edx, edx
    mov r8d, 1
    CU cuMemsetD32
    KF k_sumsq
    karg 0, [d_grad]
    karg 1, [d_sq]
    karg 2, [mdl+MD_NP]
    mov ecx, NSQ
    mov edx, 1
    mov r8d, 256
    mov r9d, 1
    call launch
    KF k_colsum
    karg 0, [d_sq]
    karg 1, [d_gn]
    karg 2, 1
    karg 3, NSQ
    mov ecx, 1
    call lin

    KF k_adamw
    karg 0, [d_params]
    karg 1, [d_grad]
    karg 2, [d_adm]
    karg 3, [d_adv]
    karg 4, [d_bf]
    karg 5, [d_gn]
    karg 6, [mdl+MD_NP]
    karg 7, [mdl+MD_NDEC]
%macro f32arg 2
    cvtsd2ss xmm0, %2
    movd [kl+KL_ARGS+%1*8], xmm0
%endmacro
    f32arg 8, [rbx+OP_LR]
    f32arg 9, [rbx+OP_B1]
    f32arg 10, [rbx+OP_B2]
    f32arg 11, [rbx+OP_EPS]
    f32arg 12, [rbx+OP_WD]
    f32arg 15, [rbx+OP_CLIP]
    ; bias corrections 1/(1 - b^t)
    movsd xmm0, [rbx+OP_B1]
    call math_log
    cvtsi2sd xmm1, rsi
    mulsd xmm0, xmm1
    call math_exp
    movsd xmm1, [c_one]
    subsd xmm1, xmm0
    movsd xmm0, [c_one]
    divsd xmm0, xmm1
    f32arg 13, xmm0
    movsd xmm0, [rbx+OP_B2]
    call math_log
    cvtsi2sd xmm1, rsi
    mulsd xmm0, xmm1
    call math_exp
    movsd xmm1, [c_one]
    subsd xmm1, xmm0
    movsd xmm0, [c_one]
    divsd xmm0, xmm1
    f32arg 14, xmm0
    mov ecx, 4096
    shl ecx, 8
    call lin
    cmp dword [mdl_fp8], 0
    je .done
    call quantw
.done:
    add rsp, 56
    pop rsi
    pop rbx
    ret

; rcx = host tokens u16 [B][T+1], rdx = B, r8 = T, r9 = host out: pos [M], utok [M],
; ust [M+1] (u32, M = B*T). sorts the rows by input token for the embedding
; backward. rax = distinct tokens
global model_sort
model_sort:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov rsi, rcx
    mov r12, rdx
    imul r12, r8                ; M
    mov r13, r8                 ; T
    mov rdi, r9
    lea rbx, [cnt]
    ; count
    xor ecx, ecx
    xor r8d, r8d                ; rows seen in this sequence
    xor r10d, r10d              ; token index
.count:
    cmp rcx, r12
    jae .prefix
    movzx eax, word [rsi+r10*2]
    and eax, 0x7fff
    inc dword [rbx+rax*4]
    inc rcx
    inc r10
    inc r8
    cmp r8, r13
    jb .count
    xor r8d, r8d
    inc r10                     ; skip the extra target token at the end of the row
    jmp .count
.prefix:
    ; distinct tokens in order, each bucket becomes its start
    lea r14, [rdi+r12*4]        ; utok
    lea r15, [r14+r12*4]        ; ust
    xor eax, eax                ; token
    xor ecx, ecx                ; running start
    xor edx, edx                ; distinct
.pv:
    cmp eax, 32768
    jae .fill
    mov r9d, [rbx+rax*4]
    test r9d, r9d
    jz .pn
    mov [r14+rdx*4], eax
    mov [r15+rdx*4], ecx
    mov [rbx+rax*4], ecx
    add ecx, r9d
    inc edx
.pn:
    inc eax
    jmp .pv
.fill:
    mov [r15+rdx*4], ecx
    mov r11, rdx
    xor ecx, ecx
    xor r8d, r8d
    xor r10d, r10d
.put:
    cmp rcx, r12
    jae .clear
    movzx eax, word [rsi+r10*2]
    and eax, 0x7fff
    mov r9d, [rbx+rax*4]
    mov [rdi+r9*4], ecx
    inc dword [rbx+rax*4]
    inc rcx
    inc r10
    inc r8
    cmp r8, r13
    jb .put
    xor r8d, r8d
    inc r10
    jmp .put
.clear:
    ; only the buckets we used are dirty
    xor ecx, ecx
.cl:
    cmp rcx, r11
    jae .done
    mov eax, [r14+rcx*4]
    mov dword [rbx+rax*4], 0
    inc rcx
    jmp .cl
.done:
    mov rax, r11
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; xmm0 = sum of the per-row losses (f64), synchronous. for tests and val
global model_loss
model_loss:
    push rbx
    sub rsp, 32
    mov rbx, [losshost]
    test rbx, rbx
    jnz .have
    mov rcx, [mdl+MD_M]
    shl rcx, 2
    call mem_alloc
    mov [losshost], rax
    mov rbx, rax
.have:
    mov rcx, rbx
    mov rdx, [d_loss]
    mov r8, [mdl+MD_M]
    shl r8, 2
    call gpu_down
    xorpd xmm0, xmm0
    xor ecx, ecx
.s:
    cmp rcx, [mdl+MD_M]
    jae .done
    cvtss2sd xmm1, [rbx+rcx*4]
    addsd xmm0, xmm1
    inc rcx
    jmp .s
.done:
    add rsp, 32
    pop rbx
    ret

; one-screen description of the model
global model_summary
model_summary:
    push rbx
    sub rsp, 32
    say "  model: "
    mov rcx, [mdl+MD_L]
    call print_dec
    say " layers, d "
    mov rcx, [mdl+MD_D]
    call print_dec
    say ", heads "
    mov rcx, [mdl+MD_H]
    call print_dec
    say "/"
    mov rcx, [mdl+MD_KVH]
    call print_dec
    say " x "
    mov rcx, [mdl+MD_HD]
    call print_dec
    say ", ffn "
    mov rcx, [mdl+MD_F]
    call print_dec
    say ", ctx "
    mov rcx, [mdl+MD_T]
    call print_dec
    say ", vocab "
    mov rcx, [mdl+MD_V]
    call print_dec
    say 13, 10, "  params: "
    mov rcx, [mdl+MD_NP]
    call pcount
    say " (embedding "
    mov rcx, [mdl+MD_V]
    imul rcx, [mdl+MD_D]
    call pcount
    say ", per layer "
    mov rcx, [mdl+MD_LSIZE]
    mov rax, [mdl+MD_D]
    lea rcx, [rcx+rax*2]
    call pcount
    say ")", 13, 10, "  micro-batch "
    mov rcx, [mdl+MD_B]
    call print_dec
    say " x "
    mov rcx, [mdl+MD_T]
    call print_dec
    say ", gpu memory "
    cvtsi2sd xmm0, qword [vram]
    mulsd xmm0, [c_gib]
    mov edx, 2
    call print_fixed
    say " GiB, "
    movsd xmm0, [mdl+MD_FLOPS]
    mulsd xmm0, [c_mega]
    mov edx, 1
    call print_fixed
    say " MFLOP/token", 13, 10
    add rsp, 32
    pop rbx
    ret

; rcx = count, printed like 21.9M
pcount:
    sub rsp, 72
    mov rdx, rcx
    lea rcx, [rsp+32]
    call fmt_count
    lea rcx, [rsp+32]
    mov rdx, rax
    sub rdx, rcx
    call print
    add rsp, 72
    ret

section .rdata
align 8
c_gib  dq 9.313225746154785e-10
c_mega dq 1e-6
