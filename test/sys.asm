; stage 1 test: memory, arena, files, mapping, config + args, timer.
; run from the repo root as:  bin\sys.exe lr=1e-3 foo="a b"
default rel
bits 64
%include "lib.inc"
%include "test/check.inc"

extern Sleep

MB equ 1 << 20

section .rdata
logsdir  db "logs", 0
f_tmp    db "logs\t_sys.tmp", 0
f_bin    db "logs\t_sys.bin", 0
f_app    db "logs\t_app.txt", 0
f_cfg    db "logs\t_cfg.txt", 0
f_nope   db "logs\not_there.txt", 0
cfgtext  db "# test config", 13, 10
         db "steps = 400", 13, 10
         db "lr=3e-4   # trailing comment", 13, 10
         db "  name =  dev run  ", 13, 10
         db 13, 10
         db "tokens = 5e9", 13, 10
         db "neg = -12"                     ; no newline at the end
cfglen   equ $ - cfgtext
k_steps  db "steps", 0
k_lr     db "lr", 0
k_name   db "name", 0
k_tokens db "tokens", 0
k_neg    db "neg", 0
k_miss   db "missing", 0
k_foo    db "foo", 0
s_devrun db "dev run", 0
s_ab     db "a b", 0
s_empty  db 0
align 8
lr_file  dq 3e-4
lr_arg   dq 1e-3
zero     dq 0.0

section .bss
alignb 8
ar     resb ARENA_SIZE
buf    resq 1
fh     resq 1

section .text

; rcx, rdx = zero terminated strings. ZF set if equal
streq:
    mov al, [rcx]
    cmp al, [rdx]
    jne .ret
    inc rcx
    inc rdx
    test al, al
    jnz streq
.ret:
    ret

global start
start:
    sub rsp, 40
    call lib_init

    say "memory", 13, 10
    mov ecx, MB
    call mem_alloc
    mov rbx, rax
    mov rdi, rax
    mov ecx, MB
    xor eax, eax
    repe scasb
    check e, "mem_alloc gives zeroed memory"
    mov byte [rbx+MB-1], 0x5a
    mov rcx, rbx
    call mem_free
    test eax, eax
    check nz, "mem_free"

    lea rcx, [ar]
    mov edx, 1 << 30
    call arena_init
    lea rcx, [ar]
    mov edx, 100
    mov r8d, 16
    call arena_alloc
    mov r12, rax
    cmp rax, [ar+AR_BASE]
    check e, "arena: first alloc at the base"
    lea rcx, [ar]
    mov edx, 3*MB
    mov r8d, 4096
    call arena_alloc
    mov r13, rax
    test eax, 4095
    check z, "arena: 4096 alignment"
    mov byte [r13+3*MB-1], 1    ; faults if it wasn't committed
    mov rax, [ar+AR_COMMIT]
    cmp rax, [ar+AR_USED]
    check ae, "arena: committed covers what's used"
    lea rcx, [ar]
    call arena_reset
    lea rcx, [ar]
    mov edx, 8
    mov r8d, 8
    call arena_alloc
    cmp rax, r12
    check e, "arena: reset starts over at the base"

    say "files", 13, 10
    lea rcx, [logsdir]
    call make_dir
    mov ecx, MB
    call mem_alloc
    mov [buf], rax
    xor ecx, ecx
