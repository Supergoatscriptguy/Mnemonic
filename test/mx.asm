; mxfp8 test: the scale layout gemm_mx counts on, mxq against a cpu quantizer
; (bit for bit), mm_mx against a cpu fma loop (bit for bit), and gemm_mx against
; mm_mx on the shapes that matter
; uses: gpu\cuda gpu\kernels
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"
%include "test/check.inc"

extern ptx_mx, ptx_mx_end, ptx_gemm, ptx_gemm_end

QR    equ 64                    ; quantizer test: 64 x 1024
QC    equ 1024
QB    equ QR * QC / 32
RM    equ 70                    ; mm_mx against the cpu
RN    equ 50
RK    equ 96
BIG   equ 16 << 20              ; buffer size

section .rdata
k_probe  db "mx_probe", 0
k_mxq    db "mxq", 0
k_mm     db "mm_mx", 0
k_gemm   db "gemm_mx", 0
k_ref    db "mm_ref", 0
; (byte-id, thread-id) pairs the probe looks at
pairs    db 0,0, 1,0, 2,0, 3,0, 0,1, 1,1, 2,2, 3,3, 0,2, 0,3, 0xff
align 8
c_tol    dq 1e-4
c_tol16  dq 1e-2
c_tolq   dq 5e-2
f_448    dd 448.0
f_2m9    dd 0x3b000000          ; 2^-9

section .bss
alignb 8
kl       resb KL_SIZE
f_probe  resq 1
f_mxq    resq 1
f_mm     resq 1
f_gemm   resq 1
f_ref    resq 1
hx       resq 1                 ; host
hy       resq 1
hc       resq 1
hd       resq 1
hq       resq 1
hs       resq 1
d_x      resq 1                 ; device
d_y      resq 1
d_qa     resq 1
d_sa     resq 1
d_qb     resq 1
d_sb     resq 1
d_c      resq 1
d_r      resq 1
d_r2     resq 1
rng      resb RNG_SIZE
e4       resd 256               ; every e4m3 code as an f32

section .text

%macro getf 3
    mov rcx, %1
    lea rdx, [%2]
    call gpu_func
    mov [%3], rax
%endmacro

%macro halloc 1
    mov ecx, BIG
    call mem_alloc
    mov [%1], rax
%endmacro

%macro dalloc 1
    mov ecx, BIG
    call gpu_alloc
    mov [%1], rax
%endmacro

global start
start:
    sub rsp, 40
    call lib_init
    call gpu_init
    mov dword [gpu_arch], 1
    lea rcx, [ptx_mx]
    lea rdx, [ptx_mx_end]
    sub rdx, rcx
    call gpu_module
    mov dword [gpu_arch], 0
    mov r12, rax
    getf r12, k_probe, f_probe
    getf r12, k_mxq, f_mxq
    getf r12, k_mm, f_mm
    getf r12, k_gemm, f_gemm
    lea rcx, [ptx_gemm]
    lea rdx, [ptx_gemm_end]
    sub rdx, rcx
    call gpu_module
    getf rax, k_ref, f_ref
    lea rcx, [rng]
    mov edx, 7
    call rng_seed
    halloc hx
    halloc hy
    halloc hc
    halloc hd
    halloc hq
    halloc hs
    dalloc d_x
    dalloc d_y
    dalloc d_qa
    dalloc d_sa
    dalloc d_qb
    dalloc d_sb
    dalloc d_c
    dalloc d_r
    dalloc d_r2
    call mkdec

    say "scale layout", 13, 10
    call t_probe
    say "quantizer", 13, 10
    mov ecx, 8
    call t_quant
    xor ecx, ecx
    call t_quant
    say "matmul", 13, 10
    call t_mref
    mov ecx, 128
    mov edx, 128
    mov r8d, 64
    lea r9, [m_g1]
    call t_gemm
    mov ecx, 256
    mov edx, 384
    mov r8d, 256
    lea r9, [m_g2]
    call t_gemm
    mov ecx, 1024
    mov edx, 1024
    mov r8d, 1024
    lea r9, [m_g3]
    call t_gemm
    call t_vsf32                ; same inputs, against the unquantized f32 product
    mov ecx, 384
    mov edx, 1024
    mov r8d, 4096
    lea r9, [m_g4]
    call t_gemm
    call t_split
    call t_bf16r
    jmp t_done

