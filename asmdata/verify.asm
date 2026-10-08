; checks the teacher's NASM: pulls the sections and the code block out of an answer,
; parses its test lines, writes tests.inc for harness.asm, and builds and runs the
; candidate with nasm and link as child processes. one context and work directory
; per thread
default rel
bits 64
%include "lib.inc"
%include "asmdata/asmdata.inc"

extern CreatePipe, SetHandleInformation, CreateProcessA, CloseHandle, PeekNamedPipe
extern ReadFile, WaitForSingleObject, TerminateProcess, GetExitCodeProcess
extern GetTickCount64, GetEnvironmentVariableA, GetFullPathNameA, CopyFileA, SetErrorMode

OUTSZ   equ 1 << 16
AREA    equ 1 << 20
FILESZ  equ 8 << 20
RUNF    equ 768

; top_next's iterator
IT_POS  equ 0
IT_END  equ 8
IT_SEP  equ 16
IT_DONE equ 24

section .rdata
e_lapp   db "LOCALAPPDATA", 0
e_pf86   db "ProgramFiles(x86)", 0
s_nasm   db "\bin\NASM\nasm.exe", 0
s_vsw    db '\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -find VC\Tools\MSVC\**\bin\Hostx64\x64\link.exe', 0
s_sdk    db "\Windows Kits\10\Lib\10.0.26100.0\um\x64", 0
s_harn   db "asmdata\harness.asm", 0
f_cand   db "cand.asm", 0
f_thunk  db "thunk.asm", 0
f_inc    db "tests.inc", 0
f_harn   db "harness.asm", 0
c_q      db '"', 0
c_cand   db '" -f win64 -o cand.obj cand.asm', 0
c_thunk  db '" -f win64 -o thunk.obj thunk.asm', 0
c_harn1  db '" -f win64 -o h.obj -I "', 0
c_harn2  db '\\" harness.asm', 0
c_link1  db '" /nologo /subsystem:console /entry:__harness_start /nodefaultlib /out:t.exe h.obj thunk.obj cand.obj kernel32.lib /libpath:"', 0
c_exe    db '\t.exe"', 0
m_never  db "it never returned (ran for 5 seconds, probably an endless loop)", 0
m_start  db "couldn't start it", 0
m_that   db "    that line is: ", 0
m_wfile  db "couldn't write the candidate's files in the work dir", 0
m_in     db " in: ", 0
e_link   db "can't find link.exe (vswhere found nothing)", 0
e_harn   db "can't copy asmdata\harness.asm, run from the project folder", 0
r_none   db "no code block", 0
r_long   db "too long (over 90 lines)", 0
r_extern db "not allowed: extern", 0
r_import db "not allowed: import", 0
r_sysc   db "not allowed: syscall", 0
r_syse   db "not allowed: sysenter", 0
r_int    db "not allowed: int", 0
r_inc    db "not allowed: %include", 0
r_incbin db "not allowed: incbin", 0
p_name   db "can't read the function name", 0
p_unbal  db "unbalanced brackets", 0
p_arrow  db "no -> after the call", 0
p_many   db "more than 4 arguments", 0
p_arg    db "can't read an argument", 0
p_ret    db "can't read the result", 0
p_none   db "nothing is checked", 0
p_mixed  db "the tests call different functions", 0
p_lots   db "more than 64 tests", 0
p_few1   db "only ", 0
p_few2   db " tests (need at least 3)", 0
w_extern db "extern", 0
w_import db "import", 0
w_sysc   db "syscall", 0
w_syse   db "sysenter", 0
w_incbin db "incbin", 0
w_inc    db "%include", 0
w_int    db "int", 0
w_global db "global", 0
w_true   db "true", 0
w_false  db "false", 0
w_null   db "null", 0
w_nullp  db "nullptr", 0
w_void   db "void", 0
w_out    db "out", 0
w_arg    db "arg", 0
w_cand   db "cand.asm:", 0
heads    db "task", 0, "signature", 0, "code", 0, "explanation", 0, "tests", 0, "what was wrong", 0, 0
; element types for buffer literals, name then size in the last byte
types    db "i16", 0, 0, 0, 0, 2
         db "u16", 0, 0, 0, 0, 2
         db "i32", 0, 0, 0, 0, 4
         db "u32", 0, 0, 0, 0, 4
         db "i64", 0, 0, 0, 0, 8
         db "u64", 0, 0, 0, 0, 8
         db "i8", 0, 0, 0, 0, 0, 1
         db "u8", 0, 0, 0, 0, 0, 1
         db 0
st_names db "ok", 0, 0, 0, 0, 0, 0, 0, 0
         db "assemble", 0, 0
         db "internal", 0, 0
         db "link", 0, 0, 0, 0, 0, 0
         db "tests", 0, 0, 0, 0, 0
         db "abi", 0, 0, 0, 0, 0, 0, 0
         db "crash", 0, 0, 0, 0, 0
         db "timeout", 0, 0, 0

section .bss
nasm_exe resb 512
link_exe resb 512
sdk_dir  resb 512
initcmd  resb 1024
plock    resd 1

section .text

; finds nasm, link (through vswhere) and the sdk's import libs. call once, from the
; project folder
global vf_init
vf_init:
    push rbx
    sub rsp, 48
    mov ecx, 0x8003             ; no error boxes, for us or the children
    call SetErrorMode
    lea rcx, [e_lapp]
    lea rdx, [nasm_exe]
    mov r8d, 400
    call GetEnvironmentVariableA
    mov eax, eax                ; a DWORD, the top half of rax could be anything
    lea rcx, [nasm_exe]
    add rcx, rax
    lea rdx, [s_nasm]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [e_pf86]
    lea rdx, [sdk_dir]
    mov r8d, 300
    call GetEnvironmentVariableA
    mov ebx, eax
    lea rcx, [initcmd]
    mov byte [rcx], '"'
    inc rcx
    lea rdx, [sdk_dir]
    call fmt_str
    mov rcx, rax
    lea rdx, [s_vsw]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [sdk_dir]
    add rcx, rbx
    lea rdx, [s_sdk]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [initcmd]
    xor edx, edx
    lea r8, [link_exe]
    mov r9d, 500
    mov qword [rsp+32], 30000
    call vf_run
    ; its first line
    lea r8, [link_exe]
    xor ecx, ecx
.l:
    cmp rcx, rdx
    jae .cut
    mov al, [r8+rcx]
    cmp al, 13
    je .cut
    cmp al, 10
    je .cut
    inc rcx
    jmp .l
.cut:
    mov byte [r8+rcx], 0
    test rcx, rcx
    jnz .ok
    lea rcx, [e_link]
    call fatal
.ok:
    add rsp, 48
    pop rbx
    ret

; rcx = work directory. rax = a new context that uses it
global vf_new
vf_new:
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
    mov ecx, VC_SIZE
    call mem_alloc
    mov rbx, rax
    mov rcx, rsi
    mov edx, 480
    lea r8, [rbx+VC_DIR]
    xor r9d, r9d
    call GetFullPathNameA
    lea rcx, [rbx+VC_DIR]
    call mkdirs
    mov ecx, OUTSZ
    call mem_alloc
    mov [rbx+VC_OUT], rax
    mov ecx, OUTSZ
    call mem_alloc
    mov [rbx+VC_NOTE], rax
    mov ecx, (MAXTESTS + 1) * TS_SIZE   ; a spare, vf_tests parses into it before it knows
    call mem_alloc
    mov [rbx+VC_TESTS], rax
    mov ecx, AREA + 64
    call mem_alloc
    mov [rbx+VC_BYTES], rax
    mov ecx, FILESZ
    call mem_alloc
    mov [rbx+VC_FILE], rax
    mov rcx, rbx
    lea rdx, [f_harn]
    call vf_path
    lea rcx, [s_harn]
    mov rdx, rax
    xor r8d, r8d
    call CopyFileA
    test eax, eax
    jnz .ok
    lea rcx, [e_harn]
    call fatal
.ok:
    mov rax, rbx
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = a full path, made with every folder on the way
mkdirs:
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
    lea rbx, [rcx+3]            ; past the drive
.l:
    mov al, [rbx]
    test al, al
    jz .last
    cmp al, '\'
    jne .n
    mov byte [rbx], 0
    mov rcx, rsi
    call make_dir
    mov byte [rbx], '\'
.n:
    inc rbx
    jmp .l
