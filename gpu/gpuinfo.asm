; gpuinfo: what the gpu is, and what the driver's jit makes of our kernels
; (registers, spills, shared memory per kernel)
; uses: gpu\cuda gpu\kernels
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"

extern ExitProcess
extern ptx_basic, ptx_basic_end, ptx_gemm, ptx_gemm_end, ptx_bench, ptx_bench_end

section .text

; a row of the kernel table
%macro kinfo 2
    lea rcx, [%1]
    mov edx, %2
    call kernel
%endmacro

; print attribute ecx as a number (or ?)
%macro attr 1
    mov ecx, %1
    call gpu_attr
    mov ecx, eax
    call pnum
%endmacro

global start
start:
    sub rsp, 40
    call lib_init
    call gpu_init
    lea rcx, [gpu_name]
    call print_z
    say 13, 10, "  compute capability "
    mov ecx, [gpu_ccmaj]
    call print_dec
    say "."
    mov ecx, [gpu_ccmin]
    call print_dec
    say ", driver cuda "
    mov eax, [gpu_drv]
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov ebx, edx
    mov ecx, eax
    call print_dec
    say "."
    mov eax, ebx
    xor edx, edx
    mov ecx, 10
    div ecx
    mov ecx, eax
    call print_dec
    say ", ptx isa "
    lea rcx, [gpu_ptxver]
    call print_z
    say " for "
    lea rcx, [gpu_target]
    call print_z

    say 13, 10, "  "
    mov ecx, [gpu_nsm]
    call print_dec
    say " SMs, each: "
    attr CA_MAX_THREADS_SM
    say " threads, "
    attr CA_MAX_BLOCKS_SM
    say " blocks, "
    mov ecx, CA_REGS_SM
    call gpu_attr
    mov ecx, eax
    shr ecx, 10
    call print_dec
    say "K registers, "
    mov ecx, CA_SMEM_SM
    call gpu_attr
    mov ecx, eax
    shr ecx, 10
    call print_dec
    say " KB shared (up to "
    mov ecx, CA_SMEM_OPTIN
    call gpu_attr
    mov ecx, eax
    shr ecx, 10
    call print_dec
    say " KB per block)"

    say 13, 10, "  core clock "
    mov ecx, CA_CLOCK
    call gpu_attr
    call pghz
    say ", memory "
    mov ecx, CA_MEM_CLOCK
    call gpu_attr
    mov ebx, eax
    lea eax, [rax+rax]          ; double data rate
    call pghz
    say " x "
    mov ecx, CA_BUS_WIDTH
    call gpu_attr
    mov esi, eax
    mov ecx, eax
    call print_dec
    say " bit = "
    ; bandwidth: kHz * 1000 * 2 * bits / 8, in GB/s
    cmp ebx, -1
    je .nobw
    cmp esi, -1
    je .nobw
    mov eax, ebx
    imul rax, rsi
    shr rax, 2                  ; * 2 / 8
    xor edx, edx
    mov ecx, 1000000
    div rcx
    mov rcx, rax
    call print_dec
    say " GB/s peak"
    jmp .l2
.nobw:
    say "?"
.l2:
    say 13, 10, "  L2 "
    mov ecx, CA_L2
    call gpu_attr
    mov ecx, eax
    shr ecx, 20
    call print_dec
    say " MB, VRAM "
    cvtsi2sd xmm0, qword [gpu_vram]
    mov rax, 0x3e10000000000000     ; 2^-30
    movq xmm1, rax
    mulsd xmm0, xmm1
    mov edx, 1
    call print_fixed
    say " GiB ("
    call gpu_meminfo
    cvtsi2sd xmm0, rax
    mov rax, 0x3e10000000000000
    movq xmm1, rax
    mulsd xmm0, xmm1
    mov edx, 1
    call print_fixed
    say " free), "
    attr CA_ASYNC_ENGINES
    say " copy engines", 13, 10, 13, 10

    say "our kernels, as the jit built them for this gpu:", 13, 10
    say "  kernel       block  regs  shared   spill  blocks/SM  occupancy", 13, 10
    lea rcx, [ptx_basic]
    lea rdx, [ptx_basic_end]
    sub rdx, rcx
    call gpu_module
    mov rbx, rax
    kinfo k_vadd, 256
    kinfo k_copy16, 256
    kinfo k_f2bf, 256
    kinfo k_busy, 256
    kinfo k_empty, 32
    lea rcx, [ptx_gemm]
    lea rdx, [ptx_gemm_end]
    sub rdx, rcx
    call gpu_module
    mov rbx, rax
    kinfo k_ref, 256
    kinfo k_mma1, 32
    kinfo k_tc, 256
    lea rcx, [ptx_bench]
    lea rdx, [ptx_bench_end]
    sub rdx, rcx
    call gpu_module
    mov rbx, rax
    kinfo k_peak, 256
    call con_restore
    xor ecx, ecx
    call ExitProcess

