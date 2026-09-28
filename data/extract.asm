; extract file.parquet ...: turns each parquet file into a .docs file next to it.
; a "text" column (fineweb) gives one doc per row. a messages list with content
; and role (smoltalk) gives one doc per message, grouped into conversations.
; row groups get decoded in parallel, every doc is checked for valid utf-8
; uses: data\parquet data\snappy data\zstd
default rel
bits 64
%include "lib.inc"
%include "data/parquet.inc"
%include "data/docs.inc"

extern ExitProcess

; per thread
W_SCRATCH equ 0                 ; arena, reset for every row group
W_OUT     equ 32                ; arena, holds this file's text until it's written
W_COL     equ 64
W_COL2    equ 128
W_SIZE    equ 192

; per row group
RR_TEXT   equ 0
RR_BYTES  equ 8
RR_NDOCS  equ 16
RR_LENS   equ 24                ; u32 per doc
RR_ROLES  equ 32                ; u8 per doc
RR_NCONV  equ 40
RR_CONVN  equ 48                ; u32 messages per conversation
RR_ROWS   equ 56
RR_BAD    equ 64                ; docs that weren't valid utf-8
RR_SIZE   equ 72

section .rdata
k_text    db "text", 0
k_content db "messages.list.element.content", 0
k_role    db "messages.list.element.role", 0
usage     db "usage: extract file.parquet ...", 13, 10, 0
e_open    db "can't open the parquet file", 0
e_what    db "no text column or messages list in this file", 0
e_write   db "couldn't write the .docs file", 0
e_mism    db "content and role columns don't line up", 0
s_docs    db ".docs", 0
s_tmp     db ".tmp", 0

section .bss
alignb 8
pq       resb PQ_SIZEOF
workers  resb W_SIZE * 64
rgres    resq 1
mode     resq 1                 ; 0 text, 1 chat
ccol     resq 1
rcol     resq 1
t0       resq 1
tdec     resq 1                 ; seconds spent decoding, the rest is writing
; totals for the current file
ndocs    resq 1
nconv    resq 1
nbytes   resq 1
nrows    resq 1
nbad     resq 1
outpath  resb 1024
tmppath  resb 1024

section .text

global start
start:
    sub rsp, 40
    call lib_init
    cmp qword [argc], 2
    jae .go
    lea rcx, [usage]
    call print_z
    mov ecx, 1
    call ExitProcess
.go:
    xor ecx, ecx
    call pool_init
    ; every thread gets two arenas and its own zstd context
    xor ebx, ebx
.w:
    cmp rbx, [nthreads]
    jae .wdone
    imul rdi, rbx, W_SIZE
    lea rax, [workers]
    add rdi, rax
    lea rcx, [rdi+W_SCRATCH]
    mov rdx, 1 << 34
    call arena_init
    lea rcx, [rdi+W_OUT]
    mov rdx, 1 << 34
    call arena_init
    mov ecx, ZSTD_CTX
    call mem_alloc
    mov [rdi+W_COL+COL_ZSTD], rax
    mov [rdi+W_COL2+COL_ZSTD], rax
    mov rcx, rax
    call zstd_init
    lea rax, [rdi+W_SCRATCH]
    mov [rdi+W_COL+COL_ARENA], rax
    mov [rdi+W_COL2+COL_ARENA], rax
    inc ebx
    jmp .w
.wdone:
    mov r12d, 1
.file:
    cmp r12, [argc]
    jae .done
    lea rax, [argv]
    mov rcx, [rax+r12*8]
    call extract
    inc r12
    jmp .file
.done:
    call con_restore
    xor ecx, ecx
    call ExitProcess

; rcx = parquet path
extract:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    lea rcx, [pq]
    mov rdx, rsi
    call pq_open
    test eax, eax
    jnz .opened
    lea rcx, [e_open]
    call fatal
.opened:
    lea rcx, [pq]
    lea rdx, [k_text]
    call pq_leaf
    cmp rax, -1
    je .chat
    mov [ccol], rax
    mov qword [mode], 0
    jmp .go
.chat:
    lea rcx, [pq]
    lea rdx, [k_content]
    call pq_leaf
    cmp rax, -1
    je .what
    mov [ccol], rax
    lea rcx, [pq]
    lea rdx, [k_role]
    call pq_leaf
    cmp rax, -1
    je .what
    mov [rcol], rax
    mov qword [mode], 1
.go:
    xor ebx, ebx
