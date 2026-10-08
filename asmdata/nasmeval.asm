; nasmeval: NASM-Eval. for each held-out task in datasets\asm\eval.jsonl the model
; writes the function (greedy, on the cpu engine), and the first code block of its
; reply runs against the task's tests in harness.asm
;   bin\nasmeval                          models\mnemonic-300m-q8.mnm
;   bin\nasmeval model=models\x.mnm tag=asm300 max=800 threads=12
;   bin\nasmeval reference                the lessons' own code, has to be 100%
; replies and results go to datasets\asm\evals\<tag>.jsonl
; uses: asmdata\verify asmdata\json chat\quant chat\kernels chat\engine tokenizer\tok tokenizer\pretok
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"
%include "chat/model.inc"
%include "asmdata/asmdata.inc"

extern ExitProcess, GetActiveProcessorCount

MAXT    equ 4096
REPLY   equ 1 << 16
STRS    equ 32 << 20

; a task
TK_ID     equ 0                 ; zero terminated, like i67
TK_TOPIC  equ 8                 ; zero terminated
TK_LEVEL  equ 16
TK_PROMPT equ 24                ; (ptr, len)
TK_NAME   equ 40
TK_TESTS  equ 56
TK_CODE   equ 72
TK_RES    equ 88                ; ST_*, or R_* below
TK_SIZE   equ 96

R_NOCODE  equ 8
R_NOTOK   equ 9
R_NONAME  equ 10

section .rdata
k_model  db "model", 0
k_tok    db "tok", 0
k_tag    db "tag", 0
k_max    db "max", 0
k_thr    db "threads", 0
k_id     db "id", 0
k_topic  db "topic", 0
k_level  db "level", 0
k_prompt db "prompt", 0
k_name   db "name", 0
k_tests  db "tests", 0
k_code   db "code", 0
d_model  db "models\mnemonic-300m-q8.mnm", 0
d_tok    db "datasets\tokenizer.bin", 0
d_work   db "scratch\asmgen\eval", 0
d_evals  db "datasets\asm\evals", 0
f_eval   db "datasets\asm\eval.jsonl", 0
s_evals  db "datasets\asm\evals\", 0
s_jsonl  db ".jsonl", 0
s_ref    db "reference", 0
e_eval   db "can't read datasets\asm\eval.jsonl, run asmset first", 0
e_tok    db "can't load the tokenizer", 0
e_hash   db "the model was made with a different tokenizer", 0
e_out    db "can't write the results", 0
; result names, 12 bytes each
res      db "pass", 0, 0, 0, 0, 0, 0, 0, 0
         db "assemble", 0, 0, 0, 0
         db "internal", 0, 0, 0, 0
         db "link", 0, 0, 0, 0, 0, 0, 0, 0
         db "tests", 0, 0, 0, 0, 0, 0, 0
         db "abi", 0, 0, 0, 0, 0, 0, 0, 0, 0
         db "crash", 0, 0, 0, 0, 0, 0, 0
         db "timeout", 0, 0, 0, 0, 0
         db "no code", 0, 0, 0, 0, 0
         db "not allowed", 0
         db "wrong name", 0, 0

section .bss
alignb 8
ctx      resq 1
tasks    resq 1
ntask    resq 1
strs     resq 1                 ; bump allocator for the decoded strings
sused    resq 1
reply    resq 1
rlen     resq 1
tctx     resq 1
toks     resw MAXT
rng      resb RNG_SIZE
maxgen   resq 1
isref    resq 1
gtoks    resq 1                 ; tokens generated, all tasks
gsecs    resq 1                 ; f64
tag      resq 1
model    resq 1
outpath  resb 512
fh       resq 1
line     resq 1                 ; a jsonl line being built
tally    resq 16

section .text

global start
start:
    sub rsp, 40
    call lib_init
    call cfg_args
    call vf_init
    lea rcx, [d_work]
    call vf_new
    mov [ctx], rax
    mov ecx, STRS
    call mem_alloc
    mov [strs], rax
    mov ecx, REPLY
    call mem_alloc
    mov [reply], rax
    mov ecx, 4 << 20
    call mem_alloc
    mov [line], rax
    mov ecx, 4096 * TK_SIZE
    call mem_alloc
    mov [tasks], rax
    call load_tasks
    ; reference, or a model?
    cmp qword [argc], 2
    jb .model
    mov rcx, [argv+8]
    lea rdx, [s_ref]
    call same
    test eax, eax
    jz .model
    mov qword [isref], 1
    lea rax, [s_ref]
    mov [tag], rax
    mov [model], rax
    jmp .go
.model:
    call load_model
