; the tokenizer at runtime: load merges, encode text, decode tokens.
; encoding a chunk = keep applying the lowest ranked merge found in it, left to
; right, same as training did. most chunks are common words, so each thread keeps
; a cache of chunk -> tokens and mostly just looks things up
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"

RBITS    equ 17                 ; rank table, pair -> merge number
RSIZE    equ 1 << RBITS
EMPTY    equ 0xffffffff
CBITS    equ 16                 ; chunk cache slots per context
CE_SIZE  equ 128                ; u64 hash, u8 len, u8 ntok, 6 pad, 48 bytes, 32 tokens
CE_MAXB  equ 48
CE_MAXT  equ 32
PIECE    equ 65536              ; chunks longer than this get encoded in pieces

section .rdata
e_tok    db "not a tokenizer file (or a different vocab size)", 0
specials db "<|bos|>", 0, "<|user|>", 0, "<|assistant|>", 0, "<|system|>", 0, "<|end|>", 0
s_resv   db "<|reserved|>", 0

section .bss
alignb 8
global tok_nmerges, tok_hash
tok_nmerges resq 1
tok_hash    resq 1
merges   resq 1
rkeys    resq 1
rvals    resq 1
toff     resq 1                 ; u32 per token plus one: its bytes are tblob[toff[i]..toff[i+1])
tblob    resq 1

section .text

; rcx = path. eax = 1 if it loaded
global tok_load
tok_load:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    call file_read_all
    test rax, rax
    jz .fail
    mov rbx, rax
    mov rcx, TK_MAGIC
    cmp [rbx+TKH_MAGIC], rcx
    jne .bad
    cmp dword [rbx+TKH_VOCAB], VOCAB
    jne .bad
    cmp dword [rbx+TKH_SPECIAL0], SPECIAL0
    jne .bad
    mov eax, [rbx+TKH_NMERGES]
    mov [tok_nmerges], rax
    mov rax, [rbx+TKH_HASH]
    mov [tok_hash], rax
    lea rax, [rbx+TKH_SIZE]
    mov [merges], rax

    ; ranks
    mov ecx, RSIZE * 4
    call mem_alloc
    mov [rkeys], rax
    mov rdi, rax
    mov ecx, RSIZE
    mov eax, EMPTY
    rep stosd
    mov ecx, RSIZE * 4
    call mem_alloc
    mov [rvals], rax
    xor r12d, r12d
.rk:
    cmp r12, [tok_nmerges]
    jae .strings
    mov rax, [merges]
    mov ecx, [rax+r12*4]
    rol ecx, 16                 ; stored a | b << 16, looked up as a << 16 | b
    mov eax, ecx
    mov edx, 0x9e3779b1
    imul eax, edx
    shr eax, 32 - RBITS
    mov r8, [rkeys]
.rp:
    cmp dword [r8+rax*4], EMPTY
    je .rput
    inc eax
    and eax, RSIZE - 1
    jmp .rp
.rput:
    mov [r8+rax*4], ecx
    mov r8, [rvals]
    mov [r8+rax*4], r12d
    inc r12
    jmp .rk

.strings:
    ; every token's bytes, in id order so lengths fall out of the offsets
    mov ecx, (VOCAB + 1) * 4
    call mem_alloc
    mov [toff], rax
    mov ecx, VOCAB * MAXWORD
    call mem_alloc
    mov [tblob], rax
    mov rdi, rax                ; where the next bytes go
    mov r13, [toff]
    xor ecx, ecx
.byte:
    mov [r13+rcx*4], ecx
    mov [rdi], cl
    inc rdi
    inc ecx
    cmp ecx, 256
    jb .byte
    xor r12d, r12d
.mg:
    cmp r12, [tok_nmerges]
    jae .unused
    lea eax, [r12d+256]
    mov rdx, rdi
    sub rdx, [tblob]
    mov [r13+rax*4], edx
    mov rax, [merges]
    mov eax, [rax+r12*4]
    movzx ecx, ax
    call .copy
    mov rax, [merges]
    mov eax, [rax+r12*4]
    shr eax, 16
    mov ecx, eax
    call .copy
    inc r12
    jmp .mg
.unused:
    ; ids past the last merge (a short training run) are empty
    lea r12d, [r12d+256]
.un:
    cmp r12d, SPECIAL0
    jae .spec
    mov rdx, rdi
    sub rdx, [tblob]
    mov [r13+r12*4], edx
    inc r12d
    jmp .un