.reset:
    cmp rbx, [nthreads]
    jae .reset1
    imul rcx, rbx, W_SIZE
    lea rax, [workers+W_OUT]
    add rcx, rax
    call arena_reset
    inc ebx
    jmp .reset
.reset1:
    mov rcx, [pq+PQ_NRG]
    imul rcx, rcx, RR_SIZE
    call mem_alloc
    mov [rgres], rax
    call time_now
    mov [t0], rax
    lea rcx, [rg_task]
    xor edx, edx
    mov r8, [pq+PQ_NRG]
    mov r9d, 1
    call par_for
    mov rcx, [t0]
    call time_since
    movsd [tdec], xmm0

    mov rcx, rsi
    call write_docs

    ; report
    mov rcx, rsi
    call print_z
    say 13, 10, "  -> "
    lea rcx, [outpath]
    call print_z
    say "   "
    cmp qword [mode], 0
    je .rdocs
    mov rcx, [nconv]
    call print_dec
    say " conversations, "
    mov rcx, [ndocs]
    call print_dec
    say " messages, "
    jmp .rbytes
.rdocs:
    mov rcx, [ndocs]
    call print_dec
    say " docs, "
.rbytes:
    mov rcx, [nbytes]
    call print_count_b
    say ", "
    mov rcx, [t0]
    call time_since
    movsd [rsp+32], xmm0        ; xmm6+ are callee-saved, so the stack it is
    mov edx, 3
    call print_fixed
    say " s ("
    cvtsi2sd xmm0, qword [nbytes]
    divsd xmm0, [rsp+32]
    mov rax, 1000000000
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    mov edx, 2
    call print_fixed
    say " GB/s, decode "
    movsd xmm0, [tdec]
    mov edx, 3
    call print_fixed
    say " s)", 13, 10
    mov rax, [nrows]
    cmp rax, [pq+PQ_ROWS]
    je .rowsok
    say "  WARNING: row count doesn't match the footer", 13, 10
.rowsok:
    cmp qword [nbad], 0
    jne .bad
    say "  all valid utf-8", 13, 10
    jmp .close
.bad:
    say "  WARNING: "
    mov rcx, [nbad]
    call print_dec
    say " docs aren't valid utf-8", 13, 10
.close:
    mov rcx, [rgres]
    call mem_free
    lea rcx, [pq]
    call pq_close
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.what:
    lea rcx, [e_what]
    call fatal

; rcx = count, printed like 255MB
print_count_b:
    sub rsp, 72
    mov rdx, rcx
    lea rcx, [rsp+32]
    call fmt_count
    mov byte [rax], 'B'
    inc rax
    lea rcx, [rsp+32]
    mov rdx, rax
    sub rdx, rcx
    call print
    add rsp, 72
    ret

; par_for callback: rdx..r8 = row groups, r9 = thread
rg_task:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rdx
    mov rsi, r8
    imul rdi, r9, W_SIZE
    lea rax, [workers]
    add rdi, rax
.next:
    cmp rbx, rsi
    jae .done
    mov rcx, rdi
    mov rdx, rbx
    call do_rg
    inc rbx
    jmp .next
.done:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; locals for do_rg
D_CONV  equ 32                  ; current conversation, -1 before the first
D_TEXT  equ 40                  ; where the next message's text goes
D_ROWS  equ 48
D_DEF   equ 56
D_BAD   equ 64

; rcx = worker, rdx = row group
do_rg:
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72
    mov rdi, rcx
    mov r12, rdx
    lea rcx, [rdi+W_SCRATCH]
    call arena_reset
    imul r13, r12, RR_SIZE
    add r13, [rgres]
    lea rcx, [pq]
    lea rdx, [rdi+W_COL]
    mov r8, r12
    mov r9, [ccol]
    call pq_chunk

    ; room for the text: every value's bytes
    mov rcx, [rdi+W_COL+COL_VALS]
    mov rdx, [rdi+W_COL+COL_NV]
    xor r15d, r15d
.sum:
    test rdx, rdx
    jz .summed
    add r15, [rcx+8]
    add rcx, 16
    dec rdx
    jmp .sum
