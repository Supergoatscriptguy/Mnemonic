; gpubench: how fast this gpu is for us. pcie, vram, launches, copy/compute
; overlap, tensor core peaks (bf16, fp8, fp4), and the matmul on the shapes the
; model will use
; uses: gpu\cuda gpu\kernels
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"

extern ExitProcess
extern ptx_basic, ptx_basic_end, ptx_gemm, ptx_gemm_end, ptx_bench, ptx_bench_end
extern ptx_bench8, ptx_bench8_end, ptx_benchmx, ptx_benchmx_end

HOSTB  equ 256 << 20            ; pcie test size
VRAMB  equ 512 << 20            ; each side of the vram copy
ABYTES equ 1024 << 20           ; gemm operands, big enough for dlogits
CBYTES equ 2048 << 20           ; gemm output, big enough for the logits

section .rdata
k_copy16 db "copy16", 0
k_busy   db "busy", 0
k_empty  db "empty", 0
k_ref    db "gemm_ref", 0
k_mma1   db "gemm_mma1", 0
k_tc     db "gemm_tc", 0
k_peak   db "mma_peak", 0
k_e4m3   db "mma_e4m3", 0
k_e4m3h  db "mma_e4m3h", 0
k_mxf8   db "mma_mxf8", 0
k_nvf4   db "mma_nvf4", 0
k_mxf4   db "mma_mxf4", 0
align 8
; the tensor core rows: where the module is, kernel, flops per mma per warp, label.
; the first one is what the matmuls' "% of peak" means
mmas:
    dq m_bf16, k_peak, 4096, t_bf16
    dq m_fp8, k_e4m3, 8192, t_e4m3
    dq m_fp8, k_e4m3h, 8192, t_e4m3h
    dq m_mx, k_mxf8, 8192, t_mxf8
    dq m_mx, k_nvf4, 16384, t_nvf4
    dq m_mx, k_mxf4, 16384, t_mxf4
    dq 0
t_bf16  db "bf16  -> f32  m16n8k16  ", 0
t_e4m3  db "e4m3  -> f32  m16n8k32  ", 0
t_e4m3h db "e4m3  -> f16  m16n8k32  ", 0
t_mxf8  db "mxfp8 -> f32  m16n8k32  ", 0
t_nvf4  db "nvfp4 -> f32  m16n8k64  ", 0
t_mxf4  db "mxfp4 -> f32  m16n8k64  ", 0
align 8
c_1e3    dq 1000.0
c_1e9    dq 1e9
c_1e12   dq 1e12
c_1e6    dq 1e6
c_ftok   dq 8.3e8               ; training flops per token for main, fwd + bwd (6N + attention)
c_toks   dq 5e9
; gemm shapes: M, N, K, label, how many of it one training step of main does
; (16 layers, one logits), and the layout flags (gemm_tc: 1 = A stored [K][M],
; 2 = B stored [K][N]). the model ones use 16 x 1024 tokens. weight gradients (both
; flags) also add into what's there, like training does
shapes:
    dq 4096, 4096, 4096, s_sq4, 0, 0
    dq 8192, 8192, 8192, s_sq8, 0, 0
    dq 16384, 1280, 768, s_qkv, 16, 0
    dq 16384, 768, 768, s_proj, 16, 0
    dq 16384, 4096, 768, s_up, 16, 0
    dq 16384, 768, 2048, s_down, 16, 0
    dq 16384, 32768, 768, s_logit, 1, 0
    dq 16384, 768, 1280, s_qkvx, 16, 2
    dq 16384, 768, 768, s_projx, 16, 2
    dq 16384, 768, 4096, s_upx, 16, 2
    dq 16384, 2048, 768, s_downx, 16, 2
    dq 16384, 768, 32768, s_logitx, 1, 2
    dq 1280, 768, 16384, s_qkvw, 16, 3
    dq 768, 768, 16384, s_projw, 16, 3
    dq 4096, 768, 16384, s_upw, 16, 3
    dq 768, 2048, 16384, s_downw, 16, 3
    dq 32768, 768, 16384, s_logitw, 1, 3
    dq 0
