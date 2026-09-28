; train: the training loop.
;   bin\train dev               settings from train\dev.cfg
;   bin\train dev lr=1e-3       key=value args override the file
; carries on from the newest checkpoint in checkpoints\<run>\ if there is one.
; ctrl+c finishes the step, saves and exits (code 2), a second one exits right away.
;
; the gpu never waits on us: step k+1's tokens get sorted into a pinned buffer
; while step k runs, and step k's loss is only read back after step k+1 is queued
; uses: gpu\cuda gpu\kernels model\model train\data train\ckpt tokenizer\tok tokenizer\pretok
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"
%include "model/model.inc"
%include "tokenizer/tok.inc"
%include "train/train.inc"

extern ExitProcess, SetThreadExecutionState

MAXACC equ 1024
SAMPT  equ 128                  ; samples run on one row this long
MAXK   equ 64

section .rdata
k_fast    db "fast", 0
k_batch   db "batch", 0
k_tokens  db "tokens", 0
k_lr      db "lr", 0
k_minlr   db "min_lr", 0
k_warmup  db "warmup", 0
k_wd      db "wd", 0
k_b1      db "beta1", 0
k_b2      db "beta2", 0
k_eps     db "eps", 0
k_clip    db "clip", 0
k_seed    db "seed", 0
k_valev   db "val_every", 0
k_valb    db "val_batches", 0
k_logev   db "log_every", 0
k_saveev  db "save_every", 0
k_savemin db "save_minutes", 0
k_keep    db "keep", 0
k_stopat  db "stop_at", 0
k_data    db "data", 0
k_val     db "val", 0
k_run     db "run", 0
k_tok     db "tok", 0
k_prompt  db "prompt", 0
k_slen    db "sample_len", 0
k_temp    db "temp", 0
k_topk    db "top_k", 0
k_gen     db "gen", 0
k_gcount  db "gen_count", 0
d_data    db "datasets\fineweb\shard_*.tok", 0
d_val     db "datasets\fineweb\shard_01822.tok", 0
d_tok     db "datasets\tokenizer.bin", 0
d_prompt  db "The", 0
s_dev     db "dev", 0
s_train   db "train\", 0
s_cfg     db ".cfg", 0
s_ckroot  db "checkpoints", 0
s_ckdir   db "checkpoints\", 0
s_step    db "\step_", 0
s_ckext   db ".ckpt", 0
s_stepall db "\step_*.ckpt", 0
s_tmp     db "\tmp.ckpt", 0
s_logs    db "logs", 0
s_logdir  db "logs\", 0
s_logext  db ".log", 0
e_preset  db "no such preset (looked for train\<name>.cfg)", 0
e_tok     db "can't load the tokenizer", 0
e_accum   db "batch needs more micro-batches than this build allows", 0
align 8
c_lr      dq 1e-3
c_minlr   dq 0.1
c_wd      dq 0.1
c_b1      dq 0.9
c_b2      dq 0.95
c_eps     dq 1e-8
c_clip    dq 1.0
c_temp    dq 0.8
c_half    dq 0.5
c_one     dq 1.0
c_pi      dq 3.141592653589793
c_nan     dq 0x7ff8000000000000
c_1e12    dq 1e12
c_60      dq 60.0

section .bss
alignb 8
stats     resb PS_SIZE
opt       resb OP_SIZE
mb        resb MB_SIZE
rng       resb RNG_SIZE
hdr       resb CK_SIZE
; settings
batch     resq 1
ntokens   resq 1
lr        resq 1
minlr     resq 1
warmup    resq 1
seed      resq 1
valev     resq 1
valb      resq 1
logev     resq 1
saveev    resq 1
savemin   resq 1
keep      resq 1
stopat    resq 1
datapat   resq 1
valpath   resq 1
run       resq 1
tokpath   resq 1
prompt    resq 1
slen      resq 1
temp      resq 1
topk      resq 1
; derived
accum     resq 1
tps       resq 1                ; tokens per step
total     resq 1                ; steps
tokb      resq 1                ; bytes of one micro-batch's tokens
mbsz      resq 1                ; ...plus its sorted rows
; loop state
step      resq 1                ; steps launched
nrep      resq 1                ; next step to report
lastsave  resq 1
logh      resq 1
tctx      resq 1
; buffers
hstep     resq 2                ; pinned, a step's tokens + sorts, double buffered
dstep     resq 1
hstats    resq 2                ; pinned: per row losses, then the squared grad norm
ev        resq 2
nus       resq 2 * MAXACC       ; distinct tokens per micro-batch
tgt       resq 2                ; targets per step (the loss divides by this)
dval      resq 1
dsamp     resq 1
hlog      resq 1
seq       resw SAMPT + 8
; names
cfgpath   resb 512
ckpat     resb 512
ckpath    resb 512
cktmp     resb 512
logpath   resb 512
msg       resb 8192
topv      resq MAXK
topi      resq MAXK

section .text

%macro cfgi 3                   ; dest, key, default
    lea rcx, [%2]
    mov rdx, %3
    call cfg_int
    mov [%1], rax