section .rdata
m_g1 db "gemm_mx 128x128x64 (one tile) matches mm_mx", 0
m_g2 db "gemm_mx 256x384x256 matches mm_mx", 0
m_g3 db "gemm_mx 1024x1024x1024 matches mm_mx", 0
m_g4 db "gemm_mx 384x1024x4096 (long k) matches mm_mx", 0
section .text

; e4[c] = the e4m3 code c as an f32: (8+m) * 2^(e-10), or m * 2^-9 when e = 0
mkdec:
    xor ecx, ecx
    lea r9, [e4]
.c:
    mov eax, ecx
    shr eax, 3
    and eax, 15                 ; e
    mov edx, ecx
    and edx, 7                  ; m
    test eax, eax
    jnz .norm
    vcvtsi2ss xmm0, xmm0, edx
    vmulss xmm0, xmm0, [f_2m9]
    jmp .sign
.norm:
    add edx, 8
    vcvtsi2ss xmm0, xmm0, edx
    add eax, 117                ; e - 10 + 127
    shl eax, 23
    vmovd xmm1, eax
    vmulss xmm0, xmm0, xmm1
.sign:
    test ecx, 0x80
    jz .put
    vmovd eax, xmm0
    or eax, 0x80000000
    vmovd xmm0, eax
.put:
    vmovss [r9+rcx*4], xmm0
    inc ecx
    cmp ecx, 256
    jb .c
    ret

; xmm0 = y (f32, |y| <= 448) -> eax = the nearest e4m3 code with y's sign, ties
; to the even one. brute force over e4. trashes rcx, rdx, r8-r11, xmm1-3
enc:
    vmovd r10d, xmm0
    shr r10d, 31
    shl r10d, 7                 ; 0 or 0x80
    vcvtss2sd xmm1, xmm0, xmm0
    mov rax, 0x7ff0000000000000
    vmovq xmm3, rax             ; best distance
    xor r11d, r11d
    xor edx, edx
    lea r9, [e4]
.c:
    lea r8d, [r10+r11]
    vcvtss2sd xmm2, xmm2, [r9+r8*4]
    vsubsd xmm2, xmm1, xmm2
    vmovq rax, xmm2
    btr rax, 63
    vmovq xmm2, rax
    vcomisd xmm2, xmm3
    jb .take
    jne .skip
    test r11d, 1
    jnz .skip
.take:
    vmovapd xmm3, xmm2
    mov edx, r8d
.skip:
    inc r11d
    cmp r11d, 127               ; 0x7f is nan
    jb .c
    mov eax, edx
    ret

; rcx = host f32 buffer, edx = count: normal(0, 1)
fill_normal:
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
    call rng_normal
    cvtsd2ss xmm0, xmm0
    movss [rbx+rdi*4], xmm0
    inc edi
    jmp .r
.done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = a, rdx = b (host f32), r8d = count. xmm0 = max |a - b| / max |b|
cmpf:
    mov eax, 0x7fffffff
    vmovd xmm5, eax
    vxorps xmm2, xmm2, xmm2
    vxorps xmm3, xmm3, xmm3
    xor eax, eax
.c:
    vmovss xmm0, [rcx+rax*4]
    vmovss xmm1, [rdx+rax*4]
    vsubss xmm0, xmm0, xmm1
    vandps xmm0, xmm0, xmm5
    vandps xmm1, xmm1, xmm5
    vmaxss xmm2, xmm2, xmm0
    vmaxss xmm3, xmm3, xmm1
    inc eax
    cmp eax, r8d
    jb .c
    vcvtss2sd xmm2, xmm2, xmm2
    vcvtss2sd xmm3, xmm3, xmm3
    vdivsd xmm0, xmm2, xmm3
    ret

