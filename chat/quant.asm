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

; rcx = f32 vector, rdx = n (a multiple of 32), r8 = int8 out, r9 = scale per group out.
; each group of 32: scale = max |x| / 127, q = round(x / scale)
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