.summed:
    mov [r13+RR_BYTES], r15
    lea rcx, [rdi+W_OUT]
    lea rdx, [r15+16]
    mov r8d, 16
    call arena_alloc
    mov [r13+RR_TEXT], rax
    mov r14, [rdi+W_COL+COL_N]
    lea rcx, [rdi+W_OUT]
    lea rdx, [r14*4+16]
    mov r8d, 16
    call arena_alloc
    mov [r13+RR_LENS], rax
    cmp qword [mode], 0
    jne .chat

    ; plain text: every non-null row is a doc
    mov [r13+RR_ROWS], r14
    mov rbx, [rdi+W_COL+COL_NV]
    mov [r13+RR_NDOCS], rbx
    mov qword [r13+RR_NCONV], 0
    mov rsi, [rdi+W_COL+COL_VALS]
    mov r14, [r13+RR_TEXT]
    mov r15, [r13+RR_LENS]
    xor ebp, ebp
.doc:
    test rbx, rbx
    jz .textdone
    mov rcx, r14
    mov rdx, [rsi]
    mov r8, [rsi+8]
    mov [r15], r8d
    add r14, r8
    call copy_one
    xor eax, 1
    add rbp, rax
    add rsi, 16
    add r15, 4
    dec rbx
    jmp .doc
.textdone:
    mov [r13+RR_BAD], rbp
    jmp .done

.chat:
    lea rcx, [pq]
    lea rdx, [rdi+W_COL2]
    mov r8, r12
    mov r9, [rcol]
    call pq_chunk
    cmp r14, [rdi+W_COL2+COL_N]
    jne .mismatch
    lea rcx, [rdi+W_OUT]
    lea rdx, [r14+16]
    mov r8d, 16
    call arena_alloc
    mov [r13+RR_ROLES], rax
    lea rcx, [rdi+W_OUT]
    lea rdx, [r14*4+16]
    mov r8d, 16
    call arena_alloc
    mov [r13+RR_CONVN], rax

    ; walk the level entries. rep 0 starts a row (conversation). def 3 or more
    ; means the list element exists, def 4 means its field is non-null too
    xor ebx, ebx                ; entry
    xor esi, esi                ; content value
    xor ebp, ebp                ; role value
    xor r15d, r15d              ; messages
    mov qword [rsp+D_CONV], -1
    mov rax, [r13+RR_TEXT]
    mov [rsp+D_TEXT], rax
    mov qword [rsp+D_ROWS], 0
    mov qword [rsp+D_BAD], 0
.e:
    cmp rbx, r14
    jae .edone
    mov rax, [rdi+W_COL+COL_REP]
    cmp dword [rax+rbx*4], 0
    jne .same
    inc qword [rsp+D_ROWS]
    mov rax, [rsp+D_CONV]
    cmp rax, -1
    je .newc
    mov rcx, [r13+RR_CONVN]
    cmp dword [rcx+rax*4], 0
    je .same                    ; last one came out empty, reuse its slot
.newc:
    inc rax
    mov [rsp+D_CONV], rax
    mov rcx, [r13+RR_CONVN]
    mov dword [rcx+rax*4], 0
.same:
    mov rax, [rdi+W_COL+COL_DEF]
    mov eax, [rax+rbx*4]
    mov [rsp+D_DEF], rax
    cmp eax, 3
    jb .nextent
    mov r8d, ROLE_OTHER
    mov rax, [rdi+W_COL2+COL_DEF]
    cmp dword [rax+rbx*4], 4
    jne .norole
    mov rax, [rdi+W_COL2+COL_VALS]
    mov rcx, rbp
    shl rcx, 4
    mov r9, [rax+rcx]
    mov r10, [rax+rcx+8]
    inc rbp
    call rolecode
.norole:
    mov rax, [r13+RR_ROLES]
    mov [rax+r15], r8b
    xor r8d, r8d                ; content length, 0 if null
    cmp qword [rsp+D_DEF], 4
    jne .store
    mov rax, [rdi+W_COL+COL_VALS]
    mov rcx, rsi
    shl rcx, 4
    mov rdx, [rax+rcx]
    mov r8, [rax+rcx+8]
    inc rsi
    mov rcx, [rsp+D_TEXT]
    add [rsp+D_TEXT], r8
    mov [rsp+D_DEF], r8         ; done with def, keep the length
    call copy_one
    xor eax, 1
    add [rsp+D_BAD], rax
    mov r8, [rsp+D_DEF]
.store:
    mov rax, [r13+RR_LENS]
    mov [rax+r15*4], r8d
    mov rax, [r13+RR_CONVN]
    mov rcx, [rsp+D_CONV]
    inc dword [rax+rcx*4]
    inc r15