; rcx = buffer, edx = bf16 count: widen them to f32 in place, back to front
widen:
    mov eax, edx
.w:
    dec eax
    js .done
    movzx r8d, word [rcx+rax*2]
    shl r8d, 16
    mov [rcx+rax*4], r8d
    jmp .w
.done:
    ret

; ---- the scale layout gemm_mx counts on, from mx_probe: every entry of C says which
; lane and byte its scale came from
t_probe:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    xor r12d, r12d              ; 0 = A, 1 = B
.which:
    xor r13d, r13d              ; wrong entries
    lea rsi, [pairs]
.pair:
    cmp byte [rsi], 0xff
    je .judge
    lea rbx, [kl]
    mov rax, [f_probe]
    mov [rbx+KL_FUNC], rax
    grid 1, 1, 32, 1
    mov rax, [d_c]
    mov [rbx+KL_ARGS], rax
    mov [rbx+KL_ARGS+8], r12
    movzx eax, byte [rsi]
    mov [rbx+KL_ARGS+16], rax
    movzx eax, byte [rsi+1]
    mov [rbx+KL_ARGS+24], rax
    mov rcx, rbx
    call gpu_launch
    call gpu_sync
    mov rcx, [hc]
    mov rdx, [d_c]
    mov r8d, 512
    call gpu_down
    xor edi, edi                ; entry: row edi/8, column edi%8
.e:
    mov rdx, [hc]
    mov eax, [rdx+rdi*4]
    shr eax, 23
    and eax, 0xff
    sub eax, 6                  ; C = 2^5 * 2^(code-127), code - 1 = 4*lane + byte
    movzx ecx, byte [rsi+1]
    test r12d, r12d
    jnz .bexp
    mov r8d, edi                ; A: row r from lane 4(r%8) + r/8 + 2(thread-id&1)
    shr r8d, 3
    mov r9d, r8d
    and r9d, 7
    shl r9d, 2
    shr r8d, 3
    add r9d, r8d
    and ecx, 1
    lea r9d, [r9+rcx*2]
    jmp .cmp
.bexp:
    mov r9d, edi                ; B: column j from lane 4j + thread-id
    and r9d, 7
    shl r9d, 2
    add r9d, ecx
.cmp:
    shl r9d, 2
    movzx ecx, byte [rsi]
    add r9d, ecx
    cmp eax, r9d
    je .same
    inc r13d
.same:
    inc edi
    cmp edi, 128
    jb .e
    add rsi, 2
    jmp .pair
.judge:
    test r12d, r12d
    jnz .jb
    test r13d, r13d
    check z, "A: row r's scale from lane 4(r%8) + r/8 + 2*thread-id, byte byte-id"
    jmp .nextw
.jb:
    test r13d, r13d
    check z, "B: column j's scale from lane 4j + thread-id, byte byte-id"
.nextw:
    inc r12d
    cmp r12d, 2
    jb .which
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- mxq against the cpu. ecx = 8 for f32 input, 0 for bf16. blocks get scales from
; 2^-20 to 2^20, one is all zeros, and two sit right on the 1.75 edge where the scale
; steps up
t_quant:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov r15d, ecx
    mov rbx, [hx]
    xor esi, esi
.fill:
    lea rcx, [rng]
    call rng_normal
    cvtsd2ss xmm0, xmm0
    mov eax, esi
    shr eax, 5
    xor edx, edx
    mov ecx, 41
    div ecx
    lea eax, [rdx+107]          ; 2^(b%41 - 20)
    shl eax, 23
    vmovd xmm1, eax
    vmulss xmm0, xmm0, xmm1
    vmovss [rbx+rsi*4], xmm0
    inc esi
    cmp esi, QR * QC
    jb .fill
    xor eax, eax
