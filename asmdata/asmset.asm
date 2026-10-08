; asmset: the NASM fine-tuning set, from what teach saved in datasets\asm
;   asmset            re-checks every lesson, holds per_topic lessons of each topic
;                     out for NASM-Eval (and drops training lessons too close to
;                     them), writes asm-train.txt and asm-eval.txt (conversations,
;                     then runs chatdocs and tokenize on them), eval.jsonl,
;                     train.jsonl and thinking.jsonl
;   asmset mutants    breaks train.jsonl's lessons a line at a time and keeps the
;                     mutants harness.asm catches: mutants.jsonl, for teach explain
; per_topic=4 seed=42 threads=8 per_lesson=2
; uses: asmdata\verify asmdata\json
default rel
bits 64
%include "lib.inc"
%include "asmdata/asmdata.inc"

extern ExitProcess

MAXL    equ 1 << 14             ; lessons, fixes, mutants
BIGSZ   equ 4 << 20             ; one conversation or json line
WRSZ    equ 1 << 20

; a lesson
LS_ID     equ 0
LS_TOPIC  equ 8                 ; zero terminated
LS_LEVEL  equ 16
LS_TASK   equ 24                ; (ptr, len) from here on
LS_SIG    equ 40
LS_CODE   equ 56
LS_EXPL   equ 72
LS_TESTS  equ 88
LS_PATH   equ 104
LS_THINK  equ 120
LS_STH    equ 136               ; the second solution's thinking
LS_SEC    equ 152               ; and its code
LS_NAME   equ 168
LS_DROP   equ 184               ; why it's out, or 0
LS_EVAL   equ 192
LS_WORDS  equ 200               ; (ptr, count) of sorted hashes
LS_OPS    equ 216
LS_SIZE   equ 232

; a fix (a debug lesson teach saved) or a mutant
FX_ID     equ 0
FX_LS     equ 8                 ; its lesson
FX_STAGE  equ 16                ; zero terminated, what teach saw
FX_BROKEN equ 24                ; (ptr, len)
FX_WHY    equ 40                ; the explanation
FX_OP     equ 56                ; mutants: which bug
FX_ERR    equ 64                ; (ptr, len) what it does with the final tests
FX_NOW    equ 80                ; ST_*
FX_DROP   equ 88
FX_SIZE   equ 96

; a mutant made here
MT_OP     equ 0
MT_BROKEN equ 8
MT_STAGE  equ 24
MT_ERR    equ 32
MT_FIX    equ 48
MT_SIZE   equ 64

; a buffered output file
WR_H      equ 0
WR_N      equ 8
WR_BUF    equ 16

section .rdata
f_lessons db "datasets\asm\lessons*.jsonl", 0
f_fixes   db "datasets\asm\fixes*.jsonl", 0
f_mut     db "datasets\asm\mutants.jsonl", 0
f_why     db "datasets\asm\mutwhy*.jsonl", 0
f_train   db "datasets\asm\train.jsonl", 0
f_eval    db "datasets\asm\eval.jsonl", 0
f_think   db "datasets\asm\thinking.jsonl", 0
f_atrain  db "datasets\asm\asm-train.txt", 0
f_aeval   db "datasets\asm\asm-eval.txt", 0
c_docs1   db "bin\chatdocs.exe datasets\asm\asm-train.txt", 0
c_docs2   db "bin\chatdocs.exe datasets\asm\asm-eval.txt", 0
c_tok     db "bin\tokenize.exe datasets\asm\asm-train.docs datasets\asm\asm-eval.docs", 0
d_work    db "scratch\asmgen\set\w", 0
k_id      db "id", 0
k_topic   db "topic", 0
k_level   db "level", 0
k_task    db "task", 0
k_sig     db "signature", 0
k_code    db "code", 0
k_expl    db "explanation", 0
k_tests   db "tests", 0
k_path    db "path", 0
k_think   db "thinking", 0
k_sth     db "second_thinking", 0
k_sec     db "second", 0
k_name    db "name", 0
k_broken  db "broken", 0
k_stage   db "stage", 0
k_wrong   db "wrong", 0
k_op      db "op", 0
k_err     db "err", 0
k_why     db "why", 0
k_pt      db "per_topic", 0
k_seed    db "seed", 0
k_thr     db "threads", 0
k_pl      db "per_lesson", 0
s_link    db "link", 0
w_test    db "test", 0
w_tests   db "tests", 0
w_expv    db "expected value", 0
w_section db "section", 0
w_canary  db "6674804268077157163", 0
w_canx    db "5ca1ab1e", 0
w_movzx   db "movzx", 0
w_movsx   db "movsx", 0
w_dword   db "dword", 0
w_line    db "line ", 0
w_told1   db "were told", 0
w_told2   db "was told", 0
w_fence   db "```", 0
w_testn   db "test ", 0
w_cand    db "cand.", 0
w_thunk   db "thunk.obj", 0
w_texe    db "t.exe", 0
w_proto   db " The C prototype is `", 0
w_nasm    db "```nasm", 10, 0
w_endf    db 10, "```", 0
w_user    db "user: ", 0
w_asst    db "assistant: ", 0
r_canary  db "tests expect the harness canary", 0
r_movzx   db "movzx/movsx from a dword", 0
r_tests   db "its tests don't parse", 0
r_near    db "near copy of an earlier lesson", 0
r_close   db "too close to an eval task", 0
r_fls     db "fix: its lesson was dropped or held out", 0
r_fnone   db "fix: no explanation", 0
r_fsame   db "fix: only a test or a comment changed", 0
r_ftest   db "fix: the explanation is about a test", 0
r_flink   db "fix: link error blamed on something else", 0
r_fout    db "fix: broken code reaches outside", 0
r_fpass   db "fix: the old code passes the final tests", 0
r_mfmt    db "mutant: explanation off format", 0
r_fails   db "fails now: ok", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
          db "fails now: assemble", 0, 0, 0, 0, 0
          db "fails now: internal", 0, 0, 0, 0, 0
          db "fails now: link", 0, 0, 0, 0, 0, 0, 0, 0, 0
          db "fails now: tests", 0, 0, 0, 0, 0, 0, 0, 0
          db "fails now: abi", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
          db "fails now: crash", 0, 0, 0, 0, 0, 0, 0, 0
          db "fails now: timeout", 0, 0, 0, 0, 0, 0
; what the person asking says, picked at random
asks      dq a0, a1, a2, a3
a0        db "What does this NASM function do?", 0
a1        db "Can you explain this assembly code?", 0
a2        db "Explain this x86-64 function step by step.", 0
a3        db "How does this NASM routine work?", 0
mine      dq m0, m1, m2
m0        db "Here's my code:", 0
m1        db "This is what I wrote:", 0
m2        db "My attempt:", 0
huh       dq h0, h1, h2
h0        db "What's wrong?", 0
h1        db "Can you find the bug?", 0
h2        db "How do I fix it?", 0
symptom   dq 0, y1, 0, y3, y4, y5, y6, y7
y1        db "NASM gives me these errors:", 0
y3        db "It assembles, but linking fails:", 0
y4        db "It builds, but my tests fail:", 0
y5        db "My test harness says it breaks the calling convention:", 0
y6        db "It crashes:", 0
y7        db "It never returns:", 0
stagez    dq z0, z1, z2, z3, z4, z5, z6, z7
z0        db "ok", 0
z1        db "assemble", 0
z2        db "internal", 0
z3        db "link", 0
z4        db "tests", 0
z5        db "abi", 0
z6        db "crash", 0
z7        db "timeout", 0
; mutations
conds     db "l", 0, 0, "b", 0, 0, "g", 0, 0, "a", 0, 0, "le", 0, "be", 0, "ge", 0, "ae", 0
          db "e", 0, 0, "ne", 0, "z", 0, 0, "nz", 0
; for each cond above: the signed/unsigned twin, the off by one, the opposite (0 = none)
csign     db 1, 0, 3, 2, 5, 4, 7, 6, -1, -1, -1, -1
coff      db 4, 5, 6, 7, 0, 1, 2, 3, -1, -1, -1, -1
cinv      db -1, -1, -1, -1, -1, -1, -1, -1, 9, 8, 11, 10
swaps     db "shr", 0, 0, 0, "sar", 0, 0, 0, "movzx", 0, "movsx", 0, "inc", 0, 0, 0, "dec", 0, 0, 0
argr      db "rcx", 0, "rdx", 0, "ecx", 0, "edx", 0, "rdx", 0, "r8", 0, 0, "edx", 0, "r8d", 0
saved     db "rbx", 0, "rbp", 0, "rsi", 0, "rdi", 0, "r12", 0, "r13", 0, "r14", 0, "r15", 0
o_sign    db "signedness", 0
o_off     db "off by one", 0
o_inv     db "inverted condition", 0
o_init    db "missing init", 0
o_scale   db "wrong scale", 0
o_arg     db "wrong argument register", 0
o_save    db "unsaved register", 0
o_swap    db "sar instead of shr", 0, "shr instead of sar", 0, "movsx instead of movzx", 0
          db "movzx instead of movsx", 0, "dec instead of inc", 0, "inc instead of dec", 0, 0
w_jmp     db "jmp", 0
w_j       db "j", 0
w_cmov    db "cmov", 0
w_set     db "set", 0
w_xor     db "xor", 0
w_push    db "push", 0
w_pop     db "pop", 0
x_chg     db "change `", 0
x_back    db "` back to `", 0
x_add     db "add back `", 0
x_match   db "` and the matching `pop ", 0
x_end     db "`", 0
e_usage   db "usage: asmset [mutants] [per_topic=4] [seed=42] [threads=8]", 0

section .bss
alignb 8
ar        resb ARENA_SIZE
alock     resd 1
rng       resb RNG_SIZE
lessons   resq 1
nls       resq 1
fixes     resq 1
nfixes       resq 1
muts      resq 1
nmuts       resq 1
whys      resq 1
nwhys       resq 1
ctxs      resq 64
big       resq 1                ; BIGSZ, for json lines and conversations
ubuf      resq 1
abuf      resq 1
names     resb 1 << 16
reasons   resq 2 * 64           ; (reason, count)
nreason   resq 1
topics    resq 64
ntopic    resq 1
order     resq MAXL
wr        resb 24
per_topic resq 1
per_less  resq 1
seed      resq 1
counts    resq 8                ; lessons, explain, fixes, mutants, skipped, train, eval, kept
mres      resq 1                ; mutants: MT records, per_lesson slots for each lesson

section .text

global start
start:
    sub rsp, 40
    call lib_init
    call cfg_args
    lea rcx, [k_pt]
    mov edx, 4
    call cfg_int
    mov [per_topic], rax
    lea rcx, [k_pl]
    mov edx, 2
    call cfg_int
    mov [per_less], rax
    lea rcx, [k_seed]
    mov edx, 42
    call cfg_int
    mov [seed], rax
    lea rcx, [rng]
    mov rdx, rax
    call rng_seed
    lea rcx, [k_thr]
    mov edx, 8
    call cfg_int
    cmp rax, 64
    jbe .thr
    mov eax, 64
.thr:
    mov ecx, eax
    call pool_init
    call vf_init
    lea rcx, [ar]
    mov rdx, 1 << 34
    call arena_init
    mov ecx, MAXL * LS_SIZE
    call mem_alloc
    mov [lessons], rax
    mov ecx, MAXL * FX_SIZE
    call mem_alloc
    mov [fixes], rax
    mov ecx, MAXL * FX_SIZE
    call mem_alloc
    mov [muts], rax
    mov ecx, MAXL * FX_SIZE
    call mem_alloc
    mov [whys], rax
    mov ecx, BIGSZ
    call mem_alloc
    mov [big], rax
    mov ecx, BIGSZ
    call mem_alloc
    mov [ubuf], rax
    mov ecx, BIGSZ
    call mem_alloc
    mov [abuf], rax
    mov ecx, WRSZ
    call mem_alloc
    mov [wr+WR_BUF], rax
    ; a checking context for each thread
    xor ebx, ebx
.ctx:
    cmp rbx, [nthreads]
    jae .mode
    lea rcx, [names]
    lea rdx, [d_work]
    call fmt_str
    mov rcx, rax
    mov rdx, rbx
    call fmt_dec
    mov byte [rax], 0
    lea rcx, [names]
    call vf_new
    lea rcx, [ctxs]
    mov [rcx+rbx*8], rax
    inc ebx
    jmp .ctx
.mode:
    cmp qword [argc], 2
    jb .build
    mov rax, [argv+8]
    cmp dword [rax], 'muta'
    jne .build
    call mutants
    jmp .exit
.build:
    call build
.exit:
    call con_restore
    xor ecx, ecx
    call ExitProcess

; ---- loading

; rcx = size. rax = memory from the arena (any thread)
alloc:
    sub rsp, 40
    mov rdx, rcx
.lock:
    lock bts dword [alock], 0
    jnc .locked
    pause
    jmp .lock
.locked:
    lea rcx, [ar]
    mov r8d, 8
    call arena_alloc
    mov dword [alock], 0
    add rsp, 40
    ret

; rcx = json object, rdx = key. rax = the string value decoded into the arena (with
; a 0 after it), rdx = its length. rax = 0 if it's missing or not a string
jfield:
    push rbx
    push rsi
    sub rsp, 40
    call js_get
    test rax, rax
    jz .no
    cmp byte [rax], '"'
    jne .no
    mov rsi, rax
    mov rcx, rax
    call js_skip
    sub rax, rsi
    lea rcx, [rax+1]
    call alloc
    mov rbx, rax
    mov rcx, rsi
    mov rdx, rbx
    call js_str
    mov rdx, rax
    mov rax, rbx
    jmp .ret
