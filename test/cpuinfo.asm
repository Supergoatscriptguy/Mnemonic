; stage 1: console printing + cpuid feature dump
default rel
bits 64
%include "lib.inc"

extern GetActiveProcessorCount
extern ExitProcess

; table entry: flag dword + name padded to 12
%macro feat 2
    dd %1
%%s db %2
    times 12 - ($ - %%s) db ' '
%endmacro

section .rdata
feats:
    feat F_SSE42,      "sse4.2"
    feat F_AVX,        "avx"
    feat F_AVX2,       "avx2"
    feat F_FMA,        "fma"
    feat F_F16C,       "f16c"
    feat F_BMI2,       "bmi2"
    feat F_AVXVNNI,    "avx-vnni"
    feat F_VNNIINT8,   "vnni-int8"
    feat F_NECVT,      "ne-convert"
    feat F_AVX512F,    "avx512f"
    feat F_AVX512VNNI, "avx512-vnni"
    feat F_HYBRID,     "hybrid"
feats_end:

section .text
global start
start:
    sub rsp, 40
    call con_init
    call cpu_detect

    say "cpu:     "
    lea rcx, [cpu_brand]
    call print_z
    say 13, 10, "threads: "
    mov ecx, 0xffff             ; ALL_PROCESSOR_GROUPS
    call GetActiveProcessorCount
    mov ecx, eax                ; writing ecx zeroes the top half of rcx
    call print_dec
    say 13, 10, 13, 10

    ; start never returns, so we can use nonvolatile regs without saving them
    lea rbx, [feats]
.next:
    say "  "
    lea rcx, [rbx+4]
    mov edx, 12
    call print
    mov eax, [rbx]
    test eax, [cpu_feat]
    jz .no
    say "yes", 13, 10
    jmp .step
.no:
    say "-", 13, 10
.step:
    add rbx, 16
    lea rax, [feats_end]
    cmp rbx, rax
    jb .next

    say 13, 10, "bits:    0x"
    mov ecx, [cpu_feat]
    mov edx, 8
    call print_hex

    ; edge cases for the number printers
    say 13, 10, "numbers: "
    xor ecx, ecx
    call print_dec
    say " "
    mov rcx, -1
    call print_dec
    say " "
    mov rcx, 0x8000000000000000
    call print_int
    say " "
    mov rcx, -42
    call print_int
    say " 0x"
    mov ecx, 0xdeadbeef
    mov edx, 8
    call print_hex
    say 13, 10

    call con_restore            ; the shell shares this console
    xor ecx, ecx
    call ExitProcess