s_sq4   db "4096 x 4096 x 4096       ", 0
s_sq8   db "8192 x 8192 x 8192       ", 0
s_qkv   db "qkv       16384x1280x768 ", 0
s_proj  db "attn out  16384x768x768  ", 0
s_up    db "mlp up    16384x4096x768 ", 0
s_down  db "mlp down  16384x768x2048 ", 0
s_logit db "logits    16384x32768x768", 0
s_qkvx   db "qkv dx    16384x768x1280 ", 0
s_projx  db "attn dx   16384x768x768  ", 0
s_upx    db "mlp up dx 16384x768x4096 ", 0
s_downx  db "mlp dn dx 16384x2048x768 ", 0
s_logitx db "logits dx 16384x768x32768", 0
s_qkvw   db "qkv dW    1280x768x16384 ", 0
s_projw  db "attn dW   768x768x16384  ", 0
s_upw    db "mlp up dW 4096x768x16384 ", 0
s_downw  db "mlp dn dW 768x2048x16384 ", 0
s_logitw db "embed dW  32768x768x16384", 0

section .bss
alignb 8
kl       resb KL_SIZE
f_copy   resq 1
f_busy   resq 1
f_empty  resq 1
f_ref    resq 1
f_mma1   resq 1
f_tc     resq 1
m_bf16   resq 1
m_fp8    resq 1                 ; 0 if the jit wouldn't take it
m_mx     resq 1
s1       resq 1
s2       resq 1
gA       resq 1
gW       resq 1
gC       resq 1
peak     resq 1                 ; tflops, for the percentages
mixt     resq 1                 ; ms for one pass of the model shapes
mixf     resq 1                 ; and their flops

section .text

%macro getf 3
    mov rcx, %1
    lea rdx, [%2]
    call gpu_func
    mov [%3], rax
%endmacro

; xmm0 = seconds -> prints it as GB/s for rbx bytes
%macro gbs 0
    cvtsi2sd xmm1, rbx
    divsd xmm1, xmm0
    divsd xmm1, [c_1e9]
    movapd xmm0, xmm1
    mov edx, 1
    call print_fixed
    say " GB/s"
%endmacro

global start
start:
    sub rsp, 40
    call lib_init
    call gpu_init
    lea rcx, [gpu_name]
    call print_z
    say ", "
    mov ecx, [gpu_nsm]
    call print_dec
    say " SMs", 13, 10
    lea rcx, [ptx_basic]
    lea rdx, [ptx_basic_end]
    sub rdx, rcx
    call gpu_module
    mov r12, rax
    getf r12, k_copy16, f_copy
    getf r12, k_busy, f_busy
    getf r12, k_empty, f_empty
    lea rcx, [ptx_gemm]
    lea rdx, [ptx_gemm_end]
    sub rdx, rcx
    call gpu_module
    mov r12, rax
    getf r12, k_ref, f_ref
    getf r12, k_mma1, f_mma1
    getf r12, k_tc, f_tc
    lea rcx, [ptx_bench]
    lea rdx, [ptx_bench_end]
    sub rdx, rcx
    call gpu_module
    mov [m_bf16], rax
    ; fp8 needs sm_89, the block-scaled ones sm_120a. go on without them if need be
    mov dword [gpu_soft], 1
    lea rcx, [ptx_bench8]
    lea rdx, [ptx_bench8_end]
    sub rdx, rcx
    call gpu_module
    mov [m_fp8], rax
    mov dword [gpu_arch], 1
    lea rcx, [ptx_benchmx]
    lea rdx, [ptx_benchmx_end]
    sub rdx, rcx
    call gpu_module
    mov [m_mx], rax
    mov dword [gpu_arch], 0
    mov dword [gpu_soft], 0
    lea rcx, [s1]
    mov edx, 1                  ; CU_STREAM_NON_BLOCKING
    CU cuStreamCreate
    lea rcx, [s2]
    mov edx, 1
    CU cuStreamCreate

    call pcie
    call vram
    call launches
    call overlap
    call tensor
    call matmuls
    call con_restore
    xor ecx, ecx
    call ExitProcess

