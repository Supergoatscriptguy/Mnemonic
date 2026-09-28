; pqcat file column [count] [rowgroup | all]
; decodes one column chunk and prints its first entries as  rep def | value.
; with "all" it decodes every row group instead and reports totals and speed
; uses: data\parquet data\snappy data\zstd
default rel
bits 64
%include "lib.inc"
%include "data/parquet.inc"

extern ExitProcess

section .rdata
usage   db "usage: pqcat file column [count] [rowgroup | all]", 13, 10, 0
e_open  db "can't open that file", 0
e_col   db "no such column", 0
k_all   db "all", 0

section .bss
alignb 8
pq      resb PQ_SIZEOF
ar      resb ARENA_SIZE
col     resb COL_SIZE
count   resq 1
rg      resq 1
colidx  resq 1
line    resb 128

section .text

global start
start:
    sub rsp, 40
    call lib_init
    cmp qword [argc], 3
    jae .go
    lea rcx, [usage]
    call print_z
    mov ecx, 1
    call ExitProcess
.go:
    mov qword [count], 10
    cmp qword [argc], 4
    jb .open
    mov rcx, [argv+24]
    call parse_int
    mov [count], rax
    cmp qword [argc], 5
    jb .open
    mov rcx, [argv+32]
    cmp dword [rcx], 'all'
    je .all
    call parse_int
    mov [rg], rax
.open:
    call setup

    lea rcx, [pq]
    lea rdx, [col]
    mov r8, [rg]
    mov r9, [colidx]
    call pq_chunk

    mov rcx, [argv+16]
    call print_z
    say ", row group "
    mov rcx, [rg]
    call print_dec
    say ": "
    mov rcx, [col+COL_N]
    call print_dec
    say " entries, "
    mov rcx, [col+COL_NV]
    call print_dec
    say " values", 13, 10, "  rep def | value", 13, 10

    ; rbx = entry, rsi = value index
    xor ebx, ebx
    xor esi, esi
.entry:
    cmp rbx, [count]
    jae .end
    cmp rbx, [col+COL_N]
    jae .end
    say "  "
    xor ecx, ecx
    mov rax, [col+COL_REP]
    test rax, rax
    jz .r
    mov ecx, [rax+rbx*4]
.r:
    call print_dec
    say "   "
    lea rax, [pq]                ; max def, to know if this entry has a value
    mov r12, [colidx]
    imul r12, r12, LF_SIZE
    add r12, [pq+PQ_LEAF]
    mov r13d, [r12+LF_MAXDEF]   ; no def levels means everything's there
    mov ecx, r13d
    mov rax, [col+COL_DEF]
    test rax, rax
    jz .d
    mov ecx, [rax+rbx*4]
.d:
    mov r14d, ecx
    call print_dec
    say " | "
    cmp r14d, r13d
    jne .null
    ; value, cut short and with control chars blanked
    mov rax, [col+COL_VALS]
    mov rdx, rsi
    shl rdx, 4
    mov r8, [rax+rdx]
    mov r9, [rax+rdx+8]
    inc rsi
    cmp r9, 100
    jbe .cp
    mov r9d, 100
.cp:
    lea rdi, [line]
    xor ecx, ecx
.ch:
    cmp rcx, r9
    jae .show
    mov al, [r8+rcx]
    cmp al, 32
    jae .keep
    mov al, ' '
.keep:
    mov [rdi+rcx], al
    inc rcx
    jmp .ch
.show:
    lea rcx, [line]
    mov rdx, r9
    call print
    jmp .eol
.null:
    say "(null)"
.eol:
    say 13, 10
    inc rbx
    jmp .entry

.all:
    call setup
    call time_now
    mov r15, rax
    xor r12d, r12d              ; row group
    xor r13d, r13d              ; entries
    xor r14d, r14d              ; values
    xor edi, edi                ; value bytes
.rg:
    cmp r12, [pq+PQ_NRG]
    jae .alldone
    lea rcx, [ar]
    call arena_reset
    lea rcx, [pq]
    lea rdx, [col]
    mov r8, r12
    mov r9, [colidx]
    call pq_chunk
    add r13, [col+COL_N]
    mov rcx, [col+COL_NV]
    add r14, rcx
    mov rax, [col+COL_VALS]
.sum:
    test rcx, rcx
    jz .summed
    add rdi, [rax+8]
    add rax, 16
    dec rcx
    jmp .sum
.summed:
    inc r12
    jmp .rg
.alldone:
    mov rcx, r15
    call time_since
    movapd xmm6, xmm0
    mov rcx, [argv+16]
    call print_z
    say ", all "
    mov rcx, [pq+PQ_NRG]
    call print_dec
    say " row groups: "
    mov rcx, r13
    call print_dec
    say " entries, "
    mov rcx, r14
    call print_dec
    say " values, "
    mov rcx, rdi
    call print_dec
    say " bytes", 13, 10, "  "
    movapd xmm0, xmm6
    mov edx, 3
    call print_fixed
    say " s, "
    cvtsi2sd xmm0, rdi
    divsd xmm0, xmm6
    mov rax, 1000000
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    mov edx, 1
    call print_fixed
    say " MB/s of values (one thread)", 13, 10
.end:
    lea rcx, [pq]
    call pq_close
    call con_restore
    xor ecx, ecx
    call ExitProcess

; opens argv[1], finds column argv[2], sets up the arena and zstd context
setup:
    sub rsp, 40
    lea rcx, [pq]
    mov rdx, [argv+8]
    call pq_open
    test eax, eax
    jnz .opened
    lea rcx, [e_open]
    call fatal
.opened:
    lea rcx, [pq]
    mov rdx, [argv+16]
    call pq_leaf
    cmp rax, -1
    jne .found
    lea rcx, [e_col]
    call fatal
.found:
    mov [colidx], rax
    lea rcx, [ar]
    mov rdx, 1 << 34            ; 16 GB of address space, only what's used gets committed
    call arena_init
    lea rax, [ar]
    mov [col+COL_ARENA], rax
    mov ecx, ZSTD_CTX
    call mem_alloc
    mov [col+COL_ZSTD], rax
    mov rcx, rax
    call zstd_init
    add rsp, 40
    ret
