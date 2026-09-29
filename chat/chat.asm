; chat: talk to the model, on the cpu.
;   bin\chat                         models\mnemonic-q8.mnm
;   bin\chat model=models\mnemonic-q4.mnm temp=0.8 top_p=0.9
;   bin\chat eval=datasets\chat\val.tok rows=8     loss and speed on a .tok file
; the conversation lives in the kv cache, so a turn only runs its new tokens.
; /reset starts over, /quit (or ctrl+z) leaves, ctrl+c stops a reply
; uses: chat\quant chat\kernels chat\engine tokenizer\tok tokenizer\pretok
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"
%include "chat/model.inc"

extern ExitProcess

MAXLINE equ 16384

section .rdata
k_model  db "model", 0
k_tok    db "tok", 0
k_temp   db "temp", 0
k_topp   db "top_p", 0
k_max    db "max", 0
k_thr    db "threads", 0
k_seed   db "seed", 0
k_eval   db "eval", 0
k_rows   db "rows", 0
d_model  db "models\mnemonic-q8.mnm", 0
d_tok    db "datasets\tokenizer.bin", 0
s_qt     db "f32", 0, 0, 0, 0, 0, "int8", 0, 0, 0, 0, "int4", 0
e_tok    db "can't load the tokenizer", 0
e_hash   db "the model was made with a different tokenizer", 0
e_eval   db "can't read the eval file", 0
align 8
c_temp   dq 0.7
c_topp   dq 0.9
c_mb     dq 9.5367431640625e-07
c_m      dq 1e-6

section .bss
alignb 8
rng      resb RNG_SIZE
tctx     resq 1
maxgen   resq 1
line     resb MAXLINE
toks     resw MAXLINE
pend     resb 64                ; bytes of a character that isn't complete yet
npend    resq 1

section .text

global start
start:
    sub rsp, 40
    call lib_init
    call cfg_args
    lea rcx, [k_thr]
    xor edx, edx
    call cfg_int
    mov ecx, eax
    call pool_init
    lea rcx, [k_tok]
    lea rdx, [d_tok]
    call cfg_str
    mov rcx, rax
    call tok_load
    test eax, eax
    jnz .tok
    lea rcx, [e_tok]
    call fatal
.tok:
    call tok_cache_new
    mov [tctx], rax
    lea rcx, [k_model]
    lea rdx, [d_model]
    call cfg_str
    mov rcx, rax
    call eng_load
    mov rax, [eng+EN_TOKHASH]
    test rax, rax
    jz .hashok                  ; (test models have none)
    cmp rax, [tok_hash]
    je .hashok
    lea rcx, [e_hash]
    call fatal
.hashok:
    call kern_pick
    lea rcx, [k_temp]
    movsd xmm1, [c_temp]
    call cfg_float
    movsd [samp_temp], xmm0
    lea rcx, [k_topp]
    movsd xmm1, [c_topp]
    call cfg_float
    movsd [samp_topp], xmm0
    lea rcx, [k_max]
    mov edx, 400
    call cfg_int
    mov [maxgen], rax
    call time_now
    mov rdx, rax
    lea rcx, [k_seed]
    call cfg_int                ; the clock, unless told otherwise
    lea rcx, [rng]
    mov rdx, rax
    call rng_seed
    call banner
    lea rcx, [k_eval]
    xor edx, edx
    call cfg_str
    test rax, rax
    jz .chat
    mov rcx, rax
    call evaluate
    jmp .bye
.chat:
    call ctrlc_init
    call converse
.bye:
    call con_restore
    xor ecx, ecx
    call ExitProcess

; one line about what's loaded
banner:
    sub rsp, 40
    say "  Mnemonic: "
    mov rax, [eng+EN_L]
    mov rcx, [eng+EN_D]
    call params
    say " params, "
    lea rcx, [s_qt]
    mov rax, [eng+EN_QT]
    lea rcx, [rcx+rax*8]
    call print_z
    say " ("
    cvtsi2sd xmm0, qword [eng+EN_BYTES]
    mulsd xmm0, [c_mb]
    mov edx, 0
    call print_fixed
    say " MB), "
    call kern_name
    mov rcx, rax
    call print_z
    say ", "
    mov rcx, [nthreads]
    call print_dec
    say " threads", 13, 10
    add rsp, 40
    ret