; ---- host <-> device, pageable vs pinned. best of 5 for each
pcie:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    say 13, 10, "pcie, 256 MB copies (best of 5)", 13, 10
    mov ecx, HOSTB
    call gpu_alloc
    mov r12, rax
    mov ebx, HOSTB
    mov ecx, HOSTB
    call mem_alloc
    mov rsi, rax
    mov ecx, HOSTB
    call gpu_host
    mov rdi, rax
    say "  pageable   up "
    mov rcx, rsi
    xor edx, edx
    call xfer
    gbs
    say "   down "
    mov rcx, rsi
    mov edx, 1
    call xfer
    gbs
    say 13, 10, "  pinned     up "
    mov rcx, rdi
    xor edx, edx
    call xfer
    gbs
    say "   down "
    mov rcx, rdi
    mov edx, 1
    call xfer
    gbs
    say 13, 10
    mov rcx, r12
    call gpu_free
    mov rcx, rsi
    call mem_free
    mov rcx, rdi
    CU cuMemFreeHost
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = host buffer, edx = 1 for down, r12 = device buffer. xmm0 = best seconds of 5
xfer:
    push rbx
    push rsi
    push rdi
    push r13
    sub rsp, 56
    mov rsi, rcx
    mov edi, edx
    mov rax, 0x7ff0000000000000
    mov [rsp+40], rax           ; best
    mov r13d, 5
.rep:
    call time_now
    mov rbx, rax
    test edi, edi
    jnz .down
    mov rcx, r12
    mov rdx, rsi
    mov r8d, HOSTB
    call gpu_up
    jmp .t
.down:
    mov rcx, rsi
    mov rdx, r12
    mov r8d, HOSTB
    call gpu_down
.t:
    mov rcx, rbx
    call time_since
    minsd xmm0, [rsp+40]
    movsd [rsp+40], xmm0
    dec r13d
    jnz .rep
    movsd xmm0, [rsp+40]
    add rsp, 56
    pop r13
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- vram: copy16 on 512 MB, read + write both count
vram:
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    say 13, 10, "vram", 13, 10
    mov ecx, VRAMB
    call gpu_alloc
    mov rsi, rax
    mov ecx, VRAMB
    call gpu_alloc
    mov rdi, rax
    lea rbx, [kl]
    mov rax, [f_copy]
    mov [rbx+KL_FUNC], rax
    mov eax, [gpu_nsm]
    shl eax, 3                  ; 8 blocks per SM, grid-stride does the rest
    grid eax, 1, 256, 1
    mov [rbx+KL_ARGS], rdi
    mov [rbx+KL_ARGS+8], rsi
    mov qword [rbx+KL_ARGS+16], VRAMB / 16
    mov qword [rbx+KL_STREAM], 0
    mov rcx, rbx
    call gpu_launch             ; warm up
    xor ecx, ecx
    call gpu_tstart
    mov ebx, 10
.r:
    lea rcx, [kl]
    call gpu_launch
    dec ebx
    jnz .r
    xor ecx, ecx
    call gpu_tstop
    divsd xmm0, [c_1e3]
    mov rax, 10
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1            ; seconds per copy
    movsd [rsp+32], xmm0        ; xmm0-5 don't survive calls, say included
    say "  copy16 kernel, 512 MB -> 512 MB: "
    mov ebx, VRAMB * 2
    movsd xmm0, [rsp+32]
    gbs
    say "   ("
    ; percent of the theoretical: memclock kHz * 2 * bits / 8
    mov ecx, CA_MEM_CLOCK
    call gpu_attr
    mov ebx, eax
    mov ecx, CA_BUS_WIDTH
    call gpu_attr
    imul rax, rbx
    shr rax, 2
    imul rax, rax, 1000
    cvtsi2sd xmm1, rax
    mov ebx, VRAMB * 2
    cvtsi2sd xmm0, rbx
    divsd xmm0, [rsp+32]
    divsd xmm0, xmm1
    mulsd xmm0, [c_100]
    mov edx, 0
    call print_fixed
    say "% of peak)", 13, 10
    mov rcx, rsi
    call gpu_free
    mov rcx, rdi
    call gpu_free
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- launch cost: queued back to back, and launch + wait each time
launches:
    push rbx
    push rsi
    sub rsp, 40
    say 13, 10, "kernel launches (empty kernel)", 13, 10
    lea rbx, [kl]
    mov rax, [f_empty]
    mov [rbx+KL_FUNC], rax
    grid 1, 1, 32, 1
    mov rcx, rbx
    call gpu_launch
    call gpu_sync
    say "  queued:        "
    call time_now
    mov rsi, rax
    mov ebx, 20000
