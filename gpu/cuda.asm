; the cuda driver api, loaded from nvcuda.dll at runtime. it ships with the
; graphics driver, no toolkit needed. every function gets looked up by name into
; a table of pointers, then called through the CU macro (gpu/cuda.inc)
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"

extern LoadLibraryA, GetProcAddress, SetEnvironmentVariableA, GetFullPathNameA, ExitProcess

LOGSZ equ 16384
MAXP  equ 8192                  ; launches one profile can hold
MAXFN equ 256

; what we call a function, and what nvcuda.dll exports it as
%macro FUNCS 0
    F cuInit,                   cuInit
    F cuDriverGetVersion,       cuDriverGetVersion
    F cuDeviceGet,              cuDeviceGet
    F cuDeviceGetCount,         cuDeviceGetCount
    F cuDeviceGetName,          cuDeviceGetName
    F cuDeviceGetAttribute,     cuDeviceGetAttribute
    F cuDeviceTotalMem,         cuDeviceTotalMem_v2
    F cuDevicePrimaryCtxRetain, cuDevicePrimaryCtxRetain
    F cuCtxSetCurrent,          cuCtxSetCurrent
    F cuCtxSynchronize,         cuCtxSynchronize
    F cuMemGetInfo,             cuMemGetInfo_v2
    F cuMemAlloc,               cuMemAlloc_v2
    F cuMemFree,                cuMemFree_v2
    F cuMemAllocHost,           cuMemAllocHost_v2
    F cuMemFreeHost,            cuMemFreeHost
    F cuMemcpyHtoD,             cuMemcpyHtoD_v2
    F cuMemcpyDtoH,             cuMemcpyDtoH_v2
    F cuMemcpyDtoD,             cuMemcpyDtoD_v2
    F cuMemcpyHtoDAsync,        cuMemcpyHtoDAsync_v2
    F cuMemcpyDtoHAsync,        cuMemcpyDtoHAsync_v2
    F cuMemsetD32,              cuMemsetD32_v2
    F cuModuleLoadDataEx,       cuModuleLoadDataEx
    F cuModuleGetFunction,      cuModuleGetFunction
    F cuModuleUnload,           cuModuleUnload
    F cuLaunchKernel,           cuLaunchKernel
    F cuFuncGetAttribute,       cuFuncGetAttribute
    F cuFuncSetAttribute,       cuFuncSetAttribute
    F cuStreamCreate,           cuStreamCreate
    F cuStreamSynchronize,      cuStreamSynchronize
    F cuStreamDestroy,          cuStreamDestroy_v2
    F cuEventCreate,            cuEventCreate
    F cuEventRecord,            cuEventRecord
    F cuEventSynchronize,       cuEventSynchronize
    F cuEventElapsedTime,       cuEventElapsedTime
    F cuEventDestroy,           cuEventDestroy_v2
    F cuGetErrorName,           cuGetErrorName
    F cuGetErrorString,         cuGetErrorString
    F cuOccupancy,              cuOccupancyMaxActiveBlocksPerMultiprocessor
%endmacro

section .rdata
%macro F 2
    db %str(%2), 0
%endmacro
names:
    FUNCS
    db 0
%unmacro F 2

s_dll     db "nvcuda.dll", 0
s_cache   db "cache", 0
s_cudadir db "cache\cuda", 0
s_env     db "CUDA_CACHE_PATH", 0
e_dll     db "can't load nvcuda.dll, is the nvidia driver installed?", 0
e_nodev   db "no cuda devices", 0
e_old     db "this needs compute capability 8.0 or newer (bf16 tensor cores)", 0
m_missing db "nvcuda.dll doesn't have ", 0
m_fail    db 13, 10, "cuda: ", 0
s_unknown db "?", 0
m_jit     db "ptx jit (its line numbers are 4 more than in the .ptx file, the header's in front):", 13, 10, 0

; ptx targets we know, newest first: compute capability, target name, ptx isa version
align 8
targets:
    dq 120
    db "sm_120", 0, 0, "8.7", 0, 0, 0, 0, 0
    dq 100
    db "sm_100", 0, 0, "8.6", 0, 0, 0, 0, 0
    dq 90
    db "sm_90", 0, 0, 0, "7.8", 0, 0, 0, 0, 0
    dq 89
    db "sm_89", 0, 0, 0, "7.8", 0, 0, 0, 0, 0
    dq 86
    db "sm_86", 0, 0, 0, "7.1", 0, 0, 0, 0, 0
    dq 80
    db "sm_80", 0, 0, 0, "7.0", 0, 0, 0, 0, 0
    dq 0

