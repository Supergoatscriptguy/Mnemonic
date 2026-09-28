; shared declarations, %include in anything that uses lib/

extern con_init, print, print_z, print_dec, print_int, print_hex
extern cpu_detect, cpu_feat, cpu_brand

; cpu_feat bits
F_SSE42      equ 1 << 0
F_AVX        equ 1 << 1
F_AVX2       equ 1 << 2
F_FMA        equ 1 << 3
F_F16C       equ 1 << 4
F_BMI2       equ 1 << 5
F_AVXVNNI    equ 1 << 6
F_VNNIINT8   equ 1 << 7      ; signed x signed int8 dot products
F_NECVT      equ 1 << 8      ; AVX-NE-CONVERT, bf16 <-> fp32
F_AVX512F    equ 1 << 9
F_AVX512VNNI equ 1 << 10
F_HYBRID     equ 1 << 11     ; P + E cores

; all of these need the OS to save ymm state
F_YMM_MASK   equ F_AVX | F_AVX2 | F_FMA | F_F16C | F_AVXVNNI | F_VNNIINT8 | F_NECVT
F_ZMM_MASK   equ F_AVX512F | F_AVX512VNNI

; print a literal: say "text", 13, 10
; it's a normal call, so volatile regs get trashed
%macro say 1+
    section .rdata
    %%s db %1
    %%n equ $ - %%s
    section .text
    lea rcx, [%%s]
    mov edx, %%n
    call print
%endmacro