%endmacro
%macro cfgf 3
    lea rcx, [%2]
    movsd xmm1, [%3]
    call cfg_float
    movsd [%1], xmm0
%endmacro
%macro cfgs 3
    lea rcx, [%2]
    lea rdx, [%3]
    call cfg_str
    mov [%1], rax
%endmacro

global start
start:
    sub rsp, 40
    call lib_init
    call ctrlc_init
    xor ecx, ecx
    call pool_init
    call preset
    call gpu_init
    lea rcx, [k_fast]
    mov edx, 1
    call cfg_int
    mov [mdl_fast], eax
    call model_config
    mov ecx, 2
    call model_setup
    call settings
    mov rcx, [tokpath]
    call tok_load
    test eax, eax
    jnz .tok
    lea rcx, [e_tok]
    call fatal
.tok:
    call tok_cache_new
    mov [tctx], rax
    mov rcx, [datapat]
    mov rdx, [valpath]
    call ld_init
    call buffers
    call dirs
    call resume
    lea rcx, [k_gen]
    xor edx, edx
    call cfg_str
    test rax, rax
    jz .train
    mov [prompt], rax
    call generate               ; gen="..." just samples from the checkpoint
.train:
    call plan
    call trainloop
    ; loop only comes back when it's done
    mov rcx, [logh]
    call file_close
    call con_restore
    xor ecx, ecx
    call ExitProcess

; train\<first arg without an '='>.cfg, then the key=value args on top
preset:
    push rbx
    push rsi
    sub rsp, 40
    lea rsi, [s_dev]
    mov ebx, 1
.a:
    cmp rbx, [argc]
    jae .have
    lea rax, [argv]
    mov rcx, [rax+rbx*8]
    mov rdx, rcx
.eq:
    mov al, [rdx]
    test al, al
    jz .name
    cmp al, '='
    je .next
    inc rdx
    jmp .eq
.name:
    mov rsi, rcx
    jmp .have
.next:
    inc ebx
    jmp .a
.have:
    mov [run], rsi              ; run name defaults to the preset
    lea rcx, [cfgpath]
    lea rdx, [s_train]
    call fmt_str
    mov rcx, rax
    mov rdx, rsi
    call fmt_str
    mov rcx, rax
    lea rdx, [s_cfg]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [cfgpath]
    call cfg_load
    test eax, eax
    jnz .loaded
    lea rcx, [e_preset]
    call fatal
.loaded:
    call cfg_args
    add rsp, 40
    pop rsi
    pop rbx
    ret

settings:
    sub rsp, 40
    cfgi batch, k_batch, 131072
    cfgi ntokens, k_tokens, 100000000
    cfgf lr, k_lr, c_lr
    cfgf minlr, k_minlr, c_minlr
    cfgi warmup, k_warmup, 100
    cfgf opt+OP_WD, k_wd, c_wd
    cfgf opt+OP_B1, k_b1, c_b1
    cfgf opt+OP_B2, k_b2, c_b2
    cfgf opt+OP_EPS, k_eps, c_eps
    cfgf opt+OP_CLIP, k_clip, c_clip
    cfgi seed, k_seed, 1337
    cfgi valev, k_valev, 250
    cfgi valb, k_valb, 20
    cfgi logev, k_logev, 10
    cfgi saveev, k_saveev, 1000
    cfgi savemin, k_savemin, 20
    cfgi keep, k_keep, 3
    cfgi stopat, k_stopat, 0
    cfgs datapat, k_data, d_data
    cfgs valpath, k_val, d_val
    lea rcx, [k_run]
    mov rdx, [run]
    call cfg_str
    mov [run], rax
    cfgs tokpath, k_tok, d_tok
    cfgs prompt, k_prompt, d_prompt
    cfgi slen, k_slen, 48
    cfgf temp, k_temp, c_temp
    cfgi topk, k_topk, 40
    mov rax, [topk]
    mov ecx, MAXK
    cmp rax, rcx
    cmova rax, rcx
    mov ecx, 1
    cmp rax, rcx
    cmovb rax, rcx
    mov [topk], rax

    ; a step is accum micro-batches of B x T
    mov rax, [batch]
    xor edx, edx
    div qword [mdl+MD_M]
    mov ecx, 1
    cmp rax, rcx
    cmovb rax, rcx
    cmp rax, MAXACC
    jbe .acc
    lea rcx, [e_accum]
    call fatal
.acc:
    mov [accum], rax
    imul rax, [mdl+MD_M]
    mov [tps], rax
    mov rcx, rax
    mov rax, [ntokens]
    add rax, rcx
    dec rax
    xor edx, edx
    div rcx
    mov [total], rax
    ; micro-batch layout: tokens, then pos/utok/ust from model_sort
    mov rax, [mdl+MD_T]
    inc rax
    imul rax, [mdl+MD_B]
    add rax, rax
    add rax, 255
    and rax, -256
    mov [tokb], rax
    mov rcx, [mdl+MD_M]
    lea rcx, [rcx*3+1]
    shl rcx, 2
    add rcx, 255
    and rcx, -256
    add rax, rcx
    mov [mbsz], rax
    add rsp, 40
    ret