.zero:
    mov dword [rbx+rax*4], 0
    inc eax
    cmp eax, 32
    jb .zero
    mov dword [rbx+32*4], 0x41600000        ; 14.0 = 1.75 * 2^3
    mov dword [rbx+69*4], 0xc1600001        ; just past it, negative
    test r15d, r15d
    jnz .up
    ; bf16 input: round every value and keep the rounded ones for the cpu side
    mov rdi, [hy]
    xor esi, esi
.b16:
    mov r8d, [rbx+rsi*4]
    mov r10d, r8d
    shr r10d, 16
    and r10d, 1
    add r8d, 0x7fff
    add r8d, r10d
    shr r8d, 16
    mov [rdi+rsi*2], r8w
    shl r8d, 16
    mov [rbx+rsi*4], r8d
    inc esi
    cmp esi, QR * QC
    jb .b16
    mov rcx, [d_x]
    mov rdx, [hy]
    mov r8d, QR * QC * 2
    call gpu_up
    jmp .run
.up:
    mov rcx, [d_x]
    mov rdx, [hx]
    mov r8d, QR * QC * 4
    call gpu_up
.run:
    lea rbx, [kl]
    mov rax, [f_mxq]
    mov [rbx+KL_FUNC], rax
    grid QB / 256, 1, 256, 1
    mov rax, [d_x]
    mov [rbx+KL_ARGS], rax
    mov rax, [d_qa]
    mov [rbx+KL_ARGS+8], rax
    mov rax, [d_sa]
    mov [rbx+KL_ARGS+16], rax
    mov qword [rbx+KL_ARGS+24], QB
    mov [rbx+KL_ARGS+32], r15
    mov rcx, rbx
    call gpu_launch
    call gpu_sync
    mov rcx, [hq]
    mov rdx, [d_qa]
    mov r8d, QR * QC
    call gpu_down
    mov rcx, [hs]
    mov rdx, [d_sa]
    mov r8d, QB
    call gpu_down

    ; the cpu's turn, a block at a time
    xor r12d, r12d              ; block
    xor r13d, r13d              ; codes or scales that differ
    xor r14d, r14d              ; scales that aren't the smallest that fits
.blk:
    mov rsi, [hx]
    mov eax, r12d
    shl eax, 7
    add rsi, rax                ; the block's 32 floats
    xor eax, eax                ; max |x| as bits
    xor ecx, ecx
.max:
    mov edx, [rsi+rcx*4]
    and edx, 0x7fffffff
    cmp edx, eax
    cmova eax, edx
    inc ecx
    cmp ecx, 32
    jb .max
    mov edi, 127
    test eax, eax
    jz .gots
    mov edi, eax
    shr edi, 23
    mov ecx, eax
    and ecx, 0x7fffff
    cmp ecx, 0x600000
    seta cl
    movzx ecx, cl
    add edi, ecx
    sub edi, 8
    mov ecx, 1
    cmp edi, ecx
    cmovl edi, ecx
    mov ecx, 253
    cmp edi, ecx
    cmovg edi, ecx
    ; the smallest power of two that fits: max/scale <= 448 < 2 max/scale
    mov ecx, 254
    sub ecx, edi
    shl ecx, 23
    vmovd xmm1, ecx
    vmovd xmm0, eax
    vmulss xmm0, xmm0, xmm1
    vcomiss xmm0, [f_448]
    ja .loose
    vaddss xmm0, xmm0, xmm0
    vcomiss xmm0, [f_448]
    ja .gots
.loose:
    inc r14d
.gots:
    mov rax, [hs]
    movzx eax, byte [rax+r12]
    cmp eax, edi
    je .sok
    inc r13d
.sok:
    mov ecx, 254
    sub ecx, edi
    shl ecx, 23
    mov [rsp+32], ecx           ; 1 / scale
    xor ebx, ebx
