; just enough json for the lesson tools: find a value in an object or an array,
; decode a string, write one. llama-server's replies and our own jsonl files
default rel
bits 64
%include "lib.inc"

section .rdata
hexd     db "0123456789abcdef"

section .text

; rcx = text. rax = past any whitespace
global js_ws
js_ws:
    mov rax, rcx
.l:
    movzx ecx, byte [rax]
    cmp ecx, ' '
    je .n
    cmp ecx, 9
    jb .r
    cmp ecx, 13
    ja .r
.n:
    inc rax
    jmp .l
.r:
    ret

; rcx = the start of a value. rax = just past it
global js_skip
js_skip:
    mov rax, rcx
    movzx ecx, byte [rax]
    cmp ecx, '"'
    je .str
    cmp ecx, '{'
    je .nest
    cmp ecx, '['
    je .nest
.atom:
    movzx ecx, byte [rax]
    cmp ecx, ' '
    jbe .r
    cmp ecx, ','
    je .r
    cmp ecx, '}'
    je .r
    cmp ecx, ']'
    je .r
    inc rax
    jmp .atom
.str:
    inc rax
.s:
    movzx ecx, byte [rax]
    test ecx, ecx
    jz .r
    inc rax
    cmp ecx, '"'
    je .r
    cmp ecx, '\'
    jne .s
    cmp byte [rax], 0
    je .r
    inc rax
    jmp .s
.nest:
    xor edx, edx
.n:
    movzx ecx, byte [rax]
    test ecx, ecx
    jz .r
    inc rax
    cmp ecx, '"'
    je .ns
    cmp ecx, '{'
    je .in
    cmp ecx, '['
    je .in
    cmp ecx, '}'
    je .out
    cmp ecx, ']'
    jne .n
.out:
    dec edx
    jnz .n
    ret
.in:
    inc edx
    jmp .n
.ns:
    movzx ecx, byte [rax]
    test ecx, ecx
    jz .r
    inc rax
    cmp ecx, '"'
    je .n
    cmp ecx, '\'
    jne .ns
    cmp byte [rax], 0
    je .r
    inc rax
    jmp .ns
.r:
    ret

; rcx = an object, rdx = key (zero terminated). rax = its value, or 0
global js_get
js_get:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rdx
    call js_ws
    cmp byte [rax], '{'
    jne .no
    lea rsi, [rax+1]
.member:
    mov rcx, rsi
    call js_ws
    mov rsi, rax
    cmp byte [rsi], '"'
    jne .no
    ; keys are compared as written, ours never have escapes
    lea rcx, [rsi+1]
    mov rdx, rdi
    xor ebx, ebx
.cmp:
    mov al, [rdx]
    test al, al
    jz .end
    cmp al, [rcx]
    jne .val
    inc rcx
    inc rdx
    jmp .cmp
.end:
    cmp byte [rcx], '"'
    sete bl
.val:
    mov rcx, rsi
    call js_skip
    mov rcx, rax
    call js_ws
    cmp byte [rax], ':'
    jne .no
    lea rcx, [rax+1]
    call js_ws
    test ebx, ebx
    jnz .out
    mov rcx, rax
    call js_skip
    mov rcx, rax
    call js_ws
    cmp byte [rax], ','
    jne .no
    lea rsi, [rax+1]
    jmp .member
.no:
    xor eax, eax
.out:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = an array, edx = index. rax = that element, or 0
global js_at
js_at:
    push rbx
    sub rsp, 32
    mov ebx, edx
    call js_ws
    cmp byte [rax], '['
    jne .no
    lea rcx, [rax+1]
.el:
    call js_ws
    movzx ecx, byte [rax]
    test ecx, ecx
    jz .no
    cmp ecx, ']'
    je .no
    test ebx, ebx
    jz .out
    mov rcx, rax
    call js_skip
    mov rcx, rax
    call js_ws
    cmp byte [rax], ','
    jne .no
    lea rcx, [rax+1]
    dec ebx
    jmp .el
.no:
    xor eax, eax
.out:
    add rsp, 32
    pop rbx
    ret

; rcx = a string value, rdx = dst (as big as the json text is fine). escapes are
; decoded, \u into utf-8. rax = length (a 0 goes after it), -1 if it's not a string
global js_str
js_str:
    push rbx
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, rdx
    mov rbx, rdx
    mov rax, -1
    cmp byte [rsi], '"'
    jne .ret
    inc rsi
.c:
    movzx eax, byte [rsi]
    test eax, eax
    jz .end
    inc rsi
    cmp eax, '"'
    je .end
    cmp eax, '\'
    je .esc
.put:
    mov [rdi], al
    inc rdi
    jmp .c
