; quantization. weights, once, when making a model file: int8 with one scale per
; row, or int4 with one scale per group of 32 (both symmetric, round to nearest).
; activations, before every matrix-vector product: int8 with a scale per group of
; 32, so a few big values in one spot don't cost the rest their precision
default rel
bits 64
%include "lib.inc"
%include "chat/model.inc"

section .rdata
align 32
absmask  times 8 dd 0x7fffffff
perm     dd 0, 4, 1, 5, 2, 6, 3, 7  ; undoes the lane order of the two packs
c127     dd 127.0
c7       dd 7.0
c1       dd 1.0
align 16
signbit  times 4 dd 0x80000000
m8x4     times 4 dd -8.0
p7x4     times 4 dd 7.0
i8x4     times 4 dd 8
; q4_row_fit's tries: the biggest weight at about -fitc
fitc     dd 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8, 7.9, 8.0, 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 8.8, 8.9
NFIT     equ 19

section .text

; rcx = rows, rdx = cols, r8 = QT_*. rax = bytes the matrix takes in the file,
; rounded up to 64
global mf_size
mf_size:
    mov rax, rcx
    imul rax, rdx
    cmp r8d, QT_F32
    jne .q
    shl rax, 2
    jmp .round
.q:
    cmp r8d, QT_Q8
    jne .q4
    add rax, 63
    and rax, -64
    lea rax, [rax+rcx*4]
    jmp .round
.q4:
    shr rax, 1
    add rax, 63
    and rax, -64
    mov r9, rdx
    shr r9, 5
    imul r9, rcx
    lea rax, [rax+r9*4]
.round:
    add rax, 63
    and rax, -64
    ret

; rcx = f32 row, rdx = cols, r8 = int8 out, r9 = where its scale goes
global q8_row
q8_row:
    xorps xmm0, xmm0            ; max |w|
    xor eax, eax
.m:
    cmp rax, rdx
    jae .scale
    movss xmm1, [rcx+rax*4]
    andps xmm1, [absmask]
    maxss xmm0, xmm1
    inc rax
    jmp .m
.scale:
    movss xmm1, xmm0
    divss xmm1, [c127]
    movss [r9], xmm1            ; w = q * scale
    xorps xmm2, xmm2            ; 127 / max, or 0 for an all-zero row
    comiss xmm0, xmm2
    jbe .q
    movss xmm2, [c127]
    divss xmm2, xmm0
.q:
    xor eax, eax
.l:
    cmp rax, rdx
    jae .done
    movss xmm1, [rcx+rax*4]
    mulss xmm1, xmm2
    cvtss2si r10d, xmm1         ; nearest, and never past +-127
    mov [r8+rax], r10b
    inc rax
    jmp .l
.done:
    ret

; rcx = f32 row, rdx = cols (a multiple of 32), r8 = packed out (cols/2 bytes),
; r9 = scales out (cols/32 f32)
global q4_row
q4_row:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, r8
    mov rbx, rdx
    shr rbx, 5                  ; groups
.g:
    test rbx, rbx
    jz .done
    xorps xmm0, xmm0
    xor eax, eax
.m:
    movss xmm1, [rsi+rax*4]
    andps xmm1, [absmask]
    maxss xmm0, xmm1
    inc eax
    cmp eax, 32
    jb .m
    movss xmm1, xmm0
    divss xmm1, [c7]
    movss [r9], xmm1
    add r9, 4
    xorps xmm2, xmm2
    comiss xmm0, xmm2
    jbe .q
    movss xmm2, [c7]
    divss xmm2, xmm0
.q:
    ; q in [-7, 7] stored as q + 8: byte j holds weights j (low) and j + 16 (high)
    xor eax, eax
.b:
    movss xmm1, [rsi+rax*4]
    mulss xmm1, xmm2
    cvtss2si ecx, xmm1
    add ecx, 8
    movss xmm1, [rsi+rax*4+64]
    mulss xmm1, xmm2
    cvtss2si edx, xmm1
    add edx, 8
    shl edx, 4
    or ecx, edx
    mov [rdi+rax], cl
    inc eax
    cmp eax, 16
    jb .b
    add rsi, 128
    add rdi, 16
    dec rbx
    jmp .g
.done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; L for 4 weights at %1 with xmm0 = 1/scale: round, clamp to -8..7, in %2
%macro q4l 2
    movups %2, %1
    mulps %2, xmm0
    roundps %2, %2, 0
    maxps %2, [m8x4]
    minps %2, [p7x4]
%endmacro

; same as q4_row, but each group's scale is searched for instead of max/7: 19 tries
; that put the biggest weight at about -8 (so all 16 levels get used) plus q4_row's
; own, each refit by least squares (d = sum xq / sum q^2), and the one that leaves
; the least squared error wins. the format doesn't change, only the scales and q
global q4_row_fit
q4_row_fit:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 136
    mov rsi, rcx
    mov rdi, r8
    mov r12, r9
    mov rbx, rdx
    shr rbx, 5
.g:
    test rbx, rbx
    jz .done
    ; the weight with the biggest magnitude, and its sign
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    xor eax, eax
.m:
    movss xmm2, [rsi+rax*4]
    movss xmm3, xmm2
    andps xmm3, [absmask]
    comiss xmm3, xmm0
    jbe .mn
    movss xmm0, xmm3
    movss xmm1, xmm2
