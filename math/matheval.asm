; matheval [model=models\mnemonic-300m-q8.mnm] [file=datasets\math\eval.txt] [n=0]
;   [max=2000] [threads=...] [log=logs\matheval.txt]
; asks the model every problem in a mathgen file (greedy, on the cpu, like bin\chat
; temp=0) and checks the last line of its reply against the right one, exactly. a
; score per topic at the end, and every reply in the log to read through. n=0: all
; uses: chat\quant chat\kernels chat\engine tokenizer\tok tokenizer\pretok
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"
%include "chat/model.inc"

extern ExitProcess, GetActiveProcessorCount

MAXT  equ 4096                  ; tokens in a reply, at most
NTOP  equ 32

section .rdata
k_model  db "model", 0
k_file   db "file", 0
k_n      db "n", 0
k_max    db "max", 0
k_thr    db "threads", 0
k_log    db "log", 0
k_tok    db "tok", 0
d_model  db "models\mnemonic-300m-q8.mnm", 0
d_file   db "datasets\math\eval.txt", 0
d_log    db "logs\matheval.txt", 0
d_tok    db "datasets\tokenizer.bin", 0
s_logs   db "logs", 0
e_tok    db "can't load the tokenizer", 0
e_hash   db "the model was made with a different tokenizer", 0
e_file   db "can't read the problems", 0
e_log    db "can't create the log", 0
align 8
c_100    dq 100.0

section .bss
alignb 8
rng      resb RNG_SIZE
tctx     resq 1
maxgen   resq 1
nlim     resq 1
logh     resq 1
t0       resq 1
ntop     resq 1
tname    resq NTOP              ; the topics: name (in the file), problems, right
tlen     resq NTOP
tdone    resq NTOP
tgood    resq NTOP
nall     resq 1
ngood    resq 1
ntoks    resq 1
toks     resw MAXT
gen      resw MAXT
reply    resb MAXT * 24
rec      resb MAXT * 24 + 65536

section .text

global start
start:
    sub rsp, 40
    call lib_init
    call cfg_args
    ; the threads the way bin\chat picks them: 3/4 of the cpus, at most 12
    mov ecx, 0xffff
    call GetActiveProcessorCount
    lea edx, [eax+eax*2]
    shr edx, 2
    mov eax, 12
    cmp edx, eax
    cmova edx, eax
    mov eax, 1
    cmp edx, eax
    cmovb edx, eax
    lea rcx, [k_thr]
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
    jz .hashok
    cmp rax, [tok_hash]
    je .hashok
    lea rcx, [e_hash]
    call fatal
.hashok:
    call kern_pick
    xorpd xmm0, xmm0
    movsd [samp_temp], xmm0     ; greedy
    lea rcx, [k_max]
    mov edx, 2000
    call cfg_int
    mov [maxgen], rax
    lea rcx, [k_n]
    xor edx, edx
    call cfg_int
    mov [nlim], rax
    lea rcx, [rng]
    mov edx, 1
    call rng_seed
    lea rcx, [k_file]
    lea rdx, [d_file]
    call cfg_str
    mov rcx, rax
    call file_read_all
    test rax, rax
    jnz .file
    lea rcx, [e_file]
    call fatal
.file:
    mov [rsp+32], rax
    lea rcx, [s_logs]
    call make_dir
    lea rcx, [k_log]
    lea rdx, [d_log]
    call cfg_str
    mov rcx, rax
    call file_create
    cmp rax, -1
    jne .log
    lea rcx, [e_log]
    call fatal
.log:
    mov [logh], rax
    call time_now
    mov [t0], rax
    mov rcx, [rsp+32]
    call run
    mov rcx, [logh]
    call file_close
    call table
    call con_restore
    xor ecx, ecx
    call ExitProcess

; rcx = the problems, zero-terminated. a "# topic" line, "user: ...", "assistant: ..."
; and its lines, a blank line. each one goes to solve
run:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov r12, rcx                ; where the line starts
    mov r13, -1                 ; its topic
    xor r14d, r14d              ; the question
    xor r15d, r15d
    mov qword [rsp+56], 0       ; in an answer
.line:
    mov rbx, r12
.e:
    mov al, [rbx]
    test al, al
    jz .got
    cmp al, 10
    je .got
    inc rbx
    jmp .e
.got:
    mov rcx, rbx
    sub rcx, r12
    test rcx, rcx
    jnz .some
    cmp qword [rsp+56], 0       ; a blank line ends a problem
    je .next
    call .ask
    jmp .next
