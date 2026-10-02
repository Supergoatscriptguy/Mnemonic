; gpu: the cuda driver api (nvcuda.dll) from asm. include after lib.inc

extern gpu_init, gpu_module, gpu_func, gpu_launch, gpu_sync, cu_fail
extern gpu_alloc, gpu_free, gpu_up, gpu_down, gpu_host, gpu_meminfo
extern gpu_tstart, gpu_tstop, gpu_verbose
extern gpu_name, gpu_ccmaj, gpu_ccmin, gpu_nsm, gpu_vram, gpu_drv, gpu_dev, gpu_attr
extern gpu_ptxver, gpu_target
extern gpu_fname, gpu_prof_begin, gpu_prof_end, gpu_prof, prof_n, prof_fn, prof_arg, prof_ms

; the driver's functions, filled in by gpu_init. call them through CU
extern cuInit, cuDriverGetVersion, cuDeviceGet, cuDeviceGetCount, cuDeviceGetName
extern cuDeviceGetAttribute, cuDeviceTotalMem, cuDevicePrimaryCtxRetain, cuCtxSetCurrent
extern cuCtxSynchronize, cuMemGetInfo, cuMemAlloc, cuMemFree, cuMemAllocHost, cuMemFreeHost
extern cuMemcpyHtoD, cuMemcpyDtoH, cuMemcpyDtoD, cuMemcpyHtoDAsync, cuMemcpyDtoHAsync
extern cuMemsetD32, cuModuleLoadDataEx, cuModuleGetFunction, cuModuleUnload, cuLaunchKernel
extern cuFuncGetAttribute, cuFuncSetAttribute, cuStreamCreate, cuStreamSynchronize
extern cuStreamDestroy, cuEventCreate, cuEventRecord, cuEventSynchronize, cuEventElapsedTime
extern cuEventDestroy, cuGetErrorName, cuGetErrorString, cuOccupancy

; call a driver function, and if it doesn't return CUDA_SUCCESS die with its
; name and the driver's own words for what went wrong
%macro CU 1
    call [%1]
    test eax, eax
    jz %%ok
    mov ecx, eax
    lea rdx, [%%name]
    call cu_fail
    section .rdata
    %%name db %str(%1), 0
    section .text
%%ok:
%endmacro

; kernel launch, see gpu_launch. the args are values, 8 bytes each (a u32 arg
; just uses the low half), and gpu_launch points the driver at them
KL_FUNC    equ 0
KL_GX      equ 8                ; u32 grid x, y, z
KL_GY      equ 12
KL_GZ      equ 16
KL_BX      equ 20               ; u32 block x, y, z
KL_BY      equ 24
KL_BZ      equ 28
KL_SMEM    equ 32               ; u32 dynamic shared memory
KL_STREAM  equ 40
KL_ARGS    equ 48               ; 16 x u64
KL_PTRS    equ 176              ; 16 x pointer
KL_SIZE    equ 304

; fill in a launch at rbx: grid x, grid y, block x, block y
%macro grid 4
    mov dword [rbx+KL_GX], %1
    mov dword [rbx+KL_GY], %2
    mov dword [rbx+KL_GZ], 1
    mov dword [rbx+KL_BX], %3
    mov dword [rbx+KL_BY], %4
    mov dword [rbx+KL_BZ], 1
%endmacro

; the device attributes we look at (CUdevice_attribute)
CA_MAX_THREADS_BLOCK equ 1
CA_WARP              equ 10
CA_CLOCK             equ 13     ; kHz
CA_SMS               equ 16
CA_MEM_CLOCK         equ 36     ; kHz
CA_BUS_WIDTH         equ 37     ; bits
CA_L2                equ 38
CA_MAX_THREADS_SM    equ 39
CA_ASYNC_ENGINES     equ 40
CA_PCI_BUS           equ 33
CA_CC_MAJOR          equ 75
CA_CC_MINOR          equ 76
CA_SMEM_SM           equ 81
CA_REGS_SM           equ 82
CA_SMEM_OPTIN        equ 97
CA_MAX_BLOCKS_SM     equ 106

CF_NUM_REGS          equ 4      ; CUfunction_attribute
CF_LOCAL_BYTES       equ 3
CF_MAX_DYN_SMEM      equ 8
