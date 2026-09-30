; the model on the cpu, one token at a time. same math as the gpu forward pass
; (model/model.asm): rmsnorm, qkv, rope, grouped-query attention over a kv cache,
; the output projection, rmsnorm, swiglu, and the tied embedding for the logits.
; the matrices go through mv_run (kernels.asm), the rest is plain avx2 here
; uses: chat\quant chat\kernels
default rel
bits 64
%include "lib.inc"
%include "chat/model.inc"

section .rdata
e_file   db "not a model file: ", 0
c_eps    dd 1e-5
c_one    dd 1.0
c_neg    dd -1.0
align 8
c_oned   dq 1.0

section .bss
alignb 8
global eng
eng      resb EN_SIZE
cur_l    resq 1                 ; for the attention callback
cur_t    resq 1
scale    resd 1                 ; 1/sqrt(hd)
global samp_temp, samp_topp
samp_temp resq 1                ; f64
samp_topp resq 1                ; f64
topv     resd 64
topi     resd 64

section .text

; rdi = MX_* to fill, rsi = where it starts, rcx = rows, rdx = cols, r8 = QT_*.
; rax = where the next tensor starts
global eng_mx
eng_mx:
    mov [rdi+MX_Q], rsi
    mov [rdi+MX_R], rcx
    mov [rdi+MX_C], rdx
    mov [rdi+MX_T], r8
    mov rax, rcx
    imul rax, rdx
    cmp r8d, QT_Q4
    jne .s
    shr rax, 1
.s:
    add rax, 63
    and rax, -64
    add rax, rsi
    mov [rdi+MX_S], rax         ; (not used for f32)
    push rsi
    sub rsp, 32
    call mf_size
    add rsp, 32
    pop rsi
    add rax, rsi
    ret

; rcx = bytes. zeroed, aligned
%macro buf 2                    ; field, float count (a register or constant)
    mov rcx, %2
    shl rcx, 2
    add rcx, 64
    call mem_alloc
    mov [eng+%1], rax
%endmacro

; rcx = path. maps the model file and sets up everything. eax = 1, or dies
global eng_load
eng_load:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rbx, rcx
    call file_map
    test rax, rax
    jz .bad
    mov [eng+EN_BASE], rax
    mov [eng+EN_BYTES], rdx
    mov r12, rax
    mov rcx, MF_MAGIC_V
    cmp [r12+MF_MAGIC], rcx
    jne .bad
    mov rax, [r12+MF_L]
    mov [eng+EN_L], rax
    mov rax, [r12+MF_D]
    mov [eng+EN_D], rax
    mov rax, [r12+MF_H]
    mov [eng+EN_H], rax
    mov rax, [r12+MF_KVH]
    mov [eng+EN_KVH], rax
    mov rax, [r12+MF_HD]
    mov [eng+EN_HD], rax
    cmp rax, 64                 ; attention keeps a head in 8 ymm registers
    jne .bad
    mov rax, [r12+MF_F]
    mov [eng+EN_F], rax
    mov rax, [r12+MF_V]
    mov [eng+EN_V], rax
    mov rax, [r12+MF_T]
    mov [eng+EN_T], rax
    mov rax, [r12+MF_QT]
    mov [eng+EN_QT], rax
    mov rax, [r12+MF_TOKHASH]
    mov [eng+EN_TOKHASH], rax
    mov rax, [eng+EN_H]
    imul rax, [eng+EN_HD]
    mov [eng+EN_QD], rax
    mov rcx, [eng+EN_KVH]
    imul rcx, [eng+EN_HD]
    mov [eng+EN_KVD], rcx
    lea rax, [rax+rcx*2]
    mov [eng+EN_QKV], rax
    cvtsi2sd xmm0, qword [eng+EN_HD]
    sqrtsd xmm0, xmm0
    movsd xmm1, [c_oned]
    divsd xmm1, xmm0
    cvtsd2ss xmm1, xmm1
    movss [scale], xmm1

    ; the tensors, in file order
    lea rsi, [r12+MF_SIZE]
    lea rdi, [eng+EN_E]
    mov rcx, [eng+EN_V]
    mov rdx, [eng+EN_D]
    mov r8, [eng+EN_QT]
    call eng_mx
    mov rsi, rax
    mov rcx, [eng+EN_L]
    imul rcx, 4 * MX_SIZE
    mov r13, rsi
    call mem_alloc
    mov rsi, r13
    mov [eng+EN_LAYERS], rax
    mov rdi, rax
    xor r13d, r13d
