; bpetrain file.docs ... [bytes=1e9] [merges=32496] [out=datasets\tokenizer.bin] [naive=0]
; learns the bpe merges from the first `bytes` of text in the given .docs files.
; writes the tokenizer and, next to it, a readable vocab (.vocab.txt)
; uses: tokenizer\pretok tokenizer\bpe
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"
%include "data/docs.inc"

extern ExitProcess

section .rdata
k_bytes  db "bytes", 0
k_merges db "merges", 0
k_out    db "out", 0
k_naive  db "naive", 0
d_out    db "datasets\tokenizer.bin", 0
s_vocab  db ".vocab.txt", 0
s_tmp    db ".tmp", 0
usage    db "usage: bpetrain file.docs ... [bytes=1e9] [merges=32496] [out=...] [naive=0]", 13, 10, 0
e_docs   db "not a .docs file", 0
e_write  db "couldn't write the tokenizer", 0
specials db "<|bos|>", 0, "<|user|>", 0, "<|assistant|>", 0, "<|system|>", 0, "<|end|>", 0
hexd     db "0123456789abcdef"

section .bss
alignb 8
job      resb BT_SIZE
budget   resq 1
ndocs    resq 1
docs     resq 1
tbytes   resq 1
outp     resq 1
vpath    resb 1024
tmpp     resb 1024
tsoff    resq 1
tslen    resq 1
tsblob   resq 1
hdr      resb TKH_SIZE
isf      resb 1024               ; 1 = that arg is a file
t0       resq 1

section .text

global start
start:
    sub rsp, 40
    call lib_init
    ; note which args are files before cfg_args cuts the key=value ones up
    mov r12d, 1
.which:
    cmp r12, [argc]
    jae .which1
    lea rax, [argv]
    mov rcx, [rax+r12*8]
    call isfile
    lea rcx, [isf]
    mov [rcx+r12], al
    inc r12
    jmp .which
.which1:
    call cfg_args
    xor ecx, ecx
    call pool_init
    lea rcx, [k_bytes]
    mov edx, 1000000000
    call cfg_int
    mov [budget], rax
    lea rcx, [k_merges]
    mov edx, NMERGES
    call cfg_int
    cmp rax, NMERGES
    jbe .m
    mov eax, NMERGES
.m:
    mov [job+BT_NMERGES], rax
    lea rcx, [k_naive]
    xor edx, edx
    call cfg_int
    mov [job+BT_NAIVE], rax
    lea rcx, [k_out]
    lea rdx, [d_out]
    call cfg_str
    mov [outp], rax
    mov qword [job+BT_VERBOSE], 1

    ; the files are the args without an '='. first pass counts docs
    xor r15d, r15d              ; docs wanted
    mov r12d, 1
.count:
    cmp r12, [argc]
    jae .counted
    lea rax, [isf]
    cmp byte [rax+r12], 0
    je .cn
    lea rax, [argv]
    mov rcx, [rax+r12*8]
    call file_map
    test rax, rax
    jz .bad
    mov rcx, DOCS_MAGIC
    cmp [rax], rcx
    jne .bad
    add r15, [rax+DH_NDOCS]
.cn:
    inc r12
    jmp .count
.counted:
    test r15, r15
    jnz .alloc
    lea rcx, [usage]
    call print_z
    mov ecx, 1
    call ExitProcess
.alloc:
    lea rcx, [r15*8]
    shl rcx, 1
    call mem_alloc
    mov [docs], rax
    ; second pass: (ptr, len) for every doc until we have enough bytes
    mov rdi, rax
    xor ebx, ebx                ; bytes taken
    mov r12d, 1
.files:
    cmp r12, [argc]
    jae .took
    cmp rbx, [budget]
    jae .took
    lea rax, [isf]
    cmp byte [rax+r12], 0
    je .fn
    lea rax, [argv]
    mov rcx, [rax+r12*8]
    call file_map               ; mapped again, same pages, and it stays mapped
    mov rsi, rax
    mov r13, [rsi+DH_OFFS]
    add r13, rsi
    mov r14, [rsi+DH_TEXT]
    add r14, rsi
    xor ecx, ecx
.d:
    cmp rcx, [rsi+DH_NDOCS]
    jae .fn
    cmp rbx, [budget]
    jae .took
    mov rax, [r13+rcx*8]
    mov rdx, [r13+rcx*8+8]
    sub rdx, rax
    add rax, r14
    mov [rdi], rax
    mov [rdi+8], rdx
    add rdi, 16
    add rbx, rdx
    inc qword [ndocs]
    inc rcx
    jmp .d
.fn:
    inc r12
    jmp .files