section .bss
alignb 8
%macro F 2
global %1
%1 resq 1
%endmacro
table:
    FUNCS
%unmacro F 2

global gpu_dev, gpu_name, gpu_ccmaj, gpu_ccmin, gpu_nsm, gpu_vram, gpu_drv, gpu_verbose
global gpu_ptxver, gpu_target
gpu_dev     resd 1
gpu_ccmaj   resd 1
gpu_ccmin   resd 1
gpu_nsm     resd 1
gpu_drv     resd 1
gpu_verbose resd 1              ; 1 = print the jit's info log (registers, spills)
gpu_vram    resq 1
ctx         resq 1
ev0         resq 1
ev1         resq 1
gpu_name    resb 256
gpu_ptxver  resb 8
gpu_target  resb 8
cachepath   resb 1024
; the profiler
global gpu_prof, prof_n, prof_fn, prof_arg, prof_ms
gpu_prof    resd 1              ; 1 = recording
prof_n      resq 1
evmade      resq 1
prof_ev     resq MAXP + 1
prof_fn     resq MAXP
prof_arg    resq MAXP * 4       ; per launch: args 3, 4, 5, and 7 | grid z << 32
prof_ms     resd MAXP
fn_n        resq 1
fn_h        resq MAXFN          ; every kernel loaded, and its name
fn_name     resq MAXFN
jitopt      resd 8
jitval      resq 8
errlog      resb LOGSZ
infolog     resb LOGSZ

section .text

; finds the driver, picks device 0 and makes its primary context current on this thread
global gpu_init
gpu_init:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    ; the driver caches jitted ptx in %APPDATA% unless told otherwise. keep it here
    lea rcx, [s_cache]
    call make_dir
    lea rcx, [s_cudadir]
    call make_dir
    lea rcx, [s_cudadir]
    mov edx, 1024
    lea r8, [cachepath]
    xor r9d, r9d
    call GetFullPathNameA
    lea rcx, [s_env]
    lea rdx, [cachepath]
    call SetEnvironmentVariableA

    lea rcx, [s_dll]
    call LoadLibraryA
    test rax, rax
    jnz .loaded
    lea rcx, [e_dll]
    call fatal
.loaded:
    mov rbx, rax
    lea rsi, [names]
    lea rdi, [table]
.res:
    cmp byte [rsi], 0
    je .resolved
    mov rcx, rbx
    mov rdx, rsi
    call GetProcAddress
    test rax, rax
    jz .missing
    mov [rdi], rax
    add rdi, 8
.skip:
    lodsb
    test al, al
    jnz .skip
    jmp .res
.missing:
    lea rcx, [m_missing]
    call print_z
    mov rcx, rsi
    call fatal

.resolved:
    xor ecx, ecx
    CU cuInit
    lea rcx, [gpu_drv]
    CU cuDriverGetVersion
    lea rcx, [rsp+32]
    CU cuDeviceGetCount
    cmp dword [rsp+32], 0
    jne .have
    lea rcx, [e_nodev]
    call fatal
.have:
    lea rcx, [gpu_dev]
    xor edx, edx
    CU cuDeviceGet
    lea rcx, [gpu_name]
    mov edx, 255
    mov r8d, [gpu_dev]
    CU cuDeviceGetName
    mov ecx, CA_CC_MAJOR
    call gpu_attr
    mov [gpu_ccmaj], eax
    mov ecx, CA_CC_MINOR
    call gpu_attr
    mov [gpu_ccmin], eax
    mov ecx, CA_SMS
    call gpu_attr
    mov [gpu_nsm], eax
    lea rcx, [gpu_vram]
    mov edx, [gpu_dev]
    CU cuDeviceTotalMem
    lea rcx, [ctx]
    mov edx, [gpu_dev]
    CU cuDevicePrimaryCtxRetain
    mov rcx, [ctx]
    CU cuCtxSetCurrent

    ; ptx header: the newest target we know that's not newer than this gpu
    mov eax, [gpu_ccmaj]
    imul eax, eax, 10
    add eax, [gpu_ccmin]
    lea rsi, [targets]