.last:
    mov rcx, rsi
    call make_dir
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = context, rdx = file name. rax = its path in the work directory
vf_path:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    lea rcx, [rbx+VC_PATH]
    lea rdx, [rbx+VC_DIR]
    call fmt_str
    mov byte [rax], '\'
    lea rcx, [rax+1]
    mov rdx, rsi
    call fmt_str
    mov byte [rax], 0
    lea rax, [rbx+VC_PATH]
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = context, rdx = file name, r8 = data, r9 = length. written into the work dir.
; eax = 1 if it all got there
wfile:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, r8
    mov rdi, r9
    call vf_path
    mov rcx, rax
    call file_create
    cmp rax, -1
    je .no
    mov rbx, rax
    mov rcx, rax
    mov rdx, rsi
    mov r8, rdi
    call file_write
    mov esi, eax
    mov rcx, rbx
    call file_close
    mov eax, esi
    jmp .ret
.no:
    xor eax, eax
.ret:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = command line, rdx = directory to run it in (0 = ours), r8 = output buffer,
; r9 = its size, [rsp+40] = timeout in ms. stdout and stderr both go to the buffer
; (past its size gets dropped). rax = exit code, -1 if it ran out of time and got
; killed, -2 if it didn't start. rdx = output length
global vf_run
vf_run:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, RUNF
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov r12, r9
    xor r13d, r13d
    lea rax, [rsp+120]          ; STARTUPINFOA
    mov ecx, 13
.z:
    mov qword [rax+rcx*8-8], 0
    dec ecx
    jnz .z
    mov dword [rsp+120], 104
    mov dword [rsp+120+60], 0x100       ; STARTF_USESTDHANDLES
    mov dword [rsp+80], 24              ; SECURITY_ATTRIBUTES, inheritable
    mov qword [rsp+88], 0
    mov dword [rsp+96], 1
    ; a child inherits every inheritable handle around when it's created, so the
    ; pipe gets made, handed over and closed on our side in one go. otherwise another
    ; thread's child could hold our write end open
.lock:
    lock bts dword [plock], 0
    jnc .locked
    pause
    jmp .lock
.locked:
    lea rcx, [rsp+104]
    lea rdx, [rsp+112]
    lea r8, [rsp+80]
    mov r9d, 1 << 16
    call CreatePipe
    test eax, eax
    jz .nopipe
    mov rcx, [rsp+104]
    mov edx, 1                  ; HANDLE_FLAG_INHERIT
    xor r8d, r8d
    call SetHandleInformation
    mov rax, [rsp+112]
    mov [rsp+120+88], rax       ; stdout
    mov [rsp+120+96], rax       ; stderr
    xor ecx, ecx
    mov rdx, rbx
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 1
    mov qword [rsp+40], 0x08000000      ; CREATE_NO_WINDOW
    mov qword [rsp+48], 0
    mov [rsp+56], rsi
    lea rax, [rsp+120]
    mov [rsp+64], rax
    lea rax, [rsp+224]
    mov [rsp+72], rax
    call CreateProcessA
    mov r15d, eax
    mov rcx, [rsp+112]
    call CloseHandle
    mov dword [plock], 0
    test r15d, r15d
    jnz .started
    mov rcx, [rsp+104]
    call CloseHandle
    jmp .nostart
.nopipe:
    mov dword [plock], 0
.nostart:
    mov rax, -2
    xor edx, edx
    jmp .ret
.started:
    mov r14, [rsp+224]          ; the process
    mov rcx, [rsp+232]
    call CloseHandle
    call GetTickCount64
    mov r15, rax
    xor esi, esi                ; 1 once it has ended
.poll:
    mov rcx, [rsp+104]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    lea rax, [rsp+248]
    mov dword [rax], 0
    mov [rsp+32], rax
    mov qword [rsp+40], 0
    call PeekNamedPipe
    test eax, eax
    jz .idle                    ; broken: it's done writing
    mov eax, [rsp+248]
    test eax, eax
    jz .idle
    ; into the buffer, or a scratch once that's full
    xor ebx, ebx
    mov r8, r12
    sub r8, r13
    lea rdx, [rdi+r13]
    test r8, r8
    setnz bl
    jnz .room
    lea rdx, [rsp+256]
    mov r8d, 512
.room:
    cmp r8, rax
    jbe .rd
    mov r8, rax
.rd:
    mov rcx, [rsp+104]
    lea r9, [rsp+252]
    mov qword [rsp+32], 0
    call ReadFile
    test eax, eax
    jz .idle
    test ebx, ebx
    jz .poll
    mov eax, [rsp+252]
    add r13, rax
    jmp .poll
.idle:
    test esi, esi
    jnz .code
    mov rcx, r14
    mov edx, 2
    call WaitForSingleObject
    test eax, eax
    jnz .clock
    mov esi, 1                  ; ended: one more look at the pipe
    jmp .poll
.clock:
    call GetTickCount64
    sub rax, r15
    cmp rax, [rsp+RUNF+96]
    jb .poll
    mov rcx, r14
    mov edx, 1
    call TerminateProcess
    mov rcx, r14
    mov edx, -1
    call WaitForSingleObject
    mov qword [rsp+80], -1
    jmp .close
.code:
    mov rcx, r14
    lea rdx, [rsp+248]
    call GetExitCodeProcess
    mov eax, [rsp+248]
    mov [rsp+80], rax
.close:
    mov rcx, r14
    call CloseHandle
    mov rcx, [rsp+104]
    call CloseHandle
    mov rax, [rsp+80]
    mov rdx, r13
.ret:
    add rsp, RUNF
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = context, edx = timeout in ms. runs VC_CMD in the work dir, its output
; (trimmed) ends up at the start of VC_OUT. rax = exit code
vrun:
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    mov rbx, rcx
    mov eax, edx
    mov [rsp+32], rax
    lea rcx, [rbx+VC_CMD]
    lea rdx, [rbx+VC_DIR]
    mov r8, [rbx+VC_OUT]
    mov r9d, OUTSZ - 1
    call vf_run
    mov [rsp+40], rax
    lea r8, [m_never]
    cmp rax, -1
    je .say
    lea r8, [m_start]
    cmp rax, -2
    jne .trim
.say:
    mov rcx, [rbx+VC_OUT]
    mov rdx, r8
    call fmt_str
    mov rdx, rax
    sub rdx, [rbx+VC_OUT]
.trim:
    mov rcx, [rbx+VC_OUT]
    call trim
    mov [rbx+VC_OLEN], rdx
    mov rsi, rax
    mov rdi, [rbx+VC_OUT]
    mov rcx, rdx
    rep movsb
    mov byte [rdi], 0
    mov rax, [rsp+40]
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret

; append a zero terminated string at rdi
%macro cat 1
    mov rcx, rdi
    lea rdx, %1
    call fmt_str
    mov rdi, rax
%endmacro

; the function name from the first test, at rdi. uses rsi, rcx
%macro putname 0
    mov rax, [rbx+VC_TESTS]
    mov rsi, [rax+TS_FN]
    mov rcx, [rax+TS_FNLEN]
    rep movsb
%endmacro

; rcx = context (vf_tests done), rdx = code, r8 = its length. builds it with the
; harness and runs the tests. eax = ST_*, what it printed in VC_OUT / VC_OLEN
global vf_verify
vf_verify:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    mov r12, r8
    mov rdi, [rbx+VC_FILE]
    mov rcx, r12
    rep movsb
    mov byte [rdi], 10
    mov rcx, rbx
    lea rdx, [f_cand]
    mov r8, [rbx+VC_FILE]
    lea r9, [r12+1]
    call wfile
    test eax, eax
    jz .nofile
    ; the thunk gives it a name that can't clash with the harness
    mov rdi, [rbx+VC_FILE]
    emit "bits 64", 10, "extern "
    putname
    emit 10, "global __entry", 10, "section .text", 10, "__entry: jmp "
    putname
    emit 10
    mov r9, rdi
    sub r9, [rbx+VC_FILE]
    mov rcx, rbx
    lea rdx, [f_thunk]
    mov r8, [rbx+VC_FILE]
    call wfile
    test eax, eax
    jz .nofile
    mov rcx, rbx
    call vf_inc
    mov r9, rax
    mov rcx, rbx
    lea rdx, [f_inc]
    mov r8, [rbx+VC_FILE]
    call wfile
    test eax, eax
    jz .nofile
    ; nasm the candidate
    lea rdi, [rbx+VC_CMD]
    cat [c_q]
    cat [nasm_exe]
    cat [c_cand]
    mov byte [rdi], 0
    mov rcx, rbx
    mov edx, 20000
    call vrun
    mov r12d, ST_ASM
    test rax, rax
    jnz .stage
    lea rdi, [rbx+VC_CMD]
    cat [c_q]
    cat [nasm_exe]
    cat [c_thunk]
    mov byte [rdi], 0
    mov rcx, rbx
    mov edx, 20000
    call vrun
    mov r12d, ST_INTERNAL
    test rax, rax
    jnz .stage
    lea rdi, [rbx+VC_CMD]
    cat [c_q]
    cat [nasm_exe]
    cat [c_harn1]
    cat [rbx+VC_DIR]
    cat [c_harn2]
    mov byte [rdi], 0
    mov rcx, rbx
    mov edx, 20000
    call vrun
    test rax, rax
    jnz .stage
    lea rdi, [rbx+VC_CMD]
    cat [c_q]
    cat [link_exe]
    cat [c_link1]
    cat [sdk_dir]
    cat [c_q]
    mov byte [rdi], 0
    mov rcx, rbx
    mov edx, 30000
    call vrun
    mov r12d, ST_LINK
    test rax, rax
    jnz .stage
    lea rdi, [rbx+VC_CMD]
    cat [c_q]
    cat [rbx+VC_DIR]
    cat [c_exe]
    mov byte [rdi], 0
    mov rcx, rbx
    mov edx, 5000
    call vrun
    mov r12d, ST_OK
    test rax, rax
    jz .stage
    mov r12d, ST_TESTS
    cmp rax, 1
    je .stage
    mov r12d, ST_ABI
    cmp rax, 2
    je .stage
    mov r12d, ST_TIMEOUT
    cmp rax, -1
    je .stage
    mov r12d, ST_INTERNAL       ; t.exe didn't start (Defender holding it, say), not its fault
    cmp rax, -2
    je .stage
    mov r12d, ST_CRASH