.q:
    lea rcx, [kl]
    call gpu_launch
    dec ebx
    jnz .q
    call gpu_sync
    mov rcx, rsi
    call time_since
    mulsd xmm0, [c_1e6]
    mov rax, 20000
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    mov edx, 2
    call print_fixed
    say " us each", 13, 10
    say "  launch + wait: "
    call time_now
    mov rsi, rax
    mov ebx, 2000
.w:
    lea rcx, [kl]
    call gpu_launch
    call gpu_sync
    dec ebx
    jnz .w
    mov rcx, rsi
    call time_since
    mulsd xmm0, [c_1e6]
    mov rax, 2000
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    mov edx, 2
    call print_fixed
    say " us each", 13, 10
    add rsp, 40
    pop rsi
    pop rbx
    ret

; ---- copy on one stream while a kernel runs on another. this is what the data
; loader will lean on: the next batch uploads while the current one trains
overlap:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 64
    say 13, 10, "copy / compute overlap (pinned upload on one stream, busy kernel on another)", 13, 10
    mov ecx, HOSTB
    call gpu_host
    mov rsi, rax
    mov ecx, HOSTB
    call gpu_alloc
    mov rdi, rax
    mov ecx, 4 << 20
    call gpu_alloc
    mov r12, rax
    ; first touches of fresh memory are slow, get them out of the way
    call copy_run
    mov r13d, 4096
    call busy_run
    ; the copy alone
    call copy_run
    movsd [rsp+32], xmm0
    ; size the kernel to take about as long
    call busy_run
    movsd xmm1, [rsp+32]
    divsd xmm1, xmm0
    cvtsi2sd xmm0, r13
    mulsd xmm0, xmm1
    cvttsd2si r13, xmm0
    call busy_run
    movsd [rsp+40], xmm0
    ; both at once
    call time_now
    mov rbx, rax
    call up_async
    call busy_launch
    mov rcx, [s1]
    CU cuStreamSynchronize
    mov rcx, [s2]
    CU cuStreamSynchronize
    mov rcx, rbx
    call time_since
    movsd [rsp+48], xmm0
    say "  copy alone "
    movsd xmm0, [rsp+32]
    call pms
    say ", kernel alone "
    movsd xmm0, [rsp+40]
    call pms
    say ", both "
    movsd xmm0, [rsp+48]
    call pms
    say 13, 10, "  -> "
    ; how much of the shorter one got hidden
    movsd xmm0, [rsp+32]
    addsd xmm0, [rsp+40]
    subsd xmm0, [rsp+48]
    movsd xmm1, [rsp+32]
    minsd xmm1, [rsp+40]
    divsd xmm0, xmm1
    mulsd xmm0, [c_100]
    mov edx, 0
    call print_fixed
    say "% of the smaller one hidden behind the other", 13, 10
    mov rcx, rsi
    CU cuMemFreeHost
    mov rcx, rdi
    call gpu_free
    mov rcx, r12
    call gpu_free
    add rsp, 64
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; pinned rsi -> device rdi on stream s1
up_async:
    sub rsp, 40
    mov rcx, rdi
    mov rdx, rsi
    mov r8d, HOSTB
    mov r9, [s1]
    CU cuMemcpyHtoDAsync
    add rsp, 40
    ret

; xmm0 = seconds for one up_async on its own
copy_run:
    push rbx
    sub rsp, 32
    call time_now
    mov rbx, rax
    call up_async
    mov rcx, [s1]
    CU cuStreamSynchronize
    mov rcx, rbx
    call time_since
    add rsp, 32
    pop rbx
    ret

