; ctrl+c handling. first one sets stop_flag so the main loop can finish its step
; and save; a second one quits on the spot
default rel
bits 64
%include "lib.inc"

extern SetConsoleCtrlHandler, ExitProcess, Sleep

section .bss
stop_flag resd 1

section .text

global ctrlc_init
ctrlc_init:
    sub rsp, 40
    ; "ignore ctrl+c" is inherited from whoever started us, turn it back off
    xor ecx, ecx
    xor edx, edx
    call SetConsoleCtrlHandler
    lea rcx, [ctrlc_handler]
    mov edx, 1
    call SetConsoleCtrlHandler
    add rsp, 40
    ret

; windows calls this on a fresh thread. ecx = event type
global ctrlc_handler
ctrlc_handler:
    sub rsp, 40
    cmp ecx, 1
    ja .closing                 ; 2 = window closed, 5/6 = logoff/shutdown
    lock bts dword [stop_flag], 0
    jc .force                   ; it was already set
    mov eax, 1                  ; handled, don't kill us
    add rsp, 40
    ret
.force:
    call con_restore
    say 13, 10, "forced exit", 13, 10
    mov ecx, 130
    call ExitProcess
.closing:
    ; we die when this returns, so stall and let the main loop save.
    ; windows gives up on us after ~5s anyway
    mov dword [stop_flag], 1
    mov ecx, 10000
    call Sleep
    mov eax, 1
    add rsp, 40
    ret