.el:
    vmovss xmm0, [rsi+rbx*4]
    vmulss xmm0, xmm0, [rsp+32]
    call enc
    mov rdx, [hq]
    mov ecx, r12d
    shl ecx, 5
    add ecx, ebx
    movzx ecx, byte [rdx+rcx]
    cmp eax, ecx
    je .eok
    inc r13d
.eok:
    inc ebx
    cmp ebx, 32
    jb .el
    inc r12d
    cmp r12d, QB
    jb .blk

    test r15d, r15d
    jz .nb16
    test r13d, r13d
    check z, "mxq, f32 in: 65536 values and 2048 scales, the same as the cpu"
    jmp .prop
.nb16:
    test r13d, r13d
    check z, "mxq, bf16 in: 65536 values and 2048 scales, the same as the cpu"
.prop:
    test r14d, r14d
    check z, "every scale is the smallest power of two that fits its block"
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- mm_mx against the cpu: random codes and scales, odd M and N, same fma order
t_mref:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    ; codes into hq (A then B), scales into hs (A then B). no nans
    mov rbx, [hq]
    xor esi, esi
.codes:
    lea rcx, [rng]
    call rng_next
    mov ecx, eax
    and ecx, 0x7f
    cmp ecx, 0x7f
    jne .cok
    xor eax, 1
.cok:
    mov [rbx+rsi], al
    inc esi
    cmp esi, (RM + RN) * RK
    jb .codes
    mov rbx, [hs]
    xor esi, esi
.scales:
    lea rcx, [rng]
    call rng_next
    xor edx, edx
    mov ecx, 15
    div rcx
    add edx, 120                ; 2^-7 .. 2^7
    mov [rbx+rsi], dl
    inc esi
    cmp esi, (RM + RN) * RK / 32
    jb .scales
    mov rcx, [d_qa]
    mov rdx, [hq]
    mov r8d, RM * RK
    call gpu_up
    mov rcx, [d_qb]
    mov rdx, [hq]
    add rdx, RM * RK
    mov r8d, RN * RK
    call gpu_up
    mov rcx, [d_sa]
    mov rdx, [hs]
    mov r8d, RM * RK / 32
    call gpu_up
    mov rcx, [d_sb]
    mov rdx, [hs]
    add rdx, RM * RK / 32
    mov r8d, RN * RK / 32
    call gpu_up
    mov ecx, RM
    mov edx, RN
    mov r8d, RK
    mov r9, [d_r]
    xor eax, eax
    mov qword [rsp+32], 0
    call run_mm
    mov rcx, [hc]
    mov rdx, [d_r]
    mov r8d, RM * RN * 4
    call gpu_down
    ; the same sum on the cpu
    xor r12d, r12d              ; m
    xor r13d, r13d              ; mismatches
    lea r15, [e4]
.m:
    xor r14d, r14d              ; n
.n:
    imul esi, r12d, RK
    add rsi, [hq]               ; A row
    imul edi, r14d, RK
    add rdi, [hq]
    add rdi, RM * RK            ; B row
    vxorps xmm0, xmm0, xmm0
    xor ecx, ecx
.k:
    test ecx, 31
    jnz .v
    ; this block's scales: 2^(s-127) is s in the exponent field
    mov eax, ecx
    shr eax, 5
    imul edx, r12d, RK / 32
    add edx, eax
    mov rbx, [hs]
    movzx edx, byte [rbx+rdx]
    shl edx, 23
    vmovd xmm4, edx
    imul edx, r14d, RK / 32
    add edx, eax
    add edx, RM * RK / 32
    movzx edx, byte [rbx+rdx]
    shl edx, 23
    vmovd xmm5, edx