.layer:
    cmp r13, [eng+EN_L]
    jae .norms
    mov rcx, [eng+EN_QKV]
    mov rdx, [eng+EN_D]
    mov r8, [eng+EN_QT]
    call eng_mx
    mov rsi, rax
    add rdi, MX_SIZE
    mov rcx, [eng+EN_D]
    mov rdx, [eng+EN_QD]
    mov r8, [eng+EN_QT]
    call eng_mx
    mov rsi, rax
    add rdi, MX_SIZE
    mov rcx, [eng+EN_F]
    add rcx, rcx
    mov rdx, [eng+EN_D]
    mov r8, [eng+EN_QT]
    call eng_mx
    mov rsi, rax
    add rdi, MX_SIZE
    mov rcx, [eng+EN_D]
    mov rdx, [eng+EN_F]
    mov r8, [eng+EN_QT]
    call eng_mx
    mov rsi, rax
    add rdi, MX_SIZE
    inc r13
    jmp .layer
.norms:
    mov [eng+EN_NORMS], rsi

    ; kv cache and working buffers
    mov rax, [eng+EN_L]
    imul rax, [eng+EN_T]
    imul rax, [eng+EN_KVD]
    mov r13, rax
    buf EN_KC, r13
    buf EN_VC, r13
    mov rax, [eng+EN_T]
    imul rax, [eng+EN_HD]
    mov r13, rax
    buf EN_ROPE, r13
    buf EN_X, [eng+EN_D]
    mov rax, [eng+EN_F]
    add rax, [eng+EN_D]
    mov r13, rax
    buf EN_XN, r13
    buf EN_QKVB, [eng+EN_QKV]
    buf EN_Y, [eng+EN_QD]
    mov rax, [eng+EN_F]
    add rax, rax
    mov r13, rax
    buf EN_HB, r13
    buf EN_G, [eng+EN_F]
    buf EN_LOGITS, [eng+EN_V]
    buf EN_PROBS, [eng+EN_V]
    buf EN_TMP, [eng+EN_D]
    ; a row of scores per head, padded: exp8 reads and writes up to 7 past the
    ; last one, which without the padding lands in the next head's row (another thread's)
    mov rax, [eng+EN_T]
    add rax, 8
    imul rax, [eng+EN_H]
    mov r13, rax
    buf EN_ATT, r13

    ; rope table [t][i] = (cos, sin) of t * base^(-2i/hd), in f64 then f32, like the gpu's
    mov rdi, [eng+EN_ROPE]
    xor ebx, ebx
.t:
    cmp rbx, [eng+EN_T]
    jae .ready
    xor esi, esi
.i:
    mov rax, [eng+EN_HD]
    shr rax, 1
    cmp rsi, rax
    jae .tn
    movsd xmm0, [r12+MF_ROPE]
    call math_log
    lea rax, [rsi*2]
    cvtsi2sd xmm1, rax
    cvtsi2sd xmm2, qword [eng+EN_HD]
    divsd xmm1, xmm2
    mulsd xmm0, xmm1
    xorpd xmm1, xmm1
    subsd xmm1, xmm0
    movapd xmm0, xmm1
    call math_exp
    cvtsi2sd xmm1, rbx
    mulsd xmm0, xmm1
    movsd [rsp+32], xmm0
    call math_cos
    cvtsd2ss xmm0, xmm0
    mov rax, rbx
    imul rax, [eng+EN_HD]
    lea rax, [rax+rsi*2]
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
.ready:
    mov qword [eng+EN_POS], 0
    mov eax, 1
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.bad:
    lea rcx, [e_file]
    call print_z
    mov rcx, rbx
    call fatal