buffers:
    push rbx
    sub rsp, 32
    mov rbx, [mbsz]
    imul rbx, [accum]
    mov rcx, rbx
    call gpu_host
    mov [hstep], rax
    mov rcx, rbx
    call gpu_host
    mov [hstep+8], rax
    mov rcx, rbx
    call gpu_alloc
    mov [dstep], rax
    mov rcx, [mdl+MD_M]
    lea rcx, [rcx*4+64]
    call gpu_host
    mov [hstats], rax
    mov rcx, [mdl+MD_M]
    lea rcx, [rcx*4+64]
    call gpu_host
    mov [hstats+8], rax
    lea rcx, [ev]
    mov edx, 2                  ; CU_EVENT_DISABLE_TIMING
    CU cuEventCreate
    lea rcx, [ev+8]
    mov edx, 2
    CU cuEventCreate
    ; validation rows, once: the start of the val file
    mov rbx, [mdl+MD_T]
    inc rbx
    imul rbx, [mdl+MD_B]
    imul rbx, [valb]
    add rbx, rbx
    mov rcx, rbx
    call mem_alloc
    mov [msg], rax              ; borrowed for a moment
    mov rcx, [valpath]
    mov rdx, rax
    mov r8, [mdl+MD_B]
    imul r8, [valb]
    mov r9, [mdl+MD_T]
    call ld_val
    mov rcx, rbx
    call gpu_alloc
    mov [dval], rax
    mov rcx, rax
    mov rdx, [msg]
    mov r8, rbx
    call gpu_up
    mov rcx, [msg]
    call mem_free
    ; sampling
    mov ecx, 4096
    call gpu_alloc
    mov [dsamp], rax
    mov rcx, [mdl+MD_V]
    shl rcx, 2
    call mem_alloc
    mov [hlog], rax
    add rsp, 32
    pop rbx
    ret

; checkpoints\<run>\ and logs\<run>.log
dirs:
    sub rsp, 40
    lea rcx, [s_ckroot]
    call make_dir
    lea rcx, [ckpath]
    lea rdx, [s_ckdir]
    call fmt_str
    mov rcx, rax
    mov rdx, [run]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [ckpath]
    call make_dir
    lea rcx, [ckpat]
    lea rdx, [ckpath]
    call fmt_str
    mov rcx, rax
    lea rdx, [s_stepall]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [cktmp]
    lea rdx, [ckpath]
    call fmt_str
    mov rcx, rax
    lea rdx, [s_tmp]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [s_logs]
    call make_dir
    lea rcx, [logpath]
    lea rdx, [s_logdir]
    call fmt_str
    mov rcx, rax
    mov rdx, [run]
    call fmt_str
    mov rcx, rax
    lea rdx, [s_logext]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [logpath]
    call file_append
    mov [logh], rax
    add rsp, 40
    ret

; newest checkpoint, or fresh weights
resume:
    sub rsp, 40
    mov rax, [c_nan]
    mov [stats+PS_VLOSS], rax
    lea rcx, [ckpat]
    lea rdx, [msg]
    call ck_latest
    test eax, eax
    jz .fresh
    lea rcx, [msg]
    lea rdx, [hdr]
    call ck_load
    mov rax, [hdr+CK_STEP]
    mov [step], rax
    mov [stats+PS_STEP], rax
    mov rax, [hdr+CK_SEEN]
    mov [stats+PS_SEEN], rax
    mov rax, [hdr+CK_FILE]
    xor edx, edx
    div qword [ld_nfiles]       ; in case the file list changed
    mov [ld_file], rdx
    mov rax, [hdr+CK_OFF]
    mov [ld_off], rax
    mov rax, [hdr+CK_ELAPSED]
    mov [stats+PS_ELAPSED0], rax
    mov rax, [hdr+CK_VLOSS]
    mov [stats+PS_VLOSS], rax
    movdqu xmm0, [hdr+CK_RNG]
    movdqu [rng], xmm0
    movdqu xmm0, [hdr+CK_RNG+16]
    movdqu [rng+16], xmm0
    say "  resuming from "
    lea rcx, [msg]
    call print_z
    say 13, 10
    add rsp, 40
    ret
.fresh:
    mov rcx, [seed]
    call model_init
    lea rcx, [rng]
    mov rdx, [seed]
    call rng_seed
    xor eax, eax
    mov [step], rax
    add rsp, 40
    ret

