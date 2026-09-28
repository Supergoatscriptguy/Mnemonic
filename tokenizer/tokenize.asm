; tokenize file.docs ... [tok=datasets\tokenizer.bin]: writes file.tok next to each.
; plain docs become <|bos|> + tokens, one after another. chat files get the chat
; template, with MASKBIT on the assistant's tokens. all threads, in blocks of docs
; uses: tokenizer\pretok tokenizer\tok tokenizer\render
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"
%include "data/docs.inc"

extern ExitProcess

BLOCK equ 256                   ; docs (or conversations) per work item

; per thread
W_CTX     equ 0                 ; encode context
W_SCRATCH equ 8                 ; u16 buffer for one doc
W_SCAP    equ 16                ; its size in tokens
W_OUT     equ 24                ; arena for this file's tokens
W_SIZE    equ 64

section .rdata
k_tok    db "tok", 0
d_tok    db "datasets\tokenizer.bin", 0
s_tok    db ".tok", 0
s_tmp    db ".tmp", 0
usage    db "usage: tokenize file.docs ... [tok=datasets\tokenizer.bin]", 13, 10, 0
e_tok    db "can't load the tokenizer", 0
e_docs   db "not a .docs file", 0
e_write  db "couldn't write the .tok file", 0

section .bss
alignb 8
isf      resb 1024
wk       resb W_SIZE * 64
docs     resq 1                 ; the mapped .docs
chat     resq 1
nitems   resq 1
res      resq 1                 ; per block: tokens ptr, count
maxlen   resq 1                 ; tokens needed for the biggest item
hdr      resb TF_SIZE
outpath  resb 1024
tmppath  resb 1024
t0       resq 1
tot_tok  resq 1
tot_bytes resq 1

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
    jz .isfile
    cmp al, '='
    je .nf
    inc rdx
    jmp .w
.isfile:
    lea rax, [isf]
    mov byte [rax+r12], 1
.nf:
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
    xor ecx, ecx
    call pool_init
    xor ebx, ebx
.ws:
    cmp rbx, [nthreads]
    jae .wsd
    imul rdi, rbx, W_SIZE
    lea rax, [wk]
    add rdi, rax
    call tok_cache_new
    mov [rdi+W_CTX], rax
    lea rcx, [rdi+W_OUT]
    mov rdx, 1 << 36
    call arena_init
    inc ebx
    jmp .ws
.wsd:
    mov r12d, 1
.file:
    cmp r12, [argc]
    jae .done
    lea rax, [isf]
    cmp byte [rax+r12], 0
    je .fn
    lea rax, [argv]
    mov rcx, [rax+r12*8]
    call one_file
.fn:
    inc r12
    jmp .file
.done:
    call con_restore
    xor ecx, ecx
    call ExitProcess

; rcx = .docs path
one_file:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rsi, rcx
    call file_map
    test rax, rax
    jz .bad
    mov rbx, rax
    mov rcx, DOCS_MAGIC
    cmp [rbx+DH_MAGIC], rcx
    jne .bad
    mov [docs], rbx
    call time_now
    mov [t0], rax

    ; plain docs or conversations, and the biggest one for the scratch buffers
    mov rax, [rbx+DH_NCONV]
    mov [chat], rax
    xor r13d, r13d              ; biggest
    mov r8, [rbx+DH_OFFS]
    add r8, rbx
    test rax, rax
    jnz .convs
    mov rax, [rbx+DH_NDOCS]
    mov [nitems], rax
    xor ecx, ecx
.dm:
    cmp rcx, [nitems]
    jae .sized
    mov rax, [r8+rcx*8+8]
    sub rax, [r8+rcx*8]
    cmp rax, r13
    cmova r13, rax
    inc rcx
    jmp .dm
.convs:
    mov [nitems], rax
    mov r9, [rbx+DH_CONVS]
    add r9, rbx
    xor ecx, ecx
.cm:
    cmp rcx, [nitems]
    jae .sized
    mov r10, [r9+rcx*8]         ; first message
    mov r11, [r9+rcx*8+8]
    mov rax, [r8+r11*8]
    sub rax, [r8+r10*8]         ; its bytes
    sub r11, r10
    lea rax, [rax+r11*2]        ; + a role and an end token per message
    cmp rax, r13
    cmova r13, rax
    inc rcx
    jmp .cm
.sized:
    add r13, 16
    mov [maxlen], r13
    ; every thread's scratch big enough for that, and a fresh output arena
    xor r14d, r14d
.ts:
    cmp r14, [nthreads]
    jae .tsd
    imul rdi, r14, W_SIZE
    lea rax, [wk]
    add rdi, rax
    lea rcx, [rdi+W_OUT]
    call arena_reset
    cmp [rdi+W_SCAP], r13
    jae .tsn
    mov rcx, [rdi+W_SCRATCH]
    test rcx, rcx
    jz .ta
    call mem_free
.ta:
    lea rcx, [r13*2]
    call mem_alloc
    mov [rdi+W_SCRATCH], rax
    mov [rdi+W_SCAP], r13
.tsn:
    inc r14
    jmp .ts
.tsd:
    mov rcx, [nitems]
    add rcx, BLOCK - 1
    shr rcx, 8                  ; BLOCK
    mov r15, rcx
    shl rcx, 4
    add rcx, 16
    call mem_alloc
    mov [res], rax
    lea rcx, [block_task]
    xor edx, edx
    mov r8, r15
    mov r9d, 1
    call par_for

    ; header, then every block's tokens in order
    xor eax, eax
    xor ecx, ecx