; empty the kv cache (a new conversation)
global eng_reset
eng_reset:
    mov qword [eng+EN_POS], 0
    ret

; rcx = src, rdx = weight, r8 = dst, r9 = n (a multiple of 8).
; dst = src * rstd * w, rstd = 1/sqrt(mean(src^2) + 1e-5)
rmsnorm:
    vxorps ymm0, ymm0, ymm0
    xor eax, eax
.ss:
    vmovups ymm1, [rcx+rax*4]
    vfmadd231ps ymm0, ymm1, ymm1
    add rax, 8
    cmp rax, r9
    jb .ss
    vextractf128 xmm1, ymm0, 1
    vaddps xmm0, xmm0, xmm1
    vmovhlps xmm1, xmm1, xmm0
    vaddps xmm0, xmm0, xmm1
    vshufps xmm1, xmm0, xmm0, 1
    vaddss xmm0, xmm0, xmm1
    vcvtsi2ss xmm1, xmm1, r9
    vdivss xmm0, xmm0, xmm1
    vaddss xmm0, xmm0, [c_eps]
    vsqrtss xmm0, xmm0, xmm0
    vmovss xmm1, [c_one]
    vdivss xmm0, xmm1, xmm0
    vbroadcastss ymm0, xmm0
    xor eax, eax
.n:
    vmulps ymm1, ymm0, [rcx+rax*4]
    vmulps ymm1, ymm1, [rdx+rax*4]
    vmovups [r8+rax*4], ymm1
    add rax, 8
    cmp rax, r9
    jb .n
    vzeroupper
    ret

; rcx = dst, rdx = src, r8 = n: dst += src
addv:
    xor eax, eax
.a:
    vmovups ymm0, [rcx+rax*4]
    vaddps ymm0, ymm0, [rdx+rax*4]
    vmovups [rcx+rax*4], ymm0
    add rax, 8
    cmp rax, r8
    jb .a
    vzeroupper
    ret

; ecx = token -> eng.x, the embedding row as f32
embed:
    push rbx
    push rsi
    push rdi
    mov rdi, [eng+EN_X]
    mov r8, [eng+EN_D]
    mov rsi, [eng+EN_E+MX_Q]
    mov rax, [eng+EN_QT]
    cmp eax, QT_F32
    jne .q8
    mov rax, rcx
    imul rax, r8
    lea rsi, [rsi+rax*4]
    mov rcx, r8
    rep movsd
    jmp .done
.q8:
    cmp eax, QT_Q8
    jne .q4
    mov rax, rcx
    imul rax, r8
    add rsi, rax
    mov rax, [eng+EN_E+MX_S]
    movss xmm1, [rax+rcx*4]
    xor eax, eax
.b:
    movsx edx, byte [rsi+rax]
    cvtsi2ss xmm0, edx
    mulss xmm0, xmm1
    movss [rdi+rax*4], xmm0
    inc rax
    cmp rax, r8
    jb .b
    jmp .done
.q4:
    mov rax, rcx
    imul rax, r8
    shr rax, 1
    add rsi, rax                ; packed row
    mov rbx, rcx
    imul rbx, r8
    shr rbx, 3
    add rbx, [eng+EN_E+MX_S]    ; its group scales
    xor eax, eax                ; element
.g:
    movss xmm1, [rbx]
    xor ecx, ecx
.j:
    movzx edx, byte [rsi+rcx]
    and edx, 15
    sub edx, 8
    cvtsi2ss xmm0, edx
    mulss xmm0, xmm1
    lea r9, [rax+rcx]
    movss [rdi+r9*4], xmm0
    movzx edx, byte [rsi+rcx]
    shr edx, 4
    sub edx, 8
    cvtsi2ss xmm0, edx
    mulss xmm0, xmm1
    movss [rdi+r9*4+64], xmm0
    inc ecx
    cmp ecx, 16
    jb .j
    add rsi, 16
    add rbx, 4
    add rax, 32
    cmp rax, r8
    jb .g
.done:
    pop rdi
    pop rsi
    pop rbx
    ret