.nextent:
    inc rbx
    jmp .e
.edone:
    mov rax, [rsp+D_CONV]
    inc rax                     ; conversations
    jz .nc
    mov rcx, [r13+RR_CONVN]
    cmp dword [rcx+rax*4-4], 0
    jne .nc
    dec rax                     ; drop a trailing empty one
.nc:
    mov [r13+RR_NCONV], rax
    mov [r13+RR_NDOCS], r15
    mov rax, [rsp+D_ROWS]
    mov [r13+RR_ROWS], rax
    mov rax, [rsp+D_BAD]
    mov [r13+RR_BAD], rax
    ; the text actually used (null contents take nothing)
    mov rax, [rsp+D_TEXT]
    sub rax, [r13+RR_TEXT]
    mov [r13+RR_BYTES], rax
.done:
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
.mismatch:
    lea rcx, [e_mism]
    call fatal

; r9 = role string, r10 = its length. r8d = role code. touches nothing else
rolecode:
    mov r8d, ROLE_OTHER
    cmp r10, 4
    jne .n4
    cmp dword [r9], 'user'
    jne .ret
    mov r8d, ROLE_USER
    ret
.n4:
    cmp r10, 6
    jne .n6
    cmp dword [r9], 'syst'
    jne .ret
    cmp word [r9+4], 'em'
    jne .ret
    mov r8d, ROLE_SYSTEM
    ret
.n6:
    cmp r10, 9
    jne .ret
    mov rax, 'assistan'
    cmp [r9], rax
    jne .ret
    cmp byte [r9+8], 't'
    jne .ret
    mov r8d, ROLE_ASSIST
.ret:
    ret

; rcx = dst, rdx = src, r8 = len. copies it, eax = 1 if it was valid utf-8
copy_one:
    push rbx
    push rsi
    push rdi
    mov rdi, rcx
    mov rsi, rdx
    mov rbx, r8
    mov rcx, rdx
    mov rdx, r8
    call utf8_ok
    mov rcx, rbx
    rep movsb
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = text, rdx = len. eax = 1 if it's valid utf-8 (structure only, no overlong/surrogate checks)
utf8_ok:
    lea r8, [rcx+rdx]
    mov r10, 0x8080808080808080
.ascii:
    lea rax, [rcx+8]
    cmp rax, r8
    ja .tail
    test [rcx], r10
    jnz .tail
    add rcx, 8
    jmp .ascii
.tail:
    cmp rcx, r8
    jae .ok
    movzx eax, byte [rcx]
    inc rcx
    cmp eax, 0x80
    jb .ascii
    cmp eax, 0xc2
    jb .no                      ; stray continuation byte, or overlong 2 byte
    mov edx, 1
    cmp eax, 0xe0
    jb .cont
    inc edx
    cmp eax, 0xf0
    jb .cont
    inc edx
    cmp eax, 0xf5
    jae .no
.cont:
    cmp rcx, r8
    jae .no
    movzx eax, byte [rcx]
    and eax, 0xc0
    cmp eax, 0x80
    jne .no
    inc rcx
    dec edx
    jnz .cont
    jmp .ascii
.ok:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; builds the index (header, offsets, roles, conversations) and writes it plus
; every row group's text. temp file then rename. rcx = parquet path
write_docs:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    ; output name: swap the extension for .docs
    mov rdx, rcx
    lea rcx, [outpath]
    call fmt_str
    mov rcx, rax
.dot:
    dec rcx
    lea rdx, [outpath]
    cmp rcx, rdx
    jb .noext
    cmp byte [rcx], '\'
    je .noext
    cmp byte [rcx], '/'
    je .noext
    cmp byte [rcx], '.'
    jne .dot
    mov rax, rcx
.noext:
    mov rcx, rax
    lea rdx, [s_docs]
    call fmt_str
    mov byte [rax], 0
    lea rcx, [tmppath]
    lea rdx, [outpath]
    call fmt_str
    mov rcx, rax
    lea rdx, [s_tmp]
    call fmt_str
    mov byte [rax], 0

    ; totals
    xor eax, eax
    mov [ndocs], rax
    mov [nconv], rax
    mov [nbytes], rax
    mov [nrows], rax
    mov [nbad], rax
    mov rsi, [rgres]
    mov rbx, [pq+PQ_NRG]