.t:
    mov rdx, [rsi]
    test rdx, rdx
    jz .old
    cmp rax, rdx
    jae .pick
    add rsi, 24
    jmp .t
.old:
    lea rcx, [e_old]
    call fatal
.pick:
    mov rax, [rsi+8]
    mov [gpu_target], rax
    mov rax, [rsi+16]
    mov [gpu_ptxver], rax

    lea rcx, [ev0]
    xor edx, edx
    CU cuEventCreate
    lea rcx, [ev1]
    xor edx, edx
    CU cuEventCreate
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ecx = CUdevice_attribute. eax = its value, -1 if the driver won't say
global gpu_attr
gpu_attr:
    sub rsp, 40
    mov edx, ecx
    lea rcx, [rsp+32]
    mov r8d, [gpu_dev]
    call [cuDeviceGetAttribute]
    test eax, eax
    mov eax, -1
    jnz .ret
    mov eax, [rsp+32]
.ret:
    add rsp, 40
    ret

; ecx = CUresult, rdx = which function. prints what the driver says and exits
global cu_fail
cu_fail:
    and rsp, -16
    sub rsp, 64
    mov [rsp+32], ecx
    mov [rsp+40], rdx
    call con_restore
    lea rcx, [m_fail]
    call print_z
    mov rcx, [rsp+40]
    call print_z
    say " failed: "
    lea rdx, [rsp+48]
    mov qword [rdx], 0
    mov ecx, [rsp+32]
    call [cuGetErrorName]
    mov rcx, [rsp+48]
    test rcx, rcx
    jz .code
    call print_z
    say " ("
    lea rdx, [rsp+48]
    mov qword [rdx], 0
    mov ecx, [rsp+32]
    call [cuGetErrorString]
    mov rcx, [rsp+48]
    test rcx, rcx
    jz .close
    call print_z
.close:
    say ")", 13, 10
    jmp .out
.code:
    say "error "
    mov ecx, [rsp+32]
    call print_dec
    say 13, 10
.out:
    mov ecx, 4
    call ExitProcess

; rcx = ptx source (no header), rdx = its length. rax = CUmodule.
; the .version/.target header comes from the gpu we're on. if the jit refuses it,
; its error log gets printed before we die
global gpu_module
gpu_module:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    mov rsi, rcx
    mov r12, rdx
    lea rcx, [r12+256]
    call mem_alloc
    mov rbx, rax
    mov rdi, rax
    mov rcx, rdi
    lea rdx, [h_ver]
    call fmt_str
    mov rcx, rax
    lea rdx, [gpu_ptxver]
    call fmt_str
    mov rcx, rax
    lea rdx, [h_target]
    call fmt_str
    mov rcx, rax
    lea rdx, [gpu_target]
    call fmt_str
    mov rcx, rax
    lea rdx, [h_addr]
    call fmt_str
    mov rdi, rax
    mov rcx, r12
    rep movsb
    mov byte [rdi], 0

    mov dword [jitopt], 5       ; CU_JIT_ERROR_LOG_BUFFER
    mov dword [jitopt+4], 6     ; CU_JIT_ERROR_LOG_BUFFER_SIZE_BYTES
    mov dword [jitopt+8], 3     ; CU_JIT_INFO_LOG_BUFFER
    mov dword [jitopt+12], 4    ; CU_JIT_INFO_LOG_BUFFER_SIZE_BYTES
    mov dword [jitopt+16], 12   ; CU_JIT_LOG_VERBOSE
    lea rax, [errlog]
    mov [jitval], rax
    mov qword [jitval+8], LOGSZ
    lea rax, [infolog]
    mov [jitval+16], rax
    mov qword [jitval+24], LOGSZ
    mov eax, [gpu_verbose]
    mov [jitval+32], rax
    mov byte [errlog], 0
    mov byte [infolog], 0

    lea rcx, [rsp+40]
    mov rdx, rbx
    mov r8d, 5
    lea r9, [jitopt]
    lea rax, [jitval]
    mov [rsp+32], rax
    call [cuModuleLoadDataEx]
    test eax, eax
    jz .ok
    mov [rsp+48], eax
    lea rcx, [m_jit]
    call print_z
    lea rcx, [errlog]
    call print_z
    mov ecx, [rsp+48]
    lea rdx, [s_load]
    call cu_fail