.go:
    call run_all
    call summary
    call con_restore
    xor ecx, ecx
    call ExitProcess

; rcx, rdx = zero terminated. eax = 1 if they're the same
same:
    mov al, [rcx]
    cmp al, [rdx]
    jne .no
    test al, al
    jz .yes
    inc rcx
    inc rdx
    jmp same
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; rcx = object, rdx = key. rax = the string decoded (zero terminated), rdx = length
; (0, 0 if it's missing)
jfield:
    push rbx
    push rsi
    sub rsp, 40
    call js_get
    test rax, rax
    jz .no
    cmp byte [rax], '"'
    jne .no
    mov rbx, [strs]
    add rbx, [sused]
    mov rsi, rax
    mov rcx, rax
    call js_skip
    sub rax, rsi
    add rax, 8
    add [sused], rax            ; decoded is never longer
    mov rcx, rsi
    mov rdx, rbx
    call js_str
    mov rdx, rax
    mov rax, rbx
    jmp .r
.no:
    xor eax, eax
    xor edx, edx
.r:
    add rsp, 40
    pop rsi
    pop rbx
    ret

%macro getf 2
    mov rcx, rsi
    lea rdx, [%1]
    call jfield
    mov [rbx+%2], rax
    mov [rbx+%2+8], rdx
%endmacro

; datasets\asm\eval.jsonl -> tasks
load_tasks:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    lea rcx, [f_eval]
    call file_read_all
    test rax, rax
    jnz .have
    lea rcx, [e_eval]
    call fatal
.have:
    mov rsi, rax
    lea r12, [rax+rdx]
.line:
    cmp rsi, r12
    jae .done
    mov rdi, rsi
.eol:
    cmp rdi, r12
    jae .got
    cmp byte [rdi], 10
    je .got
    inc rdi
    jmp .eol
.got:
    mov byte [rdi], 0
    cmp rdi, rsi
    je .next
    mov rbx, [ntask]
    cmp rbx, 4096
    jae .done
    imul rbx, rbx, TK_SIZE
    add rbx, [tasks]
    mov rcx, rsi
    lea rdx, [k_id]
    call jfield
    mov [rbx+TK_ID], rax
    mov rcx, rsi
    lea rdx, [k_topic]
    call jfield
    mov [rbx+TK_TOPIC], rax
    mov rcx, rsi
    lea rdx, [k_level]
    call js_get
    test rax, rax
    jz .lv
    mov rcx, rax
    call parse_int
.lv:
    mov [rbx+TK_LEVEL], rax
    getf k_prompt, TK_PROMPT
    getf k_name, TK_NAME
    getf k_tests, TK_TESTS
    getf k_code, TK_CODE
    cmp qword [rbx+TK_TESTS], 0
    je .next
    cmp qword [rbx+TK_NAME], 0
    je .next
    inc qword [ntask]
.next:
    lea rsi, [rdi+1]
    jmp .line
.done:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; the tokenizer, the model, the threads, greedy decoding
load_model:
    push rbx
    sub rsp, 32
    ; 3/4 of the cpus, at most 12, like bin\chat
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
    mov [model], rax
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
    movsd [samp_temp], xmm0     ; 0 = the likeliest token every time
    lea rcx, [k_max]
    mov edx, 800
    call cfg_int
    mov [maxgen], rax
    lea rcx, [rng]
    mov edx, 1
    call rng_seed
    ; the tag: tag=, or the model file's name
    lea rcx, [k_tag]
    xor edx, edx
    call cfg_str
    test rax, rax
    jnz .tag
    mov rcx, [model]
    mov rax, rcx
.base:
    mov dl, [rcx]
    test dl, dl
    jz .ext
    inc rcx
    cmp dl, '\'
    jne .base
    mov rax, rcx
    jmp .base
.ext:
    ; copy without the extension
    mov rbx, [strs]
    add rbx, [sused]
    mov rcx, rbx
.cp:
    mov dl, [rax]
    test dl, dl
    jz .cpd
    cmp dl, '.'
    je .cpd
    mov [rcx], dl
    inc rax
    inc rcx
    jmp .cp
.cpd:
    mov byte [rcx], 0
    sub rcx, rbx
    inc rcx
    add [sused], rcx
    mov rax, rbx
.tag:
    mov [tag], rax
    say "  "
    mov rcx, [model]
    call print_z
    say ", "
    call kern_name
    mov rcx, rax
    call print_z
    say ", "
    mov rcx, [nthreads]
    call print_dec
    say " threads", 13, 10
    add rsp, 32
    pop rbx
    ret

; every task: a reply, then its code against the tests
run_all:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    lea rcx, [d_evals]
    call make_dir
    lea rcx, [outpath]
    lea rdx, [s_evals]
    call fmt_str
    mov rcx, rax
    mov rdx, [tag]
    call fmt_str
    mov rcx, rax
    lea rdx, [s_jsonl]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [outpath]
    call file_create
    cmp rax, -1
    jne .open
    lea rcx, [e_out]
    call fatal
.open:
    mov [fh], rax
    say "  "
    mov rcx, [ntask]
    call print_dec
    say " tasks", 13, 10
    xor r12d, r12d
.t:
    cmp r12, [ntask]
    jae .done
    imul rbx, r12, TK_SIZE
    add rbx, [tasks]
    cmp qword [isref], 0
    je .gen
    ; the reference: its own code, as if it were the reply
    mov rdi, [reply]
    mov dword [rdi], '```n'
    mov dword [rdi+4], 'asm'
    mov byte [rdi+7], 10
    add rdi, 8
    mov rsi, [rbx+TK_CODE]
    mov rcx, [rbx+TK_CODE+8]
    rep movsb
    mov byte [rdi], 10
    mov word [rdi+1], '``'
    mov byte [rdi+3], '`'
    add rdi, 4
    mov rax, rdi
    sub rax, [reply]
    mov [rlen], rax
    xor r13d, r13d
    jmp .score
.gen:
    mov rcx, rbx
    call generate
    mov r13, rax                ; tokens
.score:
    mov rcx, rbx
    call score
    mov [rbx+TK_RES], rax
    lea rcx, [tally]
    inc qword [rcx+rax*8]
    call show
    mov rcx, rbx
    call save
    inc r12
    jmp .t
.done:
    mov rcx, [fh]
    call file_close
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; (run_all) one line for the task in rbx: id, topic, level, result, tokens
show:
    sub rsp, 40
    say "  "
    mov rcx, [rbx+TK_ID]
    call print_z
    say 9
    mov rcx, [rbx+TK_TOPIC]
    call print_z
    say ", level "
    mov rcx, [rbx+TK_LEVEL]
    call print_dec
    say ": "
    mov rax, [rbx+TK_RES]
    imul rax, rax, 12
    lea rcx, [res]
    add rcx, rax
    call print_z
    test r13, r13
    jz .eol
    say " ("
    mov rcx, r13
    call print_dec
    say " tokens)"
.eol:
    say 13, 10
    add rsp, 40
    ret

; rcx = task. the model's reply in reply / rlen. rax = tokens it wrote
generate:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rbx, rcx
    call eng_reset
    mov ecx, TOK_BOS
    xor edx, edx
    call eng_step
    ; <|user|> the prompt <|end|> <|assistant|>
    lea rdi, [toks]
    mov word [rdi], TOK_USER
    mov rcx, [tctx]
    mov rdx, [rbx+TK_PROMPT]
    mov r8, [rbx+TK_PROMPT+8]
    lea r9, [rdi+2]
    call tok_encode
    lea r12, [rax+1]
    mov rcx, [eng+EN_T]
    shr rcx, 1
    cmp r12, rcx
    jbe .fits
    mov r12, rcx
.fits:
    lea rdi, [toks]
    mov word [rdi+r12*2], TOK_END
    mov word [rdi+r12*2+2], TOK_ASSIST
    add r12, 2
    xor esi, esi
.feed:
    cmp rsi, r12
    jae .gen
    lea rax, [toks]
    movzx ecx, word [rax+rsi*2]
    lea rdx, [rsi+1]
    xor eax, eax
    cmp rdx, r12
    sete al
    mov edx, eax
    call eng_step
    inc rsi
    jmp .feed
.gen:
    call time_now
    mov r13, rax
    mov qword [rlen], 0
    xor r12d, r12d              ; tokens out
.g:
    lea rcx, [rng]
    call samp_pick
    cmp eax, SPECIAL0
    jae .end
    mov ebx, eax
    mov ecx, eax
    call tok_bytes
    mov r8, [rlen]
    add r8, rdx
    cmp r8, REPLY - 16
    ja .end
    mov rdi, [reply]
    add rdi, [rlen]
    mov [rlen], r8
    mov rsi, rax
    mov rcx, rdx
    rep movsb
    inc r12
    inc qword [gtoks]
    cmp r12, [maxgen]
    jae .end
    mov rax, [eng+EN_POS]
    inc rax
    cmp rax, [eng+EN_T]
    jae .end
    mov ecx, ebx
    mov edx, 1
    call eng_step
    jmp .g
.end:
    mov rcx, r13
    call time_since
    addsd xmm0, [gsecs]
    movsd [gsecs], xmm0
    mov rax, r12
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = task, its reply in reply / rlen. rax = ST_* or R_*
score:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rcx, [reply]
    mov rdx, [rlen]
    call code_of
    mov rsi, rax
    mov rdi, rdx
    mov eax, R_NOCODE
    test rsi, rsi
    jz .r
    mov rcx, rsi
    mov rdx, rdi
    call code_check
    test rax, rax
    mov eax, R_NOTOK
    jnz .r
    mov rcx, rsi
    mov rdx, rdi
    mov r8, [rbx+TK_NAME]
    mov r9, [rbx+TK_NAME+8]
    call has_global
    test eax, eax
    mov eax, R_NONAME
    jz .r
    mov rcx, [ctx]
    mov rdx, [rbx+TK_TESTS]
    mov r8, [rbx+TK_TESTS+8]
    call vf_tests
    cmp rax, -1
    mov eax, ST_INTERNAL
    je .r
    mov rcx, [ctx]
    mov rdx, rsi
    mov r8, rdi
    call vf_verify
.r:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = task: a line of the results file
save:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rdi, [line]
    emit '{"id":"'
    mov rcx, rdi
    mov rdx, [rbx+TK_ID]
    call fmt_str
    mov rdi, rax
    emit '","topic":"'
    mov rcx, rdi
    mov rdx, [rbx+TK_TOPIC]
    call fmt_str
    mov rdi, rax
    emit '","level":'
    mov rcx, rdi
    mov rdx, [rbx+TK_LEVEL]
    call fmt_dec
    mov rdi, rax
    emit ',"result":"'
    mov rax, [rbx+TK_RES]
    imul rax, rax, 12
    lea rdx, [res]
    add rdx, rax
    mov rcx, rdi
    call fmt_str
    mov rdi, rax
    emit '","reply":'
    mov rcx, rdi
    mov rdx, [reply]
    mov r8, [rlen]
    call js_put
    mov rdi, rax
    mov word [rdi], 0x0a7d       ; }\n
    add rdi, 2
    mov rcx, [fh]
    mov rdx, [line]
    mov r8, rdi
    sub r8, rdx
    call file_write
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