.tot:
    test rbx, rbx
    jz .totd
    mov rax, [rsi+RR_NDOCS]
    add [ndocs], rax
    mov rax, [rsi+RR_NCONV]
    add [nconv], rax
    mov rax, [rsi+RR_BYTES]
    add [nbytes], rax
    mov rax, [rsi+RR_ROWS]
    add [nrows], rax
    mov rax, [rsi+RR_BAD]
    add [nbad], rax
    add rsi, RR_SIZE
    dec rbx
    jmp .tot
.totd:
    ; layout: r12 = roles, r13 = convs, r14 = text (file offsets)
    mov rax, [ndocs]
    lea r12, [DH_SIZE+rax*8+8]
    xor r13d, r13d
    mov r14, r12
    cmp qword [mode], 0
    je .layout
    lea r13, [r12+rax+7]
    and r13, -8
    mov rax, [nconv]
    lea r14, [r13+rax*8+8]
.layout:
    mov rcx, r14
    call mem_alloc
    mov r15, rax                ; the whole index, zeroed

    mov rax, DOCS_MAGIC
    mov [r15+DH_MAGIC], rax
    mov rax, [ndocs]
    mov [r15+DH_NDOCS], rax
    mov rax, [nconv]
    mov [r15+DH_NCONV], rax
    mov rax, [nbytes]
    mov [r15+DH_BYTES], rax
    mov qword [r15+DH_OFFS], DH_SIZE
    mov [r15+DH_TEXT], r14
    cmp qword [mode], 0
    je .offs
    mov [r15+DH_ROLES], r12
    mov [r15+DH_CONVS], r13

.offs:
    ; doc offsets: running sum of lengths across row groups
    lea rdi, [r15+DH_SIZE]
    xor edx, edx
    mov rsi, [rgres]
    mov rbx, [pq+PQ_NRG]
.org:
    test rbx, rbx
    jz .oend
    mov r8, [rsi+RR_LENS]
    mov r9, [rsi+RR_NDOCS]
.od:
    test r9, r9
    jz .onext
    mov [rdi], rdx
    add rdi, 8
    mov eax, [r8]
    add rdx, rax
    add r8, 4
    dec r9
    jmp .od
.onext:
    add rsi, RR_SIZE
    dec rbx
    jmp .org
.oend:
    mov [rdi], rdx
    cmp qword [mode], 0
    je .write

    ; roles, straight copies
    lea rdi, [r15+r12]
    mov rsi, [rgres]
    mov rbx, [pq+PQ_NRG]
.rr:
    test rbx, rbx
    jz .convs
    push rsi
    mov rcx, [rsi+RR_NDOCS]
    mov rsi, [rsi+RR_ROLES]
    rep movsb
    pop rsi
    add rsi, RR_SIZE
    dec rbx
    jmp .rr
.convs:
    ; conversation starts: running sum of message counts
    lea rdi, [r15+r13]
    xor edx, edx
    mov rsi, [rgres]
    mov rbx, [pq+PQ_NRG]
.crg:
    test rbx, rbx
    jz .cend
    mov r8, [rsi+RR_CONVN]
    mov r9, [rsi+RR_NCONV]
.cc:
    test r9, r9
    jz .cnext
    mov [rdi], rdx
    add rdi, 8
    mov eax, [r8]
    add rdx, rax
    add r8, 4
    dec r9
    jmp .cc
.cnext:
    add rsi, RR_SIZE
    dec rbx
    jmp .crg
.cend:
    mov [rdi], rdx

.write:
    lea rcx, [tmppath]
    call file_create
    cmp rax, -1
    je .fail
    mov rbx, rax
    mov rcx, rbx
    mov rdx, r15
    mov r8, r14
    call file_write
    test eax, eax
    jz .fail
    mov rsi, [rgres]
    mov rdi, [pq+PQ_NRG]
.wt:
    test rdi, rdi
    jz .wdone
    mov rcx, rbx
    mov rdx, [rsi+RR_TEXT]
    mov r8, [rsi+RR_BYTES]
    call file_write
    test eax, eax
    jz .fail
    add rsi, RR_SIZE
    dec rdi
    jmp .wt
.wdone:
    mov rcx, rbx
    call file_flush
    mov rcx, rbx
    call file_close
    lea rcx, [tmppath]
    lea rdx, [outpath]
    call file_replace
    test eax, eax
    jz .fail
    mov rcx, r15
    call mem_free
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.fail:
    lea rcx, [e_write]
    call fatal
