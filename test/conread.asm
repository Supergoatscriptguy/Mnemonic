; lib test: con_readline on a real console. it types into its own console input
; (WriteConsoleInputW), so nobody has to: a line longer than one 4096-unit read comes
; back whole, and the line after it is the next line, not the rest of the long one
default rel
bits 64
%include "lib.inc"
%include "test/check.inc"

extern AllocConsole, CreateFileA, SetStdHandle, WriteConsoleInputW, GetConsoleMode
extern SetConsoleMode, FlushConsoleInputBuffer, CloseHandle

LEN equ 6000

section .rdata
conin   db "CONIN$", 0
s_next  db "next"

section .bss
alignb 8
hin     resq 1
mode    resd 1
nw      resd 1
recs    resb 20 * 2 * (LEN + 8)
buf     resb 16384

section .text

; edx = a utf-16 unit, rdi = where the records go (a key down, then up). rdi moves on
key:
    mov ecx, edx
    and ecx, 0xdf               ; its key: the letter's capital, or 13 for enter
    mov eax, 1                  ; KEY_EVENT
    mov dword [rdi], eax
    mov dword [rdi+4], 1        ; down
    mov word [rdi+8], 1         ; repeat
    mov [rdi+10], cx
    mov word [rdi+12], 0
    mov [rdi+14], dx
    mov dword [rdi+16], 0
    mov dword [rdi+20], eax
    mov dword [rdi+24], 0       ; up
    mov word [rdi+28], 1
    mov [rdi+30], cx
    mov word [rdi+32], 0
    mov [rdi+34], dx
    mov dword [rdi+36], 0
    add rdi, 40
    ret

; LEN a's and enter, then next and enter, into the console's input
typeit:
    push rbx
    push rdi
    sub rsp, 40
    lea rdi, [recs]
    xor ebx, ebx
.k:
    mov edx, 'a'
    call key
    inc ebx
    cmp ebx, LEN
    jb .k
    mov edx, 13
    call key
    mov edx, 'n'
    call key
    mov edx, 'e'
    call key
    mov edx, 'x'
    call key
    mov edx, 't'
    call key
    mov edx, 13
    call key
    mov rcx, [hin]
    lea rdx, [recs]
    mov r8d, 2 * (LEN + 6)     ; two records a key
    lea r9, [nw]
    call WriteConsoleInputW
    add rsp, 40
    pop rdi
    pop rbx
    ret

global start
start:
    sub rsp, 56
    call lib_init
    call AllocConsole           ; fails if there's one already, that's fine
    lea rcx, [conin]
    mov edx, 0xc0000000         ; read and write
    mov r8d, 3
    xor r9d, r9d
    mov qword [rsp+32], 3       ; OPEN_EXISTING
    mov qword [rsp+40], 0
    mov qword [rsp+48], 0
    call CreateFileA
    cmp rax, -1
    jne .have
    say "  (no console to type into, skipping)", 13, 10
    jmp t_done
.have:
    mov [hin], rax
    mov ecx, -10                ; con_readline asks for stdin, give it this
    mov rdx, rax
    call SetStdHandle
    mov rcx, [hin]
    lea rdx, [mode]
    call GetConsoleMode
    mov edx, [mode]
    or edx, 3                   ; line input, processed
    and edx, ~4                 ; and no echo, 6000 a's on the screen help nobody
    mov rcx, [hin]
    call SetConsoleMode
    mov rcx, [hin]
    call FlushConsoleInputBuffer

    call typeit

    lea rcx, [buf]
    mov edx, 16384
    call con_readline
    mov rbx, rax
    cmp rbx, LEN
    jne .nl
    lea rdi, [buf]
    mov al, 'a'
    mov ecx, LEN
    repe scasb
.nl:
    check e, "a 6000 character line comes back whole"
    lea rcx, [buf]
    mov edx, 16384
    call con_readline
    cmp rax, 4
    jne .nx
    lea rsi, [buf]
    lea rdi, [s_next]
    mov ecx, 4
    repe cmpsb
.nx:
    check e, "and the next line is the next line"

    ; the same into a buffer of 1000: its first 1000, and the rest of it gets dropped
    call typeit
    lea rcx, [buf]
    mov edx, 1000
    call con_readline
    cmp rax, 1000
    check e, "into 1000 bytes: the first 1000 of it"
    lea rcx, [buf]
    mov edx, 16384
    call con_readline
    cmp rax, 4
    jne .nx2
    lea rsi, [buf]
    lea rdi, [s_next]
    mov ecx, 4
    repe cmpsb
.nx2:
    check e, "and the next line is still the next line"

    mov rcx, [hin]
    mov edx, [mode]
    call SetConsoleMode
    jmp t_done