.took:
    mov [tbytes], rbx
    mov rax, [docs]
    mov [job+BT_DOCS], rax
    mov rax, [ndocs]
    mov [job+BT_NDOCS], rax
    mov rcx, [job+BT_NMERGES]
    lea rcx, [rcx*4+8]          ; whash's tail load reads up to 8 bytes back, so some room in front
    call mem_alloc
    add rax, 8
    mov [job+BT_MERGES], rax
    mov rcx, [job+BT_NMERGES]
    shl rcx, 3
    call mem_alloc
    mov [job+BT_COUNTS], rax

    say "training on "
    mov rcx, [tbytes]
    call print_count_b
    say " of text, "
    mov rcx, [nthreads]
    call print_dec
    say " threads", 13, 10
    call time_now
    mov [t0], rax
    lea rcx, [job]
    call bpe_train
    say "  "
    mov rcx, [job+BT_DONE]
    call print_dec
    say " merges in "
    mov rcx, [t0]
    call time_since
    mov edx, 1
    call print_fixed
    say " s", 13, 10
    cmp qword [job+BT_BAD], 0
    je .save
    say "  WARNING: "
    mov rcx, [job+BT_BAD]
    call print_dec
    say " consistency problems", 13, 10

.save:
    ; tokenizer: header, then the merges
    mov rax, TK_MAGIC
    mov [hdr+TKH_MAGIC], rax
    mov dword [hdr+TKH_VOCAB], VOCAB
    mov rax, [job+BT_DONE]
    mov [hdr+TKH_NMERGES], eax
    mov dword [hdr+TKH_SPECIAL0], SPECIAL0
    mov dword [hdr+TKH_NSPECIAL], NSPECIAL
    mov rcx, [job+BT_MERGES]
    mov rdx, [job+BT_DONE]
    shl rdx, 2
    call whash
    mov [hdr+TKH_HASH], rax
    ; into out.tmp, then renamed over out, so a failed write leaves the old one
    lea rcx, [tmpp]
    mov rdx, [outp]
    call fmt_str
    mov rcx, rax
    lea rdx, [s_tmp]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [tmpp]
    call file_create
    cmp rax, -1
    je .werr
    mov rbx, rax
    mov rcx, rbx
    lea rdx, [hdr]
    mov r8d, TKH_SIZE
    call file_write
    test eax, eax
    jz .werr
    mov rcx, rbx
    mov rdx, [job+BT_MERGES]
    mov r8, [job+BT_DONE]
    shl r8, 2
    call file_write
    test eax, eax
    jz .werr
    mov rcx, rbx
    call file_flush
    mov rcx, rbx
    call file_close
    lea rcx, [tmpp]
    mov rdx, [outp]
    call file_replace
    test eax, eax
    jz .werr
    say "  wrote "
    mov rcx, [outp]
    call print_z
    say 13, 10
    call vocab
    say "  wrote "
    lea rcx, [vpath]
    call print_z
    say 13, 10
    call con_restore
    xor ecx, ecx
    call ExitProcess
.bad:
    lea rcx, [e_docs]
    call fatal
.werr:
    lea rcx, [e_write]
    call fatal

; rcx = arg. eax = 1 if it's a file name rather than key=value
isfile:
    xor eax, eax
.c:
    mov dl, [rcx]
    test dl, dl
    jz .yes
    cmp dl, '='
    je .no
    inc rcx
    jmp .c
.yes:
    mov eax, 1
.no:
    ret

print_count_b:
    sub rsp, 72
    mov rdx, rcx
    lea rcx, [rsp+32]
    call fmt_count
    cmp byte [rax-1], 'B'       ; fmt_count's B is billions, for bytes that's G
    jne .b
    mov byte [rax-1], 'G'
.b:
    mov byte [rax], 'B'
    inc rax
    lea rcx, [rsp+32]
    mov rdx, rax
    sub rdx, rcx
    call print
    add rsp, 72
    ret

; the vocab as text: id, the token quoted and escaped, how often its pair showed up
vocab:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    ; path: out with its extension swapped
    lea rcx, [vpath]
    mov rdx, [outp]
    call fmt_str
    mov rcx, rax
.dot:
    dec rcx
    lea rdx, [vpath]
    cmp rcx, rdx
    jb .noext
    cmp byte [rcx], '\'
    je .noext
    cmp byte [rcx], '.'
    jne .dot
    mov rax, rcx
.noext:
    mov rcx, rax
    lea rdx, [s_vocab]
    call fmt_str
    mov byte [rax], 0
    ; token strings from the merges
    mov ecx, VOCAB * 4
    call mem_alloc
    mov [tsoff], rax
    mov ecx, VOCAB * 2
    call mem_alloc
    mov [tslen], rax
    mov ecx, VOCAB * MAXWORD
    call mem_alloc
    mov [tsblob], rax
    xor ecx, ecx
.b:
    mov rax, [tsoff]
    mov [rax+rcx*4], ecx
    mov rax, [tslen]
    mov word [rax+rcx*2], 1
    mov rax, [tsblob]
    mov [rax+rcx], cl
    inc ecx
    cmp ecx, 256
    jb .b
    mov r12d, 256               ; blob used
    xor r13d, r13d