; prints the parameter count in millions
params:
    sub rsp, 40
    ; embedding + layers * (qkv + o + 2 ffn + ffn) * d, the norms are noise
    mov rax, [eng+EN_V]
    imul rax, [eng+EN_D]
    mov rcx, [eng+EN_QKV]
    add rcx, [eng+EN_QD]
    mov rdx, [eng+EN_F]
    lea rcx, [rcx+rdx*2]
    add rcx, rdx
    imul rcx, [eng+EN_D]
    imul rcx, [eng+EN_L]
    add rax, rcx
    cvtsi2sd xmm0, rax
    mulsd xmm0, [c_m]
    mov edx, 0
    call print_fixed
    say "M"
    add rsp, 40
    ret

; ---- the conversation
converse:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 56
    say "  /reset starts over, /quit leaves, ctrl+c stops a reply", 13, 10
    call fresh
.turn:
    say 13, 10, 27, "[1;36m> ", 27, "[0m"
    lea rcx, [line]
    mov edx, MAXLINE - 1
    call con_readline
    cmp rax, -1
    je .done
    mov rbx, rax
    cmp dword [con_intty], 0
    jne .typed
    lea rcx, [line]             ; piped in, show what was said
    mov rdx, rbx
    call print
    say 13, 10
.typed:
    test rbx, rbx
    jz .turn
    cmp dword [line], '/qui'
    je .done
    cmp dword [line], '/res'
    jne .say
    call fresh
    say "  (new conversation)", 13, 10
    jmp .turn
.say:
    mov dword [stop_flag], 0
    ; <|user|> the line <|end|> <|assistant|>
    lea rdi, [toks]
    mov word [rdi], TOK_USER
    mov rcx, [tctx]
    lea rdx, [line]
    mov r8, rbx
    lea r9, [rdi+2]
    call tok_encode
    lea r12, [rax+1]
    lea rdi, [toks]
    ; a line longer than half the context gets cut
    mov rcx, [eng+EN_T]
    shr rcx, 1
    cmp r12, rcx
    jbe .fits
    mov r12, rcx
.fits:
    mov word [rdi+r12*2], TOK_END
    mov word [rdi+r12*2+2], TOK_ASSIST
    add r12, 2                  ; tokens to feed
    ; room for them and a reply? otherwise start over with just this turn
    mov rax, [eng+EN_POS]
    add rax, r12
    add rax, [maxgen]
    cmp rax, [eng+EN_T]
    jbe .feed
    call fresh
    say "  (out of context, starting over)", 13, 10
.feed:
    xor esi, esi
.f:
    cmp rsi, r12
    jae .gen
    lea rax, [toks]
    movzx ecx, word [rax+rsi*2]
    lea rdx, [rsi+1]
    xor eax, eax
    cmp rdx, r12
    sete al                     ; logits only for the last one
    mov edx, eax
    call eng_step
    inc rsi
    jmp .f
.gen:
    say 27, "[0m  "
    mov qword [npend], 0
    xor r13d, r13d              ; tokens out
    call time_now
    mov r14, rax
.g:
    lea rcx, [rng]
    call samp_pick
    mov ebx, eax
    cmp ebx, SPECIAL0
    jae .end                    ; <|end|>, or any other special: the reply is over
    mov ecx, ebx
    call show
    inc r13
    cmp r13, [maxgen]
    jae .end
    mov rax, [eng+EN_POS]
    inc rax
    cmp rax, [eng+EN_T]
    jae .end
    cmp dword [stop_flag], 0
    jne .stopped
    mov ecx, ebx
    mov edx, 1
    call eng_step
    jmp .g
.stopped:
    mov dword [stop_flag], 0
    say " ..."
.end:
    ; the turn ends with <|end|> in the cache either way
    mov rax, [eng+EN_POS]
    cmp rax, [eng+EN_T]
    jae .stats
    mov ecx, TOK_END
    xor edx, edx
    call eng_step
.stats:
    mov rcx, r14
    call time_since
    movsd [rsp+32], xmm0
    say 13, 10, 27, "[90m  ["
    mov rcx, r13
    call print_dec
    say " tokens, "
    cvtsi2sd xmm0, r13
    divsd xmm0, [rsp+32]
    mov edx, 1
    call print_fixed
    say " tok/s]", 27, "[0m", 13, 10
    jmp .turn
