; command line and key = value config files.
; lookups search newest first, so load the cfg file, then cfg_args, and args win
default rel
bits 64
%include "lib.inc"

extern GetCommandLineA

MAXARGS equ 1024
MAXCFG  equ 256

section .bss
argc    resq 1
argv    resq MAXARGS
cmdbuf  resb 32768
ncfg    resq 1
cfg     resq MAXCFG * 2         ; key, value pointers

section .text

; splits the command line into argv. quotes group words, no escapes
global args_init
args_init:
    sub rsp, 40
    call GetCommandLineA
    mov r10, rax
    lea r11, [cmdbuf]
    lea r9, [argv]
    xor r8d, r8d
.skip:
    movzx eax, byte [r10]
    test al, al
    jz .end
    cmp al, ' '
    je .ws
    cmp al, 9
    jne .arg
.ws:
    inc r10
    jmp .skip
.arg:
    cmp r8d, MAXARGS
    jae .end
    mov [r9+r8*8], r11
    inc r8d
    xor edx, edx                ; inside quotes?
.ch:
    movzx eax, byte [r10]
    test al, al
    jz .term
    cmp al, '"'
    jne .notq
    xor edx, 1
    inc r10
    jmp .ch
.notq:
    test edx, edx
    jnz .keep
    cmp al, ' '
    je .term
    cmp al, 9
    je .term
.keep:
    mov [r11], al
    inc r11
    inc r10
    jmp .ch
.term:
    mov byte [r11], 0
    inc r11
    jmp .skip
.end:
    mov [argc], r8
    add rsp, 40
    ret

; rcx = key, rdx = value
cfg_add:
    mov rax, [ncfg]
    cmp rax, MAXCFG
    jae .full
    shl rax, 4
    lea r8, [cfg]
    mov [r8+rax], rcx
    mov [r8+rax+8], rdx
    inc qword [ncfg]
.full:
    ret

; rcx = path. eax = 1 if loaded, 0 if there's no such file.
; lines are key = value, # starts a comment. strings are cut up in place
global cfg_load
cfg_load:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    call file_read_all
    test rax, rax
    jz .done                    ; the buffer stays alive, entries point into it
    mov rsi, rax
.line:
    movzx eax, byte [rsi]
    test al, al
    jz .ok
    cmp al, 10
    je .next
    cmp al, 13
    je .next
    cmp al, ' '
    je .next
    cmp al, 9
    je .next
    cmp al, '#'
    je .eol
    mov rdi, rsi                ; key
.key:
    movzx eax, byte [rsi]
    cmp al, '='
    je .keyend
    cmp al, ' '
    je .keyend
    cmp al, 9
    je .keyend
    test al, al
    jz .ok
    cmp al, 10
    je .next                    ; no '=', ignore the line
    inc rsi
    jmp .key
.keyend:
    mov r12, rsi
.eq:
    movzx eax, byte [rsi]
    cmp al, ' '
    je .eqws
    cmp al, 9
    jne .eqchk
.eqws:
    inc rsi
    jmp .eq
.eqchk:
    cmp al, '='
    jne .eol
    mov byte [r12], 0
    inc rsi
.vws:
    movzx eax, byte [rsi]
    cmp al, ' '
    je .vskip
    cmp al, 9
    jne .val
.vskip:
    inc rsi
    jmp .vws
.val:
    mov rbx, rsi                ; value
.vend:
    movzx eax, byte [rsi]
    test al, al
    jz .trim0
    cmp al, 10
    je .trim0
    cmp al, '#'
    je .trim0
    inc rsi
    jmp .vend
.trim0:
    mov r12, rsi
.trim:
    cmp r12, rbx
    jbe .term
    movzx eax, byte [r12-1]
    cmp al, ' '
    je .trim1
    cmp al, 9
    je .trim1
    cmp al, 13
    jne .term
.trim1:
    dec r12
    jmp .trim
.term:
    movzx eax, byte [rsi]       ; grab the end char before we maybe overwrite it
    mov [rsp+32], rax
    mov byte [r12], 0
    mov rcx, rdi
    mov rdx, rbx
    call cfg_add
    mov rax, [rsp+32]
    test al, al
    jz .ok
    inc rsi
    cmp al, 10
    je .line
.eol:
    movzx eax, byte [rsi]
    test al, al
    jz .ok
    inc rsi
    cmp al, 10
    jne .eol
    jmp .line
.next:
    inc rsi
    jmp .line
.ok:
    mov eax, 1
.done:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; adds every key=value from the command line
global cfg_args
cfg_args:
    push rbx
    push rsi
    sub rsp, 40
    mov ebx, 1
.next:
    cmp rbx, [argc]
    jae .done
    lea rax, [argv]
    mov rsi, [rax+rbx*8]
    mov rdx, rsi
.find:
    mov al, [rdx]
    test al, al
    jz .skip
    cmp al, '='
    je .found
    inc rdx
    jmp .find
.found:
    mov byte [rdx], 0
    inc rdx
    mov rcx, rsi
    call cfg_add
.skip:
    inc ebx
    jmp .next
.done:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = key. rax = value string or 0
cfg_find:
    mov r8, [ncfg]
    lea r9, [cfg]
.next:
    test r8, r8
    jz .none
    dec r8
    mov r10, r8
    shl r10, 4
    mov r11, [r9+r10]
    xor edx, edx
.cmp:
    mov al, [rcx+rdx]
    cmp al, [r11+rdx]
    jne .next
    inc rdx
    test al, al
    jnz .cmp
    mov rax, [r9+r10+8]
    ret
.none:
    xor eax, eax
    ret

; rcx = key, rdx = default string
global cfg_str
cfg_str:
    sub rsp, 40
    mov [rsp+56], rdx
    call cfg_find
    test rax, rax
    jnz .done
    mov rax, [rsp+56]
.done:
    add rsp, 40
    ret

; rcx = key, rdx = default. takes 5e9 style too
global cfg_int
cfg_int:
    sub rsp, 40
    mov [rsp+56], rdx
    call cfg_find
    test rax, rax
    jz .def
    mov [rsp+48], rax
    mov rcx, rax
    call parse_int
    mov r8b, [rdx]
    or r8b, 0x20                ; 'E' -> 'e', '.' stays '.'
    cmp r8b, 'e'
    je .flt
    cmp r8b, '.'
    je .flt
    jmp .done
.flt:
    mov rcx, [rsp+48]
    call parse_float
    cvtsd2si rax, xmm0
    jmp .done
.def:
    mov rax, [rsp+56]
.done:
    add rsp, 40
    ret

; rcx = key, xmm1 = default. returns xmm0
global cfg_float
cfg_float:
    sub rsp, 40
    movsd [rsp+56], xmm1
    call cfg_find
    test rax, rax
    jz .def
    mov rcx, rax
    call parse_float
    jmp .done
.def:
    movsd xmm0, [rsp+56]
.done:
    add rsp, 40
    ret
