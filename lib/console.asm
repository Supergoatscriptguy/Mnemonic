; console output. everything goes through WriteFile so it still works redirected to a file
default rel
bits 64
%include "lib.inc"

extern GetStdHandle, WriteFile, GetConsoleMode, SetConsoleMode
extern GetConsoleOutputCP, SetConsoleOutputCP, GetLastError, ExitProcess
extern AddVectoredExceptionHandler, GetModuleHandleA
extern ReadConsoleW, WideCharToMultiByte, ReadFile

section .bss
con_out  resq 1
con_tty  resd 1                 ; 1 if stdout is a real console, not a file or pipe
oldmode  resd 1
oldcp    resd 1
written  resd 1
global con_intty
con_intty resd 1                ; stdin is a console
con_in   resq 1
wline    resw 4096

section .text

; what most programs want at startup
global lib_init
lib_init:
    sub rsp, 40
    call con_init
    call time_init
    call cpu_detect
    call args_init
    mov ecx, 1
    lea rdx, [crashed]
    call AddVectoredExceptionHandler
    add rsp, 40
    ret

; last stop for faults (access violation, divide by zero, ...): print where it
; happened as an offset into the exe (find it in bin\name.map), plus the registers
crashed:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, [rcx]              ; EXCEPTION_RECORD
    mov rdi, [rcx+8]            ; CONTEXT
    mov eax, [rsi]
    and eax, 0xf0000000
    cmp eax, 0xc0000000
    jne .pass                   ; only errors, not debugger/breakpoint chatter
    ; and only in our own code. system dlls sometimes fault on purpose and
    ; catch it themselves, that's none of our business
    xor ecx, ecx
    call GetModuleHandleA
    mov rbx, [rsi+16]
    sub rbx, rax                ; offset into the exe
    mov edx, [rax+0x3c]         ; PE header
    mov edx, [rax+rdx+0x50]     ; SizeOfImage
    cmp rbx, rdx
    jae .pass
    call con_restore
    say 13, 10, "crash: code 0x"
    mov ecx, [rsi]
    mov edx, 8
    call print_hex
    say " at exe+0x"
    mov rcx, rbx
    mov edx, 8
    call print_hex
    cmp dword [rsi], 0xc0000005
    jne .regs
    say ", touching 0x"
    mov rcx, [rsi+40]
    mov edx, 16
    call print_hex
.regs:
    say 13, 10
    lea rbx, [regnames]
    mov esi, 0x78               ; CONTEXT.Rax, the 16 gprs follow in order
.reg:
    mov rcx, rbx
    mov edx, 5
    call print
    mov rcx, [rdi+rsi]
    mov edx, 16
    call print_hex
    add rbx, 5
    add esi, 8
    lea eax, [esi-0x78]
    test eax, 31
    jnz .reg
    say 13, 10
    cmp esi, 0xf8
    jb .reg
    mov ecx, 3
    call ExitProcess
.pass:
    xor eax, eax                ; EXCEPTION_CONTINUE_SEARCH
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

section .rdata
regnames db " rax ", " rcx ", " rdx ", " rbx ", " rsp ", " rbp ", " rsi ", " rdi "
         db "  r8 ", "  r9 ", " r10 ", " r11 ", " r12 ", " r13 ", " r14 ", " r15 "
section .text

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

; rcx = buffer, rdx = its size. reads a line from stdin as utf-8, without the
; line break. rax = bytes, or -1 at the end of input (ctrl+z on a console).
; a console gets ReadConsoleW + a utf-16 -> utf-8 conversion, so non-ascii input
; works; redirected input is read as bytes
global con_readline
con_readline:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 72
    mov rsi, rcx
    mov r12, rdx
    cmp qword [con_in], 0
    jne .have
    mov ecx, -10                ; STD_INPUT_HANDLE
    call GetStdHandle
    mov [con_in], rax
    mov rcx, rax
    lea rdx, [rsp+64]
    call GetConsoleMode
    mov [con_intty], eax
.have:
    cmp dword [con_intty], 0
    je .bytes
    mov rcx, [con_in]
    lea rdx, [wline]
    mov r8d, 4096
    lea r9, [rsp+64]
    mov qword [rsp+32], 0
    call ReadConsoleW
    test eax, eax
    jz .eof
    mov ecx, [rsp+64]           ; utf-16 units read
    test ecx, ecx
    jz .eof
    lea rax, [wline]
    cmp word [rax], 26          ; ctrl+z
    je .eof
    mov ecx, 65001              ; CP_UTF8
    xor edx, edx
    lea r8, [wline]
    mov r9d, [rsp+64]
    mov [rsp+32], rsi
    mov [rsp+40], r12
    mov qword [rsp+48], 0
    mov qword [rsp+56], 0
    call WideCharToMultiByte
    mov rbx, rax
    jmp .trim
.bytes:
    ; a byte at a time until the newline (it's only for piped input)
    xor ebx, ebx
.b:
    cmp rbx, r12
    jae .trim
    mov rcx, [con_in]
    lea rdx, [rsi+rbx]
    mov r8d, 1
    lea r9, [rsp+64]
    mov qword [rsp+32], 0
    call ReadFile
    test eax, eax
    jz .end
    cmp dword [rsp+64], 0
    je .end
    cmp byte [rsi+rbx], 10
    je .nl
    inc rbx
    jmp .b
.end:
    test rbx, rbx
    jz .eof
    jmp .trim
.nl:
    inc rbx
    ; powershell puts a byte order mark in front of what it pipes
    cmp rbx, 3
    jb .trim
    mov eax, [rsi]
    and eax, 0xffffff
    cmp eax, 0xbfbbef
    jne .trim
    sub rbx, 3
    mov rcx, rbx
    mov rdi, rsi
    push rsi
    add rsi, 3
    rep movsb
    pop rsi
.trim:
    test rbx, rbx
    jz .done
    mov al, [rsi+rbx-1]
    cmp al, 10
    je .cut
    cmp al, 13
    jne .done
.cut:
    dec rbx
    jmp .trim
.done:
    mov rax, rbx
    jmp .out
.eof:
    mov rax, -1
.out:
    add rsp, 72
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = message. prints it with GetLastError and exits. never returns, so it can
; realign the stack and not care how it was reached
global fatal
fatal:
    and rsp, -16
    sub rsp, 48
    mov [rsp+32], rcx
    call GetLastError
    mov [rsp+40], rax
    say 13, 10, "error: "
    mov rcx, [rsp+32]
    call print_z
    say " (last error "
    mov rcx, [rsp+40]
    call print_dec
    say ")", 13, 10
    call con_restore
    mov ecx, 1
    call ExitProcess