.sum:
    cmp rcx, r15
    jae .summed
    mov rdx, [res]
    shl rcx, 4
    add rax, [rdx+rcx+8]
    shr rcx, 4
    inc rcx
    jmp .sum
.summed:
    mov r14, rax                ; tokens
    mov rcx, TF_MAGIC_V
    mov [hdr+TF_MAGIC], rcx
    mov [hdr+TF_NTOK], r14
    mov rax, [nitems]
    mov [hdr+TF_NDOCS], rax
    mov qword [hdr+TF_VOCAB], VOCAB
    mov rax, [tok_hash]
    mov [hdr+TF_HASH], rax
    xor eax, eax
    cmp qword [chat], 0
    setne al
    mov [hdr+TF_FLAGS], rax

    mov rcx, rsi
    call names
    lea rcx, [tmppath]
    call file_create
    cmp rax, -1
    je .werr
    mov rdi, rax
    mov rcx, rdi
    lea rdx, [hdr]
    mov r8d, TF_SIZE
    call file_write
    xor r12d, r12d
.wb:
    cmp r12, r15
    jae .wdone
    mov rax, [res]
    mov rcx, r12
    shl rcx, 4
    mov rdx, [rax+rcx]
    mov r8, [rax+rcx+8]
    shl r8, 1
    mov rcx, rdi
    call file_write
    test eax, eax
    jz .werr
    inc r12
    jmp .wb
.wdone:
    mov rcx, rdi
    call file_close
    lea rcx, [tmppath]
    lea rdx, [outpath]
    call file_replace
    test eax, eax
    jz .werr

    ; report
    lea rcx, [outpath]
    call print_z
    say "   "
    mov rcx, r14
    call print_dec
    say " tokens, "
    mov rax, [docs]
    cvtsi2sd xmm0, qword [rax+DH_BYTES]
    cvtsi2sd xmm1, r14
    divsd xmm0, xmm1
    mov edx, 2
    call print_fixed
    say " bytes/token, "
    mov rcx, [t0]
    call time_since
    movsd [rsp+32], xmm0
    mov edx, 2
    call print_fixed
    say " s ("
    mov rax, [docs]
    cvtsi2sd xmm0, qword [rax+DH_BYTES]
    divsd xmm0, [rsp+32]
    mov rax, 0x412e848000000000     ; 1e6
    movq xmm1, rax
    divsd xmm0, xmm1
    mov edx, 0
    call print_fixed
    say " MB/s)", 13, 10
    add [tot_tok], r14
    mov rax, [docs]
    mov rax, [rax+DH_BYTES]
    add [tot_bytes], rax

    mov rcx, [res]
    call mem_free
    mov rcx, [docs]
    call file_unmap
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.bad:
    lea rcx, [e_docs]
    call fatal
.werr:
    lea rcx, [e_write]
    call fatal

; rcx = .docs path. outpath = same with .tok, tmppath = that plus .tmp
names:
    sub rsp, 40
    mov rdx, rcx
    lea rcx, [outpath]
    call fmt_str
    mov rcx, rax
.dot:
    dec rcx
    lea rdx, [outpath]
    cmp rcx, rdx
    jb .noext
    cmp byte [rcx], '\'
    je .noext
    cmp byte [rcx], '.'
    jne .dot
    mov rax, rcx
.noext:
    mov rcx, rax
    lea rdx, [s_tok]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [tmppath]
    lea rdx, [outpath]
    call fmt_str
    mov rcx, rax
    lea rdx, [s_tmp]
    call fmt_str
    mov byte [rax], 0
    add rsp, 40
    ret

; par_for: blocks rdx..r8, thread r9. each block's tokens end up contiguous in
; the thread's arena (2 byte aligned allocations sit right after each other)
block_task:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov r12, rdx
    mov r13, r8
    imul rbx, r9, W_SIZE
    lea rax, [wk]
    add rbx, rax
.blk:
    cmp r12, r13
    jae .done
    mov r14, r12
    shl r14, 8                  ; first item
    lea r15, [r14+BLOCK]
    cmp r15, [nitems]
    jbe .rng
    mov r15, [nitems]
.rng:
    mov rax, [res]
    mov rcx, r12
    shl rcx, 4
    mov qword [rax+rcx], 0
    mov qword [rax+rcx+8], 0
.item:
    cmp r14, r15
    jae .bnext
    mov rcx, [rbx+W_CTX]
    mov rdx, [docs]
    mov r8, r14
    mov r9, [rbx+W_SCRATCH]
    cmp qword [chat], 0
    jne .c
    call render_doc
    jmp .r
.c:
    call render_conv
.r:
    mov rsi, rax
    lea rcx, [rbx+W_OUT]
    lea rdx, [rax*2]
    mov r8d, 2
    call arena_alloc
    mov rdi, rax
    mov rdx, [res]
    mov rcx, r12
    shl rcx, 4
    cmp qword [rdx+rcx], 0
    jne .have
    mov [rdx+rcx], rax
.have:
    add [rdx+rcx+8], rsi
    mov rcx, rsi
    mov rsi, [rbx+W_SCRATCH]
    rep movsw
    inc r14
    jmp .item
.bnext:
    inc r12
    jmp .blk
.done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
