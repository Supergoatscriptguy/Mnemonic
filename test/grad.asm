; stage 5 test: the naive model in f32, gradients against finite differences.
; a tiny model with awkward sizes, random tokens. for every parameter tensor, nudge
; it along a direction u and compare (L(w + eu) - L(w - eu)) / 2e with g.u, once
; along the gradient itself and once along a random direction
; uses: gpu\cuda gpu\kernels model\model
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"
%include "model/model.inc"
%include "test/check.inc"

TL  equ 2                       ; layers
TD  equ 48
TH  equ 4                       ; 4 query heads of 12 over 2 kv heads
TKV equ 2
TF  equ 72
TV  equ 97
TT  equ 9
TB  equ 3
TM  equ TB * TT

section .rdata
align 8
c_eps   dq 1e-3
c_shift dq 2e-4                 ; aim for a loss change this big, well above f32 noise
c_tol   dq 3e-3
c_half  dq 0.5
c_m     dq 27.0                 ; TM
m_loss  db "loss at init = ln(97) +- 0.05", 0

section .bss
alignb 8
mb      resb MB_SIZE
rng     resb RNG_SIZE
htok    resq 1
hsort   resq 1
w0      resq 1                  ; params, host copy
g0      resq 1                  ; gradient
u       resq 1                  ; direction
loss0   resq 1
eps     resq 1
tname   resb 64
; t_adam16's f32 constants: b1 b2 1-b1 1-b2 -lr eps -lr*wd, then bc1 bc2 for steps 1, 2
ac      resd 12

section .text

global start
start:
    sub rsp, 40
    call lib_init
    call gpu_init
    xor ecx, ecx
    call pool_init
    mov qword [mdl+MD_L], TL
    mov qword [mdl+MD_D], TD
    mov qword [mdl+MD_H], TH
    mov qword [mdl+MD_KVH], TKV
    mov qword [mdl+MD_F], TF
    mov qword [mdl+MD_V], TV
    mov qword [mdl+MD_T], TT
    mov qword [mdl+MD_B], TB
    mov qword [mdl+MD_NAIVE], 1
    mov rax, __?float64?__(10000.0)
    mov [mdl+MD_ROPE], rax
    mov ecx, 4
    call model_setup
    call model_summary
    mov ecx, 7
    call model_init
    lea rcx, [rng]
    mov edx, 99
    call rng_seed

    ; random tokens and their sort, on the gpu
    mov ecx, 4096
    call mem_alloc
    mov [htok], rax
    mov ecx, 4096
    call mem_alloc
    mov [hsort], rax
    xor ebx, ebx
.tok:
    cmp ebx, TB * (TT + 1)
    jae .tokd
    lea rcx, [rng]
    call rng_next
    xor edx, edx
    mov ecx, TV
    div rcx
    mov rax, [htok]
    mov [rax+rbx*2], dx
    inc ebx
    jmp .tok
