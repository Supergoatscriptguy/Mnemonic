; chatdocs file.txt [out.docs]: hand-written conversations -> a chat .docs file
; (file.docs next to it unless told otherwise), for tokenize.
; conversations are separated by blank lines. "user:", "assistant:" or "system:"
; at the start of a line begins a message, any other line continues the last
; one (joined with a newline). lines starting with # are comments
default rel
bits 64
%include "lib.inc"
%include "data/docs.inc"

extern ExitProcess

MAXMSG equ 1 << 16

section .rdata
k_user   db "user:"
k_asst   db "assistant:"
k_sys    db "system:"
e_read   db "can't read the input", 0
e_line   db "a line that continues a message, but there's no message yet", 0
e_many   db "too many messages", 0

section .bss
alignb 8
offs     resq MAXMSG + 1
roles    resb MAXMSG
convs    resq MAXMSG + 1
nmsg     resq 1
nconv    resq 1
text     resq 1                 ; message text, joined
tlen     resq 1
hdr      resb DH_SIZE
outpath  resb 1024
open     resd 1                 ; a conversation is open (has messages)

section .text

global start
start:
    sub rsp, 40
    call lib_init
    cmp qword [argc], 2
    jb .usage
    mov rcx, [argv+8]
    call file_read_all
    test rax, rax
    jnz .have
    lea rcx, [e_read]
    call fatal
.usage:
    say "usage: chatdocs file.txt [out.docs]", 13, 10
    mov ecx, 1
    call ExitProcess
.have:
    mov rsi, rax                ; input, 0 terminated
    lea rcx, [rdx+64]
    call mem_alloc
    mov [text], rax
    call parse
    call write
    say "  "
    mov rcx, [nconv]
    call print_dec
    say " conversations, "
    mov rcx, [nmsg]
    call print_dec
    say " messages -> "
    lea rcx, [outpath]
    call print_z
    say 13, 10
    xor ecx, ecx
    call ExitProcess

; rsi = the text. fills offs/roles/convs/text
parse:
    push rbx
    push rdi
    push r12
    sub rsp, 32
    mov rdi, [text]
.line:
    cmp byte [rsi], 0
    je .eof
    ; this line is [rsi, rbx), without the \r\n
    mov rbx, rsi
.end:
    mov al, [rbx]
    test al, al
    jz .got
    cmp al, 10
    je .got
    inc rbx
    jmp .end
.got:
    mov r12, rbx                ; where the next line starts, after the \n
    cmp byte [r12], 10
    jne .trim
    inc r12
.trim:
    cmp rbx, rsi
    jbe .blank
    cmp byte [rbx-1], 13
    jne .content
    dec rbx
    jmp .trim
.content:
    cmp byte [rsi], '#'
    je .next
    ; a new message?
    mov r8d, ROLE_USER
    lea rcx, [k_user]
    mov edx, 5
    call prefix
    jz .msg
    mov r8d, ROLE_ASSIST
    lea rcx, [k_asst]
    mov edx, 10
    call prefix
    jz .msg
    mov r8d, ROLE_SYSTEM
    lea rcx, [k_sys]
    mov edx, 7
    call prefix
    jz .msg
    ; carries on the last message
    cmp dword [open], 0
    jne .cont
    lea rcx, [e_line]
    call fatal
.cont:
    mov byte [rdi], 10
    inc rdi
    jmp .copy
.msg:
    add rsi, rdx
    cmp byte [rsi], ' '
    jne .start
    inc rsi
.start:
    mov rax, [nmsg]
    cmp rax, MAXMSG
    jb .room
    lea rcx, [e_many]
    call fatal
.room:
    cmp dword [open], 0
    jne .inconv
    mov rcx, [nconv]            ; a conversation starts here
    lea rdx, [convs]
    mov [rdx+rcx*8], rax
    mov dword [open], 1
.inconv:
    ; close the previous message, open this one
    mov rcx, rdi
    sub rcx, [text]
    lea rdx, [offs]
    mov [rdx+rax*8], rcx
    lea rdx, [roles]
    mov [rdx+rax], r8b
    inc qword [nmsg]
.copy:
    mov rcx, rbx
    sub rcx, rsi
    rep movsb
    jmp .next
.blank:
    call close
.next:
    mov rsi, r12
    jmp .line
.eof:
    call close
    mov rax, [nmsg]
    mov rcx, rdi
    sub rcx, [text]
    lea rdx, [offs]
    mov [rdx+rax*8], rcx
    mov [tlen], rcx
    mov rax, [nconv]
    mov rcx, [nmsg]
    lea rdx, [convs]
    mov [rdx+rax*8], rcx
    add rsp, 32
    pop r12
    pop rdi
    pop rbx
    ret

; ends the open conversation, if there is one
close:
    cmp dword [open], 0
    je .done
    mov dword [open], 0
    inc qword [nconv]
.done:
    ret

; rsi = line, rcx = literal, edx = its length. zf set if the line starts with it
prefix:
    push rsi
    push rdi
    mov rdi, rcx
    mov ecx, edx
    repe cmpsb
    pop rdi
    pop rsi
    ret

; the .docs file: header, offsets, roles, convs, text, next to the input
write:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    lea rcx, [outpath]
    cmp qword [argc], 3
    jb .same
    mov rdx, [argv+16]          ; given an output path
    call fmt_str
    mov byte [rax], 0
    jmp .named
.same:
    mov rdx, [argv+8]
    call fmt_str
    ; swap the extension (whatever follows the last dot) for .docs
    mov rdi, rax
    lea rcx, [outpath]
.dot:
    cmp rdi, rcx
    jbe .ext
    dec rdi
    cmp byte [rdi], '.'
    jne .dot
.ext:
    mov dword [rdi], '.doc'
    mov word [rdi+4], 's'
.named:
    mov rax, DOCS_MAGIC
    mov [hdr+DH_MAGIC], rax
    mov rax, [nmsg]
    mov [hdr+DH_NDOCS], rax
    mov rax, [nconv]
    mov [hdr+DH_NCONV], rax
    mov rax, [tlen]
    mov [hdr+DH_BYTES], rax
    mov qword [hdr+DH_OFFS], DH_SIZE
    mov rax, [nmsg]
    lea rax, [DH_SIZE+rax*8+8]
    mov [hdr+DH_ROLES], rax
    add rax, [nmsg]
    add rax, 7
    and rax, -8
    mov [hdr+DH_CONVS], rax
    mov rcx, [nconv]
    lea rax, [rax+rcx*8+8]
    mov [hdr+DH_TEXT], rax
    lea rcx, [outpath]
    call file_create
    mov rbx, rax
    mov rcx, rbx
    lea rdx, [hdr]
    mov r8d, DH_SIZE
    call file_write
    mov rcx, rbx
    lea rdx, [offs]
    mov r8, [nmsg]
    lea r8, [r8*8+8]
    call file_write
    mov rcx, rbx
    lea rdx, [roles]
    mov r8, [nmsg]
    call file_write
    ; pad the roles out to 8
    mov rax, [hdr+DH_CONVS]
    sub rax, [hdr+DH_ROLES]
    sub rax, [nmsg]
    mov rcx, rbx
    lea rdx, [zeros]
    mov r8, rax
    call file_write
    mov rcx, rbx
    lea rdx, [convs]
    mov r8, [nconv]
    lea r8, [r8*8+8]
    call file_write
    mov rcx, rbx
    mov rdx, [text]
    mov r8, [tlen]
    call file_write
    mov rcx, rbx
    call file_close
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

section .rdata
zeros dq 0
