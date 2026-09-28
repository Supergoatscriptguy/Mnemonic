; stage 5 test: stop a training run half way, carry on from its checkpoint, and end
; up with exactly the same weights and adam state as a run that never stopped.
; runs bin\train.exe (the tiny preset) three times, on three little .tok files cut
; from the real ones, so the runs cross files (and the stop lands in the second one)
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"
%include "train/train.inc"
%include "test/check.inc"

extern CreateProcessA, WaitForSingleObject, GetExitCodeProcess, TerminateProcess, CloseHandle

section .rdata
run_a    db "bin\train.exe tiny run=restest_a data=scratch\restest\*.tok", 0
run_b1   db "bin\train.exe tiny run=restest_b data=scratch\restest\*.tok stop_at=17", 0
run_b2   db "bin\train.exe tiny run=restest_b data=scratch\restest\*.tok", 0
s_scr    db "scratch", 0
s_dir    db "scratch\restest", 0
src      db "datasets\fineweb\shard_00000.tok", 0
dst      db "scratch\restest\part_0.tok", 0
PARTTOK  equ 10000              ; ~9.8 tiny steps per file
pat_a    db "checkpoints\restest_a\*.ckpt", 0
pat_b    db "checkpoints\restest_b\*.ckpt", 0
log_a    db "logs\restest_a.log", 0
log_b    db "logs\restest_b.log", 0
mid_b    db "checkpoints\restest_b\step_00000017.ckpt", 0
end_a    db "checkpoints\restest_a\step_00000040.ckpt", 0
end_b    db "checkpoints\restest_b\step_00000040.ckpt", 0
e_spawn  db "CreateProcess failed", 0

section .bss
alignb 8
si_      resb 104               ; STARTUPINFOA
pi_      resb 24                ; PROCESS_INFORMATION
cmd      resb 256
code     resd 1
fa       resq 1
fb       resq 1
sza      resq 1
fh       resq 1
namebuf  resb 256

section .text

global start
start:
    sub rsp, 40
    call lib_init
    ; start clean
    lea rcx, [pat_a]
    call wipe
    lea rcx, [pat_b]
    call wipe
    lea rcx, [log_a]
    call file_delete
    lea rcx, [log_b]
    call file_delete
    call parts

    lea rcx, [run_a]
    call run
    test eax, eax
    check z, "straight run, 40 steps"
    lea rcx, [run_b1]
    call run
    cmp eax, 2
    check e, "stopped run, saves at step 17 and exits with 2"
    lea rcx, [mid_b]
    call file_exists
    test eax, eax
    check nz, "its checkpoint is there"
    lea rcx, [run_b2]
    call run
    test eax, eax
    check z, "resumed run, from 17 to 40"

    ; same bytes, apart from the wall clock time in the header
    lea rcx, [end_a]
    call file_read_all
    mov [fa], rax
    mov [sza], rdx
    lea rcx, [end_b]
    call file_read_all
    mov [fb], rax
    xor ecx, ecx
    cmp rdx, [sza]
    jne .diff
    test rdx, rdx
    jz .diff
    mov rsi, [fa]
    mov rdi, [fb]
    mov qword [rsi+CK_ELAPSED], 0
    mov qword [rdi+CK_ELAPSED], 0
    mov rcx, rdx
    repe cmpsb
    sete cl
.diff:
    movzx ecx, cl
    lea rdx, [m_same]
    call t_ok
    jmp t_done

section .rdata
m_same db "both end on the same weights, adam state, step, data position and rng, bit for bit", 0
section .text

; scratch\restest\part_{0,1,2}.tok: the header and first PARTTOK tokens of
; shards 0, 1, 2, with the token count patched to match
parts:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    lea rcx, [s_scr]
    call make_dir
    lea rcx, [s_dir]
    call make_dir
    mov ecx, 65536
    call mem_alloc
    mov rsi, rax
    lea rbx, [namebuf]
    xor edi, edi
.f:
    ; copy the names and bump the digit
    mov rcx, rbx
    lea rdx, [src]
    call fmt_str
    mov byte [rax], 0
    add [rax-5], dil            ; shard_0000N.tok
    lea rcx, [rbx+128]
    lea rdx, [dst]
    call fmt_str
    mov byte [rax], 0
    add [rax-5], dil            ; part_N.tok
    mov rcx, rbx
    call file_open
    mov [fh], rax
    mov rcx, rax
    mov rdx, rsi
    mov r8d, TF_SIZE + PARTTOK * 2
    call file_read
    mov rcx, [fh]
    call file_close
    mov qword [rsi+TF_NTOK], PARTTOK
    lea rcx, [rbx+128]
    call file_create
    mov [fh], rax
    mov rcx, rax
    mov rdx, rsi
    mov r8d, TF_SIZE + PARTTOK * 2
    call file_write
    mov rcx, [fh]
    call file_close
    inc edi
    cmp edi, 3
    jb .f
    mov rcx, rsi
    call mem_free
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = pattern. deletes whatever matches
wipe:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov ecx, 1 << 16
    call mem_alloc
    mov rbx, rax
    mov rcx, rsi
    mov rdx, rbx
    mov r8d, 1 << 16
    call file_find
    mov rsi, rdx
    mov rdi, rax
.d:
    test rdi, rdi
    jz .done
    mov rcx, [rsi]
    call file_delete
    add rsi, 8
    dec rdi
    jmp .d
.done:
    mov rcx, rbx
    call mem_free
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = command line. runs it in a hidden console, eax = its exit code
; (999 if it didn't finish within two minutes)
run:
    push rbx
    sub rsp, 80
    mov rdx, rcx
    lea rcx, [cmd]
    call fmt_str                ; CreateProcess wants a writable copy
    mov byte [rax], 0
    mov dword [si_], 104
    xor ecx, ecx
    lea rdx, [cmd]
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 0
    mov qword [rsp+40], 0x08000000  ; CREATE_NO_WINDOW
    mov qword [rsp+48], 0
    mov qword [rsp+56], 0
    lea rax, [si_]
    mov [rsp+64], rax
    lea rax, [pi_]
    mov [rsp+72], rax
    call CreateProcessA
    test eax, eax
    jz .fail
    mov rcx, [pi_+8]
    call CloseHandle
    mov rbx, [pi_]
    mov rcx, rbx
    mov edx, 120000
    call WaitForSingleObject
    test eax, eax
    jz .ok
    mov rcx, rbx
    mov edx, 999
    call TerminateProcess
    mov rcx, rbx
    mov edx, -1
    call WaitForSingleObject
.ok:
    mov rcx, rbx
    lea rdx, [code]
    call GetExitCodeProcess
    mov rcx, rbx
    call CloseHandle
    mov eax, [code]
    add rsp, 80
    pop rbx
    ret
.fail:
    lea rcx, [e_spawn]
    call fatal
