; shared declarations, %include in anything that uses lib/

; console.asm
extern lib_init, con_init, con_restore, con_tty, con_out
extern print, print_z, print_dec, print_int, print_hex, print_fixed, print_sci, fatal
; fmt.asm
extern fmt_str, fmt_dec, fmt_dec0, fmt_int, fmt_hex, fmt_fixed, fmt_sci, fmt_count, fmt_hms
extern parse_int, parse_float
; cpu.asm
extern cpu_detect, cpu_feat, cpu_brand
; mem.asm
extern mem_alloc, mem_free, arena_init, arena_alloc, arena_reset
; file.asm
extern file_open, file_create, file_append, file_read, file_write, file_size, file_flush, file_close
extern file_read_all, file_map, file_unmap, file_replace, file_delete, file_exists, make_dir
; args.asm
extern args_init, argc, argv, cfg_load, cfg_args, cfg_str, cfg_int, cfg_float
; time.asm
extern time_init, time_now, time_since, qpc_freq
; rng.asm
extern rng_seed, rng_next, rng_float, rng_normal
; math.asm
extern math_log, math_exp, math_cos, math_sin
; thread.asm
extern pool_init, par_for, nthreads
; progress.asm
extern prog_begin, prog_draw, prog_msg, prog_end, prog_line
; ctrlc.asm
extern ctrlc_init, ctrlc_handler, stop_flag

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

; arena: reserve a big range up front, commit as it fills
AR_BASE      equ 0
AR_USED      equ 8
AR_COMMIT    equ 16
AR_RESERVE   equ 24
ARENA_SIZE   equ 32

RNG_SIZE     equ 32          ; xoshiro256** state, save it to resume a stream

; progress stats. the training loop fills in the public part
PS_STEP      equ 0           ; u64
PS_TOTAL     equ 8           ; u64
PS_LOSS      equ 16          ; f64
PS_VLOSS     equ 24          ; f64, nan until the first val run
PS_LR        equ 32          ; f64
PS_GNORM     equ 40          ; f64
PS_TOKS      equ 48          ; f64 tokens/sec
PS_TFLOPS    equ 56          ; f64
PS_SEEN      equ 64          ; u64 tokens seen
PS_VRAM      equ 72          ; u64 bytes, 0 total = don't show
PS_VRAMTOT   equ 80          ; u64
PS_ELAPSED0  equ 88          ; f64 seconds from earlier sessions (resume)
PS_ELAPSED   equ 96          ; f64 total, kept up to date by prog_draw
PS_T0        equ 104         ; the rest is prog_* bookkeeping
PS_STEP0     equ 112
PS_LAST      equ 120
PS_LINES     equ 128
PS_SIZE      equ 136

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

; append a literal at rdi and advance it. uses rsi and rcx
%macro emit 1+
    section .rdata
    %%s db %1
    %%n equ $ - %%s
    section .text
    lea rsi, [%%s]
    mov ecx, %%n
    rep movsb
%endmacro