.v:
    movzx eax, byte [rsi+rcx]
    vmovss xmm1, [r15+rax*4]
    vmulss xmm1, xmm1, xmm4
    movzx eax, byte [rdi+rcx]
    vmovss xmm2, [r15+rax*4]
    vmulss xmm2, xmm2, xmm5
    vfmadd231ss xmm0, xmm1, xmm2
    inc ecx
    cmp ecx, RK
    jb .k
    imul eax, r12d, RN
    add eax, r14d
    mov rdx, [hc]
    vmovd ecx, xmm0
    cmp ecx, [rdx+rax*4]
    je .same
    inc r13d
.same:
    inc r14d
    cmp r14d, RN
    jb .n
    inc r12d
    cmp r12d, RM
    jb .m
    test r13d, r13d
    check z, "mm_mx 70x50x96 = cpu fma loop on the decoded values, bit for bit"
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; mm_mx on d_qa/d_sa x d_qb/d_sb. ecx = M, edx = N, r8d = K, r9 = C, rax = R (or 0),
; [rsp+40] (5th arg) = flags
run_mm:
    push rbx
    sub rsp, 32
    lea rbx, [kl]
    mov [rbx+KL_ARGS+64], rax
    mov eax, [rsp+80]
    mov [rbx+KL_ARGS+72], rax
    mov r10, [f_mm]
    mov [rbx+KL_FUNC], r10
    mov [rbx+KL_ARGS+32], r9
    mov [rbx+KL_ARGS+40], rcx
    mov [rbx+KL_ARGS+48], rdx
    mov [rbx+KL_ARGS+56], r8
    lea eax, [rdx+15]
    shr eax, 4
    mov [rbx+KL_GX], eax
    lea eax, [rcx+15]
    shr eax, 4
    mov [rbx+KL_GY], eax
    mov dword [rbx+KL_GZ], 1
    mov dword [rbx+KL_BX], 16
    mov dword [rbx+KL_BY], 16
    mov dword [rbx+KL_BZ], 1
    jmp mx_go

; gemm_mx, same arguments plus [rsp+48] (6th) = splits
run_gemm:
    push rbx
    sub rsp, 32
    lea rbx, [kl]
    mov [rbx+KL_ARGS+64], rax
    mov eax, [rsp+80]
    mov [rbx+KL_ARGS+72], rax
    mov r10, [f_gemm]
    mov [rbx+KL_FUNC], r10
    mov [rbx+KL_ARGS+32], r9
    mov [rbx+KL_ARGS+40], rcx
    mov [rbx+KL_ARGS+48], rdx
    mov [rbx+KL_ARGS+56], r8
    mov eax, edx
    shr eax, 7
    mov [rbx+KL_GX], eax
    mov eax, ecx
    shr eax, 7
    mov [rbx+KL_GY], eax
    mov eax, [rsp+88]
    mov [rbx+KL_GZ], eax
    mov dword [rbx+KL_BX], 256
    mov dword [rbx+KL_BY], 1
    mov dword [rbx+KL_BZ], 1
mx_go:
    mov rax, [d_qa]
    mov [rbx+KL_ARGS], rax
    mov rax, [d_sa]
    mov [rbx+KL_ARGS+8], rax
    mov rax, [d_qb]
    mov [rbx+KL_ARGS+16], rax
    mov rax, [d_sb]
    mov [rbx+KL_ARGS+24], rax
    mov qword [rbx+KL_STREAM], 0
    mov rcx, rbx
    call gpu_launch
    call gpu_sync
    add rsp, 32
    pop rbx
    ret

; quantize: rcx = f32 device input, edx = values, r8 = q, r9 = s
quant:
    push rbx
    sub rsp, 32
    lea rbx, [kl]
    mov rax, [f_mxq]
    mov [rbx+KL_FUNC], rax
    mov [rbx+KL_ARGS], rcx
    mov [rbx+KL_ARGS+8], r8
    mov [rbx+KL_ARGS+16], r9
    shr edx, 5
    mov [rbx+KL_ARGS+24], rdx
    mov qword [rbx+KL_ARGS+32], 8
    add edx, 255
    shr edx, 8
    grid edx, 1, 256, 1
    mov qword [rbx+KL_STREAM], 0
    mov rcx, rbx
    call gpu_launch
    add rsp, 32
    pop rbx
    ret

