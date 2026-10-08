; stage 2 test: snappy, rle/bit-packed and zstd on hand-made inputs, then the
; real datasets if they've been downloaded (numbers checked against the footers
; and the first rows on huggingface)
; uses: data\parquet data\snappy data\zstd
default rel
bits 64
%include "lib.inc"
%include "data/parquet.inc"
%include "test/check.inc"

section .rdata
sn1      db 0x05, 0x10, "hello"
sn1_len  equ $ - sn1
sn2      db 0x0c, 0x08, "abc", 0x15, 0x03           ; literal abc, then copy 9 from 3 back
sn2_len  equ $ - sn2
sn3      db 0x06, 0x08, "xyz", 0x0a, 0x03, 0x00     ; 2 byte offset copy
sn3_len  equ $ - sn3
sn4      db 0x0c, 0x08, "abc", 0x15, 0x09           ; reaches back past the start (room for it, so only that check can catch it)
sn4_len  equ $ - sn4
s_hello  db "hello"
s_abc    db "abcabcabcabc"
s_xyz    db "xyzxyz"

rl1      db 0x03, 0xb2                  ; width 1, one packed group
rl1_x    dd 0, 1, 0, 0, 1, 1, 0, 1
rl2      db 0x0a, 0x02                  ; width 2, rle run of five 2s
rl2_x    dd 2, 2, 2, 2, 2
rl3      db 0x03, 0x88, 0xc6, 0xfa      ; width 3, 0..7 packed (the example from the spec)
rl3_x    dd 0, 1, 2, 3, 4, 5, 6, 7
rl4      db 0x06, 0x01, 0x03, 0xe4, 0xe4 ; width 2: three 1s, then 0 1 2 3 0 1 2 3
rl4_x    dd 1, 1, 1, 0, 1, 2, 3, 0, 1, 2, 3

zs1      db 0x28, 0xb5, 0x2f, 0xfd, 0x20, 10    ; single segment, 1 byte content size
         db 0x28, 0, 0, "hello"                 ; raw block
         db 0x2b, 0, 0, "!"                     ; rle block, last
zs1_len  equ $ - zs1
zs2      db 0x28, 0xb5, 0x2f, 0xfd, 0x20, 11    ; claims 11 bytes, has 10
         db 0x28, 0, 0, "hello", 0x2b, 0, 0, "!"
zs2_len  equ $ - zs2
zs3      db 0x28, 0xb5, 0x2f, 0xfd, 0x20, 10    ; a compressed block (last, 5 bytes) whose
         db 0x2d, 0, 0                          ; rle literals say 0xfffff bytes, past 128K
         db 0xfd, 0xff, 0xff, "x", 0            ; (then no sequences)
zs3_len  equ $ - zs3
s_zs     db "hello!!!!!"

fw       db "datasets\fineweb\shard_00000.parquet", 0
st       db "datasets\smoltalk\test-00000-of-00001.parquet", 0
k_text   db "text", 0
k_cont   db "messages.list.element.content", 0
k_role   db "messages.list.element.role", 0
fw_first db "Shipment & Transport-Sea, Air, Rail, Road, Pipeline", 10, "The mode"
fw_flen  equ $ - fw_first
st_first db "I am concerned my lack of a college degree"
st_flen  equ $ - st_first

section .bss
alignb 16
outbuf   resb 256
u32buf   resd 64
alignb 8
pq       resb PQ_SIZEOF
ar       resb ARENA_SIZE
col      resb COL_SIZE
zctx     resq 1

section .text

; snappy on %1 (length %2) must give exactly %3 (length %4)
%macro snap 5+
    lea rcx, [outbuf]
    mov edx, 200
    lea r8, [%1]
    mov r9d, %2
    call snappy_decompress
    mov rbx, rax
    cmp rax, %4
    jne %%bad
    lea rsi, [outbuf]
    lea rdi, [%3]
    mov ecx, %4
    repe cmpsb
%%bad:
    check e, %5
%endmacro

; rle_decode of %1 at width %2 must give the %3 values at %4
%macro rle 5+
    lea rcx, [%1]
    mov edx, 16
    mov r8d, %2
    lea r9, [u32buf]
    mov qword [rsp+32], %3
    call rle_decode
    lea rsi, [u32buf]
    lea rdi, [%4]
    mov ecx, %3
    repe cmpsd
    check e, %5
%endmacro

; rbx = string of length r8 must start with the %1 bytes at %2
%macro starts 3+
    xor eax, eax
    cmp r8, %2
    jb %%no
    mov rsi, rbx
    lea rdi, [%1]
    mov ecx, %2
    repe cmpsb
%%no:
    check e, %3
%endmacro