.some:
    cmp rcx, 2
    jb .cont
    cmp word [r12], '# '
    jne .user
    lea rcx, [r12+2]
    mov rdx, rbx
    sub rdx, rcx
    call topic
    mov r13, rax
    jmp .next
.user:
    cmp rcx, 6
    jb .cont
    cmp dword [r12], 'user'
    jne .asst
    cmp word [r12+4], ': '
    jne .asst
    lea r14, [r12+6]
    mov r15, rbx
    sub r15, r14
    jmp .next
.asst:
    cmp rcx, 11
    jb .cont
    mov rax, 'assistan'
    cmp [r12], rax
    jne .cont
    cmp word [r12+8], 't:'
    jne .cont
    lea rax, [r12+11]
    mov [rsp+40], rax           ; the last line so far
    mov rax, rbx
    sub rax, [rsp+40]
    mov [rsp+48], rax
    mov qword [rsp+56], 1
    jmp .next
.cont:
    cmp qword [rsp+56], 0
    je .next
    mov [rsp+40], r12
    mov rax, rbx
    sub rax, r12
    mov [rsp+48], rax
.next:
    cmp byte [rbx], 0
    je .end
    lea r12, [rbx+1]
    mov rax, [nlim]
    test rax, rax
    jz .line
    cmp [nall], rax
    jb .line
    jmp .done
.end:
    cmp qword [rsp+56], 0
    je .done
    call .ask
.done:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
; (run) the problem so far to solve. called, so run's locals are 8 further up
.ask:
    sub rsp, 40
    mov qword [rsp+56+48], 0
    mov rcx, r13
    mov rdx, r14
    mov r8, r15
    mov r9, [rsp+40+48]
    mov rax, [rsp+48+48]
    mov [rsp+32], rax
    call solve
    add rsp, 40
    ret

; rcx = name, rdx = its length. rax = its index, a new one if it's not there yet
topic:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov r12, rdx
    xor ebx, ebx
.t:
    cmp rbx, [ntop]
    jae .new
    lea rax, [tlen]
    cmp [rax+rbx*8], r12
    jne .n
    lea rax, [tname]
    mov rdi, [rax+rbx*8]
    push rsi
    mov rcx, r12
    repe cmpsb
    pop rsi
    je .got
.n:
    inc rbx
    jmp .t
.new:
    cmp rbx, NTOP
    jae .full
    lea rax, [tname]
    mov [rax+rbx*8], rsi
    lea rax, [tlen]
    mov [rax+rbx*8], r12
    inc qword [ntop]
.got:
    mov rax, rbx
    jmp .r
.full:
    mov rax, -1
.r:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = bytes, rdx = how many: copied to rdi
cpy:
    push rsi
    mov rsi, rcx
    mov rcx, rdx
    rep movsb
    pop rsi
    ret

; rcx = topic (-1 = none), rdx = question, r8 = its length, r9 = the right last line,
; [rsp+40] = its length. asks the model, checks the last line of what it says, logs it
solve:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rbx, rcx
    mov r12, rdx
    mov r13, r8
    mov r14, r9
    mov r15, [rsp+48+56+40]
    ; a fresh conversation: <|bos|> <|user|> the question <|end|> <|assistant|>
    call eng_reset
    mov ecx, TOK_BOS
    xor edx, edx
    call eng_step
    lea rdi, [toks]
    mov word [rdi], TOK_USER
    mov rcx, [tctx]
    mov rdx, r12
    mov r8, r13
    lea r9, [rdi+2]
    call tok_encode
    lea rsi, [rax+1]
    lea rax, [toks]
    mov word [rax+rsi*2], TOK_END
    mov word [rax+rsi*2+2], TOK_ASSIST
    add rsi, 2
    xor edi, edi
.f:
    cmp rdi, rsi
    jae .gen
    lea rax, [toks]
    movzx ecx, word [rax+rdi*2]
    lea rdx, [rdi+1]
    xor eax, eax
    cmp rdx, rsi
    sete al                     ; logits only for the last one
    mov edx, eax
    call eng_step
    inc rdi
    jmp .f
.gen:
    xor esi, esi                ; tokens out
.g:
    lea rcx, [rng]
    call samp_pick
    cmp eax, SPECIAL0
    jae .said
    lea rcx, [gen]
    mov [rcx+rsi*2], ax
    inc rsi
    cmp rsi, [maxgen]
    jae .said
    mov rcx, [eng+EN_POS]
    inc rcx
    cmp rcx, [eng+EN_T]
    jae .said
    mov ecx, eax
    mov edx, 1
    call eng_step
    jmp .g