; random normal A (M x K) and B (N x K) on the gpu as f32 (d_x, d_y), quantized into
; d_qa/d_sa and d_qb/d_sb. ecx = M, edx = N, r8d = K
mkab:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov ebx, ecx
    imul ebx, r8d               ; A values
    mov esi, edx
    imul esi, r8d               ; B values
    mov rcx, [hx]
    mov edx, ebx
    call fill_normal
    mov rcx, [hy]
    mov edx, esi
    call fill_normal
    mov rcx, [d_x]
    mov rdx, [hx]
    lea r8, [rbx*4]
    call gpu_up
    mov rcx, [d_y]
    mov rdx, [hy]
    lea r8, [rsi*4]
    call gpu_up
    mov rcx, [d_x]
    mov edx, ebx
    mov r8, [d_qa]
    mov r9, [d_sa]
    call quant
    mov rcx, [d_y]
    mov edx, esi
    mov r8, [d_qb]
    mov r9, [d_sb]
    call quant
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- gemm_mx against mm_mx. ecx = M, edx = N, r8d = K, r9 = name for the check
t_gemm:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 72
    mov r12d, ecx
    mov r13d, edx
    mov r14d, r8d
    mov rdi, r9
    call mkab
    mov ecx, r12d
    mov edx, r13d
    mov r8d, r14d
    mov r9, [d_r]
    xor eax, eax
    mov qword [rsp+32], 0
    call run_mm
    mov ecx, r12d
    mov edx, r13d
    mov r8d, r14d
    mov r9, [d_c]
    xor eax, eax
    mov qword [rsp+32], 0
    mov qword [rsp+40], 1
    call run_gemm
    mov ebx, r12d
    imul ebx, r13d
    mov rcx, [hc]
    mov rdx, [d_c]
    lea r8, [rbx*4]
    call gpu_down
    mov rcx, [hd]
    mov rdx, [d_r]
    lea r8, [rbx*4]
    call gpu_down
    mov rcx, [hc]
    mov rdx, [hd]
    mov r8d, ebx
    call cmpf
    vmovsd xmm2, xmm0, xmm0
    vcomisd xmm0, [c_tol]
    setb cl
    movzx ecx, cl
    mov rdx, rdi
    call t_okf
    add rsp, 72
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- after the 1024^3 one: mm_mx's result against mm_ref on the f32 inputs. that's
; the cost of mxfp8 itself, which we only want to see is sane
t_vsf32:
    push rbx
    sub rsp, 32
    lea rbx, [kl]
    mov rax, [f_ref]
    mov [rbx+KL_FUNC], rax
    grid 64, 64, 16, 16
    mov rax, [d_x]
    mov [rbx+KL_ARGS], rax
    mov rax, [d_y]
    mov [rbx+KL_ARGS+8], rax
    mov rax, [d_c]
    mov [rbx+KL_ARGS+16], rax
    mov qword [rbx+KL_ARGS+24], 1024
    mov qword [rbx+KL_ARGS+32], 1024
    mov qword [rbx+KL_ARGS+40], 1024
    mov qword [rbx+KL_ARGS+48], 0
    mov qword [rbx+KL_ARGS+56], 8           ; f32 in
    mov rcx, rbx
    call gpu_launch
    call gpu_sync
    mov rcx, [hc]
    mov rdx, [d_c]
    mov r8d, 1024 * 1024 * 4
    call gpu_down
    mov rcx, [hd]               ; mm_mx's, still in hd
    mov rdx, [hc]
    mov r8d, 1024 * 1024
    call cmpf
    vmovsd xmm2, xmm0, xmm0
    vcomisd xmm0, [c_tolq]
    setb cl
    movzx ecx, cl
    lea rdx, [m_q]
    call t_okf
    add rsp, 32
    pop rbx
    ret

