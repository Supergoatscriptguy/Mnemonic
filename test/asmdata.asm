; the NASM lesson tools' core: json, literals, the test-line parser, and real
; builds against harness.asm, one for each way a candidate can fail
; uses: asmdata\verify asmdata\json
default rel
bits 64
%include "lib.inc"
%include "asmdata/asmdata.inc"
%include "test/check.inc"

section .rdata
d_work   db "scratch\asmgen\test", 0
c_echo   db "cmd.exe /c echo hello", 0
c_slow   db "cmd.exe /c ping -n 4 127.0.0.1", 0
k_choice db "choices", 0
k_msg    db "message", 0
k_cont   db "content", 0
k_fin    db "finish_reason", 0
k_usage  db "usage", 0
k_toks   db "completion_tokens", 0
j_str    db '"a\"b\\c\n\u00e9\ud83d\ude00x"', 0
j_resp   db '{"choices":[{"finish_reason":"stop","index":0,"message":{"role":"assistant",'
         db '"reasoning_content":"hmm {not} [this]","content":"hi \"there\""}}],"usage":{"completion_tokens":42}}', 0
p_raw    db 'a"b\c', 10, 9, 1
p_rawn   equ $ - p_raw
s_that   db "that line is: mov eax, rcx", 0
s_buf    db "the buffer in argument 1 is wrong at byte 0", 0
s_rbx    db "rbx was not preserved", 0
s_ret    db ": returned ", 0

; a whole answer, the way the teacher writes one
answer   db `Sure, here it is.\r\n\r\n### TASK\r\nAdd up n 32-bit integers.\r\n\r\n## **Signature**\r\n`
         db `int64_t sum32(const int32_t *a, uint64_t n);\r\n### CODE\r\n\`\`\`nasm\r\n`
         db `bits 64\r\nsection .text\r\nglobal sum32\r\nsum32:\r\n    xor eax, eax\r\n    test rdx, rdx\r\n`
         db `    jz .done\r\n.l:\r\n    movsxd r8, dword [rcx]\r\n    add rax, r8\r\n    add rcx, 4\r\n`
         db `    dec rdx\r\n    jnz .l\r\n.done:\r\n    ret\r\n\`\`\`\r\n### EXPLANATION\r\nIt adds them up.\r\n`
         db `### TESTS\r\n\`\`\`\r\n- sum32(i32[1, 2, 3], 3) -> 6\r\n* \`sum32(i32[-5, 5], n=2) -> 0\`\r\n`
         db `sum32(i32[], 0) -> 0.\r\nsum32(i32[0x7fffffff, 0x7fffffff], 2) -> 4294967294\r\n\`\`\`\r\n`
answer_n equ $ - answer
s_task   db "Add up n 32-bit integers."
s_task_n equ $ - s_task
s_name   db "sum32"

; the same function, broken in every way the harness can tell
v_wrong  db `bits 64\nsection .text\nglobal sum32\nsum32:\n    xor eax, eax\n    inc rax\n    ret\n`
v_wrong_n equ $ - v_wrong
v_abi    db `bits 64\nsection .text\nglobal sum32\nsum32:\n    xor eax, eax\n    test rdx, rdx\n    jz .d\n`
         db `    mov rbx, rcx\n.l:\n    movsxd r8, dword [rbx]\n    add rax, r8\n    add rbx, 4\n    dec rdx\n`
         db `    jnz .l\n.d:\n    ret\n`
v_abi_n  equ $ - v_abi
v_rsp    db `bits 64\nsection .text\nglobal sum32\nsum32:\n    xor eax, eax\n    test rdx, rdx\n    jz .d\n`
         db `.l:\n    movsxd r8, dword [rcx]\n    add rax, r8\n    add rcx, 4\n    dec rdx\n    jnz .l\n.d:\n    ret 8\n`
v_rsp_n  equ $ - v_rsp
v_xmm    db `bits 64\nsection .text\nglobal sum32\nsum32:\n    movaps xmm7, xmm6\n    xor eax, eax\n    test rdx, rdx\n    jz .d\n`
         db `.l:\n    movsxd r8, dword [rcx]\n    add rax, r8\n    add rcx, 4\n    dec rdx\n    jnz .l\n.d:\n    ret\n`
v_xmm_n  equ $ - v_xmm
v_crash  db `bits 64\nsection .text\nglobal sum32\nsum32:\n    xor eax, eax\n    mov rax, [rax]\n    ret\n`
v_crash_n equ $ - v_crash
v_loop   db `bits 64\nsection .text\nglobal sum32\nsum32:\n    jmp sum32\n`
v_loop_n equ $ - v_loop
v_asm    db `bits 64\nsection .text\nglobal sum32\nsum32:\n    mov eax, rcx\n    ret\n`
v_asm_n  equ $ - v_asm
v_link   db `bits 64\nglobal sum32\nsum32:\n    xor eax, eax\n    ret\n`
v_link_n equ $ - v_link

