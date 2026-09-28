; tokshow "some text"        shows how the tokenizer splits it
; tokshow file.docs N         doc N of a .docs file (conversation N for chat files)
; [tok=datasets\tokenizer.bin]
; on a console every token gets its own background color, specials are yellow and
; the tokens a chat model is trained to produce are shaded green. redirected, the
; tokens are just separated with |
; uses: tokenizer\pretok tokenizer\tok tokenizer\render
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"
%include "data/docs.inc"

extern ExitProcess

section .rdata
k_tok    db "tok", 0
d_tok    db "datasets\tokenizer.bin", 0
usage    db 'usage: tokshow "text" | tokshow file.docs N  [tok=...]', 13, 10, 0
e_tok    db "can't load the tokenizer (train one with bpetrain)", 0
e_docs   db "can't open that .docs file", 0
; background colors (256 color codes, as text), plain and for targets
pal      db "24 ", "58 ", "53 ", "23 ", "94 ", "60 "
tpal     db "22 ", "28 ", "22 ", "28 ", "22 ", "28 "
hexd     db "0123456789abcdef"

section .bss
alignb 8
isf      resb 1024
ntok     resq 1
toks     resq 1
nbytes   resq 1
obuf     resq 1

section .text

global start
start:
    sub rsp, 40
    call lib_init
    mov r12d, 1
.which:
    cmp r12, [argc]
    jae .which1
    lea rax, [argv]
    mov rcx, [rax+r12*8]
    xor edx, edx
.w:
    mov al, [rcx+rdx]
    test al, al
    jz .file
    cmp al, '='
    je .notfile
    inc rdx
    jmp .w
.file:
    lea rax, [isf]
    mov byte [rax+r12], 1
.notfile:
    inc r12
    jmp .which
.which1:
    call cfg_args
    cmp byte [isf+1], 0
    jne .go
    lea rcx, [usage]
    call print_z
    mov ecx, 1
    call ExitProcess
.go:
    lea rcx, [k_tok]
    lea rdx, [d_tok]
    call cfg_str
    mov rcx, rax
    call tok_load
    test eax, eax
    jnz .loaded
    lea rcx, [e_tok]
    call fatal
.loaded:
    call tok_cache_new
    mov r15, rax
    ; a .docs file and an index, or just text?
    mov rsi, [argv+8]
    mov rcx, rsi
    call print_z_len
    cmp rax, 5
    jb .text
    cmp dword [rsi+rax-4], 'docs'
    jne .text
    cmp byte [isf+2], 0
    je .text
    mov rcx, rsi
    call file_map
    test rax, rax
    jnz .mapped
    lea rcx, [e_docs]
    call fatal
.mapped:
    mov rbx, rax
    mov rcx, [argv+16]
    call parse_int
    mov r12, rax
    ; room: the whole text is a safe bound
    mov rcx, [rbx+DH_BYTES]
    mov [nbytes], rcx
    lea rcx, [rcx*2+4096]
    call mem_alloc
    mov [toks], rax
    mov rcx, r15
    mov rdx, rbx
    mov r8, r12
    mov r9, [toks]
    cmp qword [rbx+DH_NCONV], 0
    jne .conv
    call render_doc
    mov [ntok], rax
    mov rax, [rbx+DH_OFFS]
    add rax, rbx
    mov rcx, [rax+r12*8+8]
    sub rcx, [rax+r12*8]
    mov [nbytes], rcx
    jmp .show
.conv:
    call render_conv
    mov [ntok], rax
    mov rax, [rbx+DH_CONVS]
    add rax, rbx
    mov rcx, [rax+r12*8]
    mov rdx, [rax+r12*8+8]
    mov rax, [rbx+DH_OFFS]
    add rax, rbx
    mov rdx, [rax+rdx*8]
    sub rdx, [rax+rcx*8]
    mov [nbytes], rdx
    jmp .show
.text:
    mov rcx, rsi
    call print_z_len
    mov [nbytes], rax
    lea rcx, [rax*2+64]
    call mem_alloc
    mov [toks], rax
    mov rcx, r15
    mov rdx, rsi
    mov r8, [nbytes]
    mov r9, [toks]
    call tok_encode
    mov [ntok], rax

.show:
    mov rcx, [ntok]
    imul rcx, rcx, 64
    add rcx, [nbytes]
    lea rcx, [rcx*4+4096]
    call mem_alloc
    mov [obuf], rax
    mov rdi, rax
    xor r12d, r12d
.tok:
    cmp r12, [ntok]
    jae .shown
    mov rax, [toks]
    movzx r13d, word [rax+r12*2]
    call put_token
    inc r12
    jmp .tok
