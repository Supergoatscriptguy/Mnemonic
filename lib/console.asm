; console output. everything goes through WriteFile so it still works redirected to a file
default rel
bits 64
%include "lib.inc"

extern GetStdHandle, WriteFile, GetConsoleMode, SetConsoleMode
extern GetConsoleOutputCP, SetConsoleOutputCP, GetLastError, ExitProcess

section .bss
con_out  resq 1
con_tty  resd 1                 ; 1 if stdout is a real console, not a file or pipe
oldmode  resd 1
oldcp    resd 1
written  resd 1

section .text

; what most programs want at startup
global lib_init
lib_init:
    sub rsp, 40
    call con_init
    call time_init
    call cpu_detect
    call args_init
    add rsp, 40
    ret

global con_init
con_init:
    sub rsp, 40
    mov ecx, -11                ; STD_OUTPUT_HANDLE
    call GetStdHandle
    mov [con_out], rax
    mov rcx, rax
    lea rdx, [oldmode]
    call GetConsoleMode
    test eax, eax
    jz .done                    ; redirected, leave it alone
    mov dword [con_tty], 1
    mov rcx, [con_out]
    mov edx, [oldmode]
    or edx, 5                   ; PROCESSED_OUTPUT | VIRTUAL_TERMINAL_PROCESSING
    call SetConsoleMode
    call GetConsoleOutputCP
    mov [oldcp], eax
    mov ecx, 65001              ; utf-8, for the bar characters
    call SetConsoleOutputCP
.done:
    add rsp, 40
    ret

; put the console back how we found it, the shell shares it with us
global con_restore
con_restore:
    sub rsp, 40
    cmp dword [con_tty], 0
    je .done
    say 27, "[0m", 27, "[?25h"  ; plain colors, cursor back on
    mov rcx, [con_out]
    mov edx, [oldmode]
    call SetConsoleMode
    mov ecx, [oldcp]
    call SetConsoleOutputCP
.done:
    add rsp, 40
    ret

; rcx = ptr, rdx = len
global print
print:
    sub rsp, 40
    mov r8, rdx
    mov rdx, rcx
    mov rcx, [con_out]
    lea r9, [written]
    mov qword [rsp+32], 0
    call WriteFile
    add rsp, 40
    ret

; rcx = zero terminated string
global print_z
print_z:
    mov rdx, rcx
.len:
    cmp byte [rdx], 0
    je .go
    inc rdx
    jmp .len
.go:
    sub rdx, rcx
    jmp print                   ; tail call, print returns straight to our caller

; print_x(a, b) = fmt_x(buf, a, b) then print. every arg slides over one slot
%macro printer 2
global %1
%1:
    sub rsp, 120                ; 40 for calls + 80 byte buffer
    mov r8, rdx
    mov rdx, rcx
    movapd xmm1, xmm0
    lea rcx, [rsp+40]
    call %2
    lea rcx, [rsp+40]
    mov rdx, rax
    sub rdx, rcx
    call print
    add rsp, 120
    ret
%endmacro

printer print_dec, fmt_dec      ; rcx = unsigned
printer print_int, fmt_int      ; rcx = signed
printer print_hex, fmt_hex      ; rcx = value, edx = digits
printer print_fixed, fmt_fixed  ; xmm0 = value, edx = decimals
printer print_sci, fmt_sci      ; xmm0 = value, edx = decimals

; rcx = message. prints it with GetLastError and exits
global fatal
fatal:
    sub rsp, 40
    mov [rsp+48], rcx           ; our home slots
    call GetLastError
    mov [rsp+56], rax
    say 13, 10, "error: "
    mov rcx, [rsp+48]
    call print_z
    say " (last error "
    mov rcx, [rsp+56]
    call print_dec
    say ")", 13, 10
    call con_restore
    mov ecx, 1
    call ExitProcess