.spec:
    lea rsi, [specials]
    xor ebx, ebx
.sp:
    cmp r12d, VOCAB
    jae .end
    mov rdx, rdi
    sub rdx, [tblob]
    mov [r13+r12*4], edx
    cmp ebx, 5
    jb .name
    lea rsi, [s_resv]
.name:
    lodsb
    test al, al
    jz .named
    stosb
    jmp .name
.named:
    cmp ebx, 5
    jae .sn
    inc ebx
.sn:
    inc r12d
    jmp .sp
.end:
    mov rdx, rdi
    sub rdx, [tblob]
    mov [r13+VOCAB*4], edx
    mov eax, 1
    jmp .ret
.fail:
    xor eax, eax
.ret:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.bad:
    lea rcx, [e_tok]
    call fatal
; copies token ecx's bytes to rdi (inside tok_load, its tokens are already done)
.copy:
    mov r8, [toff]
    mov esi, [r8+rcx*4]
    mov edx, [r8+rcx*4+4]
    sub edx, esi
    add rsi, [tblob]
    mov ecx, edx
    rep movsb
    ret

; ecx = token (MASKBIT is ignored). rax = its bytes, rdx = how many
global tok_bytes
tok_bytes:
    and ecx, MASKBIT - 1
    mov r8, [toff]
    mov eax, [r8+rcx*4]
    mov edx, [r8+rcx*4+4]
    sub edx, eax
    add rax, [tblob]
    ret

; ecx = pair key a << 16 | b. eax = merge number, EMPTY if there's no such merge.
; touches rdx, r8
rank:
    mov eax, ecx
    mov edx, 0x9e3779b1
    imul eax, edx
    shr eax, 32 - RBITS
    mov r8, [rkeys]
.p:
    mov edx, [r8+rax*4]
    cmp edx, ecx
    je .hit
    cmp edx, EMPTY
    je .none
    inc eax
    and eax, RSIZE - 1
    jmp .p
.hit:
    mov r8, [rvals]
    mov eax, [r8+rax*4]
    ret
.none:
    mov eax, EMPTY
    ret

; encodes one chunk the plain way. rcx = bytes, rdx = len (1..PIECE), r8 = out,
; r9 = work space (u16 x PIECE). rax = tokens written
global tok_encode_chunk
tok_encode_chunk:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov rsi, rcx
    mov r12, rdx                ; n
    mov r13, r8
    mov r14, r9
    cmp rdx, 1
    jne .load
    movzx eax, byte [rsi]
    mov [r13], ax
    mov eax, 1
    jmp .ret
.load:
    xor ecx, ecx
.l:
    movzx eax, byte [rsi+rcx]
    mov [r14+rcx*2], ax
    inc rcx
    cmp rcx, r12
    jb .l
.round:
    ; lowest ranked merge anywhere in the chunk
    mov r15d, EMPTY
    xor ebx, ebx
.scan:
    lea rax, [rbx+1]
    cmp rax, r12
    jae .scanned
    movzx ecx, word [r14+rbx*2]
    shl ecx, 16
    mov cx, [r14+rbx*2+2]
    call rank
    cmp eax, r15d
    cmovb r15d, eax
    inc rbx
    jmp .scan
.scanned:
    cmp r15d, EMPTY
    je .out
    ; apply it everywhere, left to right
    mov rax, [merges]
    mov eax, [rax+r15*4]
    movzx r8d, ax               ; a
    shr eax, 16
    mov r9d, eax                ; b
    lea r10d, [r15d+256]        ; the new token
    xor ecx, ecx                ; read
    xor edx, edx                ; write
.m:
    cmp rcx, r12
    jae .md
    movzx eax, word [r14+rcx*2]
    lea r11, [rcx+1]
    cmp r11, r12
    jae .keep
    cmp ax, r8w
    jne .keep
    cmp [r14+rcx*2+2], r9w
    jne .keep
    mov [r14+rdx*2], r10w
    add rcx, 2
    inc rdx
    jmp .m
.keep:
    mov [r14+rdx*2], ax
    inc rcx
    inc rdx
    jmp .m
.md:
    mov r12, rdx
    cmp r12, 1
    ja .round
.out:
    xor ecx, ecx
.o:
    movzx eax, word [r14+rcx*2]
    mov [r13+rcx*2], ax
    inc rcx
    cmp rcx, r12
    jb .o
    mov rax, r12