; rotary embedding on the q and k heads in eng.qkvb, position cur_t
rope:
    mov rcx, [eng+EN_QKVB]
    mov rax, [eng+EN_H]
    add rax, [eng+EN_KVH]
    imul rax, [eng+EN_HD]       ; floats to go over, in pairs
    mov rdx, [eng+EN_ROPE]
    mov r8, [cur_t]
    imul r8, [eng+EN_HD]
    lea rdx, [rdx+r8*4]         ; this position's (cos, sin) pairs
    mov r9, [eng+EN_HD]
    xor r10d, r10d              ; float index
    xor r11d, r11d              ; pair within the head
.p:
    cmp r10, rax
    jae .done
    movss xmm0, [rdx+r11*8]     ; cos
    movss xmm1, [rdx+r11*8+4]   ; sin
    movss xmm2, [rcx+r10*4]     ; x0
    movss xmm3, [rcx+r10*4+4]   ; x1
    movss xmm4, xmm2
    mulss xmm4, xmm0
    movss xmm5, xmm3
    mulss xmm5, xmm1
    subss xmm4, xmm5            ; x0 cos - x1 sin
    mulss xmm2, xmm1
    mulss xmm3, xmm0
    addss xmm2, xmm3            ; x0 sin + x1 cos
    movss [rcx+r10*4], xmm4
    movss [rcx+r10*4+4], xmm2
    add r10, 2
    inc r11
    lea r8, [r11*2]
    cmp r8, r9
    jb .p
    xor r11d, r11d              ; next head
    jmp .p
.done:
    ret

; one key's score, not summed yet: %1 = q (ymm8-15) * the 64 floats at [%2]
%macro KEY 2
    vmulps %1, ymm8, [%2]
    vfmadd231ps %1, ymm9, [%2+32]
    vfmadd231ps %1, ymm10, [%2+64]
    vfmadd231ps %1, ymm11, [%2+96]
    vfmadd231ps %1, ymm12, [%2+128]
    vfmadd231ps %1, ymm13, [%2+160]
    vfmadd231ps %1, ymm14, [%2+192]
    vfmadd231ps %1, ymm15, [%2+224]
%endmacro

; par_for callback: heads [rdx, r8) of attention at layer cur_l, position cur_t
atthead:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, rdx
    mov r12, r8
.h:
    cmp rbx, r12
    jae .done
    ; this head's query, its kv head's cache rows, its score row
    mov rax, [eng+EN_H]
    xor edx, edx
    div qword [eng+EN_KVH]
    mov rcx, rax                ; group size
    mov rax, rbx
    xor edx, edx
    div rcx                     ; kv head
    imul rax, [eng+EN_HD]
    mov r13, [cur_l]
    imul r13, [eng+EN_T]
    imul r13, [eng+EN_KVD]
    add r13, rax                ; float offset of k/v row 0 for this head
    mov r14, [eng+EN_KVD]
    shl r14, 2                  ; row stride, bytes
    mov rsi, rbx
    imul rsi, [eng+EN_HD]
    shl rsi, 2
    add rsi, [eng+EN_QKVB]      ; q
    mov rdi, [eng+EN_T]
    add rdi, 8
    imul rdi, rbx
    shl rdi, 2
    add rdi, [eng+EN_ATT]       ; scores
    mov r15, [cur_t]
    inc r15                     ; keys

    ; scores s_j = q . k_j * scale, and their max. heads are 64 wide (eng_load checks),
    ; so q lives in ymm8-15 and four keys go at once: four fma chains side by side
    ; instead of one waiting on itself
    vmovups ymm8, [rsi]
    vmovups ymm9, [rsi+32]
    vmovups ymm10, [rsi+64]
    vmovups ymm11, [rsi+96]
    vmovups ymm12, [rsi+128]
    vmovups ymm13, [rsi+160]
    vmovups ymm14, [rsi+192]
    vmovups ymm15, [rsi+224]
    mov r8, [eng+EN_KC]
    lea r8, [r8+r13*4]
    vbroadcastss xmm6, [scale]
    mov r9d, 0xff800000
    vmovd xmm7, r9d
    vbroadcastss xmm7, xmm7     ; max, 4 lanes
    xor r10d, r10d