.stage:
    mov eax, r12d
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.nofile:
    ; nasm would only build whatever the last one left there
    mov rcx, [rbx+VC_OUT]
    lea rdx, [m_wfile]
    call fmt_str
    mov byte [rax], 0
    sub rax, [rbx+VC_OUT]
    mov [rbx+VC_OLEN], rax
    mov r12d, ST_INTERNAL
    jmp .stage

; ecx = ST_*. rax = its name
global vf_stage
vf_stage:
    lea rax, [st_names]
    imul ecx, ecx, 10
    add rax, rcx
    ret

; rcx = context, rdx = code, r8 = its length. VC_OUT with the source line quoted
; under each nasm error that points at one. rax = text (VC_NOTE), rdx = length
global vf_note
vf_note:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov rbx, rcx
    mov r12, rdx                ; code
    mov r13, r8
    mov rsi, [rbx+VC_OUT]
    mov r14, rsi
    add r14, [rbx+VC_OLEN]      ; its end
    mov rdi, [rbx+VC_NOTE]
    mov r15, rdi
    add r15, OUTSZ - 1024       ; stop well short of the end
.line:
    cmp rsi, r14
    jae .done
    cmp rdi, r15
    jae .done
    mov rdx, rsi
.eol:
    cmp rdx, r14
    jae .got
    cmp byte [rdx], 10
    je .got
    inc rdx
    jmp .eol
.got:
    mov r8, rdx                 ; next line starts after it
    ; the line without trailing space
.rt:
    cmp rdx, rsi
    jbe .copy
    movzx eax, byte [rdx-1]
    cmp eax, ' '
    ja .copy
    dec rdx
    jmp .rt
.copy:
    mov rcx, rdx
    sub rcx, rsi
    cmp rcx, 512                ; with a quote under it, that still fits in the 1024 left
    jbe .cl
    mov ecx, 512
.cl:
    mov [rsp+32], r8
    mov r9, rsi
    rep movsb
    mov rsi, r9
    mov byte [rdi], 10
    inc rdi
    ; cand.asm:N: ?
    mov rcx, rsi
    mov rdx, r8
    sub rdx, rsi
    lea r8, [w_cand]
    call istarts
    test eax, eax
    jz .next
    lea rcx, [rsi+9]
    call parse_int
    cmp byte [rdx], ':'
    jne .next
    test rax, rax
    jz .next
    ; find line rax of the code
    mov rcx, r12
    lea r9, [r12+r13]
.find:
    dec rax
    jz .at
.f2:
    cmp rcx, r9
    jae .next
    cmp byte [rcx], 10
    je .f3
    inc rcx
    jmp .f2
.f3:
    inc rcx
    jmp .find
.at:
    mov rdx, rcx
.ae:
    cmp rdx, r9
    jae .ah
    cmp byte [rdx], 10
    je .ah
    inc rdx
    jmp .ae
.ah:
    sub rdx, rcx
    call trim
    mov [rsp+40], rax
    mov [rsp+48], rdx
    cat [m_that]
    mov rsi, [rsp+40]
    mov rcx, [rsp+48]
    cmp rcx, 400
    jbe .q
    mov ecx, 400
.q:
    rep movsb
    mov byte [rdi], 10
    inc rdi
.next:
    mov rsi, [rsp+32]
    inc rsi
    jmp .line
.done:
    mov rcx, [rbx+VC_NOTE]
    mov rdx, rdi
    sub rdx, rcx
    call trim
    mov [rbx+VC_NLEN], rdx
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- text

; rcx = text, rdx = length. rax, rdx = the same without whitespace at either end
global trim
trim:
    mov rax, rcx
.front:
    test rdx, rdx
    jz .done
    movzx ecx, byte [rax]
    cmp ecx, ' '
    je .f
    cmp ecx, 9
    jb .back
    cmp ecx, 13
    ja .back
.f:
    inc rax
    dec rdx
    jmp .front
.back:
    movzx ecx, byte [rax+rdx-1]
    cmp ecx, ' '
    je .b
    cmp ecx, 9
    jb .done
    cmp ecx, 13
    ja .done
.b:
    dec rdx
    jnz .back
.done:
    ret

; rcx = text, rdx = length. takes out every \r, rax = new length
global strip_cr
strip_cr:
    mov rax, rcx
    mov r9, rcx
    lea r8, [rcx+rdx]
.l:
    cmp rcx, r8
    jae .done
    mov dl, [rcx]
    inc rcx
    cmp dl, 13
    je .l
    mov [rax], dl
    inc rax
    jmp .l
.done:
    sub rax, r9
    ret

; ecx = a byte. eax = 1 for letters, digits and _
isword:
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

; rcx = text, rdx = length, r8 = lowercase literal. eax = 1 if the text starts with
; it, in any case. rcx moves past it
global istarts
istarts:
    xor eax, eax
.l:
    movzx r9d, byte [r8]
    test r9d, r9d
    jz .yes
    test rdx, rdx
    jz .no
    movzx r10d, byte [rcx]
    lea r11d, [r10-'A']
    cmp r11d, 25
    ja .c
    or r10d, 0x20
.c:
    cmp r10d, r9d
    jne .no
    inc rcx
    inc r8
    dec rdx
    jmp .l
.yes:
    mov eax, 1
.no:
    ret

; same, but the whole text has to be the literal
global ieq
ieq:
    sub rsp, 8
    call istarts
    test eax, eax
    jz .no
    test rdx, rdx
    setz al
.no:
    add rsp, 8
    ret

; rcx = text, rdx = length, r8 = lowercase word. eax = 1 if it's there as a whole
; word, anywhere
global hasword
hasword:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    lea rdi, [rcx+rdx]
    mov r12, r8
    mov rbx, rcx
.at:
    cmp rbx, rdi
    jae .no
    cmp rbx, rsi
    je .try
    movzx ecx, byte [rbx-1]
    call isword
    test eax, eax
    jnz .next
.try:
    mov rcx, rbx
    mov rdx, rdi
    sub rdx, rbx
    mov r8, r12
    call istarts
    test eax, eax
    jz .next
    cmp rcx, rdi
    jae .yes
    movzx ecx, byte [rcx]
    call isword
    test eax, eax
    jz .yes
.next:
    inc rbx
    jmp .at
.yes:
    mov eax, 1
    jmp .ret
.no:
    xor eax, eax
.ret:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- the answer