.done:
    add rsp, 56
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; a new conversation: empty cache, then <|bos|>
fresh:
    sub rsp, 40
    call eng_reset
    mov ecx, TOK_BOS
    xor edx, edx
    call eng_step
    add rsp, 40
    ret

; ecx = token. its bytes to the console as they come, but never half a utf-8
; character (a character can be split across two tokens)
show:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    call tok_bytes
    mov rsi, rax
    mov rcx, rdx
    lea rdi, [pend]
    add rdi, [npend]
    cmp rcx, 48
    jbe .cp
    mov ecx, 48
.cp:
    add [npend], rcx
    rep movsb
    ; the last character: complete?
    lea rsi, [pend]
    mov rbx, [npend]
    mov rcx, rbx
.back:
    test rcx, rcx
    jz .all
    dec rcx
    mov al, [rsi+rcx]
    and al, 0xc0
    cmp al, 0x80
    je .back                    ; a continuation byte, keep looking for the lead
    ; rcx = its lead byte. how long is it meant to be?
    movzx eax, byte [rsi+rcx]
    mov edx, 1
    cmp eax, 0xc0
    jb .len
    inc edx
    cmp eax, 0xe0
    jb .len
    inc edx
    cmp eax, 0xf0
    jb .len
    inc edx
.len:
    mov rax, rbx
    sub rax, rcx                ; bytes of it we have
    cmp rax, rdx
    jae .all
    ; print up to the lead byte, keep the rest
    mov rbx, rcx
.all:
    lea rcx, [pend]
    mov rdx, rbx
    call print
    lea rsi, [pend]
    add rsi, rbx
    lea rdi, [pend]
    mov rcx, [npend]
    sub rcx, rbx
    mov [npend], rcx
    rep movsb
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- eval=file.tok: the average loss on the first rows of a .tok file, and the speed.
; chat files count only the MASKBIT targets, like training did
evaluate:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    call file_map
    test rax, rax
    jnz .mapped
    lea rcx, [e_eval]
    call fatal
.mapped:
    mov rsi, rax
    mov r15, [rsi+TF_FLAGS]
    and r15, 1                  ; chat?
    add rsi, TF_SIZE
    lea rcx, [k_rows]
    mov edx, 4
    call cfg_int
    mov r12, rax
    ; no more rows than the file has
    mov rax, [rsi+TF_NTOK-TF_SIZE]
    dec rax
    xor edx, edx
    div qword [eng+EN_T]
    cmp r12, rax
    cmova r12, rax
    xorpd xmm0, xmm0
    movsd [rsp+32], xmm0        ; loss sum
    xor r13d, r13d              ; targets
    xor r14d, r14d              ; tokens run
    call time_now
    mov [rsp+40], rax
    xor ebx, ebx                ; row
.row:
    cmp rbx, r12
    jae .done
    call eng_reset
    mov rdi, rbx
    imul rdi, [eng+EN_T]
    lea rdi, [rsi+rdi*2]        ; row start: T + 1 tokens from here
    xor ecx, ecx
.t:
    cmp rcx, [eng+EN_T]
    jae .rn
    mov [rsp+48], rcx
    movzx ecx, word [rdi+rcx*2]
    and ecx, MASKBIT - 1
    mov edx, 1
    call eng_step
    inc r14
    mov rcx, [rsp+48]
    movzx edx, word [rdi+rcx*2+2]   ; the target
    test r15, r15
    jz .count
    test edx, MASKBIT
    jz .next
.count:
    and edx, MASKBIT - 1
    mov ecx, edx
    call eng_nll
    addsd xmm0, [rsp+32]
    movsd [rsp+32], xmm0
    inc r13
.next:
    mov rcx, [rsp+48]
    inc rcx
    jmp .t
.rn:
    inc rbx
    jmp .row
.done:
    mov rcx, [rsp+40]
    call time_since
    movsd [rsp+40], xmm0
    say "  loss "
    movsd xmm0, [rsp+32]
    cvtsi2sd xmm1, r13
    divsd xmm0, xmm1
    mov edx, 4
    call print_fixed
    say " over "
    mov rcx, r13
    call print_dec
    say " targets, "
    cvtsi2sd xmm0, r14
    divsd xmm0, [rsp+40]
    mov edx, 1
    call print_fixed
    say " tok/s", 13, 10
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
