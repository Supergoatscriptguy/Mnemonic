; chatpack out.tok in.tok [in.tok*3 ...] [ctx=1024] [seed=1]
; chat .tok files -> one file for fine-tuning. the conversations (each input
; repeated *N times) get shuffled and packed into blocks of exactly ctx tokens:
; every block starts at a conversation and none crosses into the next block, the
; leftover room is <|bos|> padding that's never a target. the trainer reads rows
; of ctx+1 tokens with a stride of ctx, so each row is one block, and no row
; starts in the middle of a conversation. longer conversations keep their first
; ctx tokens
; uses: tokenizer\tok tokenizer\pretok
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"

extern ExitProcess

MAXIN  equ 64
MAXCV  equ 4 << 20              ; conversations, repeats included
WINDOW equ 256                  ; how far ahead to look for one that fits
CHUNK  equ 32 << 20             ; output buffer

; a conversation: pointer to its tokens, token count
CV_PTR equ 0
CV_LEN equ 8

section .rdata
k_ctx    db "ctx", 0
k_seed   db "seed", 0
e_usage  db "usage: chatpack out.tok in.tok [in.tok*N ...] [ctx=1024] [seed=1]", 0
e_open   db "can't map ", 0
e_chat   db "not a chat .tok file: ", 0
e_hash   db "the inputs were made with different tokenizers", 0
e_many   db "too many conversations", 0
e_write  db "couldn't write the output", 0
align 8
c_100    dq 100.0

section .bss
alignb 8
cv       resq 1                 ; MAXCV entries of 16 bytes
used     resq 1
order    resq 1                 ; conversation indices, -1 ends a block
ncv      resq 1
nord     resq 1
nblk     resq 1
ntrunc   resq 1
ctx      resq 1
hash     resq 1
content  resq 1                 ; real tokens (not padding)
targets  resq 1
outbuf   resq 1
outn     resq 1
outh     resq 1
rng      resb RNG_SIZE
hdr      resb TF_SIZE
files    resq MAXIN
reps     resq MAXIN
nfiles   resq 1
outname  resq 1
padbuf   resq 1                 ; ctx tokens of padding

section .text

global start
start:
    sub rsp, 40
    call lib_init
    ; files first: cfg_args writes over the '=' of the options
    xor ebx, ebx
    mov esi, 1
.arg:
    cmp rsi, [argc]
    jae .args
    lea rax, [argv]
    mov rdi, [rax+rsi*8]
    mov rcx, rdi
.eq:
    mov al, [rcx]
    test al, al
    jz .file
    cmp al, '='
    je .nexta
    inc rcx
    jmp .eq
.file:
    cmp qword [outname], 0
    jne .input
    mov [outname], rdi
    jmp .nexta
.input:
    cmp ebx, MAXIN
    jae .nexta
    ; path*N: N copies
    lea rax, [reps]
    mov qword [rax+rbx*8], 1
    mov rcx, rdi
.star:
    mov al, [rcx]
    test al, al
    jz .keep
    cmp al, '*'
    je .n
    inc rcx
    jmp .star
.n:
    mov byte [rcx], 0
    inc rcx
    call parse_int
    lea rcx, [reps]
    mov [rcx+rbx*8], rax
.keep:
    lea rcx, [files]
    mov [rcx+rbx*8], rdi
    inc ebx
.nexta:
    inc esi
    jmp .arg
.args:
    mov [nfiles], rbx
    test rbx, rbx
    jnz .go
    lea rcx, [e_usage]
    call print_z
    say 13, 10
    mov ecx, 1
    call ExitProcess
.go:
    call cfg_args
    lea rcx, [k_ctx]
    mov edx, 1024
    call cfg_int
    mov [ctx], rax
    lea rcx, [k_seed]
    mov edx, 1
    call cfg_int
    lea rcx, [rng]
    mov rdx, rax
    call rng_seed
    mov ecx, MAXCV * 16
    call mem_alloc
    mov [cv], rax
    mov ecx, MAXCV
    call mem_alloc
    mov [used], rax
    mov ecx, MAXCV * 16
    call mem_alloc
    mov [order], rax

    xor esi, esi
.in:
    cmp rsi, [nfiles]
    jae .gathered
    lea rax, [files]
    mov rcx, [rax+rsi*8]
    lea rax, [reps]
    mov rdx, [rax+rsi*8]
    call gather
    inc rsi
    jmp .in