global start
start:
    sub rsp, 40
    call lib_init

    say "snappy", 13, 10
    snap sn1, sn1_len, s_hello, 5, "literal"
    snap sn2, sn2_len, s_abc, 12, "overlapping 1 byte offset copy"
    snap sn3, sn3_len, s_xyz, 6, "2 byte offset copy"
    lea rcx, [outbuf]
    mov edx, 200
    lea r8, [sn4]
    mov r9d, sn4_len
    call snappy_decompress
    cmp rax, -1
    check e, "rejects a copy from before the start"

    say "rle / bit-packed", 13, 10
    rle rl1, 1, 8, rl1_x, "width 1, bit-packed"
    rle rl2, 2, 5, rl2_x, "width 2, rle run"
    rle rl3, 3, 8, rl3_x, "width 3, 0..7 packed"
    rle rl4, 2, 11, rl4_x, "rle run then a packed group"

    say "zstd", 13, 10
    mov ecx, ZSTD_CTX
    call mem_alloc
    mov [zctx], rax
    mov rcx, rax
    call zstd_init
    mov rcx, [zctx]
    lea rdx, [outbuf]
    mov r8d, 200
    lea r9, [zs1]
    mov qword [rsp+32], zs1_len
    call zstd_decompress
    cmp rax, 10
    jne .zbad
    lea rsi, [outbuf]
    lea rdi, [s_zs]
    mov ecx, 10
    repe cmpsb
.zbad:
    check e, "raw + rle blocks"
    mov rcx, [zctx]
    lea rdx, [outbuf]
    mov r8d, 200
    lea r9, [zs2]
    mov qword [rsp+32], zs2_len
    call zstd_decompress
    cmp rax, -1
    check e, "rejects a frame that isn't its stated size"
    mov rcx, [zctx]
    lea rdx, [outbuf]
    mov r8d, 200
    lea r9, [zs3]
    mov qword [rsp+32], zs3_len
    call zstd_decompress
    cmp rax, -1
    check e, "rejects rle literals bigger than 128K"

    lea rcx, [ar]
    mov rdx, 1 << 34
    call arena_init
    lea rax, [ar]
    mov [col+COL_ARENA], rax
    mov rax, [zctx]
    mov [col+COL_ZSTD], rax

    lea rcx, [fw]
    call file_exists
    test eax, eax
    jnz .fineweb
    say "  (no fineweb shard 0, skipping. bin\download.exe fineweb 0 0)", 13, 10
    jmp .smol
.fineweb:
    say "fineweb shard 0 (zstd)", 13, 10
    lea rcx, [pq]
    lea rdx, [fw]
    call pq_open
    cmp qword [pq+PQ_ROWS], 53248
    check e, "footer: 53248 rows"
    cmp qword [pq+PQ_NRG], 52
    check e, "footer: 52 row groups"
    mov rax, [pq+PQ_RG]
    mov rax, [rax+RG_COLS]
    cmp dword [rax+CC_CODEC], C_ZSTD
    check e, "codec is zstd"
    mov rax, [pq+PQ_LEAF]
    cmp dword [rax+LF_MAXDEF], 1
    check e, "text: def 1, rep 0"
    lea rcx, [pq]
    lea rdx, [col]
    xor r8d, r8d
    xor r9d, r9d
    call pq_chunk
    mov rax, [col+COL_VALS]
    mov rbx, [rax]
    mov r8, [rax+8]
    starts fw_first, fw_flen, "first doc matches huggingface's first row"
    ; every row group: total text bytes
    xor r12d, r12d
    xor r13d, r13d
.fwrg:
    cmp r12, [pq+PQ_NRG]
    jae .fwsum
    lea rcx, [ar]
    call arena_reset
    lea rcx, [pq]
    lea rdx, [col]
    mov r8, r12
    xor r9d, r9d
    call pq_chunk
    mov rcx, [col+COL_NV]
    mov rax, [col+COL_VALS]
.fwv:
    add r13, [rax+8]
    add rax, 16
    dec rcx
    jnz .fwv
    inc r12
    jmp .fwrg
.fwsum:
    mov rax, 254737840
    cmp r13, rax
    check e, "all 52 row groups: 254737840 bytes of text"
    lea rcx, [pq]
    call pq_close

.smol:
    lea rcx, [st]
    call file_exists
    test eax, eax
    jnz .smoltalk
    say "  (no smoltalk test file, skipping)", 13, 10
    jmp t_done
.smoltalk:
    say "smoltalk test (snappy, dictionaries, nested lists)", 13, 10
    lea rcx, [ar]
    call arena_reset
    lea rcx, [pq]
    lea rdx, [st]
    call pq_open
    lea rcx, [pq]
    lea rdx, [k_cont]
    call pq_leaf
    mov r14, rax
    imul rax, rax, LF_SIZE
    add rax, [pq+PQ_LEAF]
    cmp dword [rax+LF_MAXDEF], 4
    jne .lv
    cmp dword [rax+LF_MAXREP], 1
.lv:
    check e, "content: def 4, rep 1"
    lea rcx, [pq]
    lea rdx, [col]
    xor r8d, r8d
    mov r9, r14
    call pq_chunk
    mov rax, [col+COL_VALS]
    mov rbx, [rax]
    mov r8, [rax+8]
    starts st_first, st_flen, "first message matches"
    mov rax, [col+COL_REP]
    cmp dword [rax], 0
    jne .rp
    cmp dword [rax+4], 1
.rp:
    check e, "rep levels: 0 starts a conversation, 1 continues it"
    lea rcx, [pq]
    lea rdx, [k_role]
    call pq_leaf
    mov r9, rax
    lea rcx, [pq]
    lea rdx, [col]
    xor r8d, r8d
    call pq_chunk
    mov rax, [col+COL_VALS]
    mov rbx, [rax]
    cmp dword [rbx], 'user'
    check e, "first role (from the dictionary) is user"
    lea rcx, [pq]
    call pq_close
    jmp t_done