summary:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    say 13, 10, "NASM-Eval "
    mov rcx, [tag]
    call print_z
    say ": "
    mov rcx, [tally]
    call print_dec
    say " of "
    mov rcx, [ntask]
    call print_dec
    say " pass ("
    cvtsi2sd xmm0, qword [tally]
    cvtsi2sd xmm1, qword [ntask]
    divsd xmm0, xmm1
    mov rax, 100
    cvtsi2sd xmm1, rax
    mulsd xmm0, xmm1
    mov edx, 1
    call print_fixed
    say "%)", 13, 10
    ; by level
    mov r12d, 1
.lv:
    cmp r12, 3                  ; levels 1 to 3
    ja .fails
    xor esi, esi                ; tasks
    xor edi, edi                ; passed
    mov rbx, [tasks]
    mov rcx, [ntask]
.l:
    test rcx, rcx
    jz .ls
    cmp [rbx+TK_LEVEL], r12
    jne .ln
    inc esi
    cmp qword [rbx+TK_RES], ST_OK
    jne .ln
    inc edi
.ln:
    add rbx, TK_SIZE
    dec rcx
    jmp .l
.ls:
    test esi, esi
    jz .lnext
    say "  level "
    mov rcx, r12
    call print_dec
    say ": "
    mov ecx, edi
    call print_dec
    say " of "
    mov ecx, esi
    call print_dec
    say 13, 10
.lnext:
    inc r12
    jmp .lv
.fails:
    say "  failures:"
    mov r12d, 1
.f:
    cmp r12, 11
    jae .speed
    lea rax, [tally]
    mov rcx, [rax+r12*8]
    test rcx, rcx
    jz .fn
    say " "
    imul rcx, r12, 12
    lea rax, [res]
    add rcx, rax
    call print_z
    say " "
    lea rax, [tally]
    mov rcx, [rax+r12*8]
    call print_dec
.fn:
    inc r12
    jmp .f
.speed:
    say 13, 10
    cmp qword [isref], 0
    jne .out
    say "  "
    mov rcx, [gtoks]
    call print_dec
    say " tokens, "
    cvtsi2sd xmm0, qword [gtoks]
    divsd xmm0, [gsecs]
    mov edx, 1
    call print_fixed
    say " tok/s", 13, 10
.out:
    say "  replies in "
    lea rcx, [outpath]
    call print_z
    say 13, 10
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