; buffers: upper-case a string in place
t_up     db `upper("abc") -> void ; arg1 = "ABC"\nupper("a1b") -> void ; arg1 = "A1B"\n`
         db `upper(u8[0]) -> void ; arg1 = u8[0]\n`
t_up_n   equ $ - t_up
v_up     db `bits 64\nsection .text\nglobal upper\nupper:\n    mov al, [rcx]\n    test al, al\n`
         db `    jz .d\n    lea edx, [rax-'a']\n    cmp dl, 25\n    ja .n\n    sub al, 32\n    mov [rcx], al\n`
         db `.n:\n    inc rcx\n    jmp upper\n.d:\n    ret\n`
v_up_n   equ $ - v_up
v_noup   db `bits 64\nsection .text\nglobal upper\nupper:\n    ret\n`
v_noup_n equ $ - v_noup

; code_check
k_ok     db `section .text\nglobal f\nf:\n    xor eax, eax  ; int 3 in a comment is fine\n    ret\n`
k_ok_n   equ $ - k_ok
k_ext    db `extern ExitProcess\nf: ret\n`
k_ext_n  equ $ - k_ext
k_sys    db `f:\n    mov eax, 60\n    SYSCALL\n`
k_sys_n  equ $ - k_sys
k_int    db `f:  int 3\n    ret\n`
k_int_n  equ $ - k_int
k_lint   db `f: int 0x2e\n`
k_lint_n equ $ - k_lint

section .bss
alignb 16
ctx      resq 1
rec      resb TS_SIZE
secs     resb SEC_SIZE
text     resb 4096
big      resb 1 << 16

section .text

; rcx = text, rdx = length, r8 = zero terminated needle. eax = 1 if it's in there
contains:
    push rsi
    push rdi
    mov rsi, rcx
    lea rdi, [rcx+rdx]
.at:
    cmp rsi, rdi
    jae .no
    xor ecx, ecx
.c:
    mov al, [r8+rcx]
    test al, al
    jz .yes
    lea rdx, [rsi+rcx]
    cmp rdx, rdi
    jae .no
    cmp al, [rsi+rcx]
    jne .next
    inc rcx
    jmp .c
.next:
    inc rsi
    jmp .at
.yes:
    mov eax, 1
    jmp .r
.no:
    xor eax, eax
.r:
    pop rdi
    pop rsi
    ret

; int_of on a literal: text, expected value, ok?
%macro lit 3
    section .rdata
    %%s db %1
    %%n equ $ - %%s
    %%name db "int_of ", %1, 0
    section .text
    lea rcx, [%%s]
    mov edx, %%n
    call int_of
    mov r8, %2
    xor ecx, ecx
    cmp edx, %3
    jne %%bad
    test edx, edx
    jz %%good
    cmp rax, r8
    jne %%bad
%%good:
    mov ecx, 1
%%bad:
    lea rdx, [%%name]
    call t_ok
%endmacro

; parse_test on a line: eax has to come out as %2
%macro line 2
    section .rdata
    %%s db %1
    %%n equ $ - %%s
    %%name db "parse: ", %1, 0
    section .text
    mov rcx, [ctx]
    mov qword [rcx+VC_BUSED], 0
    lea rdx, [%%s]
    mov r8d, %%n
    lea r9, [rec]
    call parse_test
    cmp eax, %2
    sete cl
    movzx ecx, cl
    lea rdx, [%%name]
    call t_ok
%endmacro

; a record field has to be %2
%macro field 3
    cmp qword [rec+%1], %2
    check e, %3
%endmacro

; vf_tests on the TESTS of the answer, then vf_verify on code %1 (length %2) has to
; give stage %3
%macro build 4
    mov rcx, [ctx]
    lea rdx, [%1]
    mov r8d, %2
    call vf_verify
    cmp eax, %3
    check e, %4
%endmacro

global start
start:
    sub rsp, 40
    call lib_init
    call vf_init
    lea rcx, [d_work]
    call vf_new
    mov [ctx], rax

    say "child processes", 13, 10
    lea rcx, [c_echo]
    xor edx, edx
    lea r8, [big]
    mov r9d, 1 << 16
    mov qword [rsp+32], 5000
    call vf_run
    mov rbx, rax
    lea rcx, [big]
    lea r8, [s_hello]
    call contains
    test rbx, rbx
    setz cl
    and al, cl
    cmp al, 1
    check e, "cmd /c echo hello: exit 0, says hello"
    lea rcx, [c_slow]
    xor edx, edx
    lea r8, [big]
    mov r9d, 1 << 16
    mov qword [rsp+32], 300
    call vf_run
    cmp rax, -1
    check e, "a 3 second ping with a 300 ms timeout gets killed"

    say "json", 13, 10
    lea rcx, [j_str]
    lea rdx, [text]
    call js_str
    lea rsi, [text]
    lea rdi, [s_dec]
    mov ecx, s_dec_n
    cmp rax, rcx
    jne .jbad
    repe cmpsb