.s4:
    lea rax, [r10+4]
    cmp rax, r15
    ja .s1
    lea r9, [r8+r14*2]
    KEY ymm0, r8
    KEY ymm1, r8+r14
    KEY ymm2, r9
    KEY ymm3, r9+r14
    vhaddps ymm0, ymm0, ymm1
    vhaddps ymm2, ymm2, ymm3
    vhaddps ymm0, ymm0, ymm2    ; lo half: keys 0-3 over dims 0-3 of each 8, hi: 4-7
    vextractf128 xmm1, ymm0, 1
    vaddps xmm0, xmm0, xmm1
    vmulps xmm0, xmm0, xmm6
    vmovups [rdi+r10*4], xmm0
    vmaxps xmm7, xmm7, xmm0
    lea r8, [r8+r14*4]
    add r10, 4
    jmp .s4
.s1:
    cmp r10, r15
    jae .sm
    KEY ymm0, r8
    vextractf128 xmm1, ymm0, 1
    vaddps xmm0, xmm0, xmm1
    vhaddps xmm0, xmm0, xmm0
    vhaddps xmm0, xmm0, xmm0
    vmulss xmm0, xmm0, xmm6
    vmovss [rdi+r10*4], xmm0
    vmaxss xmm7, xmm7, xmm0
    add r8, r14
    inc r10
    jmp .s1
.sm:
    vshufps xmm0, xmm7, xmm7, 0x4e
    vmaxps xmm7, xmm7, xmm0
    vshufps xmm0, xmm7, xmm7, 0xb1
    vmaxps xmm7, xmm7, xmm0
    ; p_j = exp(s_j - max), 8 at a time. the extra lanes past t just go unused
    vbroadcastss ymm8, xmm7
    xor r10d, r10d
.e:
    cmp r10, r15
    jae .es
    vmovups ymm0, [rdi+r10*4]
    vsubps ymm0, ymm0, ymm8
    call exp8
    vmovups [rdi+r10*4], ymm0
    add r10, 8
    jmp .e
.es:
    ; their sum, always in the same order: 8 lanes over the full blocks, the rest one by one
    vxorps ymm9, ymm9, ymm9
    xor r10d, r10d
.sv:
    lea rax, [r10+8]
    cmp rax, r15
    ja .sf
    vaddps ymm9, ymm9, [rdi+r10*4]
    add r10, 8
    jmp .sv
.sf:
    vextractf128 xmm0, ymm9, 1
    vaddps xmm9, xmm9, xmm0
    vhaddps xmm9, xmm9, xmm9
    vhaddps xmm9, xmm9, xmm9
.st:
    cmp r10, r15
    jae .sd
    vaddss xmm9, xmm9, [rdi+r10*4]
    inc r10
    jmp .st
.sd:
    vmovss xmm0, [c_one]
    vdivss xmm6, xmm0, xmm9
    ; y = sum_j p_j v_j / sum, one key at a time into all 64 outputs (ymm8-15)
    mov rdx, [eng+EN_VC]
    lea rdx, [rdx+r13*4]
    vxorps ymm8, ymm8, ymm8
    vxorps ymm9, ymm9, ymm9
    vxorps ymm10, ymm10, ymm10
    vxorps ymm11, ymm11, ymm11
    vxorps ymm12, ymm12, ymm12
    vxorps ymm13, ymm13, ymm13
    vxorps ymm14, ymm14, ymm14
    vxorps ymm15, ymm15, ymm15
    xor r10d, r10d