.said:
    add [ntoks], rsi
    lea rcx, [gen]
    mov rdx, rsi
    lea r8, [reply]
    call tok_decode
    mov [rsp+32], rax           ; the reply's length
    ; its last line, without the spaces after it
    lea rcx, [reply]
    mov rdx, rax
.trim:
    test rdx, rdx
    jz .tl
    cmp byte [rcx+rdx-1], ' '
    ja .tl
    dec rdx
    jmp .trim
.tl:
    mov r8, rdx
.bk:
    test rdx, rdx
    jz .ls
    cmp byte [rcx+rdx-1], 10
    je .ls
    dec rdx
    jmp .bk
.ls:
    lea rsi, [rcx+rdx]
    sub r8, rdx                 ; its length
    xor eax, eax
    cmp r8, r15
    jne .verdict
    mov rdi, r14
    mov rcx, r8
    repe cmpsb
    sete al
.verdict:
    movzx eax, al
    mov [rsp+40], rax
    inc qword [nall]
    add [ngood], rax
    test rbx, rbx
    js .log
    lea rcx, [tdone]
    inc qword [rcx+rbx*8]
    lea rcx, [tgood]
    add [rcx+rbx*8], rax
.log:
    lea rdi, [rec]
    emit "# "
    test rbx, rbx
    js .nt
    lea rax, [tname]
    mov rcx, [rax+rbx*8]
    lea rax, [tlen]
    mov rdx, [rax+rbx*8]
    call cpy
.nt:
    cmp qword [rsp+40], 0
    je .wrong
    emit " right"
    jmp .q
.wrong:
    emit " WRONG"
.q:
    emit 10, "user: "
    mov rcx, r12
    mov rdx, r13
    call cpy
    emit 10, "reply:", 10
    lea rcx, [reply]
    mov rdx, [rsp+32]
    call cpy
    emit 10, "want: "
    mov rcx, r14
    mov rdx, r15
    call cpy
    emit 10, 10
    mov rcx, [logh]
    lea rdx, [rec]
    mov r8, rdi
    sub r8, rdx
    call file_write
    call progress
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; the line that keeps count: 37 done, 12 right (32.4%), 214 tok/s
progress:
    sub rsp, 40
    say 13, "  "
    mov rcx, [nall]
    call print_dec
    say " done, "
    mov rcx, [ngood]
    call print_dec
    say " right ("
    cvtsi2sd xmm0, qword [ngood]
    cvtsi2sd xmm1, qword [nall]
    divsd xmm0, xmm1
    mulsd xmm0, [c_100]
    mov edx, 1
    call print_fixed
    say "%), "
    mov rcx, [t0]
    call time_since
    cvtsi2sd xmm1, qword [ntoks]
    divsd xmm1, xmm0
    movapd xmm0, xmm1
    xor edx, edx
    call print_fixed
    say " tok/s   "
    add rsp, 40
    ret

; rcx = how many done, rdx = how many right: "12 / 20  60.0%"
score:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    mov rcx, rsi
    call print_dec
    say " / "
    mov rcx, rbx
    call print_dec
    say "   "
    cvtsi2sd xmm0, rsi
    cvtsi2sd xmm1, rbx
    divsd xmm0, xmm1
    mulsd xmm0, [c_100]
    mov edx, 1
    call print_fixed
    say "%", 13, 10
    add rsp, 40
    pop rsi
    pop rbx
    ret

; the score for each topic, then all of them
table:
    push rbx
    push rsi
    sub rsp, 40
    say 13, 10, 10, "  topic        right", 13, 10
    xor ebx, ebx
.t:
    cmp rbx, [ntop]
    jae .all
    lea rax, [tdone]
    cmp qword [rax+rbx*8], 0
    je .n
    say "  "
    lea rax, [tname]
    mov rcx, [rax+rbx*8]
    lea rax, [tlen]
    mov rdx, [rax+rbx*8]
    mov rsi, rdx
    call print
.pad:
    cmp rsi, 13
    jae .p
    say " "
    inc rsi
    jmp .pad
.p:
    lea rax, [tdone]
    mov rcx, [rax+rbx*8]
    lea rax, [tgood]
    mov rdx, [rax+rbx*8]
    call score
.n:
    inc rbx
    jmp .t
.all:
    say "  all          "
    mov rcx, [nall]
    mov rdx, [ngood]
    call score
    add rsp, 40
    pop rsi
    pop rbx
    ret
