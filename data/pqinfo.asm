; pqinfo file.parquet: dumps a parquet footer. schema, leaf columns with their
; levels, codecs, encodings and sizes
; uses: data\parquet data\snappy data\zstd
default rel
bits 64
%include "lib.inc"
%include "data/parquet.inc"

extern ExitProcess

section .rdata
align 8
types    dq t0, t1, t2, t3, t4, t5, t6, t7
reps     dq r0, r1, r2
codecs   dq c0, c1, c2, c3, c4, c5, c6, c7
encs     dq e0, e1, e2, e3, e4, e5, e6, e7, e8, e9
t0 db "BOOLEAN", 0
t1 db "INT32", 0
t2 db "INT64", 0
t3 db "INT96", 0
t4 db "FLOAT", 0
t5 db "DOUBLE", 0
t6 db "BYTE_ARRAY", 0
t7 db "FIXED_LEN_BYTE_ARRAY", 0
r0 db "required", 0
r1 db "optional", 0
r2 db "repeated", 0
c0 db "UNCOMPRESSED", 0
c1 db "SNAPPY", 0
c2 db "GZIP", 0
c3 db "LZO", 0
c4 db "BROTLI", 0
c5 db "LZ4", 0
c6 db "ZSTD", 0
c7 db "LZ4_RAW", 0
e0 db "PLAIN", 0
e1 db "GROUP_VAR_INT", 0
e2 db "PLAIN_DICTIONARY", 0
e3 db "RLE", 0
e4 db "BIT_PACKED", 0
e5 db "DELTA_BINARY_PACKED", 0
e6 db "DELTA_LENGTH_BYTE_ARRAY", 0
e7 db "DELTA_BYTE_ARRAY", 0
e8 db "RLE_DICTIONARY", 0
e9 db "BYTE_STREAM_SPLIT", 0
usage db "usage: pqinfo file.parquet", 13, 10, 0
e_open db "can't open that file", 0

section .bss
alignb 8
pq      resb PQ_SIZEOF
enc     resq 1
csum    resq 1
usum    resq 1
vsum    resq 1

section .text

; rcx = name table, rdx = entries, r8 = index. prints the name, or ?n
name:
    sub rsp, 40
    cmp r8, rdx
    jae .unk
    mov rcx, [rcx+r8*8]
    call print_z
    add rsp, 40
    ret
.unk:
    mov [rsp+48], r8
    say "?"
    mov rcx, [rsp+48]
    call print_dec
    add rsp, 40
    ret

; rcx = byte count, printed like 94.5M
bytes:
    sub rsp, 40
    call print_count_
    say "B"
    add rsp, 40
    ret

; print_count via fmt_count
print_count_:
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
    lea rcx, [pq]
    mov rdx, [argv+8]
    call pq_open
    test eax, eax
    jnz .opened
    lea rcx, [e_open]
    call fatal
.opened:
    mov rcx, [argv+8]
    call print_z
    say "  "
    mov rcx, [pq+PQ_SIZE]
    call bytes
    say 13, 10, "created by: "
    mov rcx, [pq+PQ_CREATED]
    mov rdx, [pq+PQ_CREATEDLEN]
    call print
    say 13, 10, "rows: "
    mov rcx, [pq+PQ_ROWS]
    call print_dec
    say "   row groups: "
    mov rcx, [pq+PQ_NRG]
    call print_dec
    say 13, 10, 13, 10, "schema", 13, 10

    ; rbx = element, r12 = count left
    mov rbx, [pq+PQ_SCHEMA]
    mov r12, [pq+PQ_NSCHEMA]
.se:
    test r12, r12
    jz .leaves
    say "  "
    mov r13d, [rbx+SE_DEPTH]
.indent:
    test r13d, r13d
    jz .sename
    say "  "
    dec r13d
    jmp .indent
.sename:
    mov rcx, [rbx+SE_NAME]
    mov rdx, [rbx+SE_NLEN]
    call print
    say "  "
    cmp dword [rbx+SE_TYPE], -1
    jne .setype
    say "group"
    jmp .serep
.setype:
    lea rcx, [types]
    mov edx, 8
    mov r8d, [rbx+SE_TYPE]
    call name
