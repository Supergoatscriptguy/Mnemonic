; cpu feature detection
default rel
bits 64
%include "lib.inc"

section .bss
global cpu_feat, cpu_brand
cpu_feat  resd 1
cpu_brand resb 49

section .text

; set a feature bit in esi if bit %2 of %1 is on
%macro chk 3
    bt %1, %2
    jnc %%no
    or esi, %3
%%no:
%endmacro

; returns feature bits in eax, also fills cpu_feat and cpu_brand
global cpu_detect
cpu_detect:
    push rbx                    ; cpuid writes ebx, and rbx is nonvolatile
    push rsi
    xor esi, esi

    xor eax, eax
    cpuid
    mov r8d, eax                ; highest basic leaf

    mov eax, 1
    cpuid
    mov r9d, ecx
    chk r9d, 20, F_SSE42
    chk r9d, 28, F_AVX
    chk r9d, 12, F_FMA
    chk r9d, 29, F_F16C

    cmp r8d, 7
    jb .os
    mov eax, 7
    xor ecx, ecx
    cpuid
    mov r10d, eax               ; highest subleaf of leaf 7
    chk ebx, 5, F_AVX2
    chk ebx, 8, F_BMI2
    chk ebx, 16, F_AVX512F
    chk ecx, 11, F_AVX512VNNI
    chk edx, 15, F_HYBRID

    cmp r10d, 1
    jb .os
    mov eax, 7
    mov ecx, 1
    cpuid
    chk eax, 4, F_AVXVNNI
    chk edx, 4, F_VNNIINT8
    chk edx, 5, F_NECVT

.os:
    ; the cpu having it isn't enough, the OS has to save the wide regs on
    ; context switches. XCR0 says which ones it saves
    xor eax, eax
    bt r9d, 27                  ; OSXSAVE, otherwise xgetbv faults
    jnc .xcr0
    xor ecx, ecx
    xgetbv
.xcr0:
    mov ecx, eax
    and ecx, 6                  ; xmm + ymm
    cmp ecx, 6
    je .ymm_ok
    and esi, ~F_YMM_MASK
.ymm_ok:
    and eax, 0xe6               ; + opmask, zmm upper halves, zmm16-31
    cmp eax, 0xe6
    je .zmm_ok
    and esi, ~F_ZMM_MASK
.zmm_ok:

    ; brand string, 48 bytes from 3 extended leaves
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .done
    lea r10, [cpu_brand]
    mov r11d, 0x80000002
.brand:
    mov eax, r11d
    cpuid
    mov [r10], eax
    mov [r10+4], ebx
    mov [r10+8], ecx
    mov [r10+12], edx
    add r10, 16
    inc r11d
    cmp r11d, 0x80000004
    jbe .brand

.done:
    mov [cpu_feat], esi
    mov eax, esi
    pop rsi
    pop rbx
    ret