.mg:
    cmp r13, [job+BT_DONE]
    jae .text
    mov rax, [job+BT_MERGES]
    mov eax, [rax+r13*4]
    movzx r8d, ax               ; a
    shr eax, 16                 ; b
    mov r9d, eax
    lea r10d, [r13d+256]
    mov rax, [tsoff]
    mov [rax+r10*4], r12d
    mov rdi, [tsblob]
    add rdi, r12
    mov r11, [tslen]
    mov esi, [rax+r8*4]
    add rsi, [tsblob]
    movzx ecx, word [r11+r8*2]
    add r12, rcx
    mov edx, ecx
    rep movsb
    mov esi, [rax+r9*4]
    add rsi, [tsblob]
    movzx ecx, word [r11+r9*2]
    add r12, rcx
    add edx, ecx
    rep movsb
    mov [r11+r10*2], dx
    inc r13
    jmp .mg

.text:
    ; write it out through a 1 MB buffer
    mov ecx, 1 << 20
    call mem_alloc
    mov r15, rax
    lea rcx, [vpath]
    call file_create
    mov rbx, rax
    mov rdi, r15
    xor r13d, r13d              ; token
.tok:
    lea rax, [r13+256]
    cmp r13, SPECIAL0
    jae .spec
    cmp rax, 256
    jb .x
    mov rax, [job+BT_DONE]
    add rax, 256
    cmp r13, rax
    jae .spec0                  ; merges we didn't get to
.x:
    mov rcx, rdi
    mov rdx, r13
    call fmt_dec
    mov rdi, rax
    mov byte [rdi], 9
    inc rdi
    mov ecx, r13d
    call put_tok
    cmp r13, 256
    jb .eol
    mov byte [rdi], 9
    inc rdi
    mov rcx, rdi
    mov rax, [job+BT_COUNTS]
    mov rdx, [rax+r13*8-256*8]
    call fmt_dec
    mov rdi, rax
.eol:
    mov word [rdi], 0x0a0d
    add rdi, 2
    ; flush now and then
    mov rax, rdi
    sub rax, r15
    cmp rax, (1 << 20) - 4096
    jb .tn
    mov rcx, rbx
    mov rdx, r15
    mov r8, rax
    call file_write
    mov rdi, r15
.tn:
    inc r13
    jmp .tok
.spec0:
    mov r13d, SPECIAL0
.spec:
    ; the named ones
    lea rsi, [specials]
    mov r14d, 5
.sp:
    mov rcx, rdi
    mov rdx, r13
    call fmt_dec
    mov rdi, rax
    mov byte [rdi], 9
    inc rdi
    mov rcx, rdi
    mov rdx, rsi
    call fmt_str
    mov rdi, rax
    mov word [rdi], 0x0a0d
    add rdi, 2
.skipz:
    lodsb
    test al, al
    jnz .skipz
    inc r13
    dec r14d
    jnz .sp
    mov rcx, rbx
    mov rdx, r15
    mov r8, rdi
    sub r8, r15
    call file_write
    mov rcx, rbx
    call file_close
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ecx = token. writes it at rdi in quotes: raw if it's valid utf-8, with
; control chars (and ' and \) escaped, otherwise non-ascii bytes as \xNN too
put_tok:
    push rsi
    push r12
    push r13
    sub rsp, 32
    mov rax, [tsoff]
    mov esi, [rax+rcx*4]
    add rsi, [tsblob]
    mov rax, [tslen]
    movzx r12d, word [rax+rcx*2]
    mov rcx, rsi
    mov rdx, r12
    call utf8_ok
    mov r13d, eax
    mov byte [rdi], "'"
    inc rdi
.c:
    test r12d, r12d
    jz .end
    movzx eax, byte [rsi]
    inc rsi
    dec r12d
    cmp eax, 10
    je .nl
    cmp eax, 9
    je .tab
    cmp eax, 13
    je .cr
    cmp eax, "'"
    je .esc
    cmp eax, '\'
    je .esc
    cmp eax, 32
    jb .hex
    cmp eax, 127
    je .hex
    jb .raw
    test r13d, r13d
    jz .hex
.raw:
    mov [rdi], al
    inc rdi
    jmp .c
.esc:
    mov byte [rdi], '\'
    mov [rdi+1], al
    add rdi, 2
    jmp .c
.nl:
    mov word [rdi], '\n'
    add rdi, 2
    jmp .c
.tab:
    mov word [rdi], '\t'
    add rdi, 2
    jmp .c
.cr:
    mov word [rdi], '\r'
    add rdi, 2
    jmp .c
.hex:
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
    jmp .c
.end:
    mov byte [rdi], "'"
    inc rdi
    add rsp, 32
    pop r13
    pop r12
    pop rsi
    ret