plan:
    push rsi
    push rdi
    sub rsp, 40
    call model_summary
    say "  run "
    mov rcx, [run]
    call print_z
    say ": "
    mov rcx, [total]
    call print_dec
    say " steps of "
    mov rcx, [tps]
    call pcount
    say " tokens ("
    mov rcx, [accum]
    call print_dec
    say " x "
    mov rcx, [mdl+MD_B]
    call print_dec
    say " x "
    mov rcx, [mdl+MD_T]
    call print_dec
    say "), "
    mov rcx, [total]
    imul rcx, [tps]
    call pcount
    say " tokens in all", 13, 10, "  lr "
    movsd xmm0, [lr]
    mov edx, 2
    call print_sci
    say ", warmup "
    mov rcx, [warmup]
    call print_dec
    say ", cosine down to "
    movsd xmm0, [lr]
    mulsd xmm0, [minlr]
    mov edx, 2
    call print_sci
    say ", wd "
    movsd xmm0, [opt+OP_WD]
    mov edx, 2
    call print_fixed
    say ", clip "
    movsd xmm0, [opt+OP_CLIP]
    mov edx, 2
    call print_fixed
    cmp dword [mdl_fast], 0
    jne .fast
    say ", naive kernels"
.fast:
    say 13, 10, "  data: "
    mov rcx, [ld_nfiles]
    call print_dec
    say " files, val "
    mov rcx, [valpath]
    call print_z
    say 13, 10, 13, 10
    ; the log gets a marker so resumed runs are easy to spot
    lea rdi, [msg]
    emit "start step="
    mov rcx, rdi
    mov rdx, [step]
    call fmt_dec
    mov rdi, rax
    emit 13, 10
    mov rcx, [logh]
    lea rdx, [msg]
    mov r8, rdi
    sub r8, rdx
    call file_write
    add rsp, 40
    pop rdi
    pop rsi
    ret

; gen mode: a few samples of the prompt from wherever the run got to, then exit.
; bin\train dev gen="Once upon a time" gen_count=5 temp=0.7
generate:
    push rbx
    sub rsp, 32
    call model_summary
    say "  samples at step "
    mov rcx, [step]
    call print_dec
    say ", temperature "
    movsd xmm0, [temp]
    mov edx, 2
    call print_fixed
    say ", top "
    mov rcx, [topk]
    call print_dec
    say 13, 10, 13, 10
    lea rcx, [k_gcount]
    mov edx, 3
    call cfg_int
    mov rbx, rax
.g:
    test rbx, rbx
    jz .done
    call sample
    lea rcx, [msg]
    mov rdx, rax
    call show
    dec rbx
    jmp .g
.done:
    call con_restore
    xor ecx, ecx
    call ExitProcess

; rcx = count, like 131K
pcount:
    sub rsp, 72
    mov rdx, rcx
    lea rcx, [rsp+32]
    call fmt_count
    lea rcx, [rsp+32]
    mov rdx, rax
    sub rdx, rcx
    call print
    add rsp, 72
    ret

; ---- the loop
trainloop:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    ; no sleeping while we train (ES_CONTINUOUS | ES_SYSTEM_REQUIRED), until we exit
    mov ecx, 0x80000001
    call SetThreadExecutionState
    mov rax, [total]
    mov [stats+PS_TOTAL], rax
    call gpu_meminfo
    mov [stats+PS_VRAMTOT], rdx
    sub rdx, rax
    mov [stats+PS_VRAM], rdx
    lea rcx, [stats]
    call prog_begin
    call time_now
    mov [lastsave], rax
    mov rax, [step]
    mov [nrep], rax
    mov ecx, eax
    and ecx, 1
    call fill
.next:
    mov r12, [step]
    cmp r12, [total]
    jae .done
    mov ebx, r12d
    and ebx, 1
    ; step k: its tokens up, all its kernels queued, its numbers on their way back
    mov rcx, [dstep]
    lea rdx, [hstep]
    mov rdx, [rdx+rbx*8]
    mov r8, [mbsz]
    imul r8, [accum]
    xor r9d, r9d
    CU cuMemcpyHtoDAsync
    mov ecx, ebx
    mov rdx, r12
    call launch
    lea rax, [r12+1]
    mov [step], rax
    ; the step before is finished or close to it
    mov rcx, [nrep]
    cmp rcx, r12
    jae .check
    call report
    inc qword [nrep]
.check:
    ; does anything need this step to be finished? r13: 1 val, 2 save, 4 stop
    xor r13d, r13d
    mov rax, [step]
    cmp rax, [total]
    jne .nlast
    or r13d, 3
.nlast:
    xor edx, edx
    div qword [valev]
    test rdx, rdx
    jnz .nval
    or r13d, 1
.nval:
    mov rax, [step]
    xor edx, edx
    div qword [saveev]
    test rdx, rdx
    jnz .nsave
    or r13d, 2
.nsave:
    cmp qword [savemin], 0
    je .ntime
    mov rcx, [lastsave]
    call time_since
    cvtsi2sd xmm1, qword [savemin]
    mulsd xmm1, [c_60]
    comisd xmm0, xmm1
    jb .ntime
    or r13d, 2
.ntime:
    mov rax, [step]
    cmp rax, [stopat]
    jne .nstopat
    or r13d, 6
.nstopat:
    cmp dword [stop_flag], 0
    je .nctrl
    or r13d, 6