; busy kernel with r13 rounds on stream s2, out to r12
busy_launch:
    push rbx
    sub rsp, 32
    lea rbx, [kl]
    mov rax, [f_busy]
    mov [rbx+KL_FUNC], rax
    mov eax, [gpu_nsm]
    shl eax, 2
    grid eax, 1, 256, 1
    mov [rbx+KL_ARGS], r12
    mov [rbx+KL_ARGS+8], r13
    mov rax, [s2]
    mov [rbx+KL_STREAM], rax
    mov rcx, rbx
    call gpu_launch
    mov qword [rbx+KL_STREAM], 0
    add rsp, 32
    pop rbx
    ret

; xmm0 = seconds for one busy_launch on its own
busy_run:
    push rbx
    sub rsp, 32
    call time_now
    mov rbx, rax
    call busy_launch
    mov rcx, [s2]
    CU cuStreamSynchronize
    mov rcx, rbx
    call time_since
    add rsp, 32
    pop rbx
    ret

; xmm0 = seconds, printed as ms
pms:
    sub rsp, 40
    mulsd xmm0, [c_1e3]
    mov edx, 1
    call print_fixed
    say " ms"
    add rsp, 40
    ret

; ---- tensor core peaks, a row per mma type. exactly one full wave of blocks on
; every SM, and every warp keeps 8 mma chains going without touching memory
PITERS equ 40000
tensor:
    push rbx
    push rdi
    push r12
    push r13
    sub rsp, 72
    say 13, 10, "tensor cores, peak per mma.sync type", 13, 10
    mov ecx, 4 << 20
    call gpu_alloc
    mov r12, rax
    lea rdi, [mmas]
.row:
    cmp qword [rdi], 0
    je .done
    say "  "
    mov rcx, [rdi+24]
    call print_z
    mov rax, [rdi]
    mov rcx, [rax]
    test rcx, rcx
    jz .no
    mov rdx, [rdi+8]
    call gpu_func
    lea rbx, [kl]
    mov [rbx+KL_FUNC], rax
    lea rcx, [rsp+64]
    mov rdx, rax
    mov r8d, 256
    xor r9d, r9d
    CU cuOccupancy
    mov r13d, [rsp+64]
    imul r13d, [gpu_nsm]        ; blocks, all resident at once
    grid r13d, 1, 256, 1
    mov [rbx+KL_ARGS], r12
    mov qword [rbx+KL_ARGS+8], 1000
    lea rax, [r12 + (3 << 20)]  ; the clock count goes here
    mov [rbx+KL_ARGS+16], rax
    mov qword [rbx+KL_STREAM], 0
    mov rcx, rbx
    call gpu_launch             ; warm up (and let the clocks come up)
    call gpu_sync
    mov qword [rbx+KL_ARGS+8], PITERS
    xor ecx, ecx
    call gpu_tstart
    mov rcx, rbx
    call gpu_launch
    xor ecx, ecx
    call gpu_tstop
    ; flops = blocks * 8 warps * iters * 8 mma * flops per mma
    cvtsi2sd xmm1, r13
    mov rax, [rdi+16]
    imul rax, rax, 8 * 8 * PITERS
    cvtsi2sd xmm2, rax
    mulsd xmm1, xmm2
    divsd xmm0, [c_1e3]
    divsd xmm1, xmm0
    divsd xmm1, [c_1e12]
    movsd [rsp+56], xmm1
    cmp qword [peak], 0
    jne .p
    movsd [peak], xmm1