.v:
    vbroadcastss ymm0, [rdi+r10*4]
    vfmadd231ps ymm8, ymm0, [rdx]
    vfmadd231ps ymm9, ymm0, [rdx+32]
    vfmadd231ps ymm10, ymm0, [rdx+64]
    vfmadd231ps ymm11, ymm0, [rdx+96]
    vfmadd231ps ymm12, ymm0, [rdx+128]
    vfmadd231ps ymm13, ymm0, [rdx+160]
    vfmadd231ps ymm14, ymm0, [rdx+192]
    vfmadd231ps ymm15, ymm0, [rdx+224]
    add rdx, r14
    inc r10
    cmp r10, r15
    jb .v
    vbroadcastss ymm0, xmm6
    mov rax, rbx
    shl rax, 8                  ; 64 floats per head
    add rax, [eng+EN_Y]
    vmulps ymm8, ymm8, ymm0
    vmovups [rax], ymm8
    vmulps ymm9, ymm9, ymm0
    vmovups [rax+32], ymm9
    vmulps ymm10, ymm10, ymm0
    vmovups [rax+64], ymm10
    vmulps ymm11, ymm11, ymm0
    vmovups [rax+96], ymm11
    vmulps ymm12, ymm12, ymm0
    vmovups [rax+128], ymm12
    vmulps ymm13, ymm13, ymm0
    vmovups [rax+160], ymm13
    vmulps ymm14, ymm14, ymm0
    vmovups [rax+192], ymm14
    vmulps ymm15, ymm15, ymm0
    vmovups [rax+224], ymm15
    inc rbx
    jmp .h
.done:
    vzeroupper
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; g = silu(a) * b, a = hb[0..F), b = hb[F..2F)
swiglu:
    push rbx
    mov rcx, [eng+EN_HB]
    mov rdx, [eng+EN_F]
    lea rdx, [rcx+rdx*4]
    mov r8, [eng+EN_G]
    xor ebx, ebx
.l:
    vmovups ymm6, [rcx+rbx*4]
    vxorps ymm0, ymm0, ymm0
    vsubps ymm0, ymm0, ymm6
    call exp8                   ; e^-a
    vbroadcastss ymm1, [c_one]
    vaddps ymm0, ymm0, ymm1
    vdivps ymm0, ymm1, ymm0     ; sigmoid
    vmulps ymm0, ymm6, ymm0
    vmulps ymm0, ymm0, [rdx+rbx*4]
    vmovups [r8+rbx*4], ymm0
    add rbx, 8
    cmp rbx, [eng+EN_F]
    jb .l
    vzeroupper
    pop rbx
    ret

; ecx = token, edx = 1 to compute the logits. runs it through the model at the
; next position and adds it to the kv cache
global eng_step
eng_step:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov r12d, edx
    call embed
    mov rax, [eng+EN_POS]
    mov [cur_t], rax
    mov rsi, [eng+EN_LAYERS]
    xor r13d, r13d
.layer:
    cmp r13, [eng+EN_L]
    jae .final
    mov [cur_l], r13
    ; the norm weights of this layer
    mov rbx, r13
    imul rbx, [eng+EN_D]
    shl rbx, 3                  ; 2 D floats per layer
    add rbx, [eng+EN_NORMS]
    mov rcx, [eng+EN_X]
    mov rdx, rbx
    mov r8, [eng+EN_XN]
    mov r9, [eng+EN_D]
    call rmsnorm
    mov rcx, rsi
    mov rdx, [eng+EN_XN]
    mov r8, [eng+EN_QKVB]
    call mv_run
    call rope
    ; k and v into the cache at this position
    mov rax, [cur_l]
    imul rax, [eng+EN_T]
    add rax, [cur_t]
    imul rax, [eng+EN_KVD]
    shl rax, 2
    mov rcx, [eng+EN_QD]
    shl rcx, 2
    add rcx, [eng+EN_QKVB]
    mov rdi, [eng+EN_KC]
    add rdi, rax
    push rsi
    mov rsi, rcx
    mov rcx, [eng+EN_KVD]
    rep movsd
    mov rdi, [eng+EN_VC]
    add rdi, rax
    mov rcx, [eng+EN_KVD]
    rep movsd                   ; v follows k in the qkv row
    pop rsi
    ; attention, a few heads per thread
    lea rcx, [atthead]
    xor edx, edx
    mov r8, [eng+EN_H]
    mov r9d, 1
    call par_for
    lea rcx, [rsi+MX_SIZE]
    mov rdx, [eng+EN_Y]
    mov r8, [eng+EN_TMP]
    call mv_run
    mov rcx, [eng+EN_X]
    mov rdx, [eng+EN_TMP]
    mov r8, [eng+EN_D]
    call addv
    mov rdx, [eng+EN_D]
    lea rdx, [rbx+rdx*4]
    mov rcx, [eng+EN_X]
    mov r8, [eng+EN_XN]
    mov r9, [eng+EN_D]
    call rmsnorm
    lea rcx, [rsi+2*MX_SIZE]
    mov rdx, [eng+EN_XN]
    mov r8, [eng+EN_HB]
    call mv_run
    call swiglu
    lea rcx, [rsi+3*MX_SIZE]
    mov rdx, [eng+EN_G]
    mov r8, [eng+EN_TMP]
    call mv_run
    mov rcx, [eng+EN_X]
    mov rdx, [eng+EN_TMP]
    mov r8, [eng+EN_D]
    call addv
    add rsi, 4 * MX_SIZE
    inc r13
    jmp .layer