.esc:
    movzx eax, byte [rsi]
    test eax, eax
    jz .end
    inc rsi
    cmp eax, 'u'
    je .u
    mov ecx, 10
    cmp eax, 'n'
    cmove eax, ecx
    mov ecx, 9
    cmp eax, 't'
    cmove eax, ecx
    mov ecx, 13
    cmp eax, 'r'
    cmove eax, ecx
    mov ecx, 8
    cmp eax, 'b'
    cmove eax, ecx
    mov ecx, 12
    cmp eax, 'f'
    cmove eax, ecx
    jmp .put
.u:
    call hex4
    cmp eax, -1
    je .c
    mov edx, eax
    and edx, 0xfc00
    cmp edx, 0xdc00
    je .bad                     ; a low surrogate on its own
    cmp edx, 0xd800
    jne .utf8
    ; a high surrogate, the low half should follow as \uXXXX
    cmp word [rsi], '\u'
    jne .bad
    mov r11, rsi
    add rsi, 2
    mov edx, eax
    call hex4
    mov ecx, eax
    and ecx, 0xfc00
    cmp ecx, 0xdc00
    jne .unpair
    sub edx, 0xd800
    shl edx, 10
    sub eax, 0xdc00
    lea eax, [eax+edx+0x10000]
    jmp .utf8
.unpair:
    mov rsi, r11
.bad:
    mov eax, 0xfffd
.utf8:
    cmp eax, 0x80
    jb .put
    cmp eax, 0x800
    jb .two
    cmp eax, 0x10000
    jb .three
    mov ecx, eax
    shr ecx, 18
    or ecx, 0xf0
    mov [rdi], cl
    inc rdi
    mov ecx, eax
    shr ecx, 12
    and ecx, 63
    or ecx, 0x80
    mov [rdi], cl
    inc rdi
    jmp .low2
.three:
    mov ecx, eax
    shr ecx, 12
    or ecx, 0xe0
    mov [rdi], cl
    inc rdi
.low2:
    mov ecx, eax
    shr ecx, 6
    and ecx, 63
    or ecx, 0x80
    mov [rdi], cl
    inc rdi
    jmp .low1
.two:
    mov ecx, eax
    shr ecx, 6
    or ecx, 0xc0
    mov [rdi], cl
    inc rdi
.low1:
    and eax, 63
    or eax, 0x80
    jmp .put
.end:
    mov byte [rdi], 0
    mov rax, rdi
    sub rax, rbx
.ret:
    pop rdi
    pop rsi
    pop rbx
    ret

; rsi = 4 hex digits. eax = their value and rsi moves past them, or eax = -1
hex4:
    xor eax, eax
    xor ecx, ecx
.d:
    movzx r8d, byte [rsi+rcx]
    sub r8d, '0'
    cmp r8d, 9
    jbe .ok
    movzx r8d, byte [rsi+rcx]
    or r8d, 0x20
    sub r8d, 'a'
    cmp r8d, 5
    ja .no
    add r8d, 10
.ok:
    shl eax, 4
    or eax, r8d
    inc ecx
    cmp ecx, 4
    jb .d
    add rsi, 4
    ret
.no:
    mov eax, -1
    ret

; rcx = dst, rdx = text, r8 = its length. writes it as a json string, quotes and
; all. rax = past the end
global js_put
js_put:
    push rsi
    push rdi
    mov rdi, rcx
    mov rsi, rdx
    lea r9, [rdx+r8]
    lea r10, [hexd]
    mov byte [rdi], '"'
    inc rdi
.c:
    cmp rsi, r9
    jae .end
    movzx eax, byte [rsi]
    inc rsi
    cmp eax, '"'
    je .q
    cmp eax, '\'
    je .q
    cmp eax, 10
    je .n
    cmp eax, 13
    je .r
    cmp eax, 9
    je .t
    cmp eax, 0x20
    jb .u
    mov [rdi], al
    inc rdi
    jmp .c
.q:
    mov byte [rdi], '\'
    mov [rdi+1], al
    add rdi, 2
    jmp .c
.n:
    mov word [rdi], '\n'
    add rdi, 2
    jmp .c
.r:
    mov word [rdi], '\r'
    add rdi, 2
    jmp .c
.t:
    mov word [rdi], '\t'
    add rdi, 2
    jmp .c
.u:
    mov dword [rdi], '\u00'
    mov ecx, eax
    shr ecx, 4
    mov cl, [r10+rcx]
    mov [rdi+4], cl
    and eax, 15
    mov al, [r10+rax]
    mov [rdi+5], al
    add rdi, 6
    jmp .c
.end:
    mov byte [rdi], '"'
    lea rax, [rdi+1]
    pop rdi
    pop rsi
    ret