.p:
    movsd xmm0, [rsp+56]
    mov edx, 1
    call print_fixed
    say " TFLOPS  "
    movsd xmm0, [rsp+56]
    divsd xmm0, [peak]
    mov edx, 2
    call print_fixed
    say "x  at "
    ; the sm clock it actually ran at: one thread's cycles over its own nanoseconds
    lea rcx, [rsp+32]
    lea rdx, [r12 + (3 << 20)]
    mov r8d, 16
    call gpu_down
    cvtsi2sd xmm0, qword [rsp+32]
    cvtsi2sd xmm1, qword [rsp+40]
    divsd xmm0, xmm1
    movsd [rsp+48], xmm0        ; ghz
    mov edx, 2
    call print_fixed
    say " GHz = "
    ; per SM per clock, which is the tensor core width for this type
    movsd xmm0, [rsp+56]
    mulsd xmm0, [c_1e3]         ; tflops / ghz = kflops per clock
    divsd xmm0, [rsp+48]
    mov eax, [gpu_nsm]
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    mov edx, 0
    call print_fixed
    say " flops per SM per clock", 13, 10
    jmp .next
.no:
    say "the jit won't take it here", 13, 10
.next:
    add rdi, 32
    jmp .row
.done:
    mov rcx, r12
    call gpu_free
    add rsp, 72
    pop r13
    pop r12
    pop rdi
    pop rbx
    ret

; ---- matmuls: square ones and the model's own shapes
matmuls:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    say 13, 10, "matmul, C = A * W^T, bf16 in, fp32 out (average of 5 after a warm up)", 13, 10
    mov ecx, ABYTES
    call gpu_alloc
    mov [gA], rax
    mov ecx, ABYTES
    call gpu_alloc
    mov [gW], rax
    mov ecx, CBYTES
    call gpu_alloc
    mov [gC], rax
    ; some real looking data: bf16 in [-1, 1), same pair everywhere is fine for timing
    mov rcx, [gA]
    mov edx, 0x3f003e80
    mov r8d, ABYTES / 4
    CU cuMemsetD32
    mov rcx, [gW]
    mov edx, 0xbe803f00
    mov r8d, ABYTES / 4
    CU cuMemsetD32

    ; the naive ones on 4096^3 for perspective
    say "  4096^3  gemm_ref (plain fma)     "
    xor r15d, r15d
    mov r12d, 4096
    mov r13d, 4096
    mov r14d, 4096
    xor esi, esi
    mov edi, 1
    call timed
    call ptf
    say 13, 10, "  4096^3  gemm_mma1 (no tiling)    "
    mov esi, 1
    mov edi, 2
    call timed
    call ptf
    say 13, 10
    lea rbx, [shapes]
    xor eax, eax
    mov [mixt], rax
    mov [mixf], rax
.s:
    mov r12, [rbx]
    test r12, r12
    jz .done
    mov r13, [rbx+8]
    mov r14, [rbx+16]
    mov r15, [rbx+40]
    say "  "
    mov rcx, [rbx+24]
    call print_z
    say "  "
    mov esi, 2
    mov edi, 5
    call timed
    call ptf
    ; add it into a whole forward pass, as many times as the model runs it
    cvtsi2sd xmm2, qword [rbx+32]
    mulsd xmm0, xmm2
    addsd xmm0, [mixt]
    movsd [mixt], xmm0
    cvtsi2sd xmm0, r12
    cvtsi2sd xmm1, r13
    mulsd xmm0, xmm1
    cvtsi2sd xmm1, r14
    mulsd xmm0, xmm1
    addsd xmm0, xmm0
    cvtsi2sd xmm2, qword [rbx+32]
    mulsd xmm0, xmm2
    addsd xmm0, [mixf]
    movsd [mixf], xmm0
    say 13, 10
    add rbx, 48
    jmp .s