.tokd:
    mov rcx, [htok]
    mov edx, TB
    mov r8d, TT
    mov r9, [hsort]
    call model_sort
    mov [mb+MB_NU], rax
    mov ecx, 4096
    call gpu_alloc
    mov [mb+MB_TOK], rax
    mov rcx, rax
    mov rdx, [htok]
    mov r8d, 4096
    call gpu_up
    mov ecx, 4096 * 4
    call gpu_alloc
    mov [mb+MB_POS], rax
    lea rcx, [rax+TM*4]
    mov [mb+MB_UTOK], rcx
    lea rcx, [rax+TM*8]
    mov [mb+MB_UST], rcx
    mov rcx, rax
    mov rdx, [hsort]
    mov r8d, 4096
    call gpu_up
    mov qword [mb+MB_B], TB
    mov qword [mb+MB_T], TT
    mov eax, __?float32?__(0.037037037037037035)    ; 1/TM
    mov [mb+MB_SCALE], eax
    mov dword [mb+MB_FLAGS], 0

    ; loss at init
    call loss
    movsd [loss0], xmm0
    say "  loss "
    movsd xmm0, [loss0]
    mov edx, 5
    call print_fixed
    say 13, 10
    movsd xmm0, [loss0]
    mov rax, __?float64?__(4.574710978503383)  ; ln(97)
    movq xmm1, rax
    subsd xmm0, xmm1
    close_to 0.0, 0.05, "loss at init is about ln(97)"

    ; the gradient, and a copy of the weights to nudge
    call model_zero
    lea rcx, [mb]
    mov edx, FW_GRAD
    call model_fwd
    lea rcx, [mb]
    call model_bwd
    mov rbx, [mdl+MD_NP]
    lea rcx, [rbx*4]
    call mem_alloc
    mov [g0], rax
    lea rcx, [rbx*4]
    call mem_alloc
    mov [w0], rax
    lea rcx, [rbx*4]
    call mem_alloc
    mov [u], rax
    mov rcx, [g0]
    mov rdx, [d_grad]
    lea r8, [rbx*4]
    call gpu_down
    mov rcx, [w0]
    mov rdx, [d_params]
    lea r8, [rbx*4]
    call gpu_down

    ; every tensor: the embedding, each layer's four matrices and two norms, the last norm
    xor ecx, ecx
    mov rdx, [mdl+MD_V]
    imul rdx, [mdl+MD_D]
    lea r8, [n_emb]
    mov r9, -1
    call fdcheck
    mov r12, [mdl+MD_V]
    imul r12, [mdl+MD_D]        ; offset
    xor r13d, r13d              ; layer
.layer:
    cmp r13, TL
    jae .norms
    mov r14, [mdl+MD_QKV]
    imul r14, [mdl+MD_D]
    mov rcx, r12
    mov rdx, r14
    lea r8, [n_qkv]
    mov r9, r13
    call fdcheck
    add r12, r14
    mov r14, [mdl+MD_QD]
    imul r14, [mdl+MD_D]
    mov rcx, r12
    mov rdx, r14
    lea r8, [n_o]
    mov r9, r13
    call fdcheck
    add r12, r14
    mov r14, [mdl+MD_F]
    imul r14, [mdl+MD_D]
    add r14, r14
    mov rcx, r12
    mov rdx, r14
    lea r8, [n_13]
    mov r9, r13
    call fdcheck
    add r12, r14
    mov r14, [mdl+MD_F]
    imul r14, [mdl+MD_D]
    mov rcx, r12
    mov rdx, r14
    lea r8, [n_2]
    mov r9, r13
    call fdcheck
    add r12, r14
    inc r13
    jmp .layer
.norms:
    xor r13d, r13d
.nl:
    cmp r13, TL
    jae .last
    mov rcx, r12
    mov rdx, [mdl+MD_D]
    lea r8, [n_n1]
    mov r9, r13
    call fdcheck
    add r12, [mdl+MD_D]
    mov rcx, r12
    mov rdx, [mdl+MD_D]
    lea r8, [n_n2]
    mov r9, r13
    call fdcheck
    add r12, [mdl+MD_D]
    inc r13
    jmp .nl
.last:
    mov rcx, r12
    mov rdx, [mdl+MD_D]
    lea r8, [n_nf]
    mov r9, -1
    call fdcheck
    call t_adam
    call t_overfit
    call t_adam16
    jmp t_done

section .rdata
n_emb   db "embedding", 0
n_qkv   db "wqkv", 0
n_o     db "wo", 0
n_13    db "w1/w3", 0
n_2     db "w2", 0
n_n1    db "attn norm", 0
n_n2    db "mlp norm", 0
n_nf    db "final norm", 0
m_layer db "layer ", 0
m_along db ": fd along g and a random direction, err/|g|", 0
section .text

; rcx = offset, rdx = count, r8 = name, r9 = layer (-1 = none).
; fd along the gradient and along a random direction, both against g.u
fdcheck:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 64
    mov rsi, rcx
    mov rdi, rdx
    mov r12, r8
    mov r13, r9
    ; |g|
    mov rax, [g0]
    lea rbx, [rax+rsi*4]
    xorpd xmm0, xmm0
    xor ecx, ecx