; rcx = text (no \r, see strip_cr), rdx = length, r8 = SEC_SIZE for the results.
; "### TASK" style headings (1-4 #s, any case, bold or not) start a section, which
; runs to the next heading, trimmed. text before the first one is ignored
global sections
sections:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rsi, rcx
    lea rdi, [rcx+rdx]
    mov rbx, r8
    xor eax, eax
    mov ecx, SEC_SIZE / 8
.z:
    mov [rbx+rcx*8-8], rax
    dec ecx
    jnz .z
    mov r12, -1                 ; open section
.line:
    cmp rsi, rdi
    jae .end
    mov r14, rsi
.eol:
    cmp r14, rdi
    jae .got
    cmp byte [r14], 10
    je .got
    inc r14
    jmp .eol
.got:
    mov rcx, rsi
    mov rdx, r14
    sub rdx, rsi
    call heading
    cmp eax, -1
    je .next
    mov r15d, eax
    mov rcx, rsi
    call close
    mov r12d, r15d
    lea r13, [r14+1]
.next:
    lea rsi, [r14+1]
    jmp .line
.end:
    mov rcx, rdi
    call close
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; (sections) rcx = where the open section ends
close:
    cmp r12, -1
    je .r
    sub rsp, 8
    mov rdx, rcx
    sub rdx, r13
    jge .len
    xor edx, edx
.len:
    mov rcx, r13
    call trim
    mov r8, r12
    shl r8, 4
    mov [rbx+r8], rax
    mov [rbx+r8+8], rdx
    add rsp, 8
.r:
    ret

; rcx = a line, rdx = its length. eax = which section heading it is, or -1
heading:
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    mov rsi, rcx
    lea rdi, [rcx+rdx]
    call trim
    mov rsi, rax
    lea rdi, [rax+rdx]
    xor ecx, ecx
.hash:
    cmp rsi, rdi
    jae .no
    cmp byte [rsi], '#'
    jne .hashes
    inc ecx
    inc rsi
    jmp .hash
.hashes:
    dec ecx
    cmp ecx, 3
    ja .no
.sp1:
    cmp rsi, rdi
    jae .no
    movzx eax, byte [rsi]
    cmp eax, ' '
    je .s1
    cmp eax, 9
    jne .stars
.s1:
    inc rsi
    jmp .sp1
.stars:
    cmp byte [rsi], '*'
    jne .sp2
    inc rsi
    cmp rsi, rdi
    jb .stars
    jmp .no
.sp2:
    movzx eax, byte [rsi]
    cmp eax, ' '
    je .s2
    cmp eax, 9
    jne .word
.s2:
    inc rsi
    cmp rsi, rdi
    jb .sp2
    jmp .no
.word:
    lea rbx, [heads]
    xor eax, eax
    mov [rsp+32], rax
.try:
    cmp byte [rbx], 0
    je .no
    mov rcx, rsi
    mov rdx, rdi
    sub rdx, rsi
    mov r8, rbx
    call istarts
    test eax, eax
    jz .skip
    cmp rcx, rdi
    jae .yes
    movzx ecx, byte [rcx]
    call isword
    test eax, eax
    jz .yes
.skip:
    cmp byte [rbx], 0
    lea rbx, [rbx+1]
    jne .skip
    inc qword [rsp+32]
    jmp .try
.yes:
    mov eax, [rsp+32]
    jmp .ret
.no:
    mov eax, -1
.ret:
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = text, rdx = length. rax, rdx = the inside of its first ``` block (the
; language name and the line break after the fence aren't part of it), rax = 0 if
; there isn't a whole one
global code_of
code_of:
    push rsi
    push rdi
    mov rsi, rcx
    lea rdi, [rcx+rdx]
.fence:
    lea rax, [rsi+3]
    cmp rax, rdi
    ja .no
    cmp word [rsi], '``'
    jne .n
    cmp byte [rsi+2], '`'
    jne .n
    mov rcx, rax
.lang:
    cmp rcx, rdi
    jae .no
    movzx eax, byte [rcx]
    lea edx, [rax-'0']
    cmp edx, 9
    jbe .ln
    or eax, 0x20
    lea edx, [rax-'a']
    cmp edx, 25
    ja .sp
.ln:
    inc rcx
    jmp .lang
.sp:
    cmp rcx, rdi
    jae .no
    movzx eax, byte [rcx]
    cmp eax, ' '
    je .sn
    cmp eax, 9
    je .sn
    cmp eax, 10
    jne .n
    inc rcx
    mov rax, rcx                ; it starts here, now where does it end
.end:
    lea rdx, [rcx+3]
    cmp rdx, rdi
    ja .no
    cmp word [rcx], '``'
    jne .e
    cmp byte [rcx+2], '`'
    je .got
.e:
    inc rcx
    jmp .end
.sn:
    inc rcx
    jmp .sp
.n:
    inc rsi
    jmp .fence
.got:
    mov rdx, rcx
.rt:
    cmp rdx, rax
    jbe .len
    movzx ecx, byte [rdx-1]
    cmp ecx, ' '
    ja .len
    dec rdx
    jmp .rt
.len:
    sub rdx, rax
    jmp .ret
.no:
    xor eax, eax
    xor edx, edx
.ret:
    pop rdi
    pop rsi
    ret

; rcx = code (0 = there wasn't any), rdx = length. rax = 0 if it can go in, or why
; not: anything that reaches outside the function, or over 90 lines
global code_check
code_check:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    lea rax, [r_none]
    test rcx, rcx
    jz .ret
    mov rsi, rcx
    lea rdi, [rcx+rdx]
    mov r12, rdx
    xor ecx, ecx
    xor eax, eax
.cnt:
    cmp rcx, r12
    jae .counted
    cmp byte [rsi+rcx], 10
    jne .c2
    inc eax
.c2:
    inc rcx
    jmp .cnt
.counted:
    cmp eax, 90
    lea rax, [r_long]
    jae .ret
    ; words that are never fine, anywhere
    lea r13, [w_sysc]
    lea rbx, [r_sysc]
    call .word
    lea r13, [w_syse]
    lea rbx, [r_syse]
    call .word
    lea r13, [w_incbin]
    lea rbx, [r_incbin]
    call .word
    ; %include anywhere
    mov rbx, rsi
.pi:
    cmp rbx, rdi
    jae .lines
    mov rcx, rbx
    mov rdx, rdi
    sub rdx, rbx
    lea r8, [w_inc]
    call istarts
    lea rcx, [r_inc]
    test eax, eax
    jnz .why
    inc rbx
    jmp .pi
.lines:
    ; extern / import / int N at the start of a line
    mov rbx, rsi
.line:
    cmp rbx, rdi
    jae .fine
    mov rcx, rbx
    mov rdx, rdi
    sub rdx, rbx
    call .ws
    mov r13, rcx
    lea r8, [w_extern]
    call .start
    lea rcx, [r_extern]
    test eax, eax
    jnz .why
    mov rcx, r13
    mov rdx, rdi
    sub rdx, r13
    lea r8, [w_import]
    call .start
    lea rcx, [r_import]
    test eax, eax
    jnz .why
    ; a label first is fine (.local ones too, and nasm's other label characters),
    ; then int and something
    mov rcx, r13
.lab:
    cmp rcx, rdi
    jae .int
    movzx eax, byte [rcx]
    cmp eax, '.'
    je .lc
    cmp eax, '$'
    je .lc
    cmp eax, '?'
    je .lc
    cmp eax, '@'
    je .lc
    mov r8, rcx
    mov ecx, eax
    call isword
    mov rcx, r8
    test eax, eax
    jz .colon
.lc:
    inc rcx
    jmp .lab
.colon:
    cmp rcx, r13
    je .int
    cmp byte [rcx], ':'
    jne .int
    inc rcx
    mov rdx, rdi
    sub rdx, rcx
    call .ws
    mov r13, rcx
.int:
    mov rcx, r13
    mov rdx, rdi
    sub rdx, r13
    lea r8, [w_int]
    call istarts
    test eax, eax
    jz .eol
    ; one or more spaces, then a word character
    xor r8d, r8d
.isp:
    cmp rcx, rdi
    jae .eol
    movzx eax, byte [rcx]
    cmp eax, ' '
    je .is
    cmp eax, 9
    jne .iw
.is:
    inc r8d
    inc rcx
    jmp .isp
.iw:
    test r8d, r8d
    jz .eol
    mov ecx, eax
    call isword
    lea rcx, [r_int]
    test eax, eax
    jnz .why
.eol:
    cmp rbx, rdi
    jae .fine
    cmp byte [rbx], 10
    je .nl
    inc rbx
    jmp .eol
.nl:
    inc rbx
    jmp .line
.fine:
    xor eax, eax
    jmp .ret
.why:
    mov rax, rcx
.ret:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
; (code_check) the word in r13 anywhere: back out with rbx as the reason
.word:
    sub rsp, 40
    mov rcx, rsi
    mov rdx, r12
    mov r8, r13
    call hasword
    add rsp, 40
    test eax, eax
    jz .wr
    add rsp, 8                  ; not going back
    mov rcx, rbx
    jmp .why
.wr:
    ret
; rcx, rdx: skip spaces and tabs (not line breaks)
.ws:
    test rdx, rdx
    jz .wsr
    cmp byte [rcx], ' '
    je .wsn
    cmp byte [rcx], 9
    jne .wsr
.wsn:
    inc rcx
    dec rdx
    jmp .ws
.wsr:
    ret
; rcx, rdx = text, r8 = word: eax = 1 if it starts with it as a whole word
.start:
    sub rsp, 40
    call istarts
    test eax, eax
    jz .sr
    cmp rcx, rdi
    jae .sr
    movzx ecx, byte [rcx]
    call isword
    xor eax, 1
.sr:
    add rsp, 40
    ret

; rcx = code, rdx = length, r8 = name, r9 = its length. eax = 1 if a line says
; global name (the first name after global)
global has_global
has_global:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    lea rdi, [rcx+rdx]
    mov r12, r8
    mov r13, r9
    mov rbx, rcx
.line:
    cmp rbx, rdi
    jae .no
    mov rcx, rbx
.ws:
    cmp rcx, rdi
    jae .no
    movzx eax, byte [rcx]
    cmp eax, ' '
    je .w
    cmp eax, 9
    jne .kw
.w:
    inc rcx
    jmp .ws
.kw:
    mov rdx, rdi
    sub rdx, rcx
    lea r8, [w_global]
    call istarts
    test eax, eax
    jz .eol
    xor r8d, r8d
.sp:
    cmp rcx, rdi
    jae .no
    movzx eax, byte [rcx]
    cmp eax, ' '
    je .s
    cmp eax, 9
    jne .name
.s:
    inc r8d
    inc rcx
    jmp .sp
.name:
    test r8d, r8d
    jz .eol
    ; the name there has to be exactly ours
    lea rax, [rcx+r13]
    cmp rax, rdi
    ja .eol
    xor edx, edx
.cmp:
    cmp rdx, r13
    jae .end
    mov al, [rcx+rdx]
    cmp al, [r12+rdx]
    jne .eol
    inc rdx
    jmp .cmp
.end:
    add rcx, r13
    cmp rcx, rdi
    jae .yes
    movzx ecx, byte [rcx]
    call isword
    test eax, eax
    jz .yes
.eol:
    cmp rbx, rdi
    jae .no
    cmp byte [rbx], 10
    je .nl
    inc rbx
    jmp .eol
.nl:
    inc rbx
    jmp .line
.yes:
    mov eax, 1
    jmp .ret
.no:
    xor eax, eax
.ret:
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- tests: name(args) -> result ; argN = expected

; rcx = iterator. the next piece between separators that aren't inside quotes or
; brackets, trimmed: rax, rdx. rax = 0 when there are no more
top_next:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    xor eax, eax
    cmp qword [rbx+IT_DONE], 0
    jne .ret
    mov rsi, [rbx+IT_POS]
    mov rdi, rsi
    xor r8d, r8d                ; depth
    xor r9d, r9d                ; open quote
    mov r10, [rbx+IT_END]
    movzx r11d, byte [rbx+IT_SEP]
.c:
    cmp rdi, r10
    jae .last
    movzx ecx, byte [rdi]
    test r9d, r9d
    jz .free
    inc rdi
    cmp ecx, '\'
    jne .q
    cmp rdi, r10
    jae .c
    inc rdi
    jmp .c
.q:
    cmp ecx, r9d
    jne .c
    xor r9d, r9d
    jmp .c
.free:
    cmp ecx, '"'
    je .open
    cmp ecx, "'"
    je .open
    cmp ecx, '['
    je .in
    cmp ecx, '('
    je .in
    cmp ecx, ']'
    je .out
    cmp ecx, ')'
    je .out
    cmp ecx, r11d
    jne .next
    test r8d, r8d
    jne .next
    lea rax, [rdi+1]
    mov [rbx+IT_POS], rax
    jmp .part
.open:
    mov r9d, ecx
    jmp .next
.in:
    inc r8d
    jmp .next
.out:
    dec r8d
.next:
    inc rdi
    jmp .c
.last:
    mov qword [rbx+IT_DONE], 1
.part:
    mov rcx, rsi
    mov rdx, rdi
    sub rdx, rsi
    call trim
.ret:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = dst, rdx = src, r8 = length. c escapes (\n \t \r \0 \\ \" \' \xHH) to
; bytes, rax = how many
unescape:
    push rsi
    push rdi
    mov rdi, rcx
    mov rsi, rdx
    lea r9, [rdx+r8]
    mov r10, rcx
.c:
    cmp rsi, r9
    jae .done
    movzx eax, byte [rsi]
    inc rsi
    cmp eax, '\'
    jne .put
    cmp rsi, r9
    jae .put
    movzx eax, byte [rsi]
    inc rsi
    mov ecx, 10
    cmp eax, 'n'
    je .is
    mov ecx, 9
    cmp eax, 't'
    je .is
    mov ecx, 13
    cmp eax, 'r'
    je .is
    xor ecx, ecx
    cmp eax, '0'
    je .is
    cmp eax, '\'
    je .put
    cmp eax, '"'
    je .put
    cmp eax, "'"
    je .put
    cmp eax, 'x'
    je .hex
    mov byte [rdi], '\'
    inc rdi
    jmp .put
.is:
    mov eax, ecx
    jmp .put
.hex:
    xor eax, eax
    xor edx, edx
.h:
    cmp edx, 2
    jae .hd
    cmp rsi, r9
    jae .hd
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    jbe .dig
    movzx ecx, byte [rsi]
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 5
    ja .hd
    add ecx, 10
.dig:
    shl eax, 4
    add eax, ecx
    inc rsi
    inc edx
    jmp .h
.hd:
    test edx, edx
    jz .c
.put:
    mov [rdi], al
    inc rdi
    jmp .c
.done:
    mov rax, rdi
    sub rax, r10
    pop rdi
    pop rsi
    ret

; rcx = text, rdx = length: 5, -3, 0xff, 0b101, 1_000, 10u, 'a', '\n', true, null.
; rax = its 64 bits, edx = 1. edx = 0 if it isn't one, or doesn't fit in
; -2^63 .. 2^64-1
global int_of
int_of:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 120
    call trim
    mov rsi, rax
    mov rbx, rdx
    ; 'c'
    cmp rbx, 3
    jb .words
    cmp byte [rsi], "'"
    jne .words
    cmp byte [rsi+rbx-1], "'"
    jne .words
    cmp rbx, 10
    ja .no
    lea rcx, [rsp+32]
    lea rdx, [rsi+1]
    lea r8, [rbx-2]
    call unescape
    cmp rax, 1
    jne .no
    movzx eax, byte [rsp+32]
    jmp .yes
.words:
    mov rcx, rsi
    mov rdx, rbx
    lea r8, [w_true]
    call ieq
    test eax, eax
    jz .w0
    mov eax, 1
    jmp .yes
.w0:
    lea r12, [w_false]
    call .zero
    lea r12, [w_null]
    call .zero
    lea r12, [w_nullp]
    call .zero
    ; a sign
    xor r12d, r12d
    test rbx, rbx
    jz .no
    cmp byte [rsi], '-'
    jne .plus
    mov r12d, 1
    jmp .unsign
.plus:
    cmp byte [rsi], '+'
    jne .digits
.unsign:
    lea rcx, [rsi+1]
    lea rdx, [rbx-1]
    call trim
    mov rsi, rax
    mov rbx, rdx
.digits:
    ; without underscores
    lea rdi, [rsp+48]
    xor ecx, ecx
.u:
    cmp rcx, rbx
    jae .sfx0
    mov al, [rsi+rcx]
    inc rcx
    cmp al, '_'
    je .u
    lea rdx, [rsp+112]
    cmp rdi, rdx
    jae .no
    mov [rdi], al
    inc rdi
    jmp .u
.sfx0:
    lea rsi, [rsp+48]
.sfx:
    ; and without a u or l suffix
    cmp rdi, rsi
    jbe .no
    movzx eax, byte [rdi-1]
    or eax, 0x20
    cmp eax, 'u'
    je .s
    cmp eax, 'l'
    jne .base
.s:
    dec rdi
    jmp .sfx
.base:
    xor eax, eax
    mov rcx, rdi
    sub rcx, rsi
    cmp rcx, 2
    jbe .dec
    cmp byte [rsi], '0'
    jne .dec
    movzx ecx, byte [rsi+1]
    or ecx, 0x20
    cmp ecx, 'x'
    je .hex
    cmp ecx, 'b'
    je .bin
.dec:
    cmp rsi, rdi
    jae .range
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .no
    mov r8d, 10
    mul r8
    jc .no
    add rax, rcx
    jc .no
    inc rsi
    jmp .dec
.hex:
    add rsi, 2
.hx:
    cmp rsi, rdi
    jae .range
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    jbe .hd
    movzx ecx, byte [rsi]
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 5
    ja .no
    add ecx, 10
.hd:
    mov rdx, rax
    shr rdx, 60
    jnz .no
    shl rax, 4
    or rax, rcx
    inc rsi
    jmp .hx
.bin:
    add rsi, 2
.bx:
    cmp rsi, rdi
    jae .range
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 1
    ja .no
    bt rax, 63
    jc .no
    shl rax, 1
    or rax, rcx
    inc rsi
    jmp .bx
.range:
    test r12d, r12d
    jz .yes
    mov rcx, 0x8000000000000000
    cmp rax, rcx
    ja .no
    neg rax
.yes:
    mov edx, 1
    jmp .ret
.no:
    xor eax, eax
    xor edx, edx
.ret:
    add rsp, 120
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
; (int_of) the word in r12 means 0: done, if it's that
.zero:
    sub rsp, 40
    mov rcx, rsi
    mov rdx, rbx
    mov r8, r12
    call ieq
    add rsp, 40
    test eax, eax
    jz .zr
    add rsp, 8                  ; not going back
    xor eax, eax
    jmp .yes
.zr:
    ret

; rcx = context, rdx = text, r8 = length: "text" (gets a 0 after it), out[N]
; (N zeros) or a typed list like i32[1, -2, 3]. rax = the bytes, in the context's
; area, rdx = how many. rax = 0 if it isn't one
bytes_of:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 88
    mov rbx, rcx
    mov rcx, rdx
    mov rdx, r8
    call trim
    mov rsi, rax
    mov r12, rdx
    mov rdi, [rbx+VC_BYTES]
    add rdi, [rbx+VC_BUSED]
    mov r13d, AREA
    sub r13, [rbx+VC_BUSED]     ; room left
    xor r14d, r14d              ; bytes made
    cmp r12, 2
    jb .out
    cmp byte [rsi], '"'
    jne .out
    cmp byte [rsi+r12-1], '"'
    jne .out
    cmp r12, r13
    jae .no
    mov rcx, rdi
    lea rdx, [rsi+1]
    lea r8, [r12-2]
    call unescape
    mov byte [rdi+rax], 0
    lea r14, [rax+1]
    jmp .got
.out:
    mov rcx, rsi
    mov rdx, r12
    lea r8, [w_out]
    call istarts
    test eax, eax
    jz .typed
    lea rcx, [rsi+3]
    lea rdx, [r12-3]
    call trim
    cmp rdx, 3
    jb .no
    cmp byte [rax], '['
    jne .no
    cmp byte [rax+rdx-1], ']'
    jne .no
    lea rcx, [rax+1]
    sub rdx, 2
    call trim
    test rdx, rdx
    jz .no
.od:
    movzx ecx, byte [rax]
    sub ecx, '0'
    cmp ecx, 9
    ja .no
    imul r14, r14, 10
    add r14, rcx
    cmp r14, 1 << 16
    ja .no
    inc rax
    dec rdx
    jnz .od
    cmp r14, r13
    ja .no
    mov rcx, r14
    xor eax, eax
    mov r8, rdi
    rep stosb
    mov rdi, r8
    jmp .got
.typed:
    lea r8, [types]
    mov [rsp+32], r8
.ty:
    mov r8, [rsp+32]
    cmp byte [r8], 0
    je .no
    mov rcx, rsi
    mov rdx, r12
    call istarts
    test eax, eax
    jnz .tyhit
    add qword [rsp+32], 8
    jmp .ty
.tyhit:
    ; rcx, rdx = what's after the name
    mov r8, [rsp+32]
    movzx eax, byte [r8+7]
    mov [rsp+40], rax           ; element size
    call trim
    cmp rdx, 2
    jb .no
    cmp byte [rax], '['
    jne .no
    cmp byte [rax+rdx-1], ']'
    jne .no
    lea rcx, [rax+1]
    sub rdx, 2
    call trim
    test rdx, rdx
    jz .got
    mov [rsp+48+IT_POS], rax
    add rax, rdx
    mov [rsp+48+IT_END], rax
    mov qword [rsp+48+IT_SEP], ','
    mov qword [rsp+48+IT_DONE], 0
.el:
    lea rcx, [rsp+48]
    call top_next
    test rax, rax
    jz .got
    mov rcx, rax
    call int_of
    test edx, edx
    jz .no
    mov rcx, [rsp+40]
    lea r8, [r14+rcx]
    cmp r8, r13
    ja .no
.st:
    mov [rdi+r14], al
    shr rax, 8
    inc r14
    dec rcx
    jnz .st
    jmp .el
.got:
    add [rbx+VC_BUSED], r14
    mov rax, rdi
    mov rdx, r14
    jmp .ret
.no:
    xor eax, eax
    xor edx, edx
.ret:
    add rsp, 88
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = text, rdx = length. eax = 1 if it's an identifier
is_ident:
    push rbx
    push rsi
    sub rsp, 40
    xor eax, eax
    test rdx, rdx
    jz .ret
    mov rsi, rcx
    mov rbx, rdx
    movzx ecx, byte [rsi]
    lea eax, [rcx-'0']
    cmp eax, 9
    jbe .no
.c:
    movzx ecx, byte [rsi]
    call isword
    test eax, eax
    jz .ret
    inc rsi
    dec rbx
    jnz .c
    mov eax, 1
    jmp .ret
.no:
    xor eax, eax
.ret:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = text, rdx = length. name=value or name: value gives the value, anything
; else comes back as it was
named:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rbx, rdx
    mov rax, rcx
    test rdx, rdx
    jz .ret
    movzx ecx, byte [rsi]
    lea eax, [rcx-'0']
    cmp eax, 9
    jbe .keep
    call isword
    test eax, eax
    jz .keep
    mov edi, 1
.w:
    cmp rdi, rbx
    jae .keep
    movzx ecx, byte [rsi+rdi]
    call isword
    test eax, eax
    jz .sp
    inc edi
    jmp .w
.sp:
    movzx eax, byte [rsi+rdi]
    cmp eax, ' '
    je .s
    cmp eax, 9
    jne .eq
.s:
    inc edi
    cmp rdi, rbx
    jb .sp
    jmp .keep
.eq:
    cmp eax, '='
    je .val
    cmp eax, ':'
    jne .keep
.val:
    lea rcx, [rsi+rdi+1]
    mov rdx, rbx
    sub rdx, rdi
    dec rdx
    call trim
    test rdx, rdx
    jnz .ret
.keep:
    mov rax, rsi
    mov rdx, rbx
.ret:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = text, rdx = length, r8 = 3 slots for (N, expected ptr, expected len).
; eax = 1 if it's a check like argN = expected (or *argN == ...)
argcheck:
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
    lea rbx, [rcx+rdx]
    mov [rsp+32], r8
    cmp rsi, rbx
    jae .no
    cmp byte [rsi], '*'
    jne .sp0
    inc rsi
.sp0:
    mov rcx, rsi
    mov rdx, rbx
    sub rdx, rsi
    call trim
    mov rcx, rax
    lea r8, [w_arg]
    mov rsi, rcx
    call istarts
    test eax, eax
    jz .no
    mov rsi, rcx
    call .ws
    xor eax, eax
    xor edx, edx
.d:
    cmp rsi, rbx
    jae .no
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .dd
    imul rax, rax, 10
    add rax, rcx
    cmp rax, 1000
    jb .dn
    mov eax, 1000
.dn:
    inc edx
    inc rsi
    jmp .d
.dd:
    test edx, edx
    jz .no
    mov r10, [rsp+32]
    mov [r10], rax
    call .ws
    cmp rsi, rbx
    jae .no
    cmp byte [rsi], '='
    jne .no
    inc rsi
    cmp rsi, rbx
    jae .no
    cmp byte [rsi], '='
    jne .want
    inc rsi
.want:
    mov rcx, rsi
    mov rdx, rbx
    sub rdx, rsi
    call trim
    test rdx, rdx
    jz .no
    mov r10, [rsp+32]
    mov [r10+8], rax
    mov [r10+16], rdx
    mov eax, 1
    jmp .ret
.no:
    xor eax, eax
.ret:
    add rsp, 40
    pop rsi
    pop rbx
    ret
.ws:
    cmp rsi, rbx
    jae .wr
    movzx ecx, byte [rsi]
    cmp ecx, ' '
    je .wn
    cmp ecx, 9
    jb .wr
    cmp ecx, 13
    ja .wr
.wn:
    inc rsi
    jmp .ws
.wr:
    ret

; rcx = context, rdx = message, r8 = the line, r9 = its length. VC_ERR = both
perr:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rsi, r8
    mov rdi, r9
    lea rcx, [rbx+VC_ERR]
    call fmt_str
    mov rcx, rax
    lea rdx, [m_in]
    call fmt_str
    mov rcx, rdi
    cmp rcx, 300
    jbe .cp
    mov ecx, 300
.cp:
    mov rdi, rax
    rep movsb
    mov byte [rdi], 0
    mov eax, -1
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = context, rdx = one line of TESTS, r8 = its length, r9 = a test record.
; eax = 1 if it's a test, 0 if it isn't one, -1 if it looks like one but something
; in it can't be read (VC_ERR says what)
global parse_test
parse_test:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 160
    mov rbx, rcx
    mov r15, r9
    mov r12, rdx
    mov r13, r8
    mov rdi, r9
    xor eax, eax
    mov ecx, TS_SIZE / 8
    rep stosq
    mov rcx, r12
    mov rdx, r13
    call trim
    ; a "- " or "* " bullet
    cmp rdx, 2
    jb .ticks
    movzx ecx, byte [rax]
    cmp ecx, '-'
    je .bul
    cmp ecx, '*'
    jne .ticks
.bul:
    movzx ecx, byte [rax+1]
    cmp ecx, ' '
    je .bul2
    cmp ecx, 9
    jb .ticks
    cmp ecx, 13
    ja .ticks
.bul2:
    lea rcx, [rax+1]
    dec rdx
    call trim
.ticks:
    test rdx, rdx
    jz .tk1
    cmp byte [rax], '`'
    jne .tk1
    inc rax
    dec rdx
    jmp .ticks
.tk1:
    test rdx, rdx
    jz .tk2
    cmp byte [rax+rdx-1], '`'
    jne .tk2
    dec rdx
    jmp .tk1
.tk2:
    mov rcx, rax
    call trim
    mov rsi, rax
    mov r12, rdx
    mov [rsp+96], rax
    mov [rsp+104], rdx
    ; a test has a ( and an -> or =>
    mov r13, -1
    xor ecx, ecx
    xor r8d, r8d
.scan:
    cmp rcx, r12
    jae .scanned
    movzx eax, byte [rsi+rcx]
    cmp eax, '('
    jne .ar
    cmp r13, -1
    jne .ar
    mov r13, rcx
.ar:
    cmp eax, '>'
    jne .sn
    test rcx, rcx
    jz .sn
    movzx eax, byte [rsi+rcx-1]
    cmp eax, '-'
    je .arrow
    cmp eax, '='
    jne .sn
.arrow:
    mov r8d, 1
.sn:
    inc rcx
    jmp .scan
.scanned:
    cmp r13, -1
    je .skip
    test r8d, r8d
    jz .skip
    mov rcx, rsi
    mov rdx, r13
    call trim
    mov [r15+TS_FN], rax
    mov [r15+TS_FNLEN], rdx
    mov rcx, rax
    call is_ident
    lea rdx, [p_name]
    test eax, eax
    jz .err
    ; its closing bracket
    mov rcx, r13
    xor r8d, r8d
    xor r9d, r9d
    mov r14, -1
.cl:
    cmp rcx, r12
    jae .clend
    movzx eax, byte [rsi+rcx]
    test r9d, r9d
    jz .clf
    cmp eax, '\'
    jne .clq
    add rcx, 2
    jmp .cl
.clq:
    cmp eax, r9d
    jne .cln
    xor r9d, r9d
    jmp .cln
.clf:
    cmp eax, '"'
    je .clo
    cmp eax, "'"
    je .clo
    cmp eax, '('
    je .cli
    cmp eax, '['
    je .cli
    cmp eax, ')'
    je .clx
    cmp eax, ']'
    jne .cln
.clx:
    dec r8d
    jnz .cln
    mov r14, rcx
    jmp .clend
.cli:
    inc r8d
    jmp .cln
.clo:
    mov r9d, eax
.cln:
    inc rcx
    jmp .cl
.clend:
    lea rdx, [p_unbal]
    cmp r14, -1
    je .err
    lea rcx, [rsi+r14+1]
    mov rdx, r12
    sub rdx, r14
    dec rdx
    call trim
    cmp rdx, 2
    jb .noarrow
    movzx ecx, word [rax]
    cmp ecx, '->'
    je .arrow2
    cmp ecx, '=>'
    je .arrow2
.noarrow:
    lea rdx, [p_arrow]
    jmp .err
.arrow2:
    add rax, 2
    sub rdx, 2
    mov [rsp+112], rax
    mov [rsp+120], rdx
    ; the arguments
    lea rcx, [rsi+r13+1]
    mov rdx, r14
    sub rdx, r13
    dec rdx
    call trim
    test rdx, rdx
    jz .result
    mov [rsp+32+IT_POS], rax
    add rax, rdx
    mov [rsp+32+IT_END], rax
    mov qword [rsp+32+IT_SEP], ','
    mov qword [rsp+32+IT_DONE], 0
.arg:
    lea rcx, [rsp+32]
    call top_next
    test rax, rax
    jz .result
    mov rcx, rax
    call named
    mov rdi, rax
    mov r13, rdx
    lea rdx, [p_many]
    cmp qword [r15+TS_NARG], 4
    jae .err
    mov rcx, rdi
    mov rdx, r13
    call int_of
    mov r8, [r15+TS_NARG]
    imul r8, r8, 24
    lea r8, [r15+TS_ARG+r8]
    test edx, edx
    jz .buf
    mov qword [r8], 0
    mov [r8+8], rax
    jmp .argok
.buf:
    mov [rsp+128], r8
    mov rcx, rbx
    mov rdx, rdi
    mov r8, r13
    call bytes_of
    test rax, rax
    jz .badarg
    mov r8, [rsp+128]
    mov qword [r8], 1
    mov [r8+8], rax
    mov [r8+16], rdx
.argok:
    inc qword [r15+TS_NARG]
    jmp .arg
.badarg:
    lea rdx, [p_arg]
    jmp .err
.result:
    ; what comes after the arrow: the result, then ; and checks
    mov rax, [rsp+112]
    mov rdx, [rsp+120]
    mov [rsp+32+IT_POS], rax
    add rax, rdx
    mov [rsp+32+IT_END], rax
    mov qword [rsp+32+IT_SEP], ';'
    mov qword [rsp+32+IT_DONE], 0
    lea rcx, [rsp+32]
    call top_next
.dot:
    test rdx, rdx
    jz .part
    cmp byte [rax+rdx-1], '.'
    jne .rv
    dec rdx
    jmp .dot
.rv:
    mov rdi, rax
    mov r13, rdx
    mov rcx, rax
    lea r8, [w_void]
    call ieq
    test eax, eax
    jnz .part
    mov rcx, rdi
    mov rdx, r13
    call int_of
    test edx, edx
    jz .badret
    mov qword [r15+TS_HASRET], 1
    mov [r15+TS_RET], rax
.part:
    lea rcx, [rsp+32]
    call top_next
    test rax, rax
    jz .checked
    mov [rsp+64+IT_POS], rax
    add rax, rdx
    mov [rsp+64+IT_END], rax
    mov qword [rsp+64+IT_SEP], ','
    mov qword [rsp+64+IT_DONE], 0
.piece:
    lea rcx, [rsp+64]
    call top_next
    test rax, rax
    jz .part
    mov rcx, rax
    lea r8, [rsp+128]
    call argcheck
    test eax, eax
    jz .piece
    ; only for a buffer argument that exists, and an expected value we can read
    mov rax, [rsp+128]
    test rax, rax
    jz .piece
    cmp rax, [r15+TS_NARG]
    ja .piece
    dec rax
    imul rax, rax, 24
    cmp qword [r15+TS_ARG+rax], 1
    jne .piece
    mov rcx, rbx
    mov rdx, [rsp+136]
    mov r8, [rsp+144]
    call bytes_of
    test rax, rax
    jz .piece
    mov r8, [r15+TS_NCHK]
    cmp r8, MAXCHK
    jae .piece
    imul r8, r8, 24
    lea r8, [r15+TS_CHK+r8]
    mov rcx, [rsp+128]
    dec rcx
    mov [r8], rcx
    mov [r8+8], rax
    mov [r8+16], rdx
    inc qword [r15+TS_NCHK]
    jmp .piece
.badret:
    lea rdx, [p_ret]
    jmp .err
.checked:
    cmp qword [r15+TS_HASRET], 0
    jne .yes
    cmp qword [r15+TS_NCHK], 0
    jne .yes
    lea rdx, [p_none]
.err:
    mov rcx, rbx
    mov r8, [rsp+96]
    mov r9, [rsp+104]
    call perr
    jmp .ret
.yes:
    mov eax, 1
    jmp .ret
.skip:
    xor eax, eax
.ret:
    add rsp, 160
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = context, rdx = the TESTS section, r8 = its length. every test line goes into
; the context. rax = how many, or -1 with VC_ERR saying why (a bad line, fewer than
; 3 tests, or tests of different functions)
global vf_tests
vf_tests:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rbx, rcx
    mov rsi, rdx
    lea r12, [rdx+r8]
    mov qword [rbx+VC_BUSED], 0
    mov qword [rbx+VC_NT], 0
    xor r13d, r13d
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
    mov r9, r13
    imul r9, r9, TS_SIZE
    add r9, [rbx+VC_TESTS]
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    sub r8, rsi
    call parse_test
    cmp eax, -1
    je .fail
    add r13d, eax
    lea rdx, [p_lots]
    cmp r13, MAXTESTS           ; a line after the 64th test is fine, a 65th test isn't
    ja .err
    lea rsi, [rdi+1]
    jmp .line
.done:
    cmp r13, 3
    jae .same
    lea rcx, [rbx+VC_ERR]
    lea rdx, [p_few1]
    call fmt_str
    mov rcx, rax
    mov rdx, r13
    call fmt_dec
    mov rcx, rax
    lea rdx, [p_few2]
    call fmt_str
    mov byte [rax], 0
    jmp .fail
.same:
    mov r8, [rbx+VC_TESTS]
    mov r14, r8
    mov ecx, 1
.s:
    cmp rcx, r13
    jae .ok
    add r14, TS_SIZE
    mov rdx, [r8+TS_FNLEN]
    cmp rdx, [r14+TS_FNLEN]
    jne .mixed
    mov r9, [r8+TS_FN]
    mov r10, [r14+TS_FN]
.sc:
    dec rdx
    js .snext
    mov al, [r9+rdx]
    cmp al, [r10+rdx]
    jne .mixed
    jmp .sc
.snext:
    inc rcx
    jmp .s
.mixed:
    lea rcx, [rbx+VC_ERR]
    lea rdx, [p_mixed]
    call fmt_str
    mov byte [rax], 0
    jmp .fail
.err:
    lea rcx, [rbx+VC_ERR]
    call fmt_str
    mov byte [rax], 0
.fail:
    mov rax, -1
    jmp .ret
.ok:
    mov [rbx+VC_NT], r13
    mov rax, r13
.ret:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- tests.inc

; appends at rdi: a number in decimal / "0x" and 16 hex digits / "tNaK"-style labels
%macro wdec 1
    mov rcx, rdi
    mov rdx, %1
    call fmt_dec
    mov rdi, rax
%endmacro

%macro whex 1
    mov word [rdi], '0x'
    lea rcx, [rdi+2]
    mov rdx, %1
    mov r8d, 16
    call fmt_hex
    mov rdi, rax
%endmacro

; rdi = where to write, rsi = bytes, rcx = how many. "db 1,2,3", or "db 0" for none
wdb:
    push rbx
    push r12
    sub rsp, 40
    mov rbx, rsi
    mov r12, rcx
    mov dword [rdi], 'db 0'
    add rdi, 3
    test r12, r12
    jnz .first
    inc rdi
    jmp .ret
.first:
    movzx edx, byte [rbx]
    mov rcx, rdi
    call fmt_dec
    mov rdi, rax
    inc rbx
    dec r12
    jz .ret
    mov byte [rdi], ','
    inc rdi
    jmp .first
.ret:
    add rsp, 40
    pop r12
    pop rbx
    ret

; rcx = context with tests parsed. writes tests.inc for harness.asm into VC_FILE:
; NTESTS, and tests: a table of records dq arg0..arg3, checkret, ret, nchk, then nchk
; x (buffer, expected, length). rax = its length
global vf_inc
vf_inc:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rbx, rcx
    mov rdi, [rbx+VC_FILE]
    mov r12, [rbx+VC_NT]
    emit "NTESTS equ "
    wdec r12
    emit 10, "section .rdata", 10, "align 8", 10, "tests: dq "
    xor r13d, r13d
.tab:
    test r13, r13
    jz .t1
    emit ", "
.t1:
    mov byte [rdi], 't'
    inc rdi
    wdec r13
    inc r13
    cmp r13, r12
    jb .tab
    mov byte [rdi], 10
    inc rdi
    ; the records
    xor r13d, r13d
.rec:
    cmp r13, r12
    jae .exp
    mov r15, r13
    imul r15, r15, TS_SIZE
    add r15, [rbx+VC_TESTS]
    mov byte [rdi], 't'
    inc rdi
    wdec r13
    emit ": dq "
    xor r14d, r14d
.arg:
    test r14, r14
    jz .a1
    emit ", "
.a1:
    cmp r14, [r15+TS_NARG]
    jb .have
    mov byte [rdi], '0'
    inc rdi
    jmp .anext
.have:
    mov rax, r14
    imul rax, rax, 24
    cmp qword [r15+TS_ARG+rax], 1
    je .alab
    mov rax, [r15+TS_ARG+rax+8]
    whex rax
    jmp .anext
.alab:
    mov byte [rdi], 't'
    inc rdi
    wdec r13
    mov byte [rdi], 'a'
    inc rdi
    wdec r14
.anext:
    inc r14
    cmp r14, 4
    jb .arg
    cmp qword [r15+TS_HASRET], 0
    je .noret
    emit ", 1, "
    whex [r15+TS_RET]
    jmp .nchk
.noret:
    emit ", 0, 0"
.nchk:
    emit ", "
    wdec [r15+TS_NCHK]
    xor r14d, r14d
.chk:
    cmp r14, [r15+TS_NCHK]
    jae .rend
    mov rax, r14
    imul rax, rax, 24
    lea rax, [r15+TS_CHK+rax]
    mov [rsp+32], rax
    emit ", t"
    wdec r13
    mov byte [rdi], 'a'
    inc rdi
    mov rax, [rsp+32]
    wdec [rax]
    emit ", t"
    wdec r13
    mov byte [rdi], 'e'
    inc rdi
    wdec r14
    emit ", "
    mov rax, [rsp+32]
    wdec [rax+16]
    inc r14
    jmp .chk
.rend:
    mov byte [rdi], 10
    inc rdi
    inc r13
    jmp .rec
.exp:
    ; the expected bytes, still in .rdata
    xor r13d, r13d
.e1:
    cmp r13, r12
    jae .data
    mov r15, r13
    imul r15, r15, TS_SIZE
    add r15, [rbx+VC_TESTS]
    xor r14d, r14d
.e2:
    cmp r14, [r15+TS_NCHK]
    jae .e3
    mov byte [rdi], 't'
    inc rdi
    wdec r13
    mov byte [rdi], 'e'
    inc rdi
    wdec r14
    emit ": "
    mov rax, r14
    imul rax, rax, 24
    mov rsi, [r15+TS_CHK+rax+8]
    mov rcx, [r15+TS_CHK+rax+16]
    call wdb
    mov byte [rdi], 10
    inc rdi
    inc r14
    jmp .e2
.e3:
    inc r13
    jmp .e1
.data:
    ; the argument buffers, writable, with room to spare after each
    emit "section .data", 10
    xor r13d, r13d
.d1:
    cmp r13, r12
    jae .end
    mov r15, r13
    imul r15, r15, TS_SIZE
    add r15, [rbx+VC_TESTS]
    xor r14d, r14d
.d2:
    cmp r14, [r15+TS_NARG]
    jae .d3
    mov rax, r14
    imul rax, rax, 24
    cmp qword [r15+TS_ARG+rax], 1
    jne .d4
    emit "align 16", 10, "t"
    wdec r13
    mov byte [rdi], 'a'
    inc rdi
    wdec r14
    emit ": "
    mov rax, r14
    imul rax, rax, 24
    mov rsi, [r15+TS_ARG+rax+8]
    mov rcx, [r15+TS_ARG+rax+16]
    call wdb
    emit 10, "times 64 db 0", 10
.d4:
    inc r14
    jmp .d2
.d3:
    inc r13
    jmp .d1
.end:
    mov rax, rdi
    sub rax, [rbx+VC_FILE]
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