.jbad:
    check e, "escapes, \u and a surrogate pair -> utf-8"
    lea rcx, [j_resp]
    lea rdx, [k_choice]
    call js_get
    mov rcx, rax
    xor edx, edx
    call js_at
    mov rbx, rax
    mov rcx, rax
    lea rdx, [k_msg]
    call js_get
    mov rcx, rax
    lea rdx, [k_cont]
    call js_get
    mov rcx, rax
    lea rdx, [text]
    call js_str
    lea rdi, [text]
    add rdi, rax
    mov rax, rdi
    lea rdi, [tbuf]
    lea rsi, [text]
    mov rcx, rax
    sub rcx, rsi
    rep movsb
    mov rax, rdi
    expect 'hi "there"'
    mov rcx, rbx
    lea rdx, [k_fin]
    call js_get
    cmp dword [rax], '"sto'
    check e, "finish_reason, past a nested object"
    lea rcx, [j_resp]
    lea rdx, [k_usage]
    call js_get
    mov rcx, rax
    lea rdx, [k_toks]
    call js_get
    mov rcx, rax
    call parse_int
    cmp rax, 42
    check e, "usage.completion_tokens"
    lea rcx, [tbuf]
    lea rdx, [p_raw]
    mov r8d, p_rawn
    call js_put
    expect '"a\"b\\c\n\t\u0001"'

    say "literals", 13, 10
    lit "5", 5, 1
    lit " -3 ", -3, 1
    lit "0xff", 255, 1
    lit "0XFF", 255, 1
    lit "0b101", 5, 1
    lit "1_000", 1000, 1
    lit "10u", 10, 1
    lit "7UL", 7, 1
    lit "'a'", 97, 1
    lit "'\n'", 10, 1
    lit "'\x41'", 65, 1
    lit "true", 1, 1
    lit "NULL", 0, 1
    lit "nullptr", 0, 1
    lit "18446744073709551615", -1, 1
    lit "-9223372036854775808", 0x8000000000000000, 1
    lit "0xffffffffffffffff", -1, 1
    lit "18446744073709551616", 0, 0
    lit "-9223372036854775809", 0, 0
    lit "0x10000000000000000", 0, 0
    lit "abc", 0, 0
    lit "'ab'", 0, 0
    lit "0x", 0, 0
    lit "", 0, 0

    say "test lines", 13, 10
    line "sum(i32[1, 2, 3], 3) -> 6", 1
    field TS_NARG, 2, "  two arguments"
    field TS_ARG, 1, "  the first is a buffer"
    field TS_ARG+16, 12, "  of 12 bytes"
    field TS_ARG+32, 3, "  the second is 3"
    field TS_RET, 6, "  returns 6"
    line '- `upper("abc", out[4]) -> void ; arg2 = "ABC"`', 1
    field TS_ARG+16, 4, "  a string gets its 0"
    field TS_ARG+40, 4, "  out[4] is 4 bytes"
    field TS_HASRET, 0, "  void"
    field TS_NCHK, 1, "  one check"
    field TS_CHK, 1, "  on argument 2"
    line "f(count=3, 'x') => 0x10.", 1
    field TS_ARG+8, 3, "  named argument"
    field TS_ARG+32, 120, "  char argument"
    field TS_RET, 16, "  result with a full stop after it"
    line "h(u8[255, 256, -1], 3) -> 1 ; arg1 = u8[255, 0, 255], *arg2 == 3", 1
    field TS_NCHK, 1, "  the check on a number argument is skipped"
    mov rax, [rec+TS_ARG+8]
    cmp word [rax], 0x00ff
    check e, "  u8 elements wrap"
    line "This is just text (with parens) and no arrow", 0
    line "f(1, 2 -> 3", -1
    line "f(1, 2, 3, 4, 5) -> 1", -1
    line "g(1) -> void", -1
    line "g(1) -> banana", -1
    line "9lives(1) -> 1", -1

    say "the answer", 13, 10
    lea rcx, [answer]
    lea rdx, [text]
    mov r8d, answer_n
    ; (a copy, strip_cr works in place)
    mov rdi, rdx
    mov rsi, rcx
    mov rcx, r8
    rep movsb
    lea rcx, [text]
    mov edx, answer_n
    call strip_cr
    mov rbx, rax
    lea rcx, [text]
    mov rdx, rbx
    lea r8, [secs]
    call sections
    mov rsi, [secs+SEC_TASK]
    mov rcx, [secs+SEC_TASK+8]
    lea rdi, [tbuf]
    rep movsb
    mov rax, rdi
    expect "Add up n 32-bit integers."
    cmp qword [secs+SEC_SIG], 0
    setne al
    cmp qword [secs+SEC_WRONG], 0
    sete cl
    and al, cl
    cmp al, 1
    check e, "## **Signature** counts, WHAT WAS WRONG isn't there"
    mov rcx, [secs+SEC_CODE]
    mov rdx, [secs+SEC_CODE+8]
    call code_of
    mov [rsp+32], rax
    mov [rsp+40], rdx       ; (shadow slots of ours, nothing's called in between)
    mov rcx, rax
    call code_check
    test rax, rax
    check z, "the code passes code_check"
    mov rcx, [secs+SEC_CODE]
    mov rdx, [secs+SEC_CODE+8]
    call code_of
    mov rbx, rax
    mov rsi, rdx
    mov rcx, rax
    mov rdx, rsi
    lea r8, [s_name]
    mov r9d, 5
    call has_global
    cmp eax, 1
    check e, "global sum32"
    mov rcx, [ctx]
    mov rdx, [secs+SEC_TESTS]
    mov r8, [secs+SEC_TESTS+8]
    call vf_tests
    cmp rax, 4
    check e, "4 tests (bullets, backticks, a named argument, a full stop)"

    say "builds", 13, 10
    mov rcx, [ctx]
    mov rdx, rbx
    mov r8, rsi
    call vf_verify
    cmp eax, ST_OK
    check e, "the right code passes"
    build v_wrong, v_wrong_n, ST_TESTS, "a wrong result"
    build v_abi, v_abi_n, ST_ABI, "rbx used without saving it"
    mov rcx, [ctx]
    mov rdx, [rcx+VC_OLEN]
    mov rcx, [rcx+VC_OUT]
    lea r8, [s_rbx]
    call contains
    cmp eax, 1
    check e, "  and the harness says so"
    build v_rsp, v_rsp_n, ST_ABI, "right sums, but ret 8"
    mov rcx, [ctx]
    mov rdx, [rcx+VC_OLEN]
    mov rcx, [rcx+VC_OUT]
    lea r8, [s_ret]
    call contains
    test eax, eax
    check z, "  and no wrong results reported for it"
    build v_xmm, v_xmm_n, ST_ABI, "xmm6 copied over xmm7"
    build v_crash, v_crash_n, ST_CRASH, "a null pointer"
    build v_loop, v_loop_n, ST_TIMEOUT, "an endless loop (5 seconds)"
    build v_asm, v_asm_n, ST_ASM, "mov eax, rcx doesn't assemble"
    mov rcx, [ctx]
    lea rdx, [v_asm]
    mov r8d, v_asm_n
    call vf_note
    mov rcx, [ctx]
    mov rdx, [rcx+VC_NLEN]
    mov rcx, [rcx+VC_NOTE]
    lea r8, [s_that]
    call contains
    cmp eax, 1
    check e, "  vf_note quotes the line"
    build v_link, v_link_n, ST_LINK, "no section .text doesn't link (nasm 3)"
    mov rcx, [ctx]
    lea rdx, [t_up]
    mov r8d, t_up_n
    call vf_tests
    cmp rax, 3
    check e, "tests with buffer checks"
    build v_up, v_up_n, ST_OK, "in-place upper case passes"
    build v_noup, v_noup_n, ST_TESTS, "doing nothing fails"
    mov rcx, [ctx]
    mov rdx, [rcx+VC_OLEN]
    mov rcx, [rcx+VC_OUT]
    lea r8, [s_buf]
    call contains
    cmp eax, 1
    check e, "  at the buffer"

    say "code_check", 13, 10
    lea rcx, [k_ok]
    mov edx, k_ok_n
    call code_check
    test rax, rax
    check z, "plain code (int 3 in a comment)"
    lea rcx, [k_ext]
    mov edx, k_ext_n
    call code_check
    test rax, rax
    check nz, "extern"
    lea rcx, [k_sys]
    mov edx, k_sys_n
    call code_check
    test rax, rax
    check nz, "SYSCALL"
    lea rcx, [k_int]
    mov edx, k_int_n
    call code_check
    test rax, rax
    check nz, "a label then int 3"
    lea rcx, [k_lint]
    mov edx, k_lint_n
    call code_check
    test rax, rax
    check nz, "int 0x2e"
    xor ecx, ecx
    xor edx, edx
    call code_check
    test rax, rax
    check nz, "no code at all"
    jmp t_done

section .rdata
s_hello  db "hello", 0
s_dec    db 'a"b\c', 10, 0xc3, 0xa9, 0xf0, 0x9f, 0x98, 0x80, 'x'
s_dec_n  equ $ - s_dec