.shown:
    cmp dword [con_tty], 0
    je .stats
    mov dword [rdi], 0x6d305b1b ; esc [0m
    add rdi, 4
.stats:
    mov word [rdi], 0x0a0d
    add rdi, 2
    mov rcx, [obuf]
    mov rdx, rdi
    sub rdx, rcx
    call print
    say 13, 10
    mov rcx, [ntok]
    call print_dec
    say " tokens, "
    mov rcx, [nbytes]
    call print_dec
    say " bytes"
    cmp qword [ntok], 0
    je .ids
    say ", "
    cvtsi2sd xmm0, qword [nbytes]
    cvtsi2sd xmm1, qword [ntok]
    divsd xmm0, xmm1
    mov edx, 2
    call print_fixed
    say " bytes/token"
.ids:
    say 13, 10
    cmp qword [ntok], 200
    ja .end
    xor r12d, r12d
.id:
    cmp r12, [ntok]
    jae .idend
    mov rax, [toks]
    movzx ecx, word [rax+r12*2]
    and ecx, MASKBIT - 1
    call print_dec
    say " "
    inc r12
    jmp .id
.idend:
    say 13, 10
.end:
    call con_restore
    xor ecx, ecx
    call ExitProcess

; rcx = zero terminated string. rax = its length
print_z_len:
    xor eax, eax
.c:
    cmp byte [rcx+rax], 0
    je .ret
    inc rax
    jmp .c
.ret:
    ret

; r13d = token (maybe with MASKBIT), r12 = its position. appends it at rdi
put_token:
    push rsi
    push rbx
    push r14
    sub rsp, 32
    mov ecx, r13d
    and ecx, MASKBIT - 1
    mov r14d, ecx
    call tok_bytes
    mov rsi, rax
    mov rbx, rdx
    cmp dword [con_tty], 0
    jne .color
    cmp r12, 0
    je .plainspec
    mov byte [rdi], '|'
    inc rdi
.plainspec:
    jmp .bytes
.color:
    cmp r14d, SPECIAL0
    jb .bg
    mov rax, 0x6d33333b315b1b   ; esc [1;33m
    mov [rdi], rax
    add rdi, 7
    jmp .bytes
.bg:
    ; esc [48;5;NNm esc [97m, the color cycling with the position
    mov rax, 0x3b353b38345b1b   ; esc [48;5;
    mov [rdi], rax
    add rdi, 7
    mov rax, r12
    xor edx, edx
    mov ecx, 6
    div rcx
    lea rax, [pal]
    test r13d, MASKBIT
    jz .pal
    lea rax, [tpal]
.pal:
    lea rcx, [rdx+rdx*2]
    mov dx, [rax+rcx]
    mov [rdi], dx
    add rdi, 2
    mov dword [rdi], 0x395b1b6d ; m esc [9
    mov word [rdi+4], 0x6d37    ; 7m
    add rdi, 6
.bytes:
    mov rcx, rsi
    mov rdx, rbx
    call utf8_ok
    test eax, eax
    jz .hex
.b:
    test rbx, rbx
    jz .end
    movzx eax, byte [rsi]
    inc rsi
    dec rbx
    cmp eax, 10
    je .nl
    cmp eax, 13
    je .b                       ; \r shows up as part of the \n that follows
    mov [rdi], al
    inc rdi
    jmp .b
.nl:
    ; a visible newline marker, then an actual line break
    mov dword [rdi], 0x00b586e2 ; U+21B5
    add rdi, 3
    cmp dword [con_tty], 0
    je .nl1
    mov dword [rdi], 0x6d305b1b
    add rdi, 4
.nl1:
    mov word [rdi], 0x0a0d
    add rdi, 2
    jmp .b
.hex:
    ; a piece of a multibyte character, show the bytes
.h:
    test rbx, rbx
    jz .end
    movzx eax, byte [rsi]
    inc rsi
    dec rbx
    mov word [rdi], '\x'
    mov edx, eax
    shr edx, 4
    lea r8, [hexd]
    mov dl, [r8+rdx]
    mov [rdi+2], dl
    and eax, 15
    mov al, [r8+rax]
    mov [rdi+3], al
    add rdi, 4
    jmp .h
.end:
    cmp dword [con_tty], 0
    je .ret
    mov dword [rdi], 0x6d305b1b ; esc [0m
    add rdi, 4
    cmp r14d, TOK_END
    jne .ret
    mov word [rdi], 0x0a0d      ; one turn per line
    add rdi, 2
.ret:
    add rsp, 32
    pop r14
    pop rbx
    pop rsi
    ret