.ok:
    cmp dword [gpu_verbose], 0
    je .quiet
    lea rcx, [infolog]
    call print_z
.quiet:
    mov rcx, rbx
    call mem_free
    mov rax, [rsp+40]
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = module, rdx = kernel name (kept, not copied). rax = CUfunction
global gpu_func
gpu_func:
    push rbx
    sub rsp, 48
    mov rbx, rdx
    mov r8, rdx
    mov rdx, rcx
    lea rcx, [rsp+32]
    CU cuModuleGetFunction
    mov rax, [rsp+32]
    ; its name, for the profiler
    mov rcx, [fn_n]
    cmp rcx, MAXFN
    jae .done
    lea rdx, [fn_h]
    mov [rdx+rcx*8], rax
    lea rdx, [fn_name]
    mov [rdx+rcx*8], rbx
    inc qword [fn_n]
.done:
    add rsp, 48
    pop rbx
    ret

; rcx = CUfunction. rax = its kernel name
global gpu_fname
gpu_fname:
    xor edx, edx
.f:
    cmp rdx, [fn_n]
    jae .none
    lea rax, [fn_h]
    cmp [rax+rdx*8], rcx
    je .hit
    inc rdx
    jmp .f
.hit:
    lea rax, [fn_name]
    mov rax, [rax+rdx*8]
    ret
.none:
    lea rax, [s_unknown]
    ret

; profiling: between gpu_prof_begin and gpu_prof_end every launch gets an event
; in front of it, and the gaps between the events are the kernels' gpu times.
; everything has to go on one stream for that to add up
global gpu_prof_begin
gpu_prof_begin:
    push rbx
    sub rsp, 32
.make:
    mov rbx, [evmade]           ; made once, and one more than launches for the end
    cmp rbx, MAXP + 1
    jae .ready
    lea rcx, [prof_ev]
    lea rcx, [rcx+rbx*8]
    xor edx, edx
    CU cuEventCreate
    inc qword [evmade]
    jmp .make
.ready:
    mov qword [prof_n], 0
    mov dword [gpu_prof], 1
    add rsp, 32
    pop rbx
    ret

; rcx = stream. stops recording, waits, and fills prof_ms. rax = launches recorded
global gpu_prof_end
gpu_prof_end:
    push rbx
    sub rsp, 32
    mov dword [gpu_prof], 0
    mov rdx, rcx
    mov rax, [prof_n]
    lea rcx, [prof_ev]
    mov rcx, [rcx+rax*8]
    CU cuEventRecord
    mov rax, [prof_n]
    lea rcx, [prof_ev]
    mov rcx, [rcx+rax*8]
    CU cuEventSynchronize
    xor ebx, ebx
.t:
    cmp rbx, [prof_n]
    jae .done
    lea rcx, [prof_ms]
    lea rcx, [rcx+rbx*4]
    lea rax, [prof_ev]
    mov rdx, [rax+rbx*8]
    mov r8, [rax+rbx*8+8]
    CU cuEventElapsedTime
    inc rbx
    jmp .t
.done:
    mov rax, [prof_n]
    add rsp, 32
    pop rbx
    ret

; rcx = launch (KL_*). points the driver at the argument values and launches
global gpu_launch
gpu_launch:
    push rbx
    sub rsp, 96
    mov rbx, rcx
    cmp dword [gpu_prof], 0
    jne .prof
.go:
    lea rax, [rbx+KL_ARGS]
    lea rdx, [rbx+KL_PTRS]
    mov ecx, 16
.p:
    mov [rdx], rax
    add rax, 8
    add rdx, 8
    dec ecx
    jnz .p
    mov rcx, [rbx+KL_FUNC]
    mov edx, [rbx+KL_GX]
    mov r8d, [rbx+KL_GY]
    mov r9d, [rbx+KL_GZ]
    mov eax, [rbx+KL_BX]
    mov [rsp+32], rax
    mov eax, [rbx+KL_BY]
    mov [rsp+40], rax
    mov eax, [rbx+KL_BZ]
    mov [rsp+48], rax
    mov eax, [rbx+KL_SMEM]
    mov [rsp+56], rax
    mov rax, [rbx+KL_STREAM]
    mov [rsp+64], rax
    lea rax, [rbx+KL_PTRS]
    mov [rsp+72], rax
    mov qword [rsp+80], 0
    CU cuLaunchKernel
    add rsp, 96
    pop rbx
    ret