.no:
    xor eax, eax
    xor edx, edx
.ret:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = json object, rdx = key. rax = the number there (0 if there isn't one)
jint:
    sub rsp, 40
    call js_get
    test rax, rax
    jz .r
    mov rcx, rax
    call parse_int
.r:
    add rsp, 40
    ret

; rcx = file pattern, rdx = fn(line), called with every line of every file that
; matches (zero terminated in place)
each_line:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov r12, rdx
    lea rdx, [names]
    mov r8d, 1 << 16
    call file_find
    mov r13, rax
    mov r14, rdx
.file:
    test r13, r13
    jz .done
    mov rcx, [r14]
    call file_read_all
    test rax, rax
    jz .nextf
    mov rsi, rax
    lea rdi, [rax+rdx]
.line:
    cmp rsi, rdi
    jae .nextf
    mov rbx, rsi
.eol:
    cmp rbx, rdi
    jae .got
    cmp byte [rbx], 10
    je .got
    inc rbx
    jmp .eol
.got:
    mov byte [rbx], 0
    cmp rbx, rsi
    je .skip
    mov rcx, rsi
    call r12
.skip:
    lea rsi, [rbx+1]
    jmp .line
.nextf:
    add r14, 8
    dec r13
    jmp .file
.done:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; a (ptr, len) field of a record from json: %1 = key, %2 = offset
%macro getf 2
    mov rcx, rsi
    lea rdx, [%1]
    call jfield
    mov [rbx+%2], rax
    mov [rbx+%2+8], rdx
%endmacro

; rcx = one line of lessons*.jsonl or train.jsonl
load_lesson:
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
    mov rax, [nls]
    cmp rax, MAXL
    jae .ret
    imul rbx, rax, LS_SIZE
    add rbx, [lessons]
    mov rcx, rsi
    lea rdx, [k_id]
    call jfield
    test rax, rax
    jz .ret
    lea rcx, [rax+1]            ; "i123"
    call parse_int
    mov [rbx+LS_ID], rax
    getf k_topic, LS_TOPIC
    mov rcx, rsi
    lea rdx, [k_level]
    call jint
    mov [rbx+LS_LEVEL], rax
    getf k_task, LS_TASK
    getf k_sig, LS_SIG
    getf k_code, LS_CODE
    getf k_expl, LS_EXPL
    getf k_tests, LS_TESTS
    getf k_path, LS_PATH
    getf k_think, LS_THINK
    getf k_sth, LS_STH
    getf k_sec, LS_SEC
    cmp qword [rbx+LS_CODE], 0
    je .ret
    cmp qword [rbx+LS_TESTS], 0
    je .ret
    cmp qword [rbx+LS_TASK], 0
    je .ret
    inc qword [nls]
.ret:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = a line of fixes*.jsonl, mutants.jsonl or mutwhy*.jsonl, rdx = which array
%macro loader 2
%1:
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
    mov rax, [n%2]
    cmp rax, MAXL
    jae .ret
    imul rbx, rax, FX_SIZE
    add rbx, [%2]
    mov rcx, rsi
    lea rdx, [k_id]
    call jfield
    test rax, rax
    jz .ret
    lea rcx, [rax+1]
    call parse_int
    mov [rbx+FX_ID], rax
    call .fields
    inc qword [n%2]
.ret:
    add rsp, 40
    pop rsi
    pop rbx
    ret
%endmacro

loader load_fix, fixes
.fields:
    sub rsp, 40                 ; the jfield calls' shadow space, and aligned
    getf k_broken, FX_BROKEN
    getf k_wrong, FX_WHY
    mov rcx, rsi
    lea rdx, [k_stage]
    call jfield
    mov [rbx+FX_STAGE], rax
    add rsp, 40
    ret

loader load_mut, muts
.fields:
    sub rsp, 40                 ; the jfield calls' shadow space, and aligned
    getf k_broken, FX_BROKEN
    getf k_err, FX_ERR
    mov rcx, rsi
    lea rdx, [k_stage]
    call jfield
    mov [rbx+FX_STAGE], rax
    mov rcx, rsi
    lea rdx, [k_op]
    call jfield
    mov [rbx+FX_OP], rax
    add rsp, 40
    ret

loader load_why, whys
.fields:
    sub rsp, 40                 ; the jfield calls' shadow space, and aligned
    getf k_why, FX_WHY
    mov rcx, rsi
    lea rdx, [k_op]
    call jfield
    mov [rbx+FX_OP], rax
    add rsp, 40
    ret

; rcx = id. rax = that lesson, or 0
find_lesson:
    mov r8, [lessons]
    mov r9, [nls]
.l:
    test r9, r9
    jz .no
    cmp [r8+LS_ID], rcx
    je .yes
    add r8, LS_SIZE
    dec r9
    jmp .l
.yes:
    mov rax, r8
    ret
.no:
    xor eax, eax
    ret

; rcx, rdx = zero terminated strings. eax = <0, 0, >0 like strcmp
strcmp:
    movzx eax, byte [rcx]
    movzx r8d, byte [rdx]
    sub eax, r8d
    jnz .r
    test r8d, r8d
    jz .r
    inc rcx
    inc rdx
    jmp strcmp
.r:
    ret

; ---- text helpers

; rcx = text, rdx = length, r8 = zero terminated needle (lowercase). eax = 1 if it's
; in there, any case
icontains:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    lea rdi, [rcx+rdx]
    mov rbx, r8
.at:
    cmp rsi, rdi
    jae .no
    mov rcx, rsi
    mov rdx, rdi
    sub rdx, rsi
    mov r8, rbx
    call istarts
    test eax, eax
    jnz .r
    inc rsi
    jmp .at
.no:
    xor eax, eax
.r:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rdi = dst, rsi = text, rcx = length. whitespace runs become one space, trimmed.
; rdi moves past it
flat:
    push rbx
    lea rbx, [rsi+rcx]
    xor edx, edx                ; a space is pending
    mov r8, rdi                 ; nothing written yet
.c:
    cmp rsi, rbx
    jae .done
    movzx eax, byte [rsi]
    inc rsi
    cmp eax, ' '
    je .ws
    cmp eax, 9
    jb .put
    cmp eax, 13
    jbe .ws
.put:
    test edx, edx
    jz .p
    cmp rdi, r8
    je .p
    mov byte [rdi], ' '
    inc rdi
.p:
    xor edx, edx
    mov [rdi], al
    inc rdi
    jmp .c
.ws:
    mov edx, 1
    jmp .c
.done:
    pop rbx
    ret

; rdi = dst, rcx = lesson. the task in one line, then the C prototype
prompt:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov rsi, [rbx+LS_TASK]
    mov rcx, [rbx+LS_TASK+8]
    call flat
    lea rsi, [w_proto]
.pr:
    lodsb
    test al, al
    jz .sig
    stosb
    jmp .pr
.sig:
    ; the signature without ``` fences or backticks, flat, no ; at the end
    mov r12, rdi
    mov rsi, [rbx+LS_SIG]
    mov rcx, [rbx+LS_SIG+8]
    lea r13, [rsi+rcx]
    mov r8, [ubuf]              ; (the scratch, prompt never writes into ubuf itself)
    add r8, BIGSZ / 2
    mov r9, r8
.s:
    cmp rsi, r13
    jae .sd
    movzx eax, byte [rsi]
    inc rsi
    cmp eax, '`'
    jne .sk
    lea rdx, [rsi+1]
    cmp rdx, r13
    jae .s
    cmp word [rsi], '``'
    jne .s
    add rsi, 2
.lang:
    cmp rsi, r13
    jae .sd
    movzx ecx, byte [rsi]
    mov r10, rcx
    call isw
    test eax, eax
    jz .s
    inc rsi
    jmp .lang
.sk:
    mov [r9], al
    inc r9
    jmp .s
.sd:
    mov rsi, r8
    mov rcx, r9
    sub rcx, r8
    call flat
.semi:
    cmp rdi, r12
    jbe .end
    cmp byte [rdi-1], ';'
    jne .end
    dec rdi
    cmp rdi, r12
    jbe .end
    cmp byte [rdi-1], ' '
    jne .end
    dec rdi
.end:
    mov word [rdi], '`.'
    add rdi, 2
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; ecx = byte. eax = 1 for [A-Za-z0-9_]
isw:
    xor eax, eax
    cmp ecx, '_'
    je .y
    cmp ecx, '0'
    jb .n
    cmp ecx, '9'
    jbe .y
    or ecx, 0x20
    cmp ecx, 'a'
    jb .n
    cmp ecx, 'z'
    ja .n
.y:
    mov eax, 1
.n:
    ret

; rdi = dst, rsi = code, rcx = length. ```nasm, the code trimmed, ```
fence:
    push rbx
    push r12
    sub rsp, 40
    mov rbx, rsi
    mov r12, rcx
    lea rsi, [w_nasm]
    call cpz
    mov rcx, rbx
    mov rdx, r12
    call trim
    mov rsi, rax
    mov rcx, rdx
    rep movsb
    lea rsi, [w_endf]
    call cpz
    add rsp, 40
    pop r12
    pop rbx
    ret

; rdi = dst, rsi = zero terminated. copies it, rdi moves past
cpz:
    mov al, [rsi]
    test al, al
    jz .r
    mov [rdi], al
    inc rsi
    inc rdi
    jmp cpz
.r:
    ret

; rdi = dst, rsi = text, rcx = length: copy it trimmed
cptrim:
    sub rsp, 40
    mov rdx, rcx
    mov rcx, rsi
    call trim
    mov rsi, rax
    mov rcx, rdx
    rep movsb
    add rsp, 40
    ret

; rcx = table of string pointers, edx = how many. rsi = one of them at random
pick:
    push rbx
    push rdi
    sub rsp, 40
    mov rbx, rcx
    mov edi, edx
    lea rcx, [rng]
    call rng_next
    xor edx, edx
    div rdi
    mov rsi, [rbx+rdx*8]
    add rsp, 40
    pop rdi
    pop rbx
    ret

; code without comments or blank lines, for "did the code change": rcx = code,
; rdx = length, r8 = dst. rax = length
bare:
    push rsi
    push rdi
    mov rsi, rcx
    lea r9, [rcx+rdx]
    mov rdi, r8
.line:
    cmp rsi, r9
    jae .done
    mov r10, rsi
.eol:
    cmp rsi, r9
    jae .got
    cmp byte [rsi], 10
    je .got
    cmp byte [rsi], ';'
    je .cmt
    inc rsi
    jmp .eol
.cmt:
    mov r11, rsi
.c2:
    cmp rsi, r9
    jae .got2
    cmp byte [rsi], 10
    je .got2
    inc rsi
    jmp .c2
.got:
    mov r11, rsi
.got2:
    ; [r10, r11) trimmed
.f:
    cmp r10, r11
    jae .next
    cmp byte [r10], ' '
    ja .b
    inc r10
    jmp .f
.b:
    cmp byte [r11-1], ' '
    ja .cp
    dec r11
    jmp .b
.cp:
    mov al, [r10]
    mov [rdi], al
    inc rdi
    inc r10
    cmp r10, r11
    jb .cp
    mov byte [rdi], 10
    inc rdi
.next:
    inc rsi
    jmp .line
.done:
    mov rax, rdi
    sub rax, r8
    pop rdi
    pop rsi
    ret

; ---- similarity: sorted arrays of 64-bit fnv-1a hashes

; rax = hash so far, rsi = bytes, rcx = how many
%macro fnv 0
%%l:
    test rcx, rcx
    jz %%d
    movzx edx, byte [rsi]
    xor rax, rdx
    imul rax, r11
    inc rsi
    dec rcx
    jmp %%l
%%d:
%endmacro

; rcx = array, rdx = count. sorts it and drops repeats, rax = new count
sortu:
    push rbx
    mov r8, rcx
    mov r9, rdx
    mov r10d, 1
.out:
    cmp r10, r9
    jae .uniq
    mov rax, [r8+r10*8]
    mov rbx, r10
.in:
    test rbx, rbx
    jz .put
    cmp [r8+rbx*8-8], rax
    jbe .put
    mov rcx, [r8+rbx*8-8]
    mov [r8+rbx*8], rcx
    dec rbx
    jmp .in
.put:
    mov [r8+rbx*8], rax
    inc r10
    jmp .out
.uniq:
    xor eax, eax
    test r9, r9
    jz .r
    mov eax, 1
    mov r10d, 1
.u:
    cmp r10, r9
    jae .r
    mov rcx, [r8+r10*8]
    cmp rcx, [r8+rax*8-8]
    je .un
    mov [r8+rax*8], rcx
    inc rax
.un:
    inc r10
    jmp .u
.r:
    pop rbx
    ret

; rcx = lesson: LS_WORDS (pairs of words in the task, lowercase) and LS_OPS (pairs of
; instructions in the code, operands without spaces)
shingles:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, rcx
    ; words: lowercase [a-z0-9_] runs, as (start, len) in big
    mov rsi, [rbx+LS_TASK]
    mov r12, [rbx+LS_TASK+8]
    lea r12, [rsi+r12]
    mov r13, [big]
    mov rdi, r13
    mov r8, [ubuf]              ; lowercased copy
    mov r9, r8
.w:
    cmp rsi, r12
    jae .wend
    movzx eax, byte [rsi]
    inc rsi
    lea ecx, [rax-'A']
    cmp ecx, 25
    ja .lw
    or eax, 0x20
.lw:
    mov ecx, eax
    mov r10d, eax
    call isw
    test eax, eax
    jz .sep
    mov [r9], r10b
    inc r9
    jmp .w
.sep:
    mov byte [r9], ' '
    inc r9
    jmp .w
.wend:
    mov byte [r9], ' '
    inc r9
    ; runs between spaces
    mov rsi, r8
    xor r14d, r14d              ; words
.run:
    cmp rsi, r9
    jae .pairs
    cmp byte [rsi], ' '
    jne .ws
    inc rsi
    jmp .run
.ws:
    mov [rdi], rsi
    mov rcx, rsi
.we:
    cmp byte [rcx], ' '
    je .wl
    inc rcx
    jmp .we
.wl:
    mov rax, rcx
    sub rax, rsi
    mov [rdi+8], rax
    add rdi, 16
    inc r14
    mov rsi, rcx
    cmp r14, 8192
    jb .run
.pairs:
    lea rcx, [r14*8+8]
    call alloc
    mov r15, rax
    mov r11, 0x100000001b3
    xor r12d, r12d
.pr:
    lea rax, [r12+1]
    cmp rax, r14
    jae .pd
    mov rax, 0xcbf29ce484222325
    mov rdx, r12
    shl rdx, 4
    mov rsi, [r13+rdx]
    mov rcx, [r13+rdx+8]
    fnv
    xor rax, ' '
    imul rax, r11
    mov rdx, r12
    shl rdx, 4
    mov rsi, [r13+rdx+16]
    mov rcx, [r13+rdx+24]
    fnv
    mov [r15+r12*8], rax
    inc r12
    jmp .pr
.pd:
    mov rcx, r15
    mov rdx, r12
    call sortu
    mov [rbx+LS_WORDS], r15
    mov [rbx+LS_WORDS+8], rax
    ; ops: for each line "mnemonic operands", the pair with the one before
    mov rcx, [rbx+LS_CODE+8]
    lea rcx, [rcx*8+8]
    call alloc
    mov r15, rax
    xor r14d, r14d              ; hashes
    mov rsi, [rbx+LS_CODE]
    mov r12, [rbx+LS_CODE+8]
    add r12, rsi
    mov r13, [ubuf]             ; previous token, then the current one at +4096
    mov qword [r13], 0          ; length of prev
.line:
    cmp rsi, r12
    jae .od
    mov rdi, rsi
.oe:
    cmp rdi, r12
    jae .og
    cmp byte [rdi], 10
    je .og
    inc rdi
    jmp .oe
.og:
    ; [rsi, rdi) up to any ;
    mov r8, rsi
.oc:
    cmp r8, rdi
    jae .ot
    cmp byte [r8], ';'
    je .ot
    inc r8
    jmp .oc
.ot:
    mov rcx, rsi
    mov rdx, r8
    sub rdx, rsi
    call trim
    lea rsi, [rdi+1]
    ; letters, then whitespace, then the rest
    test rdx, rdx
    jz .line
    lea r8, [rax+rdx]
    mov r9, r13
    add r9, 4096 + 8
    mov r10, r9
.ml:
    cmp rax, r8
    jae .line
    movzx ecx, byte [rax]
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 25
    ja .msp
    mov cl, [rax]
    mov [r10], cl
    inc r10
    inc rax
    jmp .ml
.msp:
    cmp r10, r9
    je .line                    ; didn't start with a letter
    cmp rax, r8
    jae .line                   ; no operands, like ret
    movzx ecx, byte [rax]
    cmp ecx, ' '
    je .ms
    cmp ecx, 9
    jne .line                   ; a letter run then something else, like a label
.ms:
    mov byte [r10], ' '
    inc r10
.mr:
    cmp rax, r8
    jae .mtok
    movzx ecx, byte [rax]
    inc rax
    cmp ecx, ' '
    jbe .mr
    mov [r10], cl
    inc r10
    lea rdx, [r9+240]
    cmp r10, rdx
    jb .mr
.mtok:
    ; hash prev | cur, then cur becomes prev
    mov r11, 0x100000001b3
    mov rax, 0xcbf29ce484222325
    mov [rsp+24], rsi
    lea rsi, [r13+8]
    mov rcx, [r13]
    fnv
    xor rax, '|'
    imul rax, r11
    mov rsi, r9
    mov rcx, r10
    sub rcx, r9
    fnv
    mov [r15+r14*8], rax
    inc r14
    mov rcx, r10
    sub rcx, r9
    mov [r13], rcx
    mov rsi, r9
    lea rdi, [r13+8]
    rep movsb
    mov rsi, [rsp+24]
    jmp .line
.od:
    mov rcx, r15
    mov rdx, r14
    call sortu
    mov [rbx+LS_OPS], r15
    mov [rbx+LS_OPS+8], rax
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx, rdx = sorted hashes a, count; r8, r9 = b. rax = shared, rdx = in either.
; both 0 if either is empty
jac:
    xor eax, eax
    test rdx, rdx
    jz .zero
    test r9, r9
    jz .zero
    push rbx
    push rsi
    lea r10, [rcx+rdx*8]
    lea r11, [r8+r9*8]
    mov rsi, rdx
    add rsi, r9                 ; |a| + |b|
.m:
    cmp rcx, r10
    jae .d
    cmp r8, r11
    jae .d
    mov rbx, [rcx]
    cmp rbx, [r8]
    je .same
    jb .a
    add r8, 8
    jmp .m
.a:
    add rcx, 8
    jmp .m
.same:
    inc rax
    add rcx, 8
    add r8, 8
    jmp .m
.d:
    mov rdx, rsi
    sub rdx, rax
    pop rsi
    pop rbx
    ret
.zero:
    xor edx, edx
    ret

; rcx = lesson a, rdx = lesson b, r8d = LS_WORDS or LS_OPS, r9d = threshold in
; tenths. eax = 1 if their similarity is over it (r9d >= 100 means "at least",
; minus 100: 107 = at least 0.7)
similar:
    push rbx
    sub rsp, 32
    mov ebx, r9d
    mov r10, rcx
    mov r11, rdx
    mov rcx, [r10+r8]
    mov rdx, [r10+r8+8]
    mov r9, [r11+r8+8]
    mov r8, [r11+r8]
    call jac
    test rdx, rdx
    jz .no
    imul rax, rax, 10
    cmp ebx, 100
    jae .atleast
    imul rdx, rbx
    cmp rax, rdx
    seta al
    movzx eax, al
    jmp .r
.atleast:
    sub ebx, 100
    imul rdx, rbx
    cmp rax, rdx
    setae al
    movzx eax, al
    jmp .r
.no:
    xor eax, eax
.r:
    add rsp, 32
    pop rbx
    ret

; ---- output

; rcx = path. opens wr
wr_open:
    sub rsp, 40
    call file_create
    cmp rax, -1
    jne .ok
    lea rcx, [f_train]
    call fatal
.ok:
    mov [wr+WR_H], rax
    mov qword [wr+WR_N], 0
    add rsp, 40
    ret

; rcx = bytes, rdx = how many
wr_put:
    push rsi
    push rdi
    push rbx
    sub rsp, 32
    mov rsi, rcx
    mov rbx, rdx
.more:
    test rbx, rbx
    jz .r
    mov rax, WRSZ
    sub rax, [wr+WR_N]
    jnz .room
    call wr_flush
    mov rax, WRSZ
.room:
    cmp rax, rbx
    jbe .cp
    mov rax, rbx
.cp:
    mov rdi, [wr+WR_BUF]
    add rdi, [wr+WR_N]
    mov rcx, rax
    add [wr+WR_N], rax
    sub rbx, rax
    rep movsb
    jmp .more
.r:
    add rsp, 32
    pop rbx
    pop rdi
    pop rsi
    ret

wr_flush:
    sub rsp, 40
    mov rcx, [wr+WR_H]
    mov rdx, [wr+WR_BUF]
    mov r8, [wr+WR_N]
    call file_write
    mov qword [wr+WR_N], 0
    add rsp, 40
    ret

wr_close:
    sub rsp, 40
    call wr_flush
    mov rcx, [wr+WR_H]
    call file_close
    add rsp, 40
    ret

; rdi = end of what's in big. writes big to wr with a line break
wr_big:
    sub rsp, 40
    mov byte [rdi], 10
    mov rcx, [big]
    lea rdx, [rdi+1]
    sub rdx, rcx
    call wr_put
    add rsp, 40
    ret

; json bits into rdi: a literal (key and punctuation), then a (ptr, len) string
%macro jlit 1+
    emit %1
%endmacro

%macro jstr 2
    mov rcx, rdi
    mov rdx, %1
    mov r8, %2
    call js_put
    mov rdi, rax
%endmacro

%macro jdec 1
    mov rcx, rdi
    mov rdx, %1
    call fmt_dec
    mov rdi, rax
%endmacro

; rcx = user text, rdx = length, r8 = assistant text, r9 = length. one conversation
; in chatdocs' format: "." for an empty line, and one that would read as a comment,
; a role or a "." itself gets the whole conversation skipped. eax = 1 if written
conv:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov r14, rcx
    mov r15, rdx
    mov r12, r8
    mov r13, r9
    ; check both first
    call trim
    mov rcx, rax
    call okmsg
    test eax, eax
    jz .skip
    mov rcx, r12
    mov rdx, r13
    call trim
    mov rcx, rax
    call okmsg
    test eax, eax
    jz .skip
    mov rdi, [big]
    lea rsi, [w_user]
    call cpz
    mov rcx, r14
    mov rdx, r15
    call msg
    lea rsi, [w_asst]
    call cpz
    mov rcx, r12
    mov rdx, r13
    call msg
    mov byte [rdi], 10
    inc rdi
    mov rcx, [big]
    mov rdx, rdi
    sub rdx, rcx
    call wr_put
    mov eax, 1
    jmp .r
.skip:
    inc qword [counts+32]
    xor eax, eax
.r:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = message (trimmed), rdx = length. eax = 0 if a line after the first is "."
; or starts with #, user:, assistant: or system:
okmsg:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    lea rdi, [rcx+rdx]
.first:
    cmp rsi, rdi
    jae .ok
    cmp byte [rsi], 10
    je .line
    inc rsi
    jmp .first
.line:
    inc rsi
    cmp rsi, rdi
    jae .ok
    mov al, [rsi]
    cmp al, '#'
    je .bad
    cmp al, '.'
    jne .roles
    lea rcx, [rsi+1]
    cmp rcx, rdi
    jae .bad
    cmp byte [rcx], 10
    je .bad
    cmp byte [rcx], 13
    je .bad
.roles:
    lea rbx, [roles]
.r:
    cmp byte [rbx], 0
    je .first
    mov rcx, rsi
    mov rdx, rdi
    sub rdx, rsi
    mov r8, rbx
    call startsz
    test eax, eax
    jnz .bad
.rn:
    cmp byte [rbx], 0
    lea rbx, [rbx+1]
    jne .rn
    jmp .r
.bad:
    xor eax, eax
    jmp .ret
.ok:
    mov eax, 1
.ret:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx, rdx = text, r8 = literal. eax = 1 if the text starts with it exactly
startsz:
    xor eax, eax
.l:
    mov r9b, [r8]
    test r9b, r9b
    jz .y
    test rdx, rdx
    jz .n
    cmp r9b, [rcx]
    jne .n
    inc rcx
    inc r8
    dec rdx
    jmp .l
.y:
    mov eax, 1
.n:
    ret

; rdi = dst, rcx = message, rdx = length. its lines, trailing space off, "." for
; empty ones, each with a line break
msg:
    push rbx
    push rsi
    sub rsp, 40
    call trim
    mov rsi, rax
    lea rbx, [rax+rdx]
.line:
    mov rcx, rsi
.e:
    cmp rcx, rbx
    jae .got
    cmp byte [rcx], 10
    je .got
    inc rcx
    jmp .e
.got:
    mov rdx, rcx
.rt:
    cmp rdx, rsi
    jbe .empty
    cmp byte [rdx-1], ' '
    ja .cp
    dec rdx
    jmp .rt
.empty:
    mov byte [rdi], '.'
    inc rdi
    jmp .nl
.cp:
    mov r8, rcx
    mov rcx, rdx
    sub rcx, rsi
    rep movsb
    mov rcx, r8
.nl:
    mov byte [rdi], 10
    inc rdi
    lea rsi, [rcx+1]
    cmp rcx, rbx
    jb .line
    add rsp, 40
    pop rsi
    pop rbx
    ret

; ---- build

build:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    lea rcx, [f_lessons]
    lea rdx, [load_lesson]
    call each_line
    say "  "
    mov rcx, [nls]
    call print_dec
    say " lessons", 13, 10
    ; in idea order
    mov rcx, [lessons]
    mov rdx, [nls]
    call sort_lessons
    ; lint
    mov rbx, [lessons]
    mov r12, [nls]
.lint:
    test r12, r12
    jz .check
    mov rcx, [rbx+LS_TESTS]
    mov rdx, [rbx+LS_TESTS+8]
    lea r8, [w_canary]
    call icontains
    test eax, eax
    jnz .canary
    mov rcx, [rbx+LS_TESTS]
    mov rdx, [rbx+LS_TESTS+8]
    lea r8, [w_canx]
    call icontains
    test eax, eax
    jnz .canary
    mov rcx, rbx
    call movzx32
    test eax, eax
    jz .ln
    lea rax, [r_movzx]
    mov [rbx+LS_DROP], rax
    jmp .ln
.canary:
    lea rax, [r_canary]
    mov [rbx+LS_DROP], rax
.ln:
    add rbx, LS_SIZE
    dec r12
    jmp .lint
.check:
    say "  checking them again", 13, 10
    lea rcx, [check_lessons]
    xor edx, edx
    mov r8, [nls]
    mov r9d, 1
    call par_for
    ; near copies: compare each with the kept ones before it
    mov rbx, [lessons]
    xor r12d, r12d
.sh:
    cmp r12, [nls]
    jae .dedup
    mov rcx, rbx
    call shingles
    add rbx, LS_SIZE
    inc r12
    jmp .sh
.dedup:
    xor r12d, r12d
.d1:
    cmp r12, [nls]
    jae .split
    imul rbx, r12, LS_SIZE
    add rbx, [lessons]
    cmp qword [rbx+LS_DROP], 0
    jne .d4
    xor r13d, r13d
.d2:
    cmp r13, r12
    jae .d4
    imul r14, r13, LS_SIZE
    add r14, [lessons]
    cmp qword [r14+LS_DROP], 0
    jne .d3
    mov rcx, rbx
    mov rdx, r14
    mov r8d, LS_OPS
    mov r9d, 107
    call similar
    test eax, eax
    jz .d3
    lea rax, [r_near]
    mov [rbx+LS_DROP], rax
    jmp .d4
.d3:
    inc r13
    jmp .d2
.d4:
    inc r12
    jmp .d1
.split:
    call split
    ; anything too close to an eval task is out of training
    xor r12d, r12d
.n1:
    cmp r12, [nls]
    jae .write
    imul rbx, r12, LS_SIZE
    add rbx, [lessons]
    cmp qword [rbx+LS_DROP], 0
    jne .n4
    cmp qword [rbx+LS_EVAL], 0
    jne .n4
    xor r13d, r13d
.n2:
    cmp r13, [nls]
    jae .n4
    imul r14, r13, LS_SIZE
    add r14, [lessons]
    cmp qword [r14+LS_EVAL], 0
    je .n3
    mov rcx, rbx
    mov rdx, r14
    call close_to
    test eax, eax
    jz .n3
    lea rax, [r_close]
    mov [rbx+LS_DROP], rax
    jmp .n4
.n3:
    inc r13
    jmp .n2
.n4:
    inc r12
    jmp .n1
.write:
    call write_lists
    call write_convs
    ; and on into tokens
    lea rcx, [c_docs1]
    call show_run
    lea rcx, [c_docs2]
    call show_run
    lea rcx, [c_tok]
    call show_run
    call report
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = lessons, rdx = count: by id, insertion sort (they're nearly in order)
sort_lessons:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, LS_SIZE + 8
    mov r12, rcx
    mov r13, rdx
    mov ebx, 1
.out:
    cmp rbx, r13
    jae .r
    ; take [rbx] out
    imul rsi, rbx, LS_SIZE
    add rsi, r12
    mov rdi, rsp
    mov ecx, LS_SIZE
    rep movsb
    mov rax, [rsp+LS_ID]
    mov r8, rbx
.in:
    test r8, r8
    jz .put
    imul rsi, r8, LS_SIZE
    add rsi, r12
    sub rsi, LS_SIZE
    cmp [rsi+LS_ID], rax
    jbe .put
    lea rdi, [rsi+LS_SIZE]
    mov ecx, LS_SIZE
    rep movsb
    dec r8
    jmp .in
.put:
    imul rdi, r8, LS_SIZE
    add rdi, r12
    mov rsi, rsp
    mov ecx, LS_SIZE
    rep movsb
    inc rbx
    jmp .out
.r:
    add rsp, LS_SIZE + 8
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = lesson. eax = 1 if its code does movzx/movsx with a dword source
movzx32:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, [rcx+LS_CODE]
    mov rdi, [rcx+LS_CODE+8]
    add rdi, rsi
    mov rbx, rsi
.at:
    cmp rbx, rdi
    jae .no
    mov r12, rbx
    mov rcx, rbx
    mov rdx, rdi
    sub rdx, rbx
    lea r8, [w_movzx]
    call istarts
    test eax, eax
    jnz .hit
    mov rcx, rbx
    mov rdx, rdi
    sub rdx, rbx
    lea r8, [w_movsx]
    call istarts
    test eax, eax
    jz .next
.hit:
    ; a word boundary before, then: space, a register, a comma, dword
    cmp rbx, rsi
    je .h1
    movzx ecx, byte [rbx-1]
    call isw
    test eax, eax
    jnz .next
.h1:
    lea rcx, [rbx+5]
    cmp rcx, rdi
    jae .next
    cmp byte [rcx], ' '
    je .h2
    cmp byte [rcx], 9
    jne .next
.h2:
    cmp rcx, rdi
    jae .next
    cmp byte [rcx], ' '
    je .h3
    cmp byte [rcx], 9
    jne .reg
.h3:
    inc rcx
    jmp .h2
.reg:
    mov r12, rcx
.h4:
    cmp rcx, rdi
    jae .next
    mov r8, rcx
    movzx ecx, byte [rcx]
    call isw
    mov rcx, r8
    test eax, eax
    jz .h5
    inc rcx
    jmp .h4
.h5:
    cmp rcx, r12
    je .next
.h6:
    cmp rcx, rdi
    jae .next
    cmp byte [rcx], ' '
    je .h7
    cmp byte [rcx], 9
    je .h7
    cmp byte [rcx], ','
    jne .next
    inc rcx
.h8:
    cmp rcx, rdi
    jae .next
    cmp byte [rcx], ' '
    je .h9
    cmp byte [rcx], 9
    jne .dw
.h9:
    inc rcx
    jmp .h8
.h7:
    inc rcx
    jmp .h6
.dw:
    mov rdx, rdi
    sub rdx, rcx
    lea r8, [w_dword]
    call istarts
    test eax, eax
    jnz .yes
.next:
    inc rbx
    jmp .at
.yes:
    mov eax, 1
    jmp .r
.no:
    xor eax, eax
.r:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; par_for: lessons rdx..r8 on thread r9. parses the tests and builds the code again
check_lessons:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rdx
    mov rdi, r8
    lea rax, [ctxs]
    mov r12, [rax+r9*8]
.l:
    cmp rsi, rdi
    jae .r
    imul rbx, rsi, LS_SIZE
    add rbx, [lessons]
    cmp qword [rbx+LS_DROP], 0
    jne .n
    mov rcx, r12
    mov rdx, [rbx+LS_TESTS]
    mov r8, [rbx+LS_TESTS+8]
    call vf_tests
    cmp rax, -1
    jne .t
    lea rax, [r_tests]
    mov [rbx+LS_DROP], rax
    jmp .n
.t:
    mov rax, [r12+VC_TESTS]
    mov rcx, [rax+TS_FN]
    mov [rbx+LS_NAME], rcx
    mov rcx, [rax+TS_FNLEN]
    mov [rbx+LS_NAME+8], rcx
    mov rcx, r12
    mov rdx, [rbx+LS_CODE]
    mov r8, [rbx+LS_CODE+8]
    call vf_verify
    test eax, eax
    jz .n
    lea rcx, [r_fails]
    imul eax, eax, 24
    add rax, rcx
    mov [rbx+LS_DROP], rax
.n:
    inc rsi
    jmp .l
.r:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; per_topic lessons of each topic go to eval, picked at random. topics in name order
split:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    ; the topics
    xor r12d, r12d
.t1:
    cmp r12, [nls]
    jae .sort
    imul rbx, r12, LS_SIZE
    add rbx, [lessons]
    cmp qword [rbx+LS_DROP], 0
    jne .t3
    xor r13d, r13d
.t2:
    cmp r13, [ntopic]
    jae .add
    lea rax, [topics]
    mov rcx, [rax+r13*8]
    mov rdx, [rbx+LS_TOPIC]
    call strcmp
    test eax, eax
    jz .t3
    inc r13
    jmp .t2
.add:
    mov rax, [ntopic]
    cmp rax, 64
    jae .t3
    lea rcx, [topics]
    mov rdx, [rbx+LS_TOPIC]
    mov [rcx+rax*8], rdx
    inc qword [ntopic]
.t3:
    inc r12
    jmp .t1
.sort:
    mov r12d, 1
.s1:
    cmp r12, [ntopic]
    jae .pick
    lea rax, [topics]
    mov r14, [rax+r12*8]
    mov r13, r12
.s2:
    test r13, r13
    jz .s3
    lea rax, [topics]
    mov rcx, [rax+r13*8-8]
    mov rdx, r14
    call strcmp
    test eax, eax
    jle .s3
    lea rax, [topics]
    mov rcx, [rax+r13*8-8]
    mov [rax+r13*8], rcx
    dec r13
    jmp .s2
.s3:
    lea rax, [topics]
    mov [rax+r13*8], r14
    inc r12
    jmp .s1
.pick:
    xor r15d, r15d              ; topic
.p1:
    cmp r15, [ntopic]
    jae .r
    ; this topic's lessons, in order
    xor r14d, r14d
    xor r12d, r12d
.p2:
    cmp r12, [nls]
    jae .p3
    imul rbx, r12, LS_SIZE
    add rbx, [lessons]
    cmp qword [rbx+LS_DROP], 0
    jne .p2n
    lea rax, [topics]
    mov rcx, [rax+r15*8]
    mov rdx, [rbx+LS_TOPIC]
    call strcmp
    test eax, eax
    jnz .p2n
    lea rax, [order]
    mov [rax+r14*8], rbx
    inc r14
.p2n:
    inc r12
    jmp .p2
.p3:
    ; partial fisher-yates
    xor r13d, r13d
.p4:
    cmp r13, [per_topic]
    jae .p5
    cmp r13, r14
    jae .p5
    lea rcx, [rng]
    call rng_next
    mov rcx, r14
    sub rcx, r13
    xor edx, edx
    div rcx
    add rdx, r13
    lea rax, [order]
    mov rcx, [rax+r13*8]
    mov r8, [rax+rdx*8]
    mov [rax+r13*8], r8
    mov [rax+rdx*8], rcx
    mov qword [r8+LS_EVAL], 1
    inc r13
    jmp .p4
.p5:
    inc r15
    jmp .p1
.r:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = lesson, rdx = eval lesson. eax = 1 if they share the function name, the code
; is over 0.4 alike or the task over 0.3
close_to:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    mov rcx, [rbx+LS_NAME+8]
    cmp rcx, [rsi+LS_NAME+8]
    jne .code
    mov r8, [rbx+LS_NAME]
    mov r9, [rsi+LS_NAME]
.n:
    dec rcx
    js .yes
    mov al, [r8+rcx]
    cmp al, [r9+rcx]
    jne .code
    jmp .n
.code:
    mov rcx, rbx
    mov rdx, rsi
    mov r8d, LS_OPS
    mov r9d, 4
    call similar
    test eax, eax
    jnz .yes
    mov rcx, rbx
    mov rdx, rsi
    mov r8d, LS_WORDS
    mov r9d, 3
    call similar
    jmp .r
.yes:
    mov eax, 1
.r:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; train.jsonl, eval.jsonl, thinking.jsonl
write_lists:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    xor r14d, r14d              ; 0 = train.jsonl, 1 = eval.jsonl
.file:
    lea rcx, [f_train]
    test r14, r14
    jz .open
    lea rcx, [f_eval]
.open:
    call wr_open
    xor r12d, r12d
.l:
    cmp r12, [nls]
    jae .closef
    imul rbx, r12, LS_SIZE
    add rbx, [lessons]
    cmp qword [rbx+LS_DROP], 0
    jne .n
    cmp [rbx+LS_EVAL], r14
    jne .n
    mov rdi, [big]
    jlit '{"id":"i'
    jdec [rbx+LS_ID]
    jlit '","topic":'
    mov rcx, [rbx+LS_TOPIC]
    call zlen
    jstr [rbx+LS_TOPIC], rax
    jlit ',"level":'
    jdec [rbx+LS_LEVEL]
    test r14, r14
    jnz .ev
    jlit ',"task":'
    jstr [rbx+LS_TASK], [rbx+LS_TASK+8]
    jmp .nm
.ev:
    jlit ',"prompt":'
    mov rsi, rdi
    mov rdi, [abuf]
    mov rcx, rbx
    call prompt
    mov rcx, rsi
    mov rdx, [abuf]
    mov r8, rdi
    sub r8, rdx
    mov rdi, rsi
    call js_put
    mov rdi, rax
.nm:
    jlit ',"name":'
    jstr [rbx+LS_NAME], [rbx+LS_NAME+8]
    jlit ',"tests":'
    jstr [rbx+LS_TESTS], [rbx+LS_TESTS+8]
    jlit ',"code":'
    jstr [rbx+LS_CODE], [rbx+LS_CODE+8]
    mov byte [rdi], '}'
    inc rdi
    call wr_big
    lea rax, [counts+40]
    inc qword [rax+r14*8]
.n:
    inc r12
    jmp .l
.closef:
    call wr_close
    inc r14
    cmp r14, 2
    jb .file
    ; the thinking, for a reasoning set some day. eval ones are marked so they stay out
    lea rcx, [f_think]
    call wr_open
    xor r12d, r12d
.t:
    cmp r12, [nls]
    jae .tclose
    imul rbx, r12, LS_SIZE
    add rbx, [lessons]
    mov rax, [rbx+LS_DROP]
    test rax, rax
    jz .tk
    lea rcx, [r_close]
    cmp rax, rcx                ; still a good lesson, just not for training now
    jne .tn
.tk:
    cmp qword [rbx+LS_THINK], 0
    je .tn
    mov rdi, [big]
    jlit '{"id":"i'
    jdec [rbx+LS_ID]
    jlit '","split":"'
    cmp qword [rbx+LS_EVAL], 0
    jne .te
    cmp qword [rbx+LS_DROP], 0
    jne .tx
    jlit 'train"'
    jmp .t2
.te:
    jlit 'eval"'
    jmp .t2
.tx:
    jlit 'held"'
.t2:
    jlit ',"topic":'
    mov rcx, [rbx+LS_TOPIC]
    call zlen
    jstr [rbx+LS_TOPIC], rax
    jlit ',"level":'
    jdec [rbx+LS_LEVEL]
    jlit ',"path":'
    mov rcx, [rbx+LS_PATH]
    call zlen
    jstr [rbx+LS_PATH], rax
    jlit ',"prompt":'
    mov rsi, rdi
    mov rdi, [abuf]
    mov rcx, rbx
    call prompt
    mov rcx, rsi
    mov rdx, [abuf]
    mov r8, rdi
    sub r8, rdx
    mov rdi, rsi
    call js_put
    mov rdi, rax
    jlit ',"thinking":'
    jstr [rbx+LS_THINK], [rbx+LS_THINK+8]
    jlit ',"code":'
    jstr [rbx+LS_CODE], [rbx+LS_CODE+8]
    jlit ',"explanation":'
    jstr [rbx+LS_EXPL], [rbx+LS_EXPL+8]
    cmp qword [rbx+LS_STH], 0
    je .tend
    jlit ',"second_thinking":'
    jstr [rbx+LS_STH], [rbx+LS_STH+8]
    jlit ',"second":'
    jstr [rbx+LS_SEC], [rbx+LS_SEC+8]
.tend:
    mov byte [rdi], '}'
    inc rdi
    call wr_big
.tn:
    inc r12
    jmp .t
.tclose:
    call wr_close
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = zero terminated (or 0). rax = length
zlen:
    xor eax, eax
    test rcx, rcx
    jz .r
.l:
    cmp byte [rcx+rax], 0
    je .r
    inc rax
    jmp .l
.r:
    ret

; asm-train.txt (lessons, explain-this-code, fixes, mutants) and asm-eval.txt
write_convs:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    lea rcx, [f_atrain]
    call wr_open
    lea rcx, [hdr1]
    mov edx, hdr1_n
    call wr_put
    xor r12d, r12d
.l:
    cmp r12, [nls]
    jae .fixes
    imul rbx, r12, LS_SIZE
    add rbx, [lessons]
    cmp qword [rbx+LS_DROP], 0
    jne .n
    cmp qword [rbx+LS_EVAL], 0
    jne .n
    mov rcx, rbx
    call lesson_conv
    add [counts], rax
    ; explain this code
    mov rdi, [ubuf]
    lea rcx, [asks]
    mov edx, 4
    call pick
    call cpz
    mov word [rdi], 0x0a0a
    add rdi, 2
    mov rsi, [rbx+LS_CODE]
    mov rcx, [rbx+LS_CODE+8]
    call fence
    mov rcx, [ubuf]
    mov rdx, rdi
    sub rdx, rcx
    mov r8, [rbx+LS_EXPL]
    mov r9, [rbx+LS_EXPL+8]
    call conv
    add [counts+8], rax
.n:
    inc r12
    jmp .l
.fixes:
    call fix_convs
    call mut_convs
    call wr_close
    lea rcx, [f_aeval]
    call wr_open
    lea rcx, [hdr2]
    mov edx, hdr2_n
    call wr_put
    xor r12d, r12d
.e:
    cmp r12, [nls]
    jae .done
    imul rbx, r12, LS_SIZE
    add rbx, [lessons]
    cmp qword [rbx+LS_DROP], 0
    jne .en
    cmp qword [rbx+LS_EVAL], 0
    je .en
    mov rcx, rbx
    call lesson_conv
.en:
    inc r12
    jmp .e
.done:
    call wr_close
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = lesson. the task (and prototype) as the question, the code and explanation
; as the answer. rax = 1 if written
lesson_conv:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov rdi, [ubuf]
    call prompt
    mov r12, rdi
    mov rdi, [abuf]
    mov rsi, [rbx+LS_CODE]
    mov rcx, [rbx+LS_CODE+8]
    call fence
    mov word [rdi], 0x0a0a
    add rdi, 2
    mov rsi, [rbx+LS_EXPL]
    mov rcx, [rbx+LS_EXPL+8]
    call cptrim
    mov rcx, [ubuf]
    mov rdx, r12
    sub rdx, rcx
    mov r8, [abuf]
    mov r9, rdi
    sub r9, r8
    call conv
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = lesson, rdx = broken code, r8 = its length, r9 = ST_*, [rsp+40] = what it
; did, [rsp+48] = that length. the debug question into ubuf: the task, the code,
; the symptom, the error, a question. rax = its end
bug_question:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    mov r13, r8
    mov r14, r9
    mov rdi, [ubuf]
    mov rsi, [rbx+LS_TASK]
    mov rcx, [rbx+LS_TASK+8]
    call flat
    mov word [rdi], 0x0a0a
    add rdi, 2
    lea rcx, [mine]
    mov edx, 3
    call pick
    call cpz
    mov byte [rdi], 10
    inc rdi
    mov rsi, r12
    mov rcx, r13
    call fence
    mov word [rdi], 0x0a0a
    add rdi, 2
    lea rax, [symptom]
    mov rsi, [rax+r14*8]
    call cpz
    mov byte [rdi], 10
    mov word [rdi+1], '``'
    mov byte [rdi+3], '`'
    mov byte [rdi+4], 10
    add rdi, 5
    mov rsi, [rsp+88+40]
    mov rcx, [rsp+88+48]
    call cptrim
    mov byte [rdi], 10
    mov word [rdi+1], '``'
    mov byte [rdi+3], '`'
    mov word [rdi+4], 0x0a0a
    add rdi, 6
    lea rcx, [huh]
    mov edx, 3
    call pick
    call cpz
    mov rax, rdi
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; fixes*.jsonl: the ones whose lesson is in training, whose code changed and still
; fails the final tests, become debug conversations
fix_convs:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    lea rcx, [f_fixes]
    lea rdx, [load_fix]
    call each_line
    mov rsi, [fixes]
    xor r12d, r12d
.f:
    cmp r12, [nfixes]
    jae .run
    mov rcx, [rsi+FX_ID]
    call find_lesson
    mov [rsi+FX_LS], rax
    lea rdx, [r_fls]
    test rax, rax
    jz .drop
    cmp qword [rax+LS_DROP], 0
    jne .drop
    cmp qword [rax+LS_EVAL], 0
    jne .drop
    mov rbx, rax
    lea rdx, [r_fnone]
    cmp qword [rsi+FX_WHY], 0
    je .drop
    cmp qword [rsi+FX_BROKEN], 0
    je .drop
    ; did the code change, past comments?
    mov rcx, [rsi+FX_BROKEN]
    mov rdx, [rsi+FX_BROKEN+8]
    mov r8, [ubuf]
    call bare
    mov r13, rax
    mov rcx, [rbx+LS_CODE]
    mov rdx, [rbx+LS_CODE+8]
    mov r8, [abuf]
    call bare
    lea rdx, [r_fsame]
    cmp rax, r13
    jne .changed
    mov rcx, r13
    push rsi
    mov rsi, [ubuf]
    mov rdi, [abuf]
    repe cmpsb
    pop rsi
    je .drop
.changed:
    ; an explanation about a test means the tests changed too
    mov rcx, [rsi+FX_WHY]
    mov rdx, [rsi+FX_WHY+8]
    lea r8, [w_test]
    call hasword
    lea rdx, [r_ftest]
    test eax, eax
    jnz .drop
    mov rcx, [rsi+FX_WHY]
    mov rdx, [rsi+FX_WHY+8]
    lea r8, [w_tests]
    call hasword
    lea rdx, [r_ftest]
    test eax, eax
    jnz .drop
    mov rcx, [rsi+FX_WHY]
    mov rdx, [rsi+FX_WHY+8]
    lea r8, [w_expv]
    call icontains
    lea rdx, [r_ftest]
    test eax, eax
    jnz .drop
    ; nasm 3 needs section .text; any other story for a link error is made up
    mov rcx, [rsi+FX_STAGE]
    lea rdx, [s_link]
    call strcmp
    test eax, eax
    jnz .out
    mov rcx, [rsi+FX_WHY]
    mov rdx, [rsi+FX_WHY+8]
    lea r8, [w_section]
    call icontains
    lea rdx, [r_flink]
    test eax, eax
    jz .drop
.out:
    mov rcx, [rsi+FX_BROKEN]
    mov rdx, [rsi+FX_BROKEN+8]
    call code_check
    lea rdx, [r_fout]
    test rax, rax
    jnz .drop
    jmp .next
.drop:
    mov [rsi+FX_DROP], rdx
.next:
    add rsi, FX_SIZE
    inc r12
    jmp .f
.run:
    lea rcx, [check_fixes]
    lea rdx, [fixes]
    mov r8, [nfixes]
    mov r9d, 1
    call par_for
    mov rsi, [fixes]
    xor r15d, r15d
.w:
    cmp r15, [nfixes]
    jae .r
    cmp qword [rsi+FX_DROP], 0
    jne .wn
    mov [rsp+48], rsi
    mov rbx, [rsi+FX_LS]
    mov rcx, rbx
    mov rdx, [rsi+FX_BROKEN]
    mov r8, [rsi+FX_BROKEN+8]
    mov r9, [rsi+FX_NOW]
    mov rax, [rsi+FX_ERR]
    mov [rsp+32], rax
    mov rax, [rsi+FX_ERR+8]
    mov [rsp+40], rax
    call bug_question
    mov [rsp+56], rax
    mov rsi, [rsp+48]
    mov rdi, [abuf]
    mov rcx, [rsi+FX_WHY+8]
    mov rsi, [rsi+FX_WHY]
    call cptrim
    mov word [rdi], 0x0a0a
    add rdi, 2
    mov rsi, [rbx+LS_CODE]
    mov rcx, [rbx+LS_CODE+8]
    call fence
    mov rcx, [ubuf]
    mov rdx, [rsp+56]
    sub rdx, rcx
    mov r8, [abuf]
    mov r9, rdi
    sub r9, r8
    call conv
    add [counts+16], rax
    mov rsi, [rsp+48]
.wn:
    add rsi, FX_SIZE
    inc r15
    jmp .w
.r:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; par_for: fixes rdx..r8 on thread r9, rcx = &array. the broken code against the
; lesson's final tests: it has to fail, and what it does goes in FX_ERR
check_fixes:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rdx
    mov rdi, r8
    mov r13, [rcx]
    lea rax, [ctxs]
    mov r12, [rax+r9*8]
.l:
    cmp rsi, rdi
    jae .r
    imul rbx, rsi, FX_SIZE
    add rbx, r13
    cmp qword [rbx+FX_DROP], 0
    jne .n
    mov rax, [rbx+FX_LS]
    mov rcx, r12
    mov rdx, [rax+LS_TESTS]
    mov r8, [rax+LS_TESTS+8]
    call vf_tests
    mov rcx, r12
    mov rdx, [rbx+FX_BROKEN]
    mov r8, [rbx+FX_BROKEN+8]
    call vf_verify
    mov [rbx+FX_NOW], rax
    test eax, eax
    jnz .err
    lea rax, [r_fpass]
    mov [rbx+FX_DROP], rax
    jmp .n
.err:
    mov rcx, r12
    mov rdx, [rbx+FX_LS]
    call errtext
    mov [rbx+FX_ERR], rax
    mov [rbx+FX_ERR+8], rdx
.n:
    inc rsi
    jmp .l
.r:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = context after vf_verify, rdx = lesson. its output as a person would see it:
; "test 3" becomes the call, and our file names go. rax = text (arena), rdx = length
errtext:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov r12, rcx
    mov r13, rdx
    mov rcx, [r12+VC_OLEN]
    lea rcx, [rcx*2+4096]
    mov r15, rcx
    call alloc
    mov rbx, rax
    mov rdi, rax
    lea r15, [rax+r15-512]      ; leave room for the last replacement
    mov rsi, [r12+VC_OUT]
    mov r14, rsi
    add r14, [r12+VC_OLEN]
    mov qword [rsp+40], 1       ; at the start of a line
.c:
    cmp rsi, r14
    jae .done
    cmp rdi, r15
    jae .done
    cmp qword [rsp+40], 0
    je .names
    mov qword [rsp+40], 0
    ; test N at the start of a line
    mov rcx, rsi
    mov rdx, r14
    sub rdx, rsi
    lea r8, [w_testn]
    call startsz
    test eax, eax
    jz .names
    lea rcx, [rsi+5]
    call parse_int
    lea r8, [rsi+5]
    cmp rdx, r8
    je .names
    mov [rsp+32], rdx
    mov rcx, r12
    mov rdx, r13
    mov r8, rax
    call nth_call
    test rax, rax
    jz .names
    mov rsi, rax
    mov rcx, rdx
    rep movsb
    mov rsi, [rsp+32]
    jmp .c
.names:
    movzx eax, byte [rsi]
    cmp eax, 10
    jne .cand
    mov qword [rsp+40], 1
    jmp .copy
.cand:
    mov rcx, rsi
    mov rdx, r14
    sub rdx, rsi
    lea r8, [w_cand]
    call startsz
    test eax, eax
    jz .thunk
    mov rax, [r13+LS_NAME]
    mov rcx, [r13+LS_NAME+8]
    mov [rsp+32], rsi
    mov rsi, rax
    rep movsb
    mov rsi, [rsp+32]
    mov byte [rdi], '.'
    inc rdi
    add rsi, 5
    jmp .c
.thunk:
    mov rcx, rsi
    mov rdx, r14
    sub rdx, rsi
    lea r8, [w_thunk]
    call startsz
    test eax, eax
    jz .texe
    mov dword [rdi], 'main'
    mov dword [rdi+4], '.obj'
    add rdi, 8
    add rsi, 9
    jmp .c
.texe:
    mov rcx, rsi
    mov rdx, r14
    sub rdx, rsi
    lea r8, [w_texe]
    call startsz
    test eax, eax
    jz .copy
    cmp rsi, [r12+VC_OUT]
    je .te
    movzx ecx, byte [rsi-1]
    call isw
    test eax, eax
    jnz .copy
.te:
    mov dword [rdi], 'main'
    mov dword [rdi+4], '.exe'
    add rdi, 8
    add rsi, 5
    jmp .c
.copy:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .c
.done:
    mov rcx, rbx
    mov rdx, rdi
    sub rdx, rbx
    call trim
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = context, rdx = lesson, r8 = N. rax, rdx = the Nth test's call as written,
; up to its arrow. rax = 0 if there's no such test
nth_call:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov r12, rcx
    mov r13, rdx
    mov r14, r8
    mov rsi, [rdx+LS_TESTS]
    mov rdi, [rdx+LS_TESTS+8]
    add rdi, rsi
.line:
    cmp rsi, rdi
    jae .none
    mov rbx, rsi
.e:
    cmp rbx, rdi
    jae .got
    cmp byte [rbx], 10
    je .got
    inc rbx
    jmp .e
.got:
    mov qword [r12+VC_BUSED], 0
    mov rcx, r12
    mov rdx, rsi
    mov r8, rbx
    sub r8, rsi
    mov r9, [r12+VC_TESTS]
    call parse_test
    lea rsi, [rbx+1]
    cmp eax, 1
    jne .line
    dec r14
    jnz .line
    ; from the name to the first arrow
    mov r9, [r12+VC_TESTS]
    mov rax, [r9+TS_FN]
    mov rcx, rax
.a:
    cmp rcx, rbx
    jae .cut
    movzx edx, word [rcx]
    cmp edx, '->'
    je .cut
    cmp edx, '=>'
    je .cut
    inc rcx
    jmp .a
.cut:
    cmp rcx, rax
    jbe .len
    cmp byte [rcx-1], ' '
    ja .len
    dec rcx
    jmp .cut
.len:
    mov rdx, rcx
    sub rdx, rax
    jmp .r
.none:
    xor eax, eax
    xor edx, edx
.r:
    ; that parsed over test 0 and the byte buffers, and mutate_one's next vf_verify
    ; writes tests.inc from them: put the lesson's tests back
    mov rbx, rax
    mov rsi, rdx
    mov rcx, r12
    mov rdx, [r13+LS_TESTS]
    mov r8, [r13+LS_TESTS+8]
    call vf_tests
    mov rax, rbx
    mov rdx, rsi
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; mutants.jsonl + mutwhy*.jsonl: the explained mutants of training lessons become
; debug conversations too
mut_convs:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80
    lea rcx, [f_why]
    lea rdx, [load_why]
    call each_line
    cmp qword [nwhys], 0
    je .r
    lea rcx, [f_mut]
    lea rdx, [load_mut]
    call each_line
    mov rsi, [muts]
    xor r15d, r15d
.m:
    cmp r15, [nmuts]
    jae .r
    mov [rsp+48], rsi
    mov rcx, [rsi+FX_ID]
    call find_lesson
    test rax, rax
    jz .n
    cmp qword [rax+LS_DROP], 0
    jne .n
    cmp qword [rax+LS_EVAL], 0
    jne .n
    mov rbx, rax
    ; its explanation, if it's in shape
    mov rcx, rsi
    call find_why
    test rax, rax
    jz .n
    mov [rsp+56], rax
    mov rsi, rax
    cmp qword [rsi+FX_WHY+8], 1200
    ja .fmt
    lea r12, [w_line]
    call .has
    lea r12, [w_told1]
    call .has
    lea r12, [w_told2]
    call .has
    lea r12, [w_fence]
    call .has
    mov rsi, [rsp+48]
    mov rcx, [rsi+FX_STAGE]
    call stage_of
    mov r9, rax
    mov rcx, rbx
    mov rdx, [rsi+FX_BROKEN]
    mov r8, [rsi+FX_BROKEN+8]
    mov rax, [rsi+FX_ERR]
    mov [rsp+32], rax
    mov rax, [rsi+FX_ERR+8]
    mov [rsp+40], rax
    call bug_question
    mov [rsp+64], rax
    mov rsi, [rsp+56]
    mov rdi, [abuf]
    mov rcx, [rsi+FX_WHY+8]
    mov rsi, [rsi+FX_WHY]
    call cptrim
    mov word [rdi], 0x0a0a
    add rdi, 2
    mov rsi, [rbx+LS_CODE]
    mov rcx, [rbx+LS_CODE+8]
    call fence
    mov rcx, [ubuf]
    mov rdx, [rsp+64]
    sub rdx, rcx
    mov r8, [abuf]
    mov r9, rdi
    sub r9, r8
    call conv
    add [counts+24], rax
    jmp .n
.fmt:
    lea rcx, [r_mfmt]
    call reason
.n:
    mov rsi, [rsp+48]
    add rsi, FX_SIZE
    inc r15
    jmp .m
.r:
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; (mut_convs) the explanation in rsi has the text in r12: off format, back out
.has:
    sub rsp, 40
    mov rcx, [rsi+FX_WHY]
    mov rdx, [rsi+FX_WHY+8]
    mov r8, r12
    call icontains
    add rsp, 40
    test eax, eax
    jz .hr
    add rsp, 8                  ; not going back
    jmp .fmt
.hr:
    ret

; rcx = mutant. rax = its explanation record (same id and op), or 0
find_why:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rsi, [whys]
    mov rdi, [nwhys]
.l:
    test rdi, rdi
    jz .no
    mov rax, [rsi+FX_ID]
    cmp rax, [rbx+FX_ID]
    jne .n
    mov rcx, [rsi+FX_OP]
    mov rdx, [rbx+FX_OP]
    test rcx, rcx
    jz .n
    test rdx, rdx
    jz .n
    call strcmp
    test eax, eax
    jnz .n
    mov rax, rsi
    jmp .r
.n:
    add rsi, FX_SIZE
    dec rdi
    jmp .l
.no:
    xor eax, eax
.r:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = a stage name. rax = ST_*
stage_of:
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
    xor ebx, ebx
.l:
    cmp ebx, 8
    jae .no
    lea rax, [stagez]
    mov rdx, [rax+rbx*8]
    mov rcx, rsi
    call strcmp
    test eax, eax
    jz .yes
    inc ebx
    jmp .l
.no:
    mov ebx, ST_TESTS
.yes:
    mov eax, ebx
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = command line. runs it here and prints what it said
show_run:
    sub rsp, 56
    xor edx, edx
    mov r8, [big]
    mov r9d, 1 << 16
    mov qword [rsp+32], 600000
    call vf_run
    mov rcx, [big]
    call print
    add rsp, 56
    ret

; rcx = reason. counts it
reason:
    mov rax, [nreason]
    lea rdx, [reasons]
    xor r8d, r8d
.l:
    cmp r8, rax
    jae .new
    mov r9, r8
    shl r9, 4
    cmp [rdx+r9], rcx
    je .inc
    inc r8
    jmp .l
.new:
    cmp rax, 64
    jae .r
    shl rax, 4
    mov [rdx+rax], rcx
    mov qword [rdx+rax+8], 1
    inc qword [nreason]
.r:
    ret
.inc:
    inc qword [rdx+r9+8]
    ret

; counts and why things got left out
report:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, [lessons]
    mov rsi, [nls]
.l:
    test rsi, rsi
    jz .f
    mov rcx, [rbx+LS_DROP]
    test rcx, rcx
    jz .ln
    call reason
.ln:
    add rbx, LS_SIZE
    dec rsi
    jmp .l
.f:
    mov rbx, [fixes]
    mov rsi, [nfixes]
.fl:
    test rsi, rsi
    jz .say
    mov rcx, [rbx+FX_DROP]
    test rcx, rcx
    jz .fn
    call reason
.fn:
    add rbx, FX_SIZE
    dec rsi
    jmp .fl
.say:
    say "  train "
    mov rcx, [counts+40]
    call print_dec
    say " lessons, eval "
    mov rcx, [counts+48]
    call print_dec
    say 13, 10, "  conversations: "
    mov rcx, [counts]
    call print_dec
    say " lessons, "
    mov rcx, [counts+8]
    call print_dec
    say " explain, "
    mov rcx, [counts+16]
    call print_dec
    say " fixes, "
    mov rcx, [counts+24]
    call print_dec
    say " mutants, "
    mov rcx, [counts+32]
    call print_dec
    say " skipped for format", 13, 10, "  left out:", 13, 10
    xor ebx, ebx
.r:
    cmp rbx, [nreason]
    jae .ret
    mov rsi, rbx
    shl rsi, 4
    lea rax, [reasons]
    add rsi, rax
    say "    "
    mov rcx, [rsi+8]
    call print_dec
    say "  "
    mov rcx, [rsi]
    call print_z
    say 13, 10
    inc rbx
    jmp .r
.ret:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; ---- mutants

mutants:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    lea rcx, [f_train]
    lea rdx, [load_lesson]
    call each_line
    ; load_lesson doesn't read name: it's the first test's
    mov rbx, [lessons]
    mov r12, [nls]
    test r12, r12
    jnz .slots
    say "  no train.jsonl, run asmset first", 13, 10
    jmp .r
.slots:
    mov rcx, [nls]
    imul rcx, [per_less]
    imul rcx, rcx, MT_SIZE
    add rcx, 64
    call alloc
    mov [mres], rax
    say "  "
    mov rcx, [nls]
    call print_dec
    say " lessons, breaking each one", 13, 10
    lea rcx, [mutate_some]
    xor edx, edx
    mov r8, [nls]
    mov r9d, 1
    call par_for
    ; write them out in lesson order
    lea rcx, [f_mut]
    call wr_open
    xor r12d, r12d
    xor r13d, r13d              ; written
.w:
    mov rax, [nls]
    imul rax, [per_less]
    cmp r12, rax
    jae .wd
    imul rbx, r12, MT_SIZE
    add rbx, [mres]
    cmp qword [rbx+MT_OP], 0
    je .wn
    mov rax, r12
    xor edx, edx
    div qword [per_less]
    imul r14, rax, LS_SIZE
    add r14, [lessons]
    mov rdi, [big]
    jlit '{"id":"i'
    jdec [r14+LS_ID]
    jlit '","op":'
    mov rcx, [rbx+MT_OP]
    call zlen
    jstr [rbx+MT_OP], rax
    jlit ',"broken":'
    jstr [rbx+MT_BROKEN], [rbx+MT_BROKEN+8]
    jlit ',"stage":'
    lea rax, [stagez]
    mov rcx, [rbx+MT_STAGE]
    mov rcx, [rax+rcx*8]
    mov [rsp+32], rcx
    call zlen
    jstr [rsp+32], rax
    jlit ',"err":'
    jstr [rbx+MT_ERR], [rbx+MT_ERR+8]
    jlit ',"fix":'
    jstr [rbx+MT_FIX], [rbx+MT_FIX+8]
    mov byte [rdi], '}'
    inc rdi
    call wr_big
    inc r13
.wn:
    inc r12
    jmp .w
.wd:
    call wr_close
    say "  "
    mov rcx, r13
    call print_dec
    say " mutants -> datasets\asm\mutants.jsonl", 13, 10
.r:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; per lesson scratch
MS_LINES  equ 0                 ; 128 x (ptr, len)
MS_SITES  equ 2048              ; 256 x (line, kind, arg)
MS_RNG    equ 2048 + 256 * 24
MS_SIZE   equ MS_RNG + 32 + 16 * 8          ; + the kinds seen
MAXLINES  equ 128

; site kinds
K_COND    equ 0                 ; arg = new cond index, op name in the high bits
K_SWAP    equ 1                 ; arg = swaps index of the new mnemonic
K_INIT    equ 2
K_SCALE   equ 3                 ; arg = the new scale digit
K_ARG     equ 4                 ; arg = argr pair
K_SAVE    equ 5                 ; arg = saved register index

; par_for: lessons rdx..r8 on thread r9
mutate_some:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov [rsp+32], rdx
    mov [rsp+40], r8
    lea rax, [ctxs]
    mov r12, [rax+r9*8]
    mov ecx, MS_SIZE
    call alloc
    mov r13, rax                ; scratch
.l:
    mov rax, [rsp+32]
    cmp rax, [rsp+40]
    jae .r
    imul rbx, rax, LS_SIZE
    add rbx, [lessons]
    mov rcx, rbx
    mov rdx, r12
    mov r8, r13
    mov r9, rax
    call mutate_one
    inc qword [rsp+32]
    jmp .l
.r:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = lesson, rdx = context, r8 = scratch, r9 = lesson index. finds every one-line
; bug it can make, tries up to 10 of them in a random order (seeded by the lesson,
; so threads don't matter) and keeps up to per_lesson that the tests catch
mutate_one:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov rbx, rcx
    mov r12, rdx
    mov r13, r8
    mov [rsp+48], r9
    mov rcx, r12
    mov rdx, [rbx+LS_TESTS]
    mov r8, [rbx+LS_TESTS+8]
    call vf_tests
    cmp rax, -1
    je .r
    mov rax, [r12+VC_TESTS]
    mov rcx, [rax+TS_FN]
    mov [rbx+LS_NAME], rcx
    mov rcx, [rax+TS_FNLEN]
    mov [rbx+LS_NAME+8], rcx
    ; the lines
    mov rsi, [rbx+LS_CODE]
    mov rdi, [rbx+LS_CODE+8]
    add rdi, rsi
    xor r14d, r14d
.ln:
    cmp rsi, rdi
    jae .lines
    cmp r14, MAXLINES
    jae .r
    mov rcx, rsi
.le:
    cmp rcx, rdi
    jae .lg
    cmp byte [rcx], 10
    je .lg
    inc rcx
    jmp .le
.lg:
    mov rax, r14
    shl rax, 4
    mov [r13+MS_LINES+rax], rsi
    mov rdx, rcx
    sub rdx, rsi
    mov [r13+MS_LINES+rax+8], rdx
    inc r14
    lea rsi, [rcx+1]
    jmp .ln
.lines:
    mov [rsp+56], r14
    mov rcx, r13
    mov rdx, r14
    call sites
    mov r15, rax                ; how many
    test r15, r15
    jz .r
    ; shuffle them
    lea rcx, [r13+MS_RNG]
    mov rdx, [seed]
    mov rax, [rbx+LS_ID]
    mov r8, 0x9e3779b97f4a7c15
    imul rax, r8
    add rdx, rax
    call rng_seed
    mov rsi, r15
.sh:
    cmp rsi, 1
    jbe .kinds
    lea rcx, [r13+MS_RNG]
    call rng_next
    xor edx, edx
    div rsi
    dec rsi
    ; swap site rsi and rdx
    imul rax, rsi, 24
    imul rdx, rdx, 24
    lea rax, [r13+MS_SITES+rax]
    lea rdx, [r13+MS_SITES+rdx]
    mov rcx, [rax]
    mov r8, [rdx]
    mov [rax], r8
    mov [rdx], rcx
    mov rcx, [rax+8]
    mov r8, [rdx+8]
    mov [rax+8], r8
    mov [rdx+8], rcx
    mov rcx, [rax+16]
    mov r8, [rdx+16]
    mov [rax+16], r8
    mov [rdx+16], rcx
    jmp .sh
.kinds:
    ; the first site of each kind of bug goes to the front, so a lesson with lots of
    ; argument registers doesn't only ever get that bug
    xor esi, esi                ; site
    xor edi, edi                ; distinct kinds so far
.k1:
    cmp rsi, r15
    jae .try
    imul rcx, rsi, 24
    lea rcx, [r13+MS_SITES+rcx]
    call site_op                ; (the same name is the same pointer)
    lea rcx, [o_arg]
    cmp rax, rcx
    je .k3                      ; nearly every function has one: only as a fallback
    xor ecx, ecx
.k2:
    cmp rcx, rdi
    jae .knew
    cmp [r13+MS_RNG+32+rcx*8], rax
    je .k3
    inc rcx
    jmp .k2
.knew:
    cmp rdi, 16
    jae .k3
    mov [r13+MS_RNG+32+rdi*8], rax
    ; swap site rsi into place rdi
    imul rax, rsi, 24
    imul rdx, rdi, 24
    lea rax, [r13+MS_SITES+rax]
    lea rdx, [r13+MS_SITES+rdx]
    mov rcx, [rax]
    mov r8, [rdx]
    mov [rax], r8
    mov [rdx], rcx
    mov rcx, [rax+8]
    mov r8, [rdx+8]
    mov [rax+8], r8
    mov [rdx+8], rcx
    mov rcx, [rax+16]
    mov r8, [rdx+16]
    mov [rax+16], r8
    mov [rdx+16], rcx
    inc rdi
.k3:
    inc rsi
    jmp .k1
.try:
    xor r14d, r14d              ; tried
    xor esi, esi                ; kept
.t:
    cmp r14, r15
    jae .r
    cmp r14, 10
    jae .r
    cmp rsi, [per_less]
    jae .r
    imul rdi, r14, 24
    lea rdi, [r13+MS_SITES+rdi]
    ; one per kind of bug
    mov rcx, rdi
    call site_op
    mov [rsp+32], rax
    mov r10, [rsp+48]
    imul r10, [per_less]
    imul r10, r10, MT_SIZE
    add r10, [mres]
    xor r9d, r9d
.dup:
    cmp r9, rsi
    jae .apply
    mov rcx, [rsp+32]
    mov rdx, [r10+MT_OP]
    call strcmp                 ; (leaves r9 and r10 alone)
    test eax, eax
    jz .tn
    add r10, MT_SIZE
    inc r9
    jmp .dup
.apply:
    mov rcx, rbx
    mov rdx, r13
    mov r8, rdi
    mov r9, [rsp+56]
    call apply
    mov [rsp+40], rax           ; the broken code, rdx = length
    mov rcx, r12
    mov r8, rdx
    mov rdx, rax
    call vf_verify
    cmp eax, ST_TESTS
    jb .tn
    ; a bug that builds and that the tests catch
    mov r8, [rsp+48]
    imul r8, [per_less]
    add r8, rsi
    imul r8, r8, MT_SIZE
    add r8, [mres]
    mov [r8+MT_STAGE], rax
    mov rax, [rsp+32]
    mov [r8+MT_OP], rax
    mov rax, [rsp+40]
    mov [r8+MT_BROKEN], rax
    mov [rsp+32], r8
    mov rcx, [rsp+40]
    call zlen
    mov r8, [rsp+32]
    mov [r8+MT_BROKEN+8], rax
    mov rcx, r12
    mov rdx, rbx
    call errtext
    mov r8, [rsp+32]
    mov [r8+MT_ERR], rax
    mov [r8+MT_ERR+8], rdx
    mov rcx, rbx
    mov rdx, r13
    mov r8, rdi
    call fixtext
    mov r8, [rsp+32]
    mov [r8+MT_FIX], rax
    mov [r8+MT_FIX+8], rdx
    inc rsi
.tn:
    inc r14
    jmp .t
.r:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- mutation sites

; rcx = scratch with the lines, rdx = how many lines. every one-line bug we can make
; goes in MS_SITES as (line, kind | arg << 8 | table << 16, opstart | opend << 16 |
; restend << 32 | prefix << 48). rax = how many
sites:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 128
    mov rbx, rcx
    mov r12, rdx
    xor r13d, r13d              ; line
    xor r14d, r14d              ; sites
.line:
    cmp r13, r12
    jae .done
    mov rax, r13
    shl rax, 4
    mov rsi, [rbx+MS_LINES+rax]
    mov r15, [rbx+MS_LINES+rax+8]
    cmp r15, 4000
    jae .next
    ; quotes: leave the line alone
    xor ecx, ecx
.q:
    cmp rcx, r15
    jae .parse
    mov al, [rsi+rcx]
    cmp al, '"'
    je .next
    cmp al, "'"
    je .next
    inc rcx
    jmp .q
.parse:
    xor edi, edi
    call .ws
    ; a label first?
    mov rcx, rdi
.lab:
    cmp rcx, r15
    jae .op
    movzx eax, byte [rsi+rcx]
    cmp eax, '.'
    je .ln
    mov r8, rcx
    mov ecx, eax
    call isw
    mov rcx, r8
    test eax, eax
    jz .labend
.ln:
    inc rcx
    jmp .lab
.labend:
    cmp rcx, rdi
    je .op
    cmp byte [rsi+rcx], ':'
    jne .op
    lea rdi, [rcx+1]
    call .ws
.op:
    ; a letter, then letters and digits, then a space, a tab, a comment or the end
    mov [rsp+32], rdi
    cmp rdi, r15
    jae .next
    movzx eax, byte [rsi+rdi]
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    ja .next
.oc:
    inc rdi
    cmp rdi, r15
    jae .oend
    movzx ecx, byte [rsi+rdi]
    lea eax, [rcx-'0']
    cmp eax, 9
    jbe .oc
    mov eax, ecx
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    jbe .oc
    cmp ecx, ' '
    je .oend
    cmp ecx, 9
    je .oend
    cmp ecx, ';'
    jne .next
.oend:
    mov [rsp+40], rdi
    mov rax, rdi
    sub rax, [rsp+32]
    cmp rax, 15
    ja .next
    ; the op in lowercase
    mov rcx, [rsp+32]
    xor edx, edx
.lc:
    cmp rcx, rdi
    jae .lcd
    movzx eax, byte [rsi+rcx]
    lea r8d, [rax-'A']
    cmp r8d, 25
    ja .lc1
    or eax, 0x20
.lc1:
    mov [rsp+64+rdx], al
    inc rcx
    inc rdx
    jmp .lc
.lcd:
    mov byte [rsp+64+rdx], 0
    ; the rest ends before a comment and the spaces in front of it
    mov rcx, rdi
.semi:
    cmp rcx, r15
    jae .rend
    cmp byte [rsi+rcx], ';'
    je .rback
    inc rcx
    jmp .semi
.rback:
    cmp rcx, rdi
    jbe .rend
    movzx eax, byte [rsi+rcx-1]
    cmp eax, ' '
    je .rb
    cmp eax, 9
    jne .rend
.rb:
    dec rcx
    jmp .rback
.rend:
    mov [rsp+48], rcx
    shl rcx, 32
    mov rax, [rsp+40]
    shl rax, 16
    or rcx, rax
    or rcx, [rsp+32]
    mov [rsp+56], rcx
    ; jcc, cmovcc, setcc (not jmp)
    lea rcx, [rsp+64]
    lea rdx, [w_jmp]
    call strcmp
    test eax, eax
    jz .swap
    mov qword [rsp+88], 4
    lea rcx, [rsp+64]
    mov edx, 15
    lea r8, [w_cmov]
    call startsz
    test eax, eax
    jnz .cond
    mov qword [rsp+88], 3
    lea rcx, [rsp+64]
    mov edx, 15
    lea r8, [w_set]
    call startsz
    test eax, eax
    jnz .cond
    mov qword [rsp+88], 1
    cmp byte [rsp+64], 'j'
    jne .swap
.cond:
    xor r10d, r10d
.cf:
    cmp r10, 12
    jae .swap
    lea rcx, [rsp+64]
    add rcx, [rsp+88]
    lea rdx, [conds]
    imul rax, r10, 3
    add rdx, rax
    call strcmp                 ; (keeps r9-r11)
    test eax, eax
    jz .cfound
    inc r10
    jmp .cf
.cfound:
    ; one site for each table that has a twin for it
    xor r11d, r11d
.ct:
    cmp r11, 3
    jae .swap
    lea rax, [csign]
    imul rcx, r11, 12
    add rax, rcx
    movsx eax, byte [rax+r10]
    cmp eax, -1
    je .ctn
    mov ecx, K_COND
    shl eax, 8
    or ecx, eax
    mov rax, r11
    shl rax, 16
    or rcx, rax
    mov rdx, [rsp+88]
    shl rdx, 48
    or rdx, [rsp+56]
    call .add
.ctn:
    inc r11
    jmp .ct
.swap:
    xor r10d, r10d
.sw:
    cmp r10, 6
    jae .init
    lea rcx, [rsp+64]
    lea rdx, [swaps]
    imul rax, r10, 6
    add rdx, rax
    call strcmp
    test eax, eax
    jz .swhit
    inc r10
    jmp .sw
.swhit:
    mov rcx, r10
    shl rcx, 8
    or ecx, K_SWAP
    mov rdx, [rsp+56]
    call .add
.init:
    ; xor reg, reg (the same one twice)
    lea rcx, [rsp+64]
    lea rdx, [w_xor]
    call strcmp
    test eax, eax
    jnz .scale
    mov rdi, [rsp+40]
    call .ws
    mov r8, rdi                 ; first word
.i1:
    cmp rdi, [rsp+48]
    jae .scale
    movzx ecx, byte [rsi+rdi]
    call isw
    test eax, eax
    jz .i2
    inc rdi
    jmp .i1
.i2:
    mov r9, rdi
    sub r9, r8                  ; its length
    jz .scale
    call .ws
    cmp rdi, [rsp+48]
    jae .scale
    cmp byte [rsi+rdi], ','
    jne .scale
    inc rdi
    call .ws
    mov r10, rdi                ; second word
.i3:
    cmp rdi, [rsp+48]
    jae .i4
    movzx ecx, byte [rsi+rdi]
    call isw
    test eax, eax
    jz .i4
    inc rdi
    jmp .i3
.i4:
    mov rax, rdi
    sub rax, r10
    cmp rax, r9
    jne .scale
    call .ws
    cmp rdi, [rsp+48]           ; past the rest's end is the comment
    jb .scale
    xor ecx, ecx
.i5:
    cmp rcx, r9
    jae .ihit
    movzx eax, byte [rsi+r8]
    movzx edx, byte [rsi+r10]
    or eax, 0x20
    or edx, 0x20
    cmp eax, edx
    jne .scale
    inc r8
    inc r10
    inc rcx
    jmp .i5
.ihit:
    mov ecx, K_INIT
    mov rdx, [rsp+56]
    call .add
.scale:
    ; *2, *4 or *8 in the rest
    mov rdi, [rsp+40]
.sc:
    cmp rdi, [rsp+48]
    jae .args
    cmp byte [rsi+rdi], '*'
    je .star
.sc1:
    inc rdi
    jmp .sc
.star:
    mov r8, rdi
    inc rdi
    call .ws
    cmp rdi, [rsp+48]
    jae .args
    movzx eax, byte [rsi+rdi]
    mov edx, '1'
    cmp eax, '2'
    je .sk
    mov edx, '8'
    cmp eax, '4'
    je .sk
    mov edx, '4'
    cmp eax, '8'
    je .sk
    mov rdi, r8
    jmp .sc1
.sk:
    lea rcx, [rdi+1]
    cmp rcx, [rsp+48]
    jae .shit
    mov [rsp+80], rdx
    movzx ecx, byte [rsi+rcx]
    call isw
    mov rdx, [rsp+80]
    test eax, eax
    jz .shit
    mov rdi, r8
    jmp .sc1
.shit:
    mov ecx, edx
    shl ecx, 8
    or ecx, K_SCALE
    mov rdx, [rsp+56]
    call .add
.args:
    ; an argument register in the rest, as the wrong one
    xor r10d, r10d
.ar:
    cmp r10, 4
    jae .save
    mov [rsp+80], r10
    mov rcx, rsi
    add rcx, [rsp+40]
    mov rdx, [rsp+48]
    sub rdx, [rsp+40]
    lea r8, [argr]
    lea r8, [r8+r10*8]
    call hasword
    test eax, eax
    jz .arn
    mov r10, [rsp+80]
    mov rcx, rsi
    add rcx, [rsp+40]
    mov rdx, [rsp+48]
    sub rdx, [rsp+40]
    lea r8, [argr]
    lea r8, [r8+r10*8+4]
    call hasword
    test eax, eax
    jnz .arn
    mov rcx, [rsp+80]
    shl rcx, 8
    or ecx, K_ARG
    mov rdx, [rsp+56]
    call .add
    jmp .save
.arn:
    mov r10, [rsp+80]
    inc r10
    jmp .ar
.save:
    ; push of a register the caller wants back
    lea rcx, [rsp+64]
    lea rdx, [w_push]
    call strcmp
    test eax, eax
    jnz .next
    mov rcx, rsi
    add rcx, [rsp+40]
    mov rdx, [rsp+48]
    sub rdx, [rsp+40]
    call trim
    mov [rsp+96], rax
    mov [rsp+104], rdx
    xor r10d, r10d
.sv:
    cmp r10, 8
    jae .next
    mov [rsp+112], r10
    mov rcx, [rsp+96]
    mov rdx, [rsp+104]
    lea r8, [saved]
    lea r8, [r8+r10*4]
    call ieq
    mov r10, [rsp+112]
    test eax, eax
    jnz .svhit
    inc r10
    jmp .sv
.svhit:
    mov rcx, r10
    shl rcx, 8
    or ecx, K_SAVE
    mov rdx, [rsp+56]
    call .add
.next:
    inc r13
    jmp .line
.done:
    mov rax, r14
    add rsp, 128
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
; (sites) skip spaces and tabs at rsi+rdi
.ws:
    cmp rdi, r15
    jae .wr
    cmp byte [rsi+rdi], ' '
    je .wn
    cmp byte [rsi+rdi], 9
    jne .wr
.wn:
    inc rdi
    jmp .ws
.wr:
    ret
; (sites) one more: rcx = kind word, rdx = offsets
.add:
    cmp r14, 256
    jae .addr
    imul rax, r14, 24
    lea rax, [rbx+MS_SITES+rax]
    mov [rax], r13
    mov [rax+8], rcx
    mov [rax+16], rdx
    inc r14
.addr:
    ret

; rcx = site. rax = the name of its bug
site_op:
    mov rdx, [rcx+8]
    movzx eax, dl
    mov r8, rdx
    shr r8, 8
    and r8d, 0xff               ; arg
    cmp eax, K_COND
    jne .s1
    shr rdx, 16
    and edx, 0xff
    lea rax, [o_sign]
    test edx, edx
    jz .r
    lea rax, [o_off]
    cmp edx, 1
    je .r
    lea rax, [o_inv]
    ret
.s1:
    cmp eax, K_SWAP
    jne .s2
    lea rax, [o_swap]
.sk:
    test r8d, r8d
    jz .r
.sz:
    cmp byte [rax], 0
    lea rax, [rax+1]
    jne .sz
    dec r8d
    jmp .sk
.s2:
    lea rcx, [o_init]
    cmp eax, K_INIT
    je .c
    lea rcx, [o_scale]
    cmp eax, K_SCALE
    je .c
    lea rcx, [o_arg]
    cmp eax, K_ARG
    je .c
    lea rcx, [o_save]
.c:
    mov rax, rcx
.r:
    ret

; rcx = a line, rdx = its length, r8 = site, r9 = dst. writes the line with the
; site's bug in it (nothing for a removed line). rax = past it
mutline:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov r12, rcx
    mov r13, rdx
    mov rbx, r8
    mov rdi, r9
    mov rax, [rbx+16]
    movzx r14d, ax              ; opstart
    mov r15, rax
    shr r15, 16
    and r15d, 0xffff            ; opend
    movzx eax, byte [rbx+8]
    cmp eax, K_COND
    je .cond
    cmp eax, K_SWAP
    je .swap
    cmp eax, K_SCALE
    je .scale
    cmp eax, K_ARG
    je .arg
    jmp .r
.cond:
    mov rcx, [rbx+16]
    shr rcx, 48
    add rcx, r14
    mov rsi, r12
    rep movsb
    movzx eax, byte [rbx+9]
    lea rsi, [conds]
    imul eax, eax, 3
    add rsi, rax
    call cpz
    jmp .tail
.swap:
    mov rcx, r14
    mov rsi, r12
    rep movsb
    movzx eax, byte [rbx+9]
    xor eax, 1
    lea rsi, [swaps]
    imul eax, eax, 6
    add rsi, rax
    call cpz
    jmp .tail
.scale:
    mov rcx, r15
    mov rsi, r12
    rep movsb
    mov rax, [rbx+16]
    shr rax, 32
    and eax, 0xffff
    mov [rsp+32], rax
    mov rcx, r15
.s:
    cmp rcx, [rsp+32]
    jae .rest
    mov al, [r12+rcx]
    cmp al, '*'
    jne .sput
    lea rdx, [rcx+1]
.sw:
    cmp rdx, [rsp+32]
    jae .sput
    cmp byte [r12+rdx], ' '
    je .swn
    cmp byte [r12+rdx], 9
    jne .sd
.swn:
    inc rdx
    jmp .sw
.sd:
    mov al, [r12+rdx]
    cmp al, '2'
    je .sk
    cmp al, '4'
    je .sk
    cmp al, '8'
    jne .sput0
.sk:
    lea r8, [rdx+1]
    cmp r8, [rsp+32]
    jae .sy
    mov r9, rcx
    movzx ecx, byte [r12+r8]
    call isw
    mov rcx, r9
    test eax, eax
    jnz .sput0
.sy:
    mov byte [rdi], '*'
    mov al, [rbx+9]
    mov [rdi+1], al
    add rdi, 2
    lea rcx, [rdx+1]
    jmp .s
.sput0:
    mov al, '*'
.sput:
    mov [rdi], al
    inc rdi
    inc rcx
    jmp .s
.arg:
    mov rcx, r15
    mov rsi, r12
    rep movsb
    mov rax, [rbx+16]
    shr rax, 32
    and eax, 0xffff
    mov [rsp+32], rax
    movzx eax, byte [rbx+9]
    lea rsi, [argr]
    lea rsi, [rsi+rax*8]        ; A, and B 4 after it
    mov r14, rsi
    mov rcx, r15
.a:
    cmp rcx, [rsp+32]
    jae .rest
    mov [rsp+40], rcx
    ; a word boundary before?
    test rcx, rcx
    jz .a1
    movzx ecx, byte [r12+rcx-1]
    call isw
    mov rcx, [rsp+40]
    test eax, eax
    jnz .aput
.a1:
    lea rcx, [r12+rcx]
    mov rdx, [rsp+32]
    sub rdx, [rsp+40]
    mov r8, r14
    call istarts
    test eax, eax
    jz .aput0
    ; and after
    mov rdx, rcx
    sub rdx, r12
    cmp rdx, [rsp+32]
    jae .ahit
    mov [rsp+48], rdx
    movzx ecx, byte [rcx]
    call isw
    mov rdx, [rsp+48]
    test eax, eax
    jnz .aput0
.ahit:
    lea rsi, [r14+4]
    call cpz
    mov rcx, rdx
    jmp .a
.aput0:
    mov rcx, [rsp+40]
.aput:
    mov al, [r12+rcx]
    mov [rdi], al
    inc rdi
    inc rcx
    jmp .a
.rest:
    mov r15, [rsp+32]
.tail:
    ; the rest of the line from r15 (opend, or restend after a rewrite of the rest)
    mov rcx, r13
    sub rcx, r15
    lea rsi, [r12+r15]
    rep movsb
.r:
    mov rax, rdi
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = text, rdx = length. rax, rdx = it without a comment, trimmed
lbare:
    sub rsp, 40
    xor eax, eax
.l:
    cmp rax, rdx
    jae .t
    cmp byte [rcx+rax], ';'
    je .cut
    inc rax
    jmp .l
.cut:
    mov rdx, rax
.t:
    call trim
    add rsp, 40
    ret

; rcx = line, rdx = length, r8 = register. eax = 1 if it's pop register
is_pop:
    push rbx
    sub rsp, 32
    mov rbx, r8
    call lbare
    mov rcx, rax
    lea r8, [w_pop]
    call istarts
    test eax, eax
    jz .r
    test rdx, rdx
    jz .no
    movzx eax, byte [rcx]
    cmp eax, ' '
    je .sp
    cmp eax, 9
    jne .no
.sp:
    call trim
    mov rcx, rax
    mov r8, rbx
    call ieq
    jmp .r
.no:
    xor eax, eax
.r:
    add rsp, 32
    pop rbx
    ret

; rcx = lesson, rdx = scratch, r8 = site, r9 = lines. rax = the code with the bug
; (arena, a 0 after it), rdx = its length
apply:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov rbx, rcx
    mov r12, rdx
    mov r13, r8
    mov r14, r9
    mov rcx, [rbx+LS_CODE+8]
    add rcx, 256
    call alloc
    mov rdi, rax
    mov [rsp+32], rax
    mov qword [rsp+40], 1       ; nothing written yet
    xor r15d, r15d
.line:
    cmp r15, r14
    jae .done
    mov rax, r15
    shl rax, 4
    mov rsi, [r12+MS_LINES+rax]
    mov rcx, [r12+MS_LINES+rax+8]
    movzx edx, byte [r13+8]
    cmp r15, [r13]
    jne .other
    cmp edx, K_INIT
    je .next
    cmp edx, K_SAVE
    je .next
    call .nl
    mov rdx, rcx
    mov rcx, rsi
    mov r8, r13
    mov r9, rdi
    call mutline
    mov rdi, rax
    jmp .next
.other:
    cmp edx, K_SAVE
    jne .copy
    cmp r15, [r13]
    jb .copy
    ; the pops that went with the removed push
    mov [rsp+48], rcx
    movzx eax, byte [r13+9]
    lea r8, [saved]
    lea r8, [r8+rax*4]
    mov rdx, rcx
    mov rcx, rsi
    call is_pop
    mov rcx, [rsp+48]
    test eax, eax
    jnz .next
.copy:
    call .nl
    rep movsb
.next:
    inc r15
    jmp .line
.done:
    mov byte [rdi], 0
    mov rax, [rsp+32]
    mov rdx, rdi
    sub rdx, rax
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
; (apply) a line break before every line but the first
.nl:
    cmp qword [rsp+48], 0
    je .nl1
    mov qword [rsp+48], 0
    ret
.nl1:
    mov byte [rdi], 10
    inc rdi
    ret

; rcx = lesson, rdx = scratch, r8 = site. what the fix is, for the explainer:
; "change `x` back to `y`" or "add back `y`". rax = text (arena), rdx = length
fixtext:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rbx, r8
    mov rax, [rbx]
    shl rax, 4
    mov r12, [rdx+MS_LINES+rax]     ; the original line
    mov r13, [rdx+MS_LINES+rax+8]
    mov ecx, 16384
    call alloc
    mov r14, rax
    mov rdi, rax
    movzx eax, byte [rbx+8]
    cmp eax, K_INIT
    je .add
    cmp eax, K_SAVE
    je .add
    lea rsi, [x_chg]
    call cpz
    ; the line with the bug, past the end of what we're writing
    lea r9, [r14+8192]
    mov rcx, r12
    mov rdx, r13
    mov r8, rbx
    call mutline
    lea rcx, [r14+8192]
    mov rdx, rax
    sub rdx, rcx
    call lbare
    mov rsi, rax
    mov rcx, rdx
    rep movsb
    lea rsi, [x_back]
    call cpz
    call .orig
    lea rsi, [x_end]
    call cpz
    jmp .r
.add:
    lea rsi, [x_add]
    call cpz
    call .orig
    movzx eax, byte [rbx+8]
    cmp eax, K_SAVE
    jne .end
    lea rsi, [x_match]
    call cpz
    movzx eax, byte [rbx+9]
    lea rsi, [saved]
    lea rsi, [rsi+rax*4]
    call cpz
.end:
    lea rsi, [x_end]
    call cpz
.r:
    mov rax, r14
    mov rdx, rdi
    sub rdx, r14
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
; (fixtext) the original line, bare
.orig:
    sub rsp, 40
    mov rcx, r12
    mov rdx, r13
    call lbare
    mov rsi, rax
    mov rcx, rdx
    rep movsb
    add rsp, 40
    ret

section .rdata
roles     db "user:", 0, "assistant:", 0, "system:", 0, 0
hdr1      db "# made by bin\asmset, don't edit", 10, 10
hdr1_n    equ $ - hdr1
hdr2      db "# made by bin\asmset: the NASM-Eval lessons, for the loss", 10, 10
hdr2_n    equ $ - hdr2