.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rax = a new encode context (cache + work space), one per thread
global tok_cache_new
tok_cache_new:
    push rbx
    sub rsp, 32
    mov ecx, TC_SIZE
    call mem_alloc
    mov rbx, rax
    mov ecx, (1 << CBITS) * CE_SIZE
    call mem_alloc
    mov [rbx+TC_CACHE], rax
    mov ecx, PIECE * 2 + 64
    call mem_alloc
    mov [rbx+TC_WORK], rax
    mov rax, rbx
    add rsp, 32
    pop rbx
    ret

; rcx = context, rdx = text, r8 = len, r9 = out (room for len tokens).
; rax = tokens written
global tok_encode
tok_encode:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rbx, rcx
    mov rsi, rdx
    lea r12, [rdx+r8]
    mov rdi, r9                 ; out cursor
    mov [rsp+32], r9
.chunk:
    cmp rsi, r12
    jae .done
    mov rcx, rsi
    mov rdx, r12
    call pretok_next
    mov r13, rax                ; end of this chunk
    mov r14, rax
    sub r14, rsi                ; its length
    cmp dword [rbx+TC_NOCACHE], 0
    jne .slow
    cmp r14, CE_MAXB
    ja .slow
    ; cached?
    mov rcx, rsi
    mov rdx, r14
    call whash
    mov r15, rax
    shr rax, 64 - CBITS
    shl rax, 7                  ; CE_SIZE
    add rax, [rbx+TC_CACHE]
    mov [rsp+40], rax
    cmp [rax], r15
    jne .miss
    movzx edx, byte [rax+8]
    cmp rdx, r14
    jne .miss
    lea r10, [rax+16]
    mov r11, rsi
    call memeq
    jne .miss
    mov rax, [rsp+40]
    movzx ecx, byte [rax+9]
    lea r8, [rax+64]
.hit:
    movzx edx, word [r8]
    mov [rdi], dx
    add r8, 2
    add rdi, 2
    dec ecx
    jnz .hit
    mov rsi, r13
    jmp .chunk
.miss:
    mov rcx, rsi
    mov rdx, r14
    mov r8, rdi
    mov r9, [rbx+TC_WORK]
    call tok_encode_chunk
    cmp rax, CE_MAXT
    ja .adv                     ; too many tokens to cache, fine
    ; remember it
    mov r8, [rsp+40]
    mov [r8], r15
    mov [r8+8], r14b
    mov [r8+9], al
    xor ecx, ecx
.cb:
    mov dl, [rsi+rcx]
    mov [r8+16+rcx], dl
    inc ecx
    cmp rcx, r14
    jb .cb
    xor ecx, ecx
.ct:
    mov dx, [rdi+rcx*2]
    mov [r8+64+rcx*2], dx
    inc ecx
    cmp rcx, rax
    jb .ct
    jmp .adv
.slow:
    ; long chunk (or cache off): encode it directly, PIECE bytes at a time
    mov rdx, r14
    cmp rdx, PIECE
    jbe .s1
    mov edx, PIECE
.s1:
    mov rcx, rsi
    mov r8, rdi
    mov r9, [rbx+TC_WORK]
    mov r15, rdx
    call tok_encode_chunk
    lea rdi, [rdi+rax*2]
    add rsi, r15
    sub r14, r15
    jnz .slow
    jmp .chunk
.adv:
    lea rdi, [rdi+rax*2]
    mov rsi, r13
    jmp .chunk
.done:
    mov rax, rdi
    sub rax, [rsp+32]
    shr rax, 1
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = tokens, rdx = how many, r8 = out. rax = bytes written.
; MASKBIT is ignored, specials come out as their names
global tok_decode
tok_decode:
    push rsi
    push rdi
    push rbx
    mov rbx, rcx
    mov r9, rdx
    mov rdi, r8
    mov r10, [toff]
    mov r11, [tblob]
.t:
    test r9, r9
    jz .done
    movzx eax, word [rbx]
    and eax, MASKBIT - 1
    mov esi, [r10+rax*4]
    mov ecx, [r10+rax*4+4]
    sub ecx, esi
    add rsi, r11
    rep movsb
    add rbx, 2
    dec r9
    jmp .t
.done:
    mov rax, rdi
    sub rax, r8
    pop rbx
    pop rdi
    pop rsi
    ret