.fill:
    mov eax, ecx
    imul eax, eax, 31
    mov edx, ecx
    shr edx, 8
    add eax, edx
    mov rdx, [buf]
    mov [rdx+rcx], al
    inc ecx
    cmp ecx, MB
    jb .fill

    ; checkpoint style: write a temp file, flush, rename over the real one
    lea rcx, [f_tmp]
    call file_create
    mov [fh], rax
    mov rcx, rax
    mov rdx, [buf]
    mov r8d, MB
    call file_write
    test eax, eax
    check nz, "file_write 1 MB"
    mov rcx, [fh]
    call file_flush
    mov rcx, [fh]
    call file_close
    lea rcx, [f_tmp]
    lea rdx, [f_bin]
    call file_replace
    test eax, eax
    check nz, "file_replace temp -> final"
    lea rcx, [f_tmp]
    call file_exists
    test eax, eax
    check z, "temp file is gone after the rename"

    lea rcx, [f_bin]
    call file_read_all
    mov rsi, rax
    cmp rdx, MB
    check e, "file_read_all size"
    mov rdi, [buf]
    mov ecx, MB
    repe cmpsb
    check e, "file_read_all contents"

    lea rcx, [f_bin]
    call file_map
    mov r12, rax
    cmp rdx, MB
    check e, "file_map size"
    mov rsi, r12
    mov rdi, [buf]
    mov ecx, MB
    repe cmpsb
    check e, "file_map contents"
    mov rcx, r12
    call file_unmap

    lea rcx, [f_app]
    call file_delete
    lea rcx, [f_app]
    call file_append
    mov [fh], rax
    mov rcx, rax
    lea rdx, [s_ab]
    mov r8d, 1
    call file_write             ; "a"
    mov rcx, [fh]
    call file_close
    lea rcx, [f_app]
    call file_append
    mov [fh], rax
    mov rcx, rax
    lea rdx, [s_ab+2]
    mov r8d, 1
    call file_write             ; "b"
    mov rcx, [fh]
    call file_close
    lea rcx, [f_app]
    call file_read_all
    mov rbx, rdx
    cmp word [rax], 'ab'
    check e, "file_append adds to the end"

    lea rcx, [f_bin]
    call file_delete
    lea rcx, [f_app]
    call file_delete
    lea rcx, [f_bin]
    call file_exists
    test eax, eax
    check z, "file_delete"

    say "config", 13, 10
    lea rcx, [f_cfg]
    call file_create
    mov [fh], rax
    mov rcx, rax
    lea rdx, [cfgtext]
    mov r8d, cfglen
    call file_write
    mov rcx, [fh]
    call file_close

    lea rcx, [f_nope]
    call cfg_load
    test eax, eax
    check z, "cfg_load of a missing file returns 0"
    lea rcx, [f_cfg]
    call cfg_load
    test eax, eax
    check nz, "cfg_load"
    lea rcx, [k_steps]
    xor edx, edx
    call cfg_int
    cmp rax, 400
    check e, "steps = 400"
    lea rcx, [k_lr]
    movsd xmm1, [zero]
    call cfg_float
    movq rax, xmm0
    cmp rax, [lr_file]
    check e, "lr = 3e-4, with a trailing comment"
    lea rcx, [k_name]
    lea rdx, [s_empty]
    call cfg_str
    mov rcx, rax
    lea rdx, [s_devrun]
    call streq
    check e, "name = 'dev run', trimmed"
    lea rcx, [k_tokens]
    xor edx, edx
    call cfg_int
    mov rdx, 5000000000
    cmp rax, rdx
    check e, "tokens = 5e9 as an int"
    lea rcx, [k_neg]
    xor edx, edx
    call cfg_int
    cmp rax, -12
    check e, "neg = -12 on the last line, no newline"
    lea rcx, [k_miss]
    mov edx, 77
    call cfg_int
    cmp rax, 77
    check e, "missing key gives the default"

    cmp qword [argc], 3
    jb .noargs
    call cfg_args
    lea rcx, [k_lr]
    movsd xmm1, [zero]
    call cfg_float
    movq rax, xmm0
    cmp rax, [lr_arg]
    check e, "arg lr=1e-3 overrides the file"
    lea rcx, [k_foo]
    lea rdx, [s_empty]
    call cfg_str
    mov rcx, rax
    lea rdx, [s_ab]
    call streq
    check e, "quoted arg foo=", 34, "a b", 34
    jmp .time
.noargs:
    say "  (skipped args, run as: sys.exe lr=1e-3 foo=", 34, "a b", 34, ")", 13, 10
.time:
    lea rcx, [f_cfg]
    call file_delete

    say "timer", 13, 10
    call time_now
    mov r12, rax
    mov ecx, 50
    call Sleep
    mov rcx, r12
    call time_since
    close_to 0.058, 0.02, "Sleep(50) measured in seconds"   ; 50 ms plus up to a 15.6 ms tick
    mov rax, [qpc_freq]
    test rax, rax
    check nz, "qpc frequency is set"

    jmp t_done