.final:
    inc qword [eng+EN_POS]
    test r12d, r12d
    jz .done
    mov rbx, [eng+EN_L]
    imul rbx, [eng+EN_D]
    shl rbx, 3
    add rbx, [eng+EN_NORMS]
    mov rcx, [eng+EN_X]
    mov rdx, rbx
    mov r8, [eng+EN_XN]
    mov r9, [eng+EN_D]
    call rmsnorm
    lea rcx, [eng+EN_E]
    mov rdx, [eng+EN_XN]
    mov r8, [eng+EN_LOGITS]
    call mv_run
.done:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ecx = the token that came next. xmm0 = -log p(it) under the current logits (f64)
global eng_nll
eng_nll:
    push rbx
    push rsi
    sub rsp, 56
    mov ebx, ecx
    mov rsi, [eng+EN_LOGITS]
    call lmax
    vmovss [rsp+32], xmm7
    ; sum of exp(l - max)
    mov rsi, [eng+EN_LOGITS]
    vbroadcastss ymm8, xmm7
    vxorps ymm9, ymm9, ymm9
    xor eax, eax
.e:
    vmovups ymm0, [rsi+rax*4]
    vsubps ymm0, ymm0, ymm8
    mov [rsp+40], rax
    call exp8
    mov rax, [rsp+40]
    mov rsi, [eng+EN_LOGITS]
    vaddps ymm9, ymm9, ymm0
    add rax, 8
    cmp rax, [eng+EN_V]
    jb .e
    vmovaps ymm0, ymm9
    vextractf128 xmm1, ymm0, 1
    vaddps xmm0, xmm0, xmm1
    vmovhlps xmm1, xmm1, xmm0
    vaddps xmm0, xmm0, xmm1
    vshufps xmm1, xmm0, xmm0, 1
    vaddss xmm0, xmm0, xmm1
    vzeroupper
    cvtss2sd xmm0, xmm0
    call math_log
    cvtss2sd xmm1, [rsp+32]
    addsd xmm0, xmm1            ; lse
    mov rsi, [eng+EN_LOGITS]
    cvtss2sd xmm1, [rsi+rbx*4]
    subsd xmm0, xmm1
    add rsp, 56
    pop rsi
    pop rbx
    ret

; rsi = logits. xmm7 = their max (ymm8 scratch)
lmax:
    mov r8d, 0xff800000
    vmovd xmm7, r8d
    vbroadcastss ymm7, xmm7
    xor eax, eax
.m:
    vmaxps ymm7, ymm7, [rsi+rax*4]
    add rax, 8
    cmp rax, [eng+EN_V]
    jb .m
    vextractf128 xmm8, ymm7, 1
    vmaxps xmm7, xmm7, xmm8
    vmovhlps xmm8, xmm8, xmm7
    vmaxps xmm7, xmm7, xmm8
    vshufps xmm8, xmm7, xmm7, 1
    vmaxss xmm7, xmm7, xmm8
    ret

; rcx = rng. eax = the next token from the logits: temperature samp_temp (0 = the
; most likely one), then top-p samp_topp among the 64 likeliest. the probabilities
; come from the softmax over the whole vocab
global samp_pick
samp_pick:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov r12, rcx
    mov rsi, [eng+EN_LOGITS]
    call lmax
    xorpd xmm0, xmm0
    comisd xmm0, [samp_temp]
    jb .soft
    ; greedy: the first one that equals the max
    mov rsi, [eng+EN_LOGITS]
    xor eax, eax