.done:
    ; what that says about training main on 5b tokens
    movsd xmm0, [mixf]
    divsd xmm0, [mixt]
    divsd xmm0, [c_1e9]         ; mixf/ms -> tflops
    movsd [mixt], xmm0
    say 13, 10, "  all the matmuls of a training step of main (forward + backward): "
    movsd xmm0, [mixt]
    mov edx, 1
    call print_fixed
    say " TFLOPS. at that rate, main (126M) on 5B tokens is ~"
    movsd xmm0, [c_toks]
    mulsd xmm0, [c_ftok]
    movsd xmm1, [mixt]
    mulsd xmm1, [c_1e12]
    divsd xmm0, xmm1
    mov rax, 0x40ac200000000000     ; 3600
    movq xmm1, rax
    divsd xmm0, xmm1
    mov edx, 1
    call print_fixed
    say " hours of pure matmul", 13, 10
    mov rcx, [gA]
    call gpu_free
    mov rcx, [gW]
    call gpu_free
    mov rcx, [gC]
    call gpu_free
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; esi = which (0 ref, 1 mma1, 2 tc), edi = runs, r12/r13/r14 = M/N/K, r15 = layout flags.
; xmm0 = ms per run (after one warm up run)
timed:
    push rbx
    sub rsp, 32
    lea rbx, [kl]
    mov rax, [gA]
    mov [rbx+KL_ARGS], rax
    mov rax, [gW]
    mov [rbx+KL_ARGS+8], rax
    mov rax, [gC]
    mov [rbx+KL_ARGS+16], rax
    mov [rbx+KL_ARGS+24], r12
    mov [rbx+KL_ARGS+32], r13
    mov [rbx+KL_ARGS+40], r14
    mov [rbx+KL_ARGS+56], r15
    xor eax, eax
    test r15d, 1
    jz .nor
    mov rax, [gC]              ; weight gradients add up
.nor:
    mov [rbx+KL_ARGS+48], rax
    mov dword [rbx+KL_GZ], 1
    mov dword [rbx+KL_BZ], 1
    mov qword [rbx+KL_STREAM], 0
    cmp esi, 1
    je .mma1
    ja .tc
    mov rax, [f_ref]
    mov [rbx+KL_FUNC], rax
    lea eax, [r13+15]
    shr eax, 4
    mov [rbx+KL_GX], eax
    lea eax, [r12+15]
    shr eax, 4
    mov [rbx+KL_GY], eax
    mov dword [rbx+KL_BX], 16
    mov dword [rbx+KL_BY], 16
    jmp .go
.mma1:
    mov rax, [f_mma1]
    mov [rbx+KL_FUNC], rax
    mov eax, r13d
    shr eax, 3
    mov [rbx+KL_GX], eax
    mov eax, r12d
    shr eax, 4
    mov [rbx+KL_GY], eax
    mov dword [rbx+KL_BX], 32
    mov dword [rbx+KL_BY], 1
    jmp .go
.tc:
    mov rax, [f_tc]
    mov [rbx+KL_FUNC], rax
    mov eax, r13d
    shr eax, 7
    mov [rbx+KL_GX], eax
    mov eax, r12d
    shr eax, 7
    mov [rbx+KL_GY], eax
    mov dword [rbx+KL_BX], 256
    mov dword [rbx+KL_BY], 1
.go:
    mov rcx, rbx
    call gpu_launch
    xor ecx, ecx
    call gpu_tstart
    mov ebx, edi
.r:
    lea rcx, [kl]
    call gpu_launch
    dec ebx
    jnz .r
    xor ecx, ecx
    call gpu_tstop
    cvtsi2sd xmm1, rdi
    divsd xmm0, xmm1
    add rsp, 32
    pop rbx
    ret

; xmm0 = ms for an M x N x K (r12, r13, r14) matmul. prints ms, TFLOPS, % of peak.
; keeps xmm0
ptf:
    sub rsp, 56
    movsd [rsp+32], xmm0
    mov edx, 2
    call print_fixed
    say " ms  "
    cvtsi2sd xmm0, r12
    cvtsi2sd xmm1, r13
    mulsd xmm0, xmm1
    cvtsi2sd xmm1, r14
    mulsd xmm0, xmm1
    addsd xmm0, xmm0            ; 2 flops per multiply-add
    divsd xmm0, [rsp+32]
    divsd xmm0, [c_1e9]
    movsd [rsp+40], xmm0
    mov edx, 1
    call print_fixed
    say " TFLOPS  "
    movsd xmm0, [rsp+40]
    divsd xmm0, [peak]
    mulsd xmm0, [c_100]
    mov edx, 0
    call print_fixed
    say "% of peak"
    movsd xmm0, [rsp+32]
    add rsp, 56
    ret

section .rdata
align 8
c_100 dq 100.0