section .rdata
m_q   db "mxfp8 1024^3 against the f32 product, max error over max value", 0
m_spl db "gemm_mx 256x256x2048 split 4 ways, partials summed = mm_mx", 0
m_b16 db "gemm_mx 256x384x512, C = R + A B^T as bf16 = mm_mx", 0
section .text

; ---- split k: 4 partials into d_c, added up on the cpu
t_split:
    push rbx
    push rsi
    sub rsp, 56
    mov ecx, 256
    mov edx, 256
    mov r8d, 2048
    call mkab
    mov ecx, 256
    mov edx, 256
    mov r8d, 2048
    mov r9, [d_r]
    xor eax, eax
    mov qword [rsp+32], 0
    call run_mm
    mov ecx, 256
    mov edx, 256
    mov r8d, 2048
    mov r9, [d_c]
    xor eax, eax
    mov qword [rsp+32], 0
    mov qword [rsp+40], 4
    call run_gemm
    mov rcx, [hc]
    mov rdx, [d_c]
    mov r8d, 4 * 256 * 256 * 4
    call gpu_down
    mov rcx, [hd]
    mov rdx, [d_r]
    mov r8d, 256 * 256 * 4
    call gpu_down
    mov rsi, [hc]
    xor eax, eax
.sum:
    vmovss xmm0, [rsi+rax*4]
    vaddss xmm0, xmm0, [rsi+rax*4+256*256*4]
    vaddss xmm0, xmm0, [rsi+rax*4+2*256*256*4]
    vaddss xmm0, xmm0, [rsi+rax*4+3*256*256*4]
    vmovss [rsi+rax*4], xmm0
    inc eax
    cmp eax, 256 * 256
    jb .sum
    mov rcx, [hc]
    mov rdx, [hd]
    mov r8d, 256 * 256
    call cmpf
    vmovsd xmm2, xmm0, xmm0
    vcomisd xmm0, [c_tol]
    setb cl
    movzx ecx, cl
    lea rdx, [m_spl]
    call t_okf
    add rsp, 56
    pop rsi
    pop rbx
    ret

; ---- bf16 C with R added: both kernels, compared as floats
t_bf16r:
    push rbx
    sub rsp, 48
    mov ecx, 256
    mov edx, 384
    mov r8d, 512
    call mkab
    mov rcx, [hc]
    mov edx, 256 * 384
    call fill_normal
    mov rcx, [d_r2]
    mov rdx, [hc]
    mov r8d, 256 * 384 * 4
    call gpu_up
    mov ecx, 256
    mov edx, 384
    mov r8d, 512
    mov r9, [d_r]
    mov rax, [d_r2]
    mov qword [rsp+32], 4
    call run_mm
    mov ecx, 256
    mov edx, 384
    mov r8d, 512
    mov r9, [d_c]
    mov rax, [d_r2]
    mov qword [rsp+32], 4
    mov qword [rsp+40], 1
    call run_gemm
    mov rcx, [hc]
    mov rdx, [d_c]
    mov r8d, 256 * 384 * 2
    call gpu_down
    mov rcx, [hd]
    mov rdx, [d_r]
    mov r8d, 256 * 384 * 2
    call gpu_down
    mov rcx, [hc]
    mov edx, 256 * 384
    call widen
    mov rcx, [hd]
    mov edx, 256 * 384
    call widen
    mov rcx, [hc]
    mov rdx, [hd]
    mov r8d, 256 * 384
    call cmpf
    vmovsd xmm2, xmm0, xmm0
    vcomisd xmm0, [c_tol16]
    setb cl
    movzx ecx, cl
    lea rdx, [m_b16]
    call t_okf
    add rsp, 48
    pop rbx
    ret