.am:
    vucomiss xmm7, [rsi+rax*4]
    je .done
    inc rax
    cmp rax, [eng+EN_V]
    jb .am
    xor eax, eax                ; only if the logits are nan
    jmp .done
.soft:
    ; p = exp((l - max) / temp), all of them
    movsd xmm0, [samp_temp]
    cvtsd2ss xmm0, xmm0
    vmovss xmm1, [c_one]
    vdivss xmm0, xmm1, xmm0
    vmovss [rsp+32], xmm0
    vbroadcastss ymm8, xmm7
    vxorps ymm9, ymm9, ymm9
    xor ebx, ebx
.p:
    mov rsi, [eng+EN_LOGITS]
    vmovups ymm0, [rsi+rbx*4]
    vsubps ymm0, ymm0, ymm8
    vbroadcastss ymm1, [rsp+32]
    vmulps ymm0, ymm0, ymm1
    call exp8
    mov rdi, [eng+EN_PROBS]
    vmovups [rdi+rbx*4], ymm0
    vaddps ymm9, ymm9, ymm0
    add rbx, 8
    cmp rbx, [eng+EN_V]
    jb .p
    vmovaps ymm0, ymm9
    vextractf128 xmm1, ymm0, 1
    vaddps xmm0, xmm0, xmm1
    vmovhlps xmm1, xmm1, xmm0
    vaddps xmm0, xmm0, xmm1
    vshufps xmm1, xmm0, xmm0, 1
    vaddss xmm0, xmm0, xmm1
    vzeroupper
    vmovss [rsp+36], xmm0       ; total
    ; the 64 largest, descending (insertion; most never get past the last one)
    mov rdi, [eng+EN_PROBS]
    xor ebx, ebx                ; kept
    xor ecx, ecx
.k:
    cmp rcx, [eng+EN_V]
    jae .kept
    movss xmm0, [rdi+rcx*4]
    cmp ebx, 64
    jb .ins
    lea rax, [topv]
    comiss xmm0, [rax+63*4]
    jbe .nk
    dec ebx
.ins:
    mov edx, ebx
.sh:
    test edx, edx
    jz .put
    lea rax, [topv]
    comiss xmm0, [rax+rdx*4-4]
    jbe .put
    mov r8d, [rax+rdx*4-4]
    mov [rax+rdx*4], r8d
    lea rax, [topi]
    mov r8d, [rax+rdx*4-4]
    mov [rax+rdx*4], r8d
    dec edx
    jmp .sh
.put:
    lea rax, [topv]
    movss [rax+rdx*4], xmm0
    lea rax, [topi]
    mov [rax+rdx*4], ecx
    inc ebx
.nk:
    inc rcx
    jmp .k
.kept:
    ; the smallest top set whose probability reaches top_p
    cvtss2sd xmm2, [rsp+36]
    mulsd xmm2, [samp_topp]     ; top_p, in unnormalized units
    xorpd xmm3, xmm3            ; running sum
    xor r13d, r13d
    lea rax, [topv]
.c:
    cvtss2sd xmm0, [rax+r13*4]
    addsd xmm3, xmm0
    inc r13
    cmp r13d, ebx
    jae .draw
    comisd xmm3, xmm2
    jb .c
.draw:
    movsd [rsp+40], xmm3
    mov rcx, r12
    call rng_float
    mulsd xmm0, [rsp+40]
    xor ecx, ecx
    lea rax, [topv]
.w:
    lea rdx, [rcx+1]
    cmp rdx, r13
    jae .got                    ; the last one takes whatever rounding left
    cvtss2sd xmm1, [rax+rcx*4]
    subsd xmm0, xmm1
    xorpd xmm1, xmm1
    comisd xmm0, xmm1
    jb .got
    inc rcx
    jmp .w
.got:
    lea rax, [topi]
    mov eax, [rax+rcx*4]
.done:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