; one row of the kernel table: rbx = module, rcx = name, edx = block size
kernel:
    push rsi
    push rdi
    push r12
    sub rsp, 48
    mov rsi, rcx
    mov r12d, edx
    mov rdx, rcx
    mov rcx, rbx
    call gpu_func
    mov rdi, rax
    say "  "
    mov rcx, rsi
    call pad13
    mov ecx, r12d
    mov edx, 5
    call rjust
    mov ecx, CF_NUM_REGS
    call fattr
    mov ecx, eax
    mov edx, 6
    call rjust
    mov ecx, 1                  ; CU_FUNC_ATTRIBUTE_SHARED_SIZE_BYTES
    call fattr
    mov ecx, eax
    mov edx, 8
    call rjust
    mov ecx, CF_LOCAL_BYTES
    call fattr
    mov ecx, eax
    mov edx, 8
    call rjust
    ; how many of these blocks fit on one SM at once
    lea rcx, [rsp+40]
    mov rdx, rdi
    mov r8d, r12d
    xor r9d, r9d
    CU cuOccupancy
    mov ecx, [rsp+40]
    mov edx, 11
    call rjust
    say "    "
    ; resident threads / the SM's maximum
    mov eax, [rsp+40]
    imul eax, r12d
    cvtsi2sd xmm0, rax
    mov ecx, CA_MAX_THREADS_SM
    call gpu_attr
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    mov rax, 0x4059000000000000     ; 100
    movq xmm1, rax
    mulsd xmm0, xmm1
    mov edx, 0
    call print_fixed
    say "%", 13, 10
    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    ret

; ecx = function attribute of the kernel in rdi. eax = value
fattr:
    sub rsp, 40
    mov edx, ecx
    lea rcx, [rsp+32]
    mov r8, rdi
    CU cuFuncGetAttribute
    mov eax, [rsp+32]
    add rsp, 40
    ret

; rcx = name, printed padded to 13 columns
pad13:
    push rsi
    push rdi
    sub rsp, 40
    mov rsi, rcx
    call print_z
    xor edi, edi
.n:
    cmp byte [rsi+rdi], 0
    je .p
    inc edi
    jmp .n
.p:
    cmp edi, 13
    jae .ret
    say " "
    inc edi
    jmp .p
.ret:
    add rsp, 40
    pop rdi
    pop rsi
    ret

; ecx = number, edx = width. right justified
rjust:
    push rbx
    push rsi
    sub rsp, 56
    mov ebx, edx
    mov edx, ecx
    lea rcx, [rsp+32]
    call fmt_dec
    lea rcx, [rsp+32]
    sub rax, rcx
    mov rsi, rax                ; digits, kept out of rax (say trashes it)
    sub ebx, eax
.sp:
    test ebx, ebx
    jle .num
    say " "
    dec ebx
    jmp .sp
.num:
    lea rcx, [rsp+32]
    mov rdx, rsi
    call print
    add rsp, 56
    pop rsi
    pop rbx
    ret

section .rdata
k_vadd   db "vadd", 0
k_copy16 db "copy16", 0
k_f2bf   db "f2bf", 0
k_busy   db "busy", 0
k_empty  db "empty", 0
k_ref    db "gemm_ref", 0
k_mma1   db "gemm_mma1", 0
k_tc     db "gemm_tc", 0
k_peak   db "mma_peak", 0
section .text

; ecx = number, -1 prints as ?
pnum:
    sub rsp, 40
    cmp ecx, -1
    je .q
    call print_dec
    jmp .r
.q:
    say "?"
.r:
    add rsp, 40
    ret

; eax = kHz (-1 = unknown), printed as GHz
pghz:
    sub rsp, 40
    cmp eax, -1
    je .q
    cvtsi2sd xmm0, rax
    mov rax, 0x3eb0c6f7a0b5ed8d     ; 1e-6
    movq xmm1, rax
    mulsd xmm0, xmm1
    mov edx, 2
    call print_fixed
    say " GHz"
    jmp .r
.q:
    say "?"
.r:
    add rsp, 40
    ret