.nctrl:
    test r13d, r13d
    jz .fill
    mov rcx, r12
    call report
    lea rax, [r12+1]
    mov [nrep], rax
    test r13d, 1
    jz .nv
    call validate
.nv:
    test r13d, 2
    jz .ns
    call save
.ns:
    test r13d, 4
    jnz .stopped
.fill:
    mov rax, [step]
    cmp rax, [total]
    jae .next
    mov ecx, eax
    and ecx, 1
    call fill
    jmp .next
.done:
    lea rcx, [stats]
    call prog_end
    say "  finished: "
    mov rcx, [total]
    call print_dec
    say " steps, final val loss "
    movsd xmm0, [stats+PS_VLOSS]
    mov edx, 4
    call print_fixed
    say 13, 10
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.stopped:
    lea rcx, [stats]
    call prog_end
    say "  stopped after step "
    mov rcx, [step]
    call print_dec
    say ", run it again to carry on", 13, 10
    mov rcx, [logh]
    call file_close
    call con_restore
    mov ecx, 2
    call ExitProcess

; ecx = buffer. the next step's micro-batches from the loader, each sorted by
; token for the embedding backward, and how many targets they hold
fill:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov ebx, ecx
    lea rsi, [hstep]
    mov rsi, [rsi+rbx*8]
    xor edi, edi                ; micro-batch
    xor r12d, r12d              ; targets
.mb:
    cmp rdi, [accum]
    jae .done
    mov rcx, rsi
    mov rdx, [mdl+MD_B]
    mov r8, [mdl+MD_T]
    call ld_rows
    mov rcx, rsi
    mov rdx, [mdl+MD_B]
    mov r8, [mdl+MD_T]
    mov r9, rsi
    add r9, [tokb]
    call model_sort
    mov rcx, rbx
    shl rcx, 13                 ; * MAXACC * 8
    lea rdx, [nus]
    add rdx, rcx
    mov [rdx+rdi*8], rax
    ; targets: every token, or with chat data just the MASKBIT ones (the first
    ; token of a row is never a target)
    cmp qword [ld_chat], 0
    jne .chat
    add r12, [mdl+MD_M]
    jmp .nmb
.chat:
    mov rcx, [mdl+MD_B]
    mov rdx, rsi
.row:
    mov r8, [mdl+MD_T]
    lea r9, [rdx+2]
.t:
    test word [r9], MASKBIT
    jz .nt
    inc r12
.nt:
    add r9, 2
    dec r8
    jnz .t
    mov rdx, r9
    dec rcx
    jnz .row
.nmb:
    add rsi, [mbsz]
    inc rdi
    jmp .mb
.done:
    lea rax, [tgt]
    mov [rax+rbx*8], r12
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ecx = buffer, rdx = step index k. every kernel of the step, then the loss and
; grad norm copied back into pinned memory behind them, and an event to wait on
launch:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov ebx, ecx
    mov r12, rdx
    call model_zero
    ; 1/targets, so the loss is a mean over the whole step
    lea rax, [tgt]
    mov rax, [rax+rbx*8]
    cvtsi2sd xmm1, rax
    movsd xmm0, [c_one]
    divsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    movd [mb+MB_SCALE], xmm0
    mov eax, [ld_chat]
    mov [mb+MB_FLAGS], eax
    mov rax, [mdl+MD_B]
    mov [mb+MB_B], rax
    mov rax, [mdl+MD_T]
    mov [mb+MB_T], rax
    mov rsi, [dstep]
    xor edi, edi
.mb:
    cmp rdi, [accum]
    jae .opt
    mov [mb+MB_TOK], rsi
    mov rax, rsi
    add rax, [tokb]
    mov [mb+MB_POS], rax
    mov rcx, [mdl+MD_M]
    lea rax, [rax+rcx*4]
    mov [mb+MB_UTOK], rax
    lea rax, [rax+rcx*4]
    mov [mb+MB_UST], rax
    mov rcx, rbx
    shl rcx, 13
    lea rdx, [nus]
    add rdx, rcx
    mov rax, [rdx+rdi*8]
    mov [mb+MB_NU], rax
    lea rcx, [mb]
    mov edx, FW_GRAD
    call model_fwd
    lea rcx, [mb]
    call model_bwd
    add rsi, [mbsz]
    inc rdi
    jmp .mb
.opt:
    mov rcx, r12
    call lrat
    movsd [opt+OP_LR], xmm0
    lea rcx, [opt]
    lea rdx, [r12+1]
    call model_step
    lea rcx, [hstats]
    mov rcx, [rcx+rbx*8]
    mov rdx, [d_loss]
    mov r8, [mdl+MD_M]
    shl r8, 2
    xor r9d, r9d
    CU cuMemcpyDtoHAsync
    lea rcx, [hstats]
    mov rcx, [rcx+rbx*8]
    mov rax, [mdl+MD_M]
    lea rcx, [rcx+rax*4]
    mov rdx, [d_gn]
    mov r8d, 4
    xor r9d, r9d
    CU cuMemcpyDtoHAsync
    lea rcx, [ev]
    mov rcx, [rcx+rbx*8]
    xor edx, edx
    CU cuEventRecord
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = step index. xmm0 = its learning rate: linear warmup, then cosine down to
; min_lr * lr at the last step
lrat:
    sub rsp, 40
    cmp rcx, [warmup]
    jae .cos
    lea rax, [rcx+1]
    cvtsi2sd xmm0, rax
    cvtsi2sd xmm1, qword [warmup]
    divsd xmm0, xmm1
    mulsd xmm0, [lr]
    add rsp, 40
    ret