.prof:
    ; the event, then what was launched: the kernel, and args 3, 4, 5, 7 plus grid z,
    ; which for a matmul are M, N, K, flags and the split
    mov rax, [prof_n]
    cmp rax, MAXP
    jae .go
    lea rcx, [prof_ev]
    mov rcx, [rcx+rax*8]
    mov rdx, [rbx+KL_STREAM]
    CU cuEventRecord
    mov rax, [prof_n]
    lea rcx, [prof_fn]
    mov rdx, [rbx+KL_FUNC]
    mov [rcx+rax*8], rdx
    shl rax, 5
    lea rcx, [prof_arg]
    add rcx, rax
    mov rdx, [rbx+KL_ARGS+3*8]
    mov [rcx], rdx
    mov rdx, [rbx+KL_ARGS+4*8]
    mov [rcx+8], rdx
    mov rdx, [rbx+KL_ARGS+5*8]
    mov [rcx+16], rdx
    mov edx, [rbx+KL_GZ]
    shl rdx, 32
    mov r8d, [rbx+KL_ARGS+7*8]
    or rdx, r8
    mov [rcx+24], rdx
    inc qword [prof_n]
    jmp .go

; waits for everything queued on the gpu
global gpu_sync
gpu_sync:
    sub rsp, 40
    CU cuCtxSynchronize
    add rsp, 40
    ret

; rcx = bytes. rax = device pointer
global gpu_alloc
gpu_alloc:
    sub rsp, 40
    mov rdx, rcx
    lea rcx, [rsp+32]
    CU cuMemAlloc
    mov rax, [rsp+32]
    add rsp, 40
    ret

; rcx = device pointer
global gpu_free
gpu_free:
    sub rsp, 40
    CU cuMemFree
    add rsp, 40
    ret

; rcx = device dst, rdx = host src, r8 = bytes
global gpu_up
gpu_up:
    sub rsp, 40
    CU cuMemcpyHtoD
    add rsp, 40
    ret

; rcx = host dst, rdx = device src, r8 = bytes
global gpu_down
gpu_down:
    sub rsp, 40
    CU cuMemcpyDtoH
    add rsp, 40
    ret

; rcx = bytes. rax = pinned (page-locked) host memory, which copies much faster
global gpu_host
gpu_host:
    sub rsp, 40
    mov rdx, rcx
    lea rcx, [rsp+32]
    CU cuMemAllocHost
    mov rax, [rsp+32]
    add rsp, 40
    ret

; rax = free bytes, rdx = total
global gpu_meminfo
gpu_meminfo:
    sub rsp, 56
    lea rcx, [rsp+32]
    lea rdx, [rsp+40]
    CU cuMemGetInfo
    mov rax, [rsp+32]
    mov rdx, [rsp+40]
    add rsp, 56
    ret

; rcx = stream (0 = default). marks the start of a timed stretch
global gpu_tstart
gpu_tstart:
    sub rsp, 40
    mov rdx, rcx
    mov rcx, [ev0]
    CU cuEventRecord
    add rsp, 40
    ret

; rcx = stream. waits for it, xmm0 = milliseconds since gpu_tstart (gpu clock)
global gpu_tstop
gpu_tstop:
    sub rsp, 40
    mov rdx, rcx
    mov rcx, [ev1]
    CU cuEventRecord
    mov rcx, [ev1]
    CU cuEventSynchronize
    lea rcx, [rsp+32]
    mov rdx, [ev0]
    mov r8, [ev1]
    CU cuEventElapsedTime
    cvtss2sd xmm0, [rsp+32]
    add rsp, 40
    ret

section .rdata
h_ver    db ".version ", 0
h_target db 10, ".target ", 0
h_addr   db 10, ".address_size 64", 10, 10, 0
s_load   db "cuModuleLoadDataEx", 0