.n:
    cmp rcx, rdi
    jae .nd
    cvtss2sd xmm1, [rbx+rcx*4]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    inc rcx
    jmp .n
.nd:
    sqrtsd xmm0, xmm0
    movsd [rsp+32], xmm0        ; |g|
    ; the step: big enough that the loss moves ~2e-4 (tiny gradients, like the
    ; norm weights', would otherwise measure f32 rounding), at least 1e-3
    movsd xmm1, [c_shift]
    divsd xmm1, xmm0
    maxsd xmm1, [c_eps]
    movsd [eps], xmm1
    ; along g: u = g/|g|, so g.u = |g|
    mov rax, [u]
    xor ecx, ecx
.u1:
    cmp rcx, rdi
    jae .u1d
    cvtss2sd xmm1, [rbx+rcx*4]
    divsd xmm1, [rsp+32]
    cvtsd2ss xmm1, xmm1
    movss [rax+rcx*4], xmm1
    inc rcx
    jmp .u1
.u1d:
    mov rcx, rsi
    mov rdx, rdi
    call fd
    subsd xmm0, [rsp+32]
    call absdiv
    movsd [rsp+40], xmm0
    ; random unit direction
    xorpd xmm0, xmm0
    movsd [rsp+48], xmm0
    xor ebx, ebx
.u2:
    cmp rbx, rdi
    jae .u2d
    lea rcx, [rng]
    call rng_normal
    cvtsd2ss xmm0, xmm0
    mov rax, [u]
    movss [rax+rbx*4], xmm0
    cvtss2sd xmm0, xmm0
    mulsd xmm0, xmm0
    addsd xmm0, [rsp+48]
    movsd [rsp+48], xmm0
    inc rbx
    jmp .u2
.u2d:
    movsd xmm2, [rsp+48]
    sqrtsd xmm2, xmm2
    mov rax, [u]
    mov rdx, [g0]
    lea rdx, [rdx+rsi*4]
    xorpd xmm3, xmm3            ; g.u
    xor ecx, ecx
.un:
    cmp rcx, rdi
    jae .und
    cvtss2sd xmm1, [rax+rcx*4]
    divsd xmm1, xmm2
    cvtsd2ss xmm1, xmm1
    movss [rax+rcx*4], xmm1
    cvtss2sd xmm1, xmm1
    cvtss2sd xmm4, [rdx+rcx*4]
    mulsd xmm1, xmm4
    addsd xmm3, xmm1
    inc rcx
    jmp .un
.und:
    movsd [rsp+48], xmm3
    mov rcx, rsi
    mov rdx, rdi
    call fd
    subsd xmm0, [rsp+48]
    call absdiv
    maxsd xmm0, [rsp+40]
    movsd [rsp+40], xmm0

    ; "layer 1 wqkv: ..."
    lea rcx, [tname]
    test r13, r13
    js .nolayer
    lea rdx, [m_layer]
    call fmt_str
    mov rcx, rax
    mov rdx, r13
    call fmt_dec
    mov byte [rax], ' '
    lea rcx, [rax+1]
.nolayer:
    mov rdx, r12
    call fmt_str
    mov rcx, rax
    lea rdx, [m_along]
    call fmt_str
    mov byte [rax], 0
    movsd xmm0, [rsp+40]
    comisd xmm0, [c_tol]
    setb cl
    movzx ecx, cl
    lea rdx, [tname]
    movsd xmm2, [rsp+40]
    call t_okf
    add rsp, 64
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; xmm0 = |xmm0| / |g| (the |g| at [rsp+32] of fdcheck's frame, 8 up from here)
absdiv:
    movq rax, xmm0
    btr rax, 63
    movq xmm0, rax
    divsd xmm0, [rsp+8+32]
    ret

; rcx = offset, rdx = count. (L(w + eps u) - L(w - eps u)) / 2 eps
fd:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    movsd xmm0, [eps]
    call nudge
    call loss
    movsd [rsp+32], xmm0
    movsd xmm0, [eps]
    xorpd xmm1, xmm1
    subsd xmm1, xmm0
    movapd xmm0, xmm1
    call nudge
    call loss
    movsd xmm1, [rsp+32]
    subsd xmm1, xmm0
    movsd xmm0, xmm1
    divsd xmm0, [eps]
    mulsd xmm0, [c_half]
    movsd [rsp+32], xmm0
    xorpd xmm0, xmm0
    call nudge                  ; back to w
    movsd xmm0, [rsp+32]
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rbx = offset, rsi = count (fd's), xmm0 = step. uploads w + step u for that range
nudge:
    push rdi
    sub rsp, 48
    movsd [rsp+32], xmm0
    mov rcx, rsi
    shl rcx, 2
    call mem_alloc
    mov rdi, rax
    mov r8, [w0]
    lea r8, [r8+rbx*4]
    mov r9, [u]
    xor ecx, ecx
.l:
    cmp rcx, rsi
    jae .up
    cvtss2sd xmm0, [r8+rcx*4]
    cvtss2sd xmm1, [r9+rcx*4]
    mulsd xmm1, [rsp+32]
    addsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    movss [rdi+rcx*4], xmm0
    inc rcx
    jmp .l
.up:
    mov rcx, [d_params]
    lea rcx, [rcx+rbx*4]
    mov rdx, rdi
    lea r8, [rsi*4]
    call gpu_up
    mov rcx, rdi
    call mem_free
    add rsp, 48
    pop rdi
    ret

; one adamw step from w0 with gradient g0 (still in d_grad), clipped, against
; the same math in f64 on the cpu
t_adam:
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    mov rcx, [d_grad]           ; the fd runs zeroed it
    mov rdx, [g0]
    mov r8, [mdl+MD_NP]
    shl r8, 2
    call gpu_up
    lea rcx, [opt]
    mov edx, 1
    call model_step
    lea rcx, [rsp+32]
    mov rdx, [d_gn]
    mov r8d, 4
    call gpu_down
    ; |g|^2 on the cpu
    mov rbx, [g0]
    xorpd xmm0, xmm0
    xor ecx, ecx
.n:
    cmp rcx, [mdl+MD_NP]
    jae .nd
    cvtss2sd xmm1, [rbx+rcx*4]
    mulsd xmm1, xmm1
    addsd xmm0, xmm1
    inc rcx
    jmp .n
.nd:
    movsd [rsp+40], xmm0
    cvtss2sd xmm1, [rsp+32]
    subsd xmm1, xmm0
    divsd xmm1, xmm0
    movapd xmm0, xmm1
    close_to 0.0, 1e-5, "gradient norm^2 matches the cpu (relative)"
    movsd xmm0, [rsp+40]
    sqrtsd xmm0, xmm0
    ; clip factor
    addsd xmm0, [c_1em6]
    movsd xmm1, [opt+OP_CLIP]
    divsd xmm1, xmm0
    minsd xmm1, [c_one]
    movsd [rsp+40], xmm1
    ; the new weights
    mov rcx, [u]
    mov rdx, [d_params]
    mov r8, [mdl+MD_NP]
    shl r8, 2
    call gpu_down
    mov rsi, [w0]
    mov rdi, [u]
    xorpd xmm7, xmm7            ; max |diff|
    xor ecx, ecx
.p:
    cmp rcx, [mdl+MD_NP]
    jae .pd
    cvtss2sd xmm0, [rbx+rcx*4]
    mulsd xmm0, [rsp+40]        ; g
    ; t = 1: mhat = g, vhat = g^2
    movapd xmm1, xmm0
    mulsd xmm1, xmm1
    sqrtsd xmm1, xmm1
    addsd xmm1, [opt+OP_EPS]
    divsd xmm0, xmm1
    mulsd xmm0, [opt+OP_LR]     ; the step
    cvtss2sd xmm2, [rsi+rcx*4]  ; p
    cmp rcx, [mdl+MD_NDEC]
    jae .nodecay
    movsd xmm3, [opt+OP_LR]
    mulsd xmm3, [opt+OP_WD]
    mulsd xmm3, xmm2
    subsd xmm2, xmm3
.nodecay:
    subsd xmm2, xmm0
    cvtss2sd xmm3, [rdi+rcx*4]
    subsd xmm3, xmm2
    movq rax, xmm3
    btr rax, 63
    movq xmm3, rax
    maxsd xmm7, xmm3
    inc rcx
    jmp .p
.pd:
    movapd xmm0, xmm7
    close_to 0.0, 1e-6, "adamw step with clipping matches the cpu (max abs diff)"
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret

; keep training on the same batch, it should learn it by heart
t_overfit:
    push rbx
    sub rsp, 32
    mov ebx, 2
.s:
    cmp ebx, 200
    ja .done
    call model_zero
    lea rcx, [mb]
    mov edx, FW_GRAD
    call model_fwd
    lea rcx, [mb]
    call model_bwd
    lea rcx, [opt]
    mov edx, ebx
    call model_step
    inc ebx
    jmp .s
.done:
    call loss
    movsd [loss0], xmm0
    close_to 0.0, 0.05, "200 adamw steps on one batch memorize it, loss"
    add rsp, 32
    pop rbx
    ret

; adamw16 (adam16=1): two steps from w0 with g0, against the cpu doing the same f32
; ops, with m and v rounded to bf16 in between. bit for bit. the moments get the
; adam16 layout (v right after m) inside the f32 m buffer, which is big enough
t_adam16:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rbx, [mdl+MD_NP]
    mov rcx, [d_params]
    mov rdx, [w0]
    lea r8, [rbx*4]
    call gpu_up
    mov rcx, [d_grad]
    mov rdx, [g0]
    lea r8, [rbx*4]
    call gpu_up
    mov rax, [d_adv]
    mov [rsp+32], rax           ; the f32 v, back at the end
    mov rax, [d_adm]
    lea rax, [rax+rbx*2]
    mov [d_adv], rax
    mov dword [mdl_adam16], 1
    call model_adam0
    lea rcx, [opt16]
    mov edx, 1
    call model_step
    lea rcx, [opt16]
    mov edx, 2
    call model_step
    mov rcx, [u]
    mov rdx, [d_params]
    lea r8, [rbx*4]
    call gpu_down
    lea rcx, [rbx*4]
    call mem_alloc
    mov r15, rax                ; m then v, bf16
    mov rcx, r15
    mov rdx, [d_adm]
    lea r8, [rbx*4]
    call gpu_down
    mov dword [mdl_adam16], 0
    mov rax, [rsp+32]
    mov [d_adv], rax

    ; the f32 constants, made the way model_step and the kernel make them
    lea rsi, [ac]
    cvtsd2ss xmm0, [opt16+OP_B1]
    movss [rsi], xmm0
    cvtsd2ss xmm0, [opt16+OP_B2]
    movss [rsi+4], xmm0
    mov eax, __?float32?__(1.0)
    movd xmm0, eax
    subss xmm0, [rsi]
    movss [rsi+8], xmm0
    movd xmm0, eax
    subss xmm0, [rsi+4]
    movss [rsi+12], xmm0
    cvtsd2ss xmm0, [opt16+OP_LR]
    movss [rsi+16], xmm0
    cvtsd2ss xmm0, [opt16+OP_EPS]
    movss [rsi+20], xmm0
    cvtsd2ss xmm1, [opt16+OP_WD]
    mulss xmm1, [rsi+16]
    movss [rsi+24], xmm1
    xor dword [rsi+16], 0x80000000  ; -lr and -lr*wd, for the fmas
    xor dword [rsi+24], 0x80000000
    mov r12d, 1
.bc:
    movsd xmm0, [opt16+OP_B1]
    call math_log
    cvtsi2sd xmm1, r12
    mulsd xmm0, xmm1
    call math_exp
    movsd xmm1, [c_one]
    subsd xmm1, xmm0
    movsd xmm0, [c_one]
    divsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    lea rsi, [ac]
    movss [rsi+r12*8+20], xmm0  ; bc1 at 28 + 8(t-1)
    movsd xmm0, [opt16+OP_B2]
    call math_log
    cvtsi2sd xmm1, r12
    mulsd xmm0, xmm1
    call math_exp
    movsd xmm1, [c_one]
    subsd xmm1, xmm0
    movsd xmm0, [c_one]
    divsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    lea rsi, [ac]
    movss [rsi+r12*8+24], xmm0  ; bc2
    inc r12d
    cmp r12d, 2
    jbe .bc

    mov rsi, [w0]
    mov rdi, [g0]
    mov r13, [mdl+MD_NDEC]
    xor r14d, r14d              ; mismatches
    xor r12d, r12d
.e:
    cmp r12, rbx
    jae .ed
    vmovss xmm0, [rdi+r12*4]    ; g
    vmovss xmm4, [rsi+r12*4]    ; p
    vxorps xmm1, xmm1, xmm1     ; m
    vxorps xmm2, xmm2, xmm2     ; v
    lea r8, [ac+28]             ; this step's bc1, bc2
    mov r9d, 2
.t:
    lea rcx, [ac]
    vmulss xmm1, xmm1, [rcx]
    vfmadd231ss xmm1, xmm0, [rcx+8]
    vmulss xmm3, xmm0, xmm0
    vmulss xmm2, xmm2, [rcx+4]
    vfmadd231ss xmm2, xmm3, [rcx+12]
    vmulss xmm3, xmm2, [r8+4]
    vsqrtss xmm3, xmm3, xmm3
    vaddss xmm3, xmm3, [rcx+20]
    vmulss xmm5, xmm1, [r8]
    vdivss xmm5, xmm5, xmm3
    cmp r12, r13
    jae .nod
    vfmadd231ss xmm4, xmm4, [rcx+24]    ; p - lr*wd*p
.nod:
    vfmadd231ss xmm4, xmm5, [rcx+16]    ; p - lr*u
    ; m and v go to bf16 and come back that way next step
    vmovd eax, xmm1
    mov edx, eax
    shr edx, 16
    and edx, 1
    lea eax, [rax+rdx+0x7fff]
    shr eax, 16
    mov r10d, eax
    shl eax, 16
    vmovd xmm1, eax
    vmovd eax, xmm2
    mov edx, eax
    shr edx, 16
    and edx, 1
    lea eax, [rax+rdx+0x7fff]
    shr eax, 16
    mov r11d, eax
    shl eax, 16
    vmovd xmm2, eax
    add r8, 8
    dec r9d
    jnz .t
    vmovd eax, xmm4
    mov rdx, [u]
    cmp eax, [rdx+r12*4]
    jne .bad
    cmp r10w, [r15+r12*2]
    jne .bad
    lea rdx, [r15+rbx*2]
    cmp r11w, [rdx+r12*2]
    je .ok
.bad:
    inc r14d
.ok:
    inc r12
    jmp .e
.ed:
    mov rcx, r15
    call mem_free
    test r14d, r14d
    check z, "adamw16, two steps: weights, m and v the same bits as the cpu"
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; xmm0 = mean loss of a forward pass over the batch
loss:
    sub rsp, 40
    call model_zero
    lea rcx, [mb]
    mov edx, FW_LOSS
    call model_fwd
    call model_loss
    divsd xmm0, [c_m]
    add rsp, 40
    ret

section .rdata
align 8
opt     dq 1e-2, 0.9, 0.95, 1e-8, 0.1, 1.0     ; lr b1 b2 eps wd clip
opt16   dq 1e-2, 0.9, 0.95, 1e-8, 0.1, 0.0     ; no clipping, so g goes in as it is
c_1em6  dq 1e-6
c_one   dq 1.0