.cos:
    sub rcx, [warmup]
    cvtsi2sd xmm0, rcx
    mov rax, [total]
    sub rax, [warmup]
    mov ecx, 1
    cmp rax, rcx
    cmovb rax, rcx
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    minsd xmm0, [c_one]
    mulsd xmm0, [c_pi]
    call math_cos
    addsd xmm0, [c_one]
    mulsd xmm0, [c_half]        ; 1 -> 0
    movsd xmm1, [c_one]
    subsd xmm1, [minlr]
    mulsd xmm0, xmm1
    addsd xmm0, [minlr]
    mulsd xmm0, [lr]
    add rsp, 40
    ret

; rcx = step index k, whose numbers were queued by launch. waits for them, updates
; the bar, and every log_every steps writes a log line
report:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov r12, rcx
    mov ebx, ecx
    and ebx, 1
    lea rcx, [ev]
    mov rcx, [rcx+rbx*8]
    CU cuEventSynchronize
    lea rsi, [hstats]
    mov rsi, [rsi+rbx*8]
    xorpd xmm0, xmm0
    xor ecx, ecx
.s:
    cmp rcx, [mdl+MD_M]
    jae .sd
    cvtss2sd xmm1, [rsi+rcx*4]
    addsd xmm0, xmm1
    inc rcx
    jmp .s
.sd:
    lea rax, [tgt]
    cvtsi2sd xmm1, qword [rax+rbx*8]
    divsd xmm0, xmm1
    movsd [stats+PS_LOSS], xmm0
    cvtss2sd xmm0, [rsi+rcx*4]
    sqrtsd xmm0, xmm0
    movsd [stats+PS_GNORM], xmm0
    mov rcx, r12
    call lrat
    movsd [stats+PS_LR], xmm0
    lea rax, [r12+1]
    mov [stats+PS_STEP], rax
    imul rax, [tps]
    mov [stats+PS_SEEN], rax
    ; speed over this session
    mov rcx, [stats+PS_T0]
    call time_since
    lea rax, [r12+1]
    sub rax, [stats+PS_STEP0]
    imul rax, [tps]
    cvtsi2sd xmm1, rax
    divsd xmm1, xmm0
    movsd [stats+PS_TOKS], xmm1
    mulsd xmm1, [mdl+MD_FLOPS]
    divsd xmm1, [c_1e12]
    movsd [stats+PS_TFLOPS], xmm1
    call gpu_meminfo
    sub rdx, rax
    mov [stats+PS_VRAM], rdx
    lea rcx, [stats]
    xor edx, edx
    call prog_draw
    lea rax, [r12+1]
    xor edx, edx
    div qword [logev]
    test rdx, rdx
    jnz .done
    mov rcx, [stats+PS_T0]      ; the bar only keeps this fresh when it draws
    call time_since
    addsd xmm0, [stats+PS_ELAPSED0]
    movsd [stats+PS_ELAPSED], xmm0
    lea rcx, [stats]
    mov rdx, [logh]
    call prog_line
    cmp dword [con_tty], 0
    jne .done
    lea rcx, [stats]            ; no bar when redirected, so print the line
    mov rdx, [con_out]
    call prog_line