.gathered:
    call shuffle
    call pack
    call write
    call report
    xor ecx, ecx
    call ExitProcess

; rcx = input path, rdx = copies. adds its conversations (split at <|bos|>) to cv
gather:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    call file_map
    test rax, rax
    jnz .mapped
    lea rcx, [e_open]
    call print_z
    mov rcx, rbx
    call fatal
.mapped:
    mov rsi, rax
    mov rcx, TF_MAGIC_V
    cmp [rsi+TF_MAGIC], rcx
    jne .notchat
    test qword [rsi+TF_FLAGS], 1
    jz .notchat
    mov rax, [rsi+TF_HASH]
    cmp qword [hash], 0
    je .sethash
    cmp rax, [hash]
    je .hashok
    lea rcx, [e_hash]
    call fatal
.sethash:
    mov [hash], rax
.hashok:
    mov r13, [rsi+TF_NTOK]
    lea rdi, [rsi+TF_SIZE]      ; tokens
.copy:
    test r12, r12
    jz .done
    ; walk the tokens, a conversation from each <|bos|> to the next one
    xor ecx, ecx                ; index
    mov r14, -1                 ; start of the open conversation
.t:
    cmp rcx, r13
    jae .last
    movzx eax, word [rdi+rcx*2]
    and eax, MASKBIT - 1
    cmp eax, TOK_BOS
    jne .nt
    test r14, r14
    js .open
    call addcv
.open:
    mov r14, rcx
.nt:
    inc rcx
    jmp .t
.last:
    test r14, r14
    js .next
    call addcv
.next:
    dec r12
    jmp .copy
.done:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.notchat:
    lea rcx, [e_chat]
    call print_z
    mov rcx, rbx
    call fatal

; gather's helper: tokens [r14, rcx) of rdi become one conversation. keeps rcx
addcv:
    mov rax, [ncv]
    cmp rax, MAXCV
    jb .room
    lea rcx, [e_many]
    call fatal
.room:
    shl rax, 4
    add rax, [cv]
    lea rdx, [rdi+r14*2]
    mov [rax+CV_PTR], rdx
    mov rdx, rcx
    sub rdx, r14
    cmp rdx, [ctx]
    jbe .fits
    mov rdx, [ctx]              ; keep the first ctx tokens
    inc qword [ntrunc]
.fits:
    mov [rax+CV_LEN], rdx
    inc qword [ncv]
    ret

; fisher-yates over the conversations
shuffle:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, [ncv]
.i:
    cmp rbx, 1
    jbe .done
    lea rcx, [rng]
    call rng_next
    xor edx, edx
    div rbx                     ; j in [0, i]
    dec rbx
    mov rsi, [cv]
    shl rdx, 4
    add rdx, rsi
    mov rax, rbx
    shl rax, 4
    add rax, rsi
    movdqu xmm0, [rax]
    movdqu xmm1, [rdx]
    movdqu [rax], xmm1
    movdqu [rdx], xmm0
    jmp .i
.done:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; fills blocks in order: the first unused conversation, then whatever else in the
; next WINDOW still fits. order gets the indices, -1 after each block
pack:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    mov rsi, [cv]
    mov rdi, [used]
    mov r8, [order]
    xor r9d, r9d                ; order length
    xor ebx, ebx                ; first unused
.blk:
    cmp rbx, [ncv]
    jae .done
    xor r12d, r12d              ; tokens in this block
    mov rcx, rbx                ; candidate
    xor r13d, r13d              ; looked at
.cand:
    cmp rcx, [ncv]
    jae .close
    cmp r13, WINDOW
    jae .close
    cmp byte [rdi+rcx], 0
    jne .skip
    mov rax, rcx
    shl rax, 4
    mov rdx, [rsi+rax+CV_LEN]
    lea r14, [r12+rdx]
    cmp r14, [ctx]
    ja .skip
    mov r12, r14
    mov byte [rdi+rcx], 1
    mov [r8+r9*8], rcx
    inc r9
    add [content], rdx
    cmp r12, [ctx]
    jae .close
.skip:
    inc rcx
    inc r13
    jmp .cand
.close:
    mov qword [r8+r9*8], -1
    inc r9
    inc qword [nblk]
.adv:
    cmp rbx, [ncv]
    jae .blk
    cmp byte [rdi+rbx], 0
    je .blk
    inc rbx
    jmp .adv
.done:
    mov [nord], r9
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = token pointer, rdx = count. into the output buffer, flushed when full
emitt:
    push rsi
    push rdi
    push rbx
    sub rsp, 32
    mov rsi, rcx
    mov rbx, rdx
.more:
    test rbx, rbx
    jz .done
    mov rax, CHUNK / 2
    sub rax, [outn]
    cmp rax, rbx
    cmova rax, rbx              ; this much fits now
    mov rdi, [outbuf]
    mov rcx, [outn]
    lea rdi, [rdi+rcx*2]
    add [outn], rax
    sub rbx, rax
    lea rcx, [rax*2]
    rep movsb
    cmp qword [outn], CHUNK / 2
    jb .more
    call flush
    jmp .more
.done:
    add rsp, 32
    pop rbx
    pop rdi
    pop rsi
    ret

flush:
    sub rsp, 40
    mov rcx, [outh]
    mov rdx, [outbuf]
    mov r8, [outn]
    shl r8, 1
    call file_write
    test eax, eax
    jnz .ok
    lea rcx, [e_write]
    call fatal
.ok:
    mov qword [outn], 0
    add rsp, 40
    ret

; header, the blocks, one more <|bos|> so the last row has its target
write:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov ecx, CHUNK
    call mem_alloc
    mov [outbuf], rax
    mov rcx, [ctx]
    shl rcx, 1
    call mem_alloc
    mov [padbuf], rax
    mov rdi, rax
    mov rcx, [ctx]
    mov ax, TOK_BOS
    rep stosw
    mov rcx, [outname]
    call file_create
    cmp rax, -1
    jne .made
    lea rcx, [e_write]
    call fatal
.made:
    mov [outh], rax
    mov rax, TF_MAGIC_V
    mov [hdr+TF_MAGIC], rax
    mov rax, [nblk]
    imul rax, [ctx]
    inc rax
    mov [hdr+TF_NTOK], rax
    mov rax, [nord]
    sub rax, [nblk]
    mov [hdr+TF_NDOCS], rax
    mov qword [hdr+TF_VOCAB], VOCAB
    mov rax, [hash]
    mov [hdr+TF_HASH], rax
    mov qword [hdr+TF_FLAGS], 1
    mov rax, [ctx]
    mov [hdr+TF_BLOCK], rax
    mov rcx, [outh]
    lea rdx, [hdr]
    mov r8d, TF_SIZE
    call file_write
    xor ebx, ebx                ; order index
    xor r12d, r12d              ; tokens in the block so far
.o:
    cmp rbx, [nord]
    jae .end
    mov rax, [order]
    mov rax, [rax+rbx*8]
    inc rbx
    cmp rax, -1
    je .pad
    shl rax, 4
    add rax, [cv]
    mov rcx, [rax+CV_PTR]
    mov rdx, [rax+CV_LEN]
    add r12, rdx
    ; count the targets on the way
    xor r8d, r8d
.tg:
    cmp r8, rdx
    jae .emit
    test word [rcx+r8*2], MASKBIT
    jz .ntg
    inc qword [targets]
.ntg:
    inc r8
    jmp .tg
.emit:
    call emitt
    jmp .o
.pad:
    mov rdx, [ctx]
    sub rdx, r12
    xor r12d, r12d
    mov rcx, [padbuf]
    call emitt
    jmp .o
.end:
    lea rcx, [padtok]
    mov edx, 1
    call emitt
    call flush
    mov rcx, [outh]
    call file_close
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

report:
    sub rsp, 40
    say "  "
    mov rcx, [ncv]
    call print_dec
    say " conversations (with repeats), "
    mov rcx, [ntrunc]
    call print_dec
    say " cut to "
    mov rcx, [ctx]
    call print_dec
    say " tokens", 13, 10, "  "
    mov rcx, [nblk]
    call print_dec
    say " blocks of "
    mov rcx, [ctx]
    call print_dec
    say ", "
    cvtsi2sd xmm0, qword [content]
    mov rax, [nblk]
    imul rax, [ctx]
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    mulsd xmm0, [c_100]
    mov edx, 1
    call print_fixed
    say "% filled, "
    mov rcx, [targets]
    call print_dec
    say " target tokens -> "
    mov rcx, [outname]
    call print_z
    say 13, 10
    add rsp, 40
    ret

section .rdata
padtok dw TOK_BOS