.mn:
    inc eax
    cmp eax, 32
    jb .m
    movss [rsp+48], xmm0        ; max |x|
    movss [rsp+44], xmm1        ; that x
    xorps xmm2, xmm2
    comiss xmm0, xmm2
    ja .search
    mov dword [r12], 0
    mov rax, 0x8888888888888888 ; all zero
    mov [rdi], rax
    mov [rdi+8], rax
    jmp .next
.search:
    mov dword [rsp+32], 0       ; the best try so far takes away this much error
    xor r10d, r10d
.try:
    cmp r10d, NFIT
    ja .best
    jb .fit
    movss xmm0, [c7]            ; the last try is q4_row's 7 / max |x|
    divss xmm0, [rsp+48]
    jmp .go
.fit:
    lea rax, [fitc]
    movss xmm0, [rax+r10*4]
    xorps xmm0, [signbit]
    divss xmm0, [rsp+44]
.go:
    movss [rsp+52], xmm0
    shufps xmm0, xmm0, 0
    xorps xmm1, xmm1            ; sum x q
    xorps xmm2, xmm2            ; sum q^2
%assign i 0
%rep 8
    movups xmm3, [rsi+i*16]
    q4l [rsi+i*16], xmm4
    mulps xmm3, xmm4
    addps xmm1, xmm3
    mulps xmm4, xmm4
    addps xmm2, xmm4
%assign i i+1
%endrep
    haddps xmm1, xmm1
    haddps xmm1, xmm1
    haddps xmm2, xmm2
    haddps xmm2, xmm2
    xorps xmm3, xmm3
    comiss xmm2, xmm3
    jbe .tn
    ; with d = sum xq / sum q^2 the error is sum x^2 - (sum xq)^2 / sum q^2
    movss xmm3, xmm1
    mulss xmm3, xmm1
    divss xmm3, xmm2
    comiss xmm3, [rsp+32]
    jbe .tn
    movss [rsp+32], xmm3
    mov eax, [rsp+52]
    mov [rsp+36], eax
    divss xmm1, xmm2
    movss [rsp+40], xmm1
.tn:
    inc r10d
    jmp .try
.best:
    movss xmm0, [rsp+36]
    shufps xmm0, xmm0, 0
    mov eax, [rsp+40]
    mov [r12], eax
    ; q + 8 in nibbles: byte j holds weights j (low) and j + 16 (high)
%assign i 0
%rep 4
    q4l [rsi+i*16], xmm1
    cvtps2dq xmm1, xmm1
    paddd xmm1, [i8x4]
    q4l [rsi+64+i*16], xmm2
    cvtps2dq xmm2, xmm2
    paddd xmm2, [i8x4]
    pslld xmm2, 4
    por xmm1, xmm2
    movups [rsp+64+i*16], xmm1
%assign i i+1
%endrep
    xor eax, eax
.pk:
    mov ecx, [rsp+64+rax*4]
    mov [rdi+rax], cl
    inc eax
    cmp eax, 16
    jb .pk
.next:
    add rsi, 128
    add rdi, 16
    add r12, 4
    dec rbx
    jmp .g
.done:
    add rsp, 136
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = f32 vector, rdx = n (a multiple of 32), r8 = int8 out, r9 = scale per group out.
; each group of 32: scale = max |x| / 127, q = round(x / scale). trashes xmm6-7 too
global qx_vec
qx_vec:
    vmovdqu ymm7, [perm]
    vmovaps ymm6, [absmask]
    shr rdx, 5
.g:
    test rdx, rdx
    jz .done
    vmovups ymm0, [rcx]
    vmovups ymm1, [rcx+32]
    vmovups ymm2, [rcx+64]
    vmovups ymm3, [rcx+96]
    vandps ymm4, ymm0, ymm6
    vandps ymm5, ymm1, ymm6
    vmaxps ymm4, ymm4, ymm5
    vandps ymm5, ymm2, ymm6
    vmaxps ymm4, ymm4, ymm5
    vandps ymm5, ymm3, ymm6
    vmaxps ymm4, ymm4, ymm5
    vextractf128 xmm5, ymm4, 1
    vmaxps xmm4, xmm4, xmm5
    vmovhlps xmm5, xmm5, xmm4
    vmaxps xmm4, xmm4, xmm5
    vshufps xmm5, xmm4, xmm4, 1
    vmaxss xmm4, xmm4, xmm5     ; max |x| of the group
    vdivss xmm5, xmm4, [c127]
    vmovss [r9], xmm5
    add r9, 4
    vxorps xmm5, xmm5, xmm5
    vcomiss xmm4, xmm5
    jbe .zero
    vmovss xmm5, [c127]
    vdivss xmm5, xmm5, xmm4
.zero:
    vbroadcastss ymm5, xmm5
    vmulps ymm0, ymm0, ymm5
    vmulps ymm1, ymm1, ymm5
    vmulps ymm2, ymm2, ymm5
    vmulps ymm3, ymm3, ymm5
    vcvtps2dq ymm0, ymm0
    vcvtps2dq ymm1, ymm1
    vcvtps2dq ymm2, ymm2
    vcvtps2dq ymm3, ymm3
    vpackssdw ymm0, ymm0, ymm1
    vpackssdw ymm2, ymm2, ymm3
    vpacksswb ymm0, ymm0, ymm2
    vpermd ymm0, ymm7, ymm0
    vmovdqu [r8], ymm0
    add rcx, 128
    add r8, 32
    dec rdx
    jmp .g
.done:
    vzeroupper
    ret