.serep:
    cmp dword [rbx+SE_DEPTH], 0
    je .seconv                  ; the root has no repetition
    say " "
    lea rcx, [reps]
    mov edx, 3
    mov r8d, [rbx+SE_REP]
    call name
.seconv:
    cmp dword [rbx+SE_CONV], 0
    jne .conv2
    say " (UTF8)"
.conv2:
    cmp dword [rbx+SE_CONV], 3
    jne .conv3
    say " (LIST)"
.conv3:
    say 13, 10
    add rbx, SE_SIZE
    dec r12
    jmp .se

.leaves:
    say 13, 10, "leaf columns (max def / rep levels)", 13, 10
    mov rbx, [pq+PQ_LEAF]
    mov r12, [pq+PQ_NCOL]
.lf:
    test r12, r12
    jz .cols
    say "  "
    mov rcx, [rbx+LF_PATH]
    call print_z
    say "  def "
    mov ecx, [rbx+LF_MAXDEF]
    call print_dec
    say " rep "
    mov ecx, [rbx+LF_MAXREP]
    call print_dec
    say 13, 10
    add rbx, LF_SIZE
    dec r12
    jmp .lf

.cols:
    ; per column, summed over every row group
    say 13, 10, "column chunks, all row groups", 13, 10
    xor r12d, r12d              ; column index
.col:
    cmp r12, [pq+PQ_NCOL]
    jae .rgs
    xor eax, eax
    mov [enc], rax
    mov [csum], rax
    mov [usum], rax
    mov [vsum], rax
    mov rsi, [pq+PQ_RG]
    mov r13, [pq+PQ_NRG]
    imul rdi, r12, CC_SIZE
.sum:
    test r13, r13
    jz .print
    mov rax, [rsi+RG_COLS]
    add rax, rdi
    mov rcx, [rax+CC_ENC]
    or [enc], rcx
    mov rcx, [rax+CC_CSIZE]
    add [csum], rcx
    mov rcx, [rax+CC_USIZE]
    add [usum], rcx
    mov rcx, [rax+CC_NVAL]
    add [vsum], rcx
    add rsi, RG_SIZE
    dec r13
    jmp .sum
.print:
    say "  "
    imul rax, r12, LF_SIZE
    add rax, [pq+PQ_LEAF]
    mov rcx, [rax+LF_PATH]
    call print_z
    say 13, 10, "    codec "
    mov rax, [pq+PQ_RG]
    mov rax, [rax+RG_COLS]
    add rax, rdi
    lea rcx, [codecs]
    mov edx, 8
    mov r8d, [rax+CC_CODEC]
    call name
    say "   values "
    mov rcx, [vsum]
    call print_dec
    say "   compressed "
    mov rcx, [csum]
    call bytes
    say "   raw "
    mov rcx, [usum]
    call bytes
    say 13, 10, "    encodings"
    xor r13d, r13d
.enc:
    cmp r13d, 10
    jae .encd
    bt qword [enc], r13
    jnc .enc1
    say " "
    lea rcx, [encs]
    mov edx, 10
    mov r8, r13
    call name
.enc1:
    inc r13d
    jmp .enc
.encd:
    say 13, 10
    inc r12
    jmp .col

.rgs:
    ; first few row groups, to see how the file is laid out
    say 13, 10, "first row groups (rows, then per column: dict page @ data page)", 13, 10
    mov rsi, [pq+PQ_RG]
    mov r13, [pq+PQ_NRG]
    cmp r13, 3
    jbe .rg
    mov r13d, 3
.rg:
    test r13, r13
    jz .end
    say "  rows "
    mov rcx, [rsi+RG_ROWS]
    call print_dec
    mov rdi, [rsi+RG_COLS]
    mov r12, [pq+PQ_NCOL]
.rgc:
    test r12, r12
    jz .rgn
    say "   "
    mov rcx, [rdi+CC_DICT]
    call print_dec
    say " @ "
    mov rcx, [rdi+CC_DATA]
    call print_dec
    add rdi, CC_SIZE
    dec r12
    jmp .rgc
.rgn:
    say 13, 10
    add rsi, RG_SIZE
    dec r13
    jmp .rg
.end:
    lea rcx, [pq]
    call pq_close
    call con_restore
    xor ecx, ecx
    call ExitProcess