.done:
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = text, rdx = end. a copy without the color codes (ESC [ ... letter) goes to
; msg+4096, rax = its end
plain:
    lea rax, [msg+4096]
.c:
    cmp rcx, rdx
    jae .done
    mov r8b, [rcx]
    inc rcx
    cmp r8b, 27
    jne .keep
.esc:
    cmp rcx, rdx
    jae .done
    mov r8b, [rcx]
    inc rcx
    or r8b, 0x20
    cmp r8b, 'a'
    jb .esc
    cmp r8b, 'z'
    ja .esc
    jmp .c
.keep:
    mov [rax], r8b
    inc rax
    jmp .c
.done:
    ret

; rcx = text, rdx = end. to the console as is, or plain when redirected
show:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    cmp dword [con_tty], 0
    jne .print
    call plain
    lea rbx, [msg+4096]
    mov rsi, rax
.print:
    mov rcx, rbx
    mov rdx, rsi
    sub rdx, rbx
    call print
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = text, rdx = end. above the bar and into the log. the colors only go to a
; real console, the log and redirected output get the plain text
note:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rsi, rdx
    call plain
    mov rdi, rax
    cmp dword [con_tty], 0
    je .redir
    lea rcx, [stats]
    mov rdx, rbx
    mov r8, rsi
    sub r8, rbx
    call prog_msg
    jmp .log
.redir:
    lea rcx, [stats]
    lea rdx, [msg+4096]
    mov r8, rdi
    sub r8, rdx
    call prog_msg
.log:
    mov rcx, [logh]
    lea rdx, [msg+4096]
    mov r8, rdi
    sub r8, rdx
    call file_write
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; val loss over the fixed val rows, then a sample
validate:
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    mov rcx, [d_loss]
    xor edx, edx
    mov r8, [mdl+MD_M]
    CU cuMemsetD32
    mov rax, [mdl+MD_B]
    mov [mb+MB_B], rax
    mov rax, [mdl+MD_T]
    mov [mb+MB_T], rax
    mov dword [mb+MB_FLAGS], 0
    mov rsi, [dval]
    xor ebx, ebx
.b:
    cmp rbx, [valb]
    jae .sum
    mov [mb+MB_TOK], rsi
    lea rcx, [mb]
    mov edx, FW_LOSS
    call model_fwd
    mov rax, [mdl+MD_T]
    inc rax
    imul rax, [mdl+MD_B]
    lea rsi, [rsi+rax*2]
    inc rbx
    jmp .b
.sum:
    call model_loss
    mov rax, [mdl+MD_M]
    imul rax, [valb]
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    movsd [stats+PS_VLOSS], xmm0
    lea rdi, [msg]
    emit "  ", 27, "[36mval ", 27, "[0m"
    mov rcx, rdi
    movsd xmm1, [stats+PS_VLOSS]
    mov r8d, 4
    call fmt_fixed
    mov rdi, rax
    emit " at step "
    mov rcx, rdi
    mov rdx, [step]
    call fmt_dec
    mov rdi, rax
    emit 13, 10
    lea rcx, [msg]
    mov rdx, rdi
    call note
    call sample
    lea rcx, [msg]
    mov rdx, rax
    call note
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret

; a short continuation of the prompt, top-k sampling at temperature temp. the text
; goes to msg, rax = its end
sample:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    lea rdi, [seq]
    xor eax, eax
    mov ecx, SAMPT + 8
    rep stosw
    mov word [seq], TOK_BOS
    mov rsi, [prompt]
    mov rdx, rsi
.len:
    cmp byte [rdx], 0
    je .enc
    inc rdx
    jmp .len
.enc:
    sub rdx, rsi
    cmp rdx, SAMPT / 2
    jbe .encode
    mov edx, SAMPT / 2
.encode:
    mov r8, rdx
    mov rcx, [tctx]
    mov rdx, rsi
    lea r9, [seq+2]
    call tok_encode
    lea r12, [rax+1]            ; tokens so far
    mov r13, r12                ; where the prompt ends
    xor ebx, ebx
.gen:
    cmp rbx, [slen]
    jae .show
    cmp r12, SAMPT
    jae .show
    mov rcx, [dsamp]
    lea rdx, [seq]
    mov r8d, (SAMPT + 1) * 2
    call gpu_up
    mov rax, [dsamp]
    mov [mb+MB_TOK], rax
    mov qword [mb+MB_B], 1
    mov qword [mb+MB_T], SAMPT
    lea rcx, [mb]
    mov edx, FW_LOGITS
    call model_fwd
    mov rcx, [hlog]
    mov rdx, r12
    dec rdx
    imul rdx, [mdl+MD_V]
    shl rdx, 2
    add rdx, [d_logits]
    mov r8, [mdl+MD_V]
    shl r8, 2
    call gpu_down
    call pick
    cmp eax, SPECIAL0
    jae .show                   ; end of the document
    lea rcx, [seq]
    mov [rcx+r12*2], ax
    inc r12
    inc rbx
    jmp .gen
.show:
    ; "  prompt|continuation", control characters shown as spaces
    lea rdi, [msg]
    emit "  ", 27, "[90m"
    lea rcx, [seq+2]
    lea rdx, [r13-1]
    mov r8, rdi
    call tok_decode
    add rdi, rax
    emit 27, "[0m"
    lea rcx, [seq]
    lea rcx, [rcx+r13*2]
    mov rdx, r12
    sub rdx, r13
    mov r8, rdi
    call tok_decode
    lea rcx, [rdi+rax]
.clean:
    cmp rdi, rcx
    jae .end
    cmp byte [rdi], 32
    jae .ok
    cmp byte [rdi], 27
    je .ok
    mov byte [rdi], ' '
.ok:
    inc rdi
    jmp .clean
.end:
    emit 13, 10
    mov rax, rdi
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; logits in hlog. eax = the sampled token: keep the top_k, softmax them at
; temperature temp, draw one
pick:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, [hlog]
    xor ebx, ebx                ; how many kept
    xor ecx, ecx
.v:
    cmp rcx, [mdl+MD_V]
    jae .kept
    cvtss2sd xmm0, [rsi+rcx*4]
    ; full and not better than the last one: skip
    cmp rbx, [topk]
    jb .ins
    lea rax, [topv]
    comisd xmm0, [rax+rbx*8-8]
    jbe .nv
    dec rbx
.ins:
    ; insertion from the end, descending
    mov rdx, rbx
.sh:
    test rdx, rdx
    jz .put
    lea rax, [topv]
    comisd xmm0, [rax+rdx*8-8]
    jbe .put
    movsd xmm1, [rax+rdx*8-8]
    movsd [rax+rdx*8], xmm1
    lea rax, [topi]
    mov r8, [rax+rdx*8-8]
    mov [rax+rdx*8], r8
    dec rdx
    jmp .sh
.put:
    lea rax, [topv]
    movsd [rax+rdx*8], xmm0
    lea rax, [topi]
    mov [rax+rdx*8], rcx
    inc rbx
.nv:
    inc rcx
    jmp .v
.kept:
    ; p_i = exp((v_i - v_0) / temp), in place
    xorpd xmm0, xmm0
    movsd [rsp+32], xmm0        ; sum
    xor edi, edi
.p:
    cmp rdi, rbx
    jae .draw
    lea rax, [topv]
    movsd xmm0, [rax+rdi*8]
    subsd xmm0, [rax]
    divsd xmm0, [temp]
    call math_exp
    lea rax, [topv]
    movsd [rax+rdi*8], xmm0
    addsd xmm0, [rsp+32]
    movsd [rsp+32], xmm0
    inc rdi
    jmp .p
.draw:
    lea rcx, [rng]
    call rng_float
    mulsd xmm0, [rsp+32]
    xor edi, edi
    lea rax, [topv]
.w:
    lea rcx, [rdi+1]
    cmp rcx, rbx
    jae .got                    ; last one takes whatever rounding left over
    subsd xmm0, [rax+rdi*8]
    xorpd xmm1, xmm1
    comisd xmm0, xmm1
    jb .got
    inc rdi
    jmp .w
.got:
    lea rax, [topi]
    mov rax, [rax+rdi*8]
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; checkpoint of where we are now (step steps done, the loader at the next one)
save:
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    lea rdi, [hdr]
    xor eax, eax
    mov ecx, CK_SIZE / 8
    rep stosq
    mov rax, CK_MAGIC_V
    mov [hdr+CK_MAGIC], rax
    mov rax, [mdl+MD_L]
    mov [hdr+CK_L], rax
    mov rax, [mdl+MD_D]
    mov [hdr+CK_D], rax
    mov rax, [mdl+MD_H]
    mov [hdr+CK_H], rax
    mov rax, [mdl+MD_KVH]
    mov [hdr+CK_KVH], rax
    mov rax, [mdl+MD_F]
    mov [hdr+CK_F], rax
    mov rax, [mdl+MD_V]
    mov [hdr+CK_V], rax
    mov rax, [mdl+MD_T]
    mov [hdr+CK_T], rax
    mov rax, [mdl+MD_NP]
    mov [hdr+CK_NP], rax
    mov rax, [step]
    mov [hdr+CK_STEP], rax
    imul rax, [tps]
    mov [hdr+CK_SEEN], rax
    mov rax, [ld_file]
    mov [hdr+CK_FILE], rax
    mov rax, [ld_off]
    mov [hdr+CK_OFF], rax
    mov rcx, [stats+PS_T0]
    call time_since
    addsd xmm0, [stats+PS_ELAPSED0]
    movsd [hdr+CK_ELAPSED], xmm0
    mov rax, [stats+PS_VLOSS]
    mov [hdr+CK_VLOSS], rax
    movdqu xmm0, [rng]
    movdqu [hdr+CK_RNG], xmm0
    movdqu xmm0, [rng+16]
    movdqu [hdr+CK_RNG+16], xmm0
    mov rax, [total]
    mov [hdr+CK_TOTAL], rax
    ; checkpoints\run\step_00001234.ckpt
    lea rcx, [msg]
    lea rdx, [ckpath]
    call fmt_str
    mov rcx, rax
    lea rdx, [s_step]
    call fmt_str
    mov rcx, rax
    mov rdx, [step]
    mov r8d, 8
    call fmt_dec0
    mov rcx, rax
    lea rdx, [s_ckext]
    call fmt_str
    mov byte [rax], 0
    call time_now
    mov rbx, rax
    lea rcx, [hdr]
    lea rdx, [msg]
    lea r8, [cktmp]
    call ck_save
    lea rcx, [ckpat]
    mov rdx, [keep]
    call ck_prune
    lea rdi, [msg+2048]
    emit "  ", 27, "[90msaved step "
    mov rcx, rdi
    mov rdx, [step]
    call fmt_dec
    mov rdi, rax
    emit " ("
    mov rcx, rbx
    call time_since
    movapd xmm1, xmm0
    mov rcx, rdi
    mov r8d, 1
    call fmt_fixed
    mov rdi, rax
    emit " s)", 27, "[0m", 13, 10
    lea rcx, [msg+2048]
    mov rdx, rdi
    call note
    call time_now
    mov [lastsave], rax
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret
