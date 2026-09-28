; download fineweb FIRST LAST [jobs]    shards FIRST..LAST of karpathy/fineweb-edu-100b-shuffle
; download smoltalk FIRST LAST [jobs]   train files FIRST..LAST (0-8) of HuggingFaceTB/smoltalk
; download chat FIRST LAST [jobs]       train files FIRST..LAST (0-3) of HuggingFaceTB/smol-smoltalk
; download chattest 0 0                 its test file
; into datasets\fineweb or datasets\smoltalk. each file lands as .tmp and gets
; renamed once it's all there, and files that already exist are skipped, so
; just run it again after a failure. jobs = parallel downloads, default 4
; libs: winhttp.lib
default rel
bits 64
%include "lib.inc"

extern WinHttpOpen, WinHttpConnect, WinHttpOpenRequest, WinHttpSendRequest
extern WinHttpReceiveResponse, WinHttpQueryHeaders, WinHttpReadData, WinHttpCloseHandle
extern ExitProcess

BUFSZ equ 1 << 20

; per thread
T_APATH equ 0                   ; url path, ascii
T_WPATH equ 512                 ; same, utf-16 for winhttp
T_DEST  equ 1536
T_TMP   equ 2048
T_BUF   equ 2560
T_GOT   equ 2568
T_SIZE  equ 2624

section .rdata
host     dw __?utf16?__("huggingface.co"), 0
agent    dw __?utf16?__("Mnemonic/1.0"), 0
verb     dw __?utf16?__("GET"), 0
fw_url   db "/datasets/karpathy/fineweb-edu-100b-shuffle/resolve/main/shard_", 0
fw_dir   db "datasets\fineweb", 0
fw_dest  db "datasets\fineweb\shard_", 0
fw_ext   db ".parquet", 0
st_url   db "/datasets/HuggingFaceTB/smoltalk/resolve/main/data/all/train-", 0
st_dir   db "datasets\smoltalk", 0
st_dest  db "datasets\smoltalk\train-", 0
st_ext   db "-of-00009.parquet", 0
ch_url   db "/datasets/HuggingFaceTB/smol-smoltalk/resolve/main/data/train-", 0
ch_dir   db "datasets\chat", 0
ch_dest  db "datasets\chat\train-", 0
ch_ext   db "-of-00004.parquet", 0
cht_url  db "/datasets/HuggingFaceTB/smol-smoltalk/resolve/main/data/test-", 0
cht_dest db "datasets\chat\test-", 0
cht_ext  db "-of-00001.parquet", 0
ds_dir   db "datasets", 0
s_tmp    db ".tmp", 0
m_done   db "got  ", 0
m_have   db "have ", 0
m_fail   db "FAILED ", 0
usage    db "usage: download fineweb|smoltalk FIRST LAST [jobs]", 13, 10, 0
e_http   db "WinHttpOpen failed", 0
align 8
c_half   dq 0.5
c_mb     dq 1e-6

section .bss
alignb 8
tstate   resb T_SIZE * 64
session  resq 1
url_pre  resq 1
dest_pre resq 1
ext      resq 1
first    resq 1
total    resq 1
done     resq 1
failed   resq 1
got      resq 1
t0       resq 1
last     resq 1
plock    resd 1

section .text

global start
start:
    sub rsp, 40
    call lib_init
    cmp qword [argc], 4
    jae .args
.usage:
    lea rcx, [usage]
    call print_z
    mov ecx, 1
    call ExitProcess
.args:
    lea rcx, [ds_dir]
    call make_dir
    mov rax, [argv+8]
    cmp dword [rax], 'fine'
    je .fw
    cmp dword [rax], 'chat'
    je .chat
    cmp dword [rax], 'smol'
    jne .usage
    lea rax, [st_url]
    mov [url_pre], rax
    lea rax, [st_dest]
    mov [dest_pre], rax
    lea rax, [st_ext]
    mov [ext], rax
    lea rcx, [st_dir]
    call make_dir
    jmp .range
.chat:
    lea rcx, [ch_url]
    lea rdx, [ch_dest]
    lea r8, [ch_ext]
    cmp byte [rax+4], 't'       ; chattest: the one test file
    jne .ch
    lea rcx, [cht_url]
    lea rdx, [cht_dest]
    lea r8, [cht_ext]
.ch:
    mov [url_pre], rcx
    mov [dest_pre], rdx
    mov [ext], r8
    lea rcx, [ch_dir]
    call make_dir
    jmp .range
.fw:
    lea rax, [fw_url]
    mov [url_pre], rax
    lea rax, [fw_dest]
    mov [dest_pre], rax
    lea rax, [fw_ext]
    mov [ext], rax
    lea rcx, [fw_dir]
    call make_dir
.range:
    mov rcx, [argv+16]
    call parse_int
    mov [first], rax
    mov rcx, [argv+24]
    call parse_int
    sub rax, [first]
    inc rax
    mov [total], rax
    mov ebx, 4
    cmp qword [argc], 5
    jb .jobs
    mov rcx, [argv+32]
    call parse_int
    mov ebx, eax
.jobs:
    mov ecx, ebx
    call pool_init
    xor esi, esi
.bufs:
    cmp rsi, [nthreads]
    jae .open
    mov ecx, BUFSZ
    call mem_alloc
    imul rcx, rsi, T_SIZE
    lea rdx, [tstate]
    mov [rdx+rcx+T_BUF], rax
    inc esi
    jmp .bufs
.open:
    lea rcx, [agent]
    mov edx, 4                  ; WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 0
    call WinHttpOpen
    test rax, rax
    jnz .session
    lea rcx, [e_http]
    call fatal
.session:
    mov [session], rax
    call time_now
    mov [t0], rax
    lea rcx, [task]
    xor edx, edx
    mov r8, [total]
    mov r9d, 1
    call par_for
    mov qword [last], 0
    call status
    say 13, 10
    mov rcx, [done]
    call print_dec
    say " ok, "
    mov rcx, [failed]
    call print_dec
    say " failed", 13, 10
    mov rcx, [session]
    call WinHttpCloseHandle
    call con_restore
    mov rcx, [failed]
    call ExitProcess

; par_for callback: files rdx..r8 of the range, r9 = thread
task:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rdx
    mov rsi, r8
    mov rdi, r9
.next:
    cmp rbx, rsi
    jae .done
    mov rcx, rbx
    add rcx, [first]
    mov rdx, rdi
    call get_one
    inc rbx
    jmp .next
.done:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx, rdx = dst buffer, prefix. appends prefix + 5 digit index + extension
%macro name 2
    lea rcx, [rbx+%1]
    mov rdx, [%2]
    call fmt_str
    mov rcx, rax
    mov rdx, r12
    mov r8d, 5
    call fmt_dec0
    mov rcx, rax
    mov rdx, [ext]
    call fmt_str
    mov byte [rax], 0
%endmacro

; rcx = file index, rdx = thread
get_one:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov r12, rcx
    imul rbx, rdx, T_SIZE
    lea rax, [tstate]
    add rbx, rax
    name T_DEST, dest_pre
    lea rcx, [rbx+T_DEST]
    call file_exists
    test eax, eax
    jz .fetch
    lock inc qword [done]
    lea rcx, [m_have]
    lea rdx, [rbx+T_DEST]
    mov r8, -1
    call note
    jmp .ret
.fetch:
    lea rcx, [rbx+T_TMP]
    lea rdx, [rbx+T_DEST]
    call fmt_str
    mov rcx, rax
    lea rdx, [s_tmp]
    call fmt_str
    mov byte [rax], 0
    name T_APATH, url_pre
    lea rcx, [rbx+T_WPATH]
    lea rdx, [rbx+T_APATH]
    call widen
    mov r13d, 3                 ; tries
.try:
    mov rcx, rbx
    call fetch
    test eax, eax
    jnz .ok
    dec r13d
    jnz .try
    lock inc qword [failed]
    lea rcx, [m_fail]
    lea rdx, [rbx+T_DEST]
    mov r8, -1
    call note
    jmp .ret
.ok:
    lock inc qword [done]
    lea rcx, [m_done]
    lea rdx, [rbx+T_DEST]
    mov r8, [rbx+T_GOT]
    call note
.ret:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; locals for fetch
F_STATUS equ 56
F_LEN    equ 64
F_N      equ 72

; one attempt at a download. rcx = thread state. eax = 1 if the file is complete
fetch:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80
    mov rbx, rcx
    xor r12d, r12d              ; connection
    xor r13d, r13d              ; request
    mov r14, -1                 ; file
    xor r15d, r15d              ; bytes so far
    mov rcx, [session]
    lea rdx, [host]
    mov r8d, 443
    xor r9d, r9d
    call WinHttpConnect
    test rax, rax
    jz .fail
    mov r12, rax
    mov rcx, r12
    lea rdx, [verb]
    lea r8, [rbx+T_WPATH]
    xor r9d, r9d
    mov qword [rsp+32], 0
    mov qword [rsp+40], 0
    mov qword [rsp+48], 0x00800000      ; WINHTTP_FLAG_SECURE
    call WinHttpOpenRequest
    test rax, rax
    jz .fail
    mov r13, rax
    mov rcx, r13
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 0
    mov qword [rsp+40], 0
    mov qword [rsp+48], 0
    call WinHttpSendRequest
    test eax, eax
    jz .fail
    mov rcx, r13
    xor edx, edx
    call WinHttpReceiveResponse         ; redirects to the cdn get followed in here
    test eax, eax
    jz .fail
    mov dword [rsp+F_STATUS], 0
    mov dword [rsp+F_N], 4
    mov rcx, r13
    mov edx, 19 | 0x20000000            ; STATUS_CODE as a number
    xor r8d, r8d
    lea r9, [rsp+F_STATUS]
    lea rax, [rsp+F_N]
    mov [rsp+32], rax
    mov qword [rsp+40], 0
    call WinHttpQueryHeaders
    test eax, eax
    jz .fail
    cmp dword [rsp+F_STATUS], 200
    jne .fail
    mov qword [rsp+F_LEN], -1
    mov dword [rsp+F_N], 8
    mov rcx, r13
    mov edx, 5 | 0x08000000             ; CONTENT_LENGTH as a 64-bit number
    xor r8d, r8d
    lea r9, [rsp+F_LEN]
    lea rax, [rsp+F_N]
    mov [rsp+32], rax
    mov qword [rsp+40], 0
    call WinHttpQueryHeaders            ; fine if it's missing
    lea rcx, [rbx+T_TMP]
    call file_create
    cmp rax, -1
    je .fail
    mov r14, rax
