; stage 1 test: runs bin\progress.exe in a hidden console and sends it real ctrl+c
; events, checking save, exact resume, and forced exit. run from the repo root.
;   ctrltest.exe               the checks
;   ctrltest.exe send PID N    helper: attach to PID's console, send N ctrl+c
; the helper is a separate process because sending means attaching to the
; target's console, and we'd lose our own output doing that
default rel
bits 64
%include "lib.inc"
%include "test/check.inc"

extern CreateProcessA, WaitForSingleObject, GetExitCodeProcess, TerminateProcess, CloseHandle
extern FreeConsole, AttachConsole, SetConsoleCtrlHandler, GenerateConsoleCtrlEvent, Sleep

NEW_CONSOLE equ 0x10
NO_WINDOW   equ 0x08000000

section .rdata
fast     db "bin\progress.exe steps=120 step_ms=10 save_every=1000 log_every=1000 val_every=1000", 0
slow     db "bin\progress.exe steps=120 step_ms=3000 save_every=1000 log_every=1000 val_every=1000", 0
self     db "bin\ctrltest.exe send ", 0
state    db "logs\demo.state", 0
donepath db "logs\demo.done", 0
logsdir  db "logs", 0
e_spawn  db "CreateProcess failed", 0

section .bss
alignb 8
si_      resb 104               ; STARTUPINFOA
pi_      resb 24                ; PROCESS_INFORMATION
cmd      resb 256
cmd2     resb 256
expected resb 48
code     resd 1
pid      resq 1
hproc    resq 1

section .text

; rcx = command line, edx = creation flags. rax = process handle, [pid] set
spawn:
    push rbx
    sub rsp, 80
    mov ebx, edx
    mov rdx, rcx
    lea rcx, [cmd]
    call fmt_str                ; CreateProcess wants a writable copy
    mov byte [rax], 0
    mov dword [si_], 104
    mov dword [si_+60], 1       ; STARTF_USESHOWWINDOW
    mov word [si_+64], 0        ; SW_HIDE
    xor ecx, ecx
    lea rdx, [cmd]
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 0       ; no handle inheritance
    mov [rsp+40], rbx
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
    call CloseHandle            ; thread handle, not needed
    mov eax, [pi_+16]
    mov [pid], rax
    mov rax, [pi_]
    add rsp, 80
    pop rbx
    ret
.fail:
    lea rcx, [e_spawn]
    call fatal

; rcx = process. eax = its exit code, 999 if it hung and we killed it
wait_exit:
    push rbx
    sub rsp, 32
    mov rbx, rcx
    mov edx, 30000
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
    add rsp, 32
    pop rbx
    ret

; ecx = how many ctrl+c to send to [pid]
send_ctrlc:
    push rbx
    sub rsp, 32
    mov ebx, ecx
    lea rcx, [cmd2]
    lea rdx, [self]
    call fmt_str
    mov rcx, rax
    mov rdx, [pid]
    call fmt_dec
    mov byte [rax], ' '
    lea rcx, [rax+1]
    mov edx, ebx
    call fmt_dec
    mov byte [rax], 0
    lea rcx, [cmd2]
    mov edx, NO_WINDOW
    call spawn
    mov rcx, rax
    call wait_exit
    add rsp, 32
    pop rbx
    ret

cleanup:
    sub rsp, 40
    lea rcx, [state]
    call file_delete
    lea rcx, [donepath]
    call file_delete
    add rsp, 40
    ret

global start
start:
    sub rsp, 40
    call lib_init
    cmp qword [argc], 4
    jb .tests
    mov rax, [argv+8]
    cmp dword [rax], 'send'
    je sender

.tests:
    lea rcx, [logsdir]
    call make_dir

    say "clean run", 13, 10
    call cleanup
    lea rcx, [fast]
    mov edx, NEW_CONSOLE
    call spawn
    mov rcx, rax
    call wait_exit
    cmp eax, 0
    check e, "finishes with exit 0"
    lea rcx, [donepath]
    call file_read_all
    mov rbx, rax                ; check trashes rax
    test rbx, rbx
    check nz, "writes its final state"
    test rbx, rbx
    jz .ctrlc
    movdqu xmm0, [rbx]
    movdqu [expected], xmm0
    movdqu xmm0, [rbx+16]
    movdqu [expected+16], xmm0
    movdqu xmm0, [rbx+32]
    movdqu [expected+32], xmm0

.ctrlc:
    say "one ctrl+c", 13, 10
    call cleanup
    lea rcx, [fast]
    mov edx, NEW_CONSOLE
    call spawn
    mov [hproc], rax
    mov ecx, 700
    call Sleep
    mov ecx, 1
    call send_ctrlc
    mov rcx, [hproc]
    call wait_exit
    cmp eax, 2
    check e, "saves and exits with 2"
    lea rcx, [state]
    call file_read_all
    mov rbx, rax
    test rbx, rbx
    check nz, "state file is there"
    test rbx, rbx
    jz .resume
    mov rbx, [rbx]
    say "  stopped at step "
    mov rcx, rbx
    call print_dec
    say 13, 10
    cmp rbx, 0
    seta al
    cmp rbx, 120
    setb cl
    and al, cl
    cmp al, 1
    check e, "stopped part way through"

.resume:
    say "resume", 13, 10
    lea rcx, [fast]
    mov edx, NEW_CONSOLE
    call spawn
    mov rcx, rax
    call wait_exit
    cmp eax, 0
    check e, "resumed run finishes with exit 0"
    lea rcx, [donepath]
    call file_read_all
    test rax, rax
    jz .nodone
    mov rsi, rax
    lea rdi, [expected]
    mov ecx, 48
    repe cmpsb
.nodone:
    check e, "ends bit-identical to the clean run (step, loss, rng)"

    say "two ctrl+c", 13, 10
    call cleanup
    lea rcx, [slow]
    mov edx, NEW_CONSOLE
    call spawn
    mov [hproc], rax
    mov ecx, 1000               ; well inside its first 3 second step
    call Sleep
    mov ecx, 2
    call send_ctrlc
    mov rcx, [hproc]
    call wait_exit
    cmp eax, 130
    check e, "second one forces exit 130"

    call cleanup
    jmp t_done

; helper mode: ctrltest send PID N
sender:
    mov rcx, [argv+16]
    call parse_int
    mov rbx, rax
    mov rcx, [argv+24]
    call parse_int
    mov rsi, rax
    call FreeConsole
    mov ecx, ebx
    call AttachConsole
    test eax, eax
    jz .fail
    xor ecx, ecx
    mov edx, 1
    call SetConsoleCtrlHandler  ; we're on that console now too, don't kill ourselves
.send:
    xor ecx, ecx                ; CTRL_C_EVENT
    xor edx, edx                ; to everything on the console
    call GenerateConsoleCtrlEvent
    mov ecx, 20
    call Sleep
    dec rsi
    jnz .send
    xor ecx, ecx
    call ExitProcess
.fail:
    mov ecx, 3
    call ExitProcess
