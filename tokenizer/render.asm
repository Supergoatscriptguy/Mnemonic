; turns .docs entries into token sequences:
;   plain doc:    <|bos|> text
;   conversation: <|bos|> then per message <|role|> content <|end|>
; in a conversation the assistant's content and its <|end|> get MASKBIT, those are
; what the model learns to produce. everything else is context
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"
%include "data/docs.inc"

section .rdata
roletok  dw TOK_SYSTEM, TOK_USER, TOK_ASSIST, TOK_USER

section .text

; rcx = encode context, rdx = mapped .docs, r8 = doc index, r9 = out. rax = tokens
global render_doc
render_doc:
    sub rsp, 40
    mov word [r9], TOK_BOS
    mov rax, [rdx+DH_OFFS]
    add rax, rdx
    mov r10, [rax+r8*8]
    mov r11, [rax+r8*8+8]
    sub r11, r10
    add r10, [rdx+DH_TEXT]
    add r10, rdx
    mov rdx, r10
    mov r8, r11
    add r9, 2
    call tok_encode
    inc rax
    add rsp, 40
    ret

; rcx = encode context, rdx = mapped .docs, r8 = conversation index, r9 = out. rax = tokens
global render_conv
render_conv:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov r12, rcx
    mov rbx, rdx
    mov rdi, r9
    mov r15, r9                 ; start, for the count at the end
    mov rax, [rbx+DH_CONVS]
    add rax, rbx
    mov rsi, [rax+r8*8]         ; first message
    mov r13, [rax+r8*8+8]       ; one past the last
    mov word [rdi], TOK_BOS
    add rdi, 2
.msg:
    cmp rsi, r13
    jae .done
    mov rax, [rbx+DH_ROLES]
    add rax, rbx
    movzx r14d, byte [rax+rsi]
    and r14d, 3
    lea rax, [roletok]
    mov ax, [rax+r14*2]
    mov [rdi], ax
    add rdi, 2
    mov rax, [rbx+DH_OFFS]
    add rax, rbx
    mov rdx, [rax+rsi*8]
    mov r8, [rax+rsi*8+8]
    sub r8, rdx
    add rdx, [rbx+DH_TEXT]
    add rdx, rbx
    mov rcx, r12
    mov r9, rdi
    call tok_encode
    mov word [rdi+rax*2], TOK_END
    inc rax
    cmp r14d, ROLE_ASSIST
    jne .next
    xor ecx, ecx                ; the assistant's tokens are the targets
.mark:
    or word [rdi+rcx*2], MASKBIT
    inc rcx
    cmp rcx, rax
    jb .mark
.next:
    lea rdi, [rdi+rax*2]
    inc rsi
    jmp .msg
.done:
    mov rax, rdi
    sub rax, r15
    shr rax, 1
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