.read:
    mov dword [rsp+F_N], 0
    mov rcx, r13
    mov rdx, [rbx+T_BUF]
    mov r8d, BUFSZ
    lea r9, [rsp+F_N]
    call WinHttpReadData
    test eax, eax
    jz .fail
    mov esi, [rsp+F_N]
    test esi, esi
    jz .eof
    mov rcx, r14
    mov rdx, [rbx+T_BUF]
    mov r8, rsi
    call file_write
    test eax, eax
    jz .fail
    add r15, rsi
    lock add [got], rsi
    call status
    jmp .read
.eof:
    mov rax, [rsp+F_LEN]
    cmp rax, -1
    je .whole
    cmp r15, rax
    jne .fail                   ; connection dropped early
.whole:
    mov rcx, r14
    call file_close
    mov r14, -1
    lea rcx, [rbx+T_TMP]
    lea rdx, [rbx+T_DEST]
    call file_replace
    test eax, eax
    jz .fail
    mov [rbx+T_GOT], r15
    mov eax, 1
    jmp .close
.fail:
    lock sub [got], r15         ; don't count what we're throwing away
    xor eax, eax
.close:
    mov [rsp+F_STATUS], eax
    cmp r14, -1
    je .nofile
    mov rcx, r14
    call file_close
    lea rcx, [rbx+T_TMP]
    call file_delete
.nofile:
    test r13, r13
    jz .noreq
    mov rcx, r13
    call WinHttpCloseHandle
.noreq:
    test r12, r12
    jz .noconn
    mov rcx, r12
    call WinHttpCloseHandle
.noconn:
    mov eax, [rsp+F_STATUS]
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = utf-16 dst, rdx = ascii src
widen:
    movzx eax, byte [rdx]
    mov [rcx], ax
    inc rdx
    add rcx, 2
    test eax, eax
    jnz widen
    ret

; the one line status, redrawn in place every half second by whoever gets there
status:
    push rbx
    sub rsp, 48
    cmp dword [con_tty], 0
    je .ret
    mov rcx, [last]
    call time_since
    comisd xmm0, [c_half]
    jb .ret
    lock bts dword [plock], 0
    jc .ret                     ; someone else is printing, skip it
    call time_now
    mov [last], rax
    say 13, "  "
    mov rcx, [done]
    add rcx, [failed]
    call print_dec
    say "/"
    mov rcx, [total]
    call print_dec
    say " files   "
    mov rdx, [got]
    lea rcx, [rsp+32]
    call fmt_count
    mov byte [rax], 'B'
    inc rax
    lea rcx, [rsp+32]
    mov rdx, rax
    sub rdx, rcx
    call print
    say "   "
    mov rcx, [t0]
    call time_since
    cvtsi2sd xmm1, qword [got]
    divsd xmm1, xmm0
    mulsd xmm1, [c_mb]
    movapd xmm0, xmm1
    mov edx, 1
    call print_fixed
    say " MB/s", 27, "[K"
    mov dword [plock], 0
.ret:
    add rsp, 48
    pop rbx
    ret

; rcx = what happened, rdx = path, r8 = bytes or -1. one line, above the status
note:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
.lock:
    lock bts dword [plock], 0
    jnc .locked
    pause
    jmp .lock
.locked:
    cmp dword [con_tty], 0
    je .text
    say 13, 27, "[K"
.text:
    mov rcx, rbx
    call print_z
    mov rcx, rsi
    call print_z
    cmp rdi, -1
    je .eol
    say "  "
    mov rcx, rdi
    call print_dec
    say " bytes"
.eol:
    say 13, 10
    mov dword [plock], 0
    mov qword [last], 0         ; redraw the status right away
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret
