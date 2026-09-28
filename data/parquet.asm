; parquet reader. the file gets memory mapped, the footer (thrift compact
; protocol) gets parsed into plain structs, see parquet.inc
default rel
bits 64
%include "lib.inc"
%include "data/parquet.inc"

MAXDEPTH equ 32

section .rdata
e_magic  db "not a parquet file", 0
e_deep   db "parquet schema nested too deep", 0
e_codec  db "parquet: unsupported codec", 0
e_enc    db "parquet: unsupported value encoding", 0
e_size   db "parquet: page didn't decompress to its stated size", 0
e_vals   db "parquet: values run past the end of the page", 0
e_rle    db "parquet: bad rle/bit-packed data", 0
e_dict   db "parquet: bad dictionary index", 0
e_count  db "parquet: level count doesn't match the column chunk", 0

section .bss
alignb 8
pq_cur   resq 1                 ; file being parsed, its arena is where allocations go
; schema walk: one record per depth
stk      resb MAXDEPTH * 32
ST_LEFT  equ 0                  ; children still to come
ST_DEF   equ 8
ST_REP   equ 12
ST_PLEN  equ 16                 ; path length up to here
pathbuf  resb 4096

section .text

; ---- thrift compact protocol. rsi is the read cursor, these only touch rax, rcx, rdx

; unsigned varint
varint:
    xor eax, eax
    xor ecx, ecx
.more:
    movzx edx, byte [rsi]
    inc rsi
    and edx, 0x7f
    shl rdx, cl
    or rax, rdx
    add ecx, 7
    test byte [rsi-1], 0x80
    jnz .more
    ret

; zigzag varint, for i16/i32/i64
zz:
    call varint
    mov rdx, rax
    shr rax, 1
    and edx, 1
    neg rdx
    xor rax, rdx
    ret

; binary/string. rax = ptr, rcx = len
bin:
    call varint
    mov rcx, rax
    mov rax, rsi
    add rsi, rcx
    ret

; ecx = previous field id. returns eax = type (0 = end of struct), ecx = field id
fieldhdr:
    movzx eax, byte [rsi]
    inc rsi
    test eax, eax
    jz .ret
    mov edx, eax
    shr edx, 4                  ; id delta, 0 means the id follows in full
    and eax, 15
    test edx, edx
    jz .long
    add ecx, edx
.ret:
    ret
.long:
    push rax
    call zz
    mov ecx, eax
    pop rax
    ret

; returns eax = element type, rcx = count
listhdr:
    movzx eax, byte [rsi]
    inc rsi
    mov ecx, eax
    shr ecx, 4
    and eax, 15
    cmp ecx, 15
    jne .ret
    push rax
    call varint
    mov rcx, rax
    pop rax
.ret:
    ret

; skip a value of type eax
skip:
    cmp eax, 3
    jb .ret                     ; bool, the value was in the type nibble
    je .byte
    cmp eax, 6
    jbe varint                  ; i16/i32/i64
    cmp eax, 7
    je .dbl
    cmp eax, 8
    je .bin
    cmp eax, 11
    jb .list                    ; list or set
    je .map
.struct:
    xor ecx, ecx                ; ids don't matter when skipping
    call fieldhdr
    test eax, eax
    jz .ret
    call skip
    jmp .struct
.byte:
    inc rsi
    ret
.dbl:
    add rsi, 8
    ret
.bin:
    call varint
    add rsi, rax
    ret
.list:
    call listhdr
.lnext:
    test rcx, rcx
    jz .ret
    push rcx
    push rax
    call skip_elem
    pop rax
    pop rcx
    dec rcx
    jmp .lnext
.map:
    call varint
    test rax, rax
    jz .ret
    mov rcx, rax
    movzx eax, byte [rsi]       ; key type << 4 | value type
    inc rsi
.mnext:
    push rcx
    push rax
    shr eax, 4
    call skip_elem
    mov eax, [rsp]
    and eax, 15
    call skip_elem
    pop rax
    pop rcx
    dec rcx
    jnz .mnext
.ret:
    ret

; inside lists and maps, bools take a whole byte
skip_elem:
    cmp eax, 3
    ja skip
    inc rsi
    ret

; ---- struct parsers. rdi = struct to fill, rbx = last field id

%macro enter_p 0
    push rbx
    push rdi
    push r12
    push r13
    sub rsp, 40
    mov [rsp+32], rdi
    xor ebx, ebx
%endmacro

%macro leave_p 0
    add rsp, 40
    pop r13
    pop r12
    pop rdi
    pop rbx
    ret
%endmacro

; next field: ebx = its id, eax = type, jumps to %1 at the end of the struct
%macro nextfield 1
    mov ecx, ebx
    call fieldhdr
    mov ebx, ecx
    test eax, eax
    jz %1
%endmacro

%macro on 2                     ; field id, label
    cmp ebx, %1
    je %2
%endmacro

; rcx = bytes, zeroed, from the current file's arena
alloc:
    sub rsp, 40
    mov rdx, rcx
    mov rcx, [pq_cur]           ; PQ_ARENA is at 0
    mov r8d, 16
    call arena_alloc
    add rsp, 40
    ret

p_schema:
    enter_p
    mov dword [rdi+SE_TYPE], -1
    mov dword [rdi+SE_CONV], -1
.f:
    nextfield .done
    on 1, .type
    on 3, .rep
    on 4, .name
    on 5, .nch
    on 6, .conv
    call skip
    jmp .f
.type:
    call zz
    mov [rdi+SE_TYPE], eax
    jmp .f
.rep:
    call zz
    mov [rdi+SE_REP], eax
    jmp .f
.name:
    call bin
    mov [rdi+SE_NAME], rax
    mov [rdi+SE_NLEN], rcx
    jmp .f
.nch:
    call zz
    mov [rdi+SE_NCHILD], eax
    jmp .f
.conv:
    call zz
    mov [rdi+SE_CONV], eax
    jmp .f
.done:
    leave_p

p_colmeta:
    enter_p
.f:
    nextfield .done
    on 1, .type
    on 2, .enc
    on 4, .codec
    on 5, .nval
    on 6, .usize
    on 7, .csize
    on 9, .data
    on 11, .dict
    call skip
    jmp .f
.type:
    call zz
    mov [rdi+CC_TYPE], eax
    jmp .f
.enc:
    call listhdr
    mov r12, rcx
.enc1:
    test r12, r12
    jz .f
    call zz
    and eax, 63
    bts [rdi+CC_ENC], rax
    dec r12
    jmp .enc1
.codec:
    call zz
    mov [rdi+CC_CODEC], eax
    jmp .f
.nval:
    call zz
    mov [rdi+CC_NVAL], rax
    jmp .f
.usize:
    call zz
    mov [rdi+CC_USIZE], rax
    jmp .f
.csize:
    call zz
    mov [rdi+CC_CSIZE], rax
    jmp .f
.data:
    call zz
    mov [rdi+CC_DATA], rax
    jmp .f
.dict:
    call zz
    mov [rdi+CC_DICT], rax
    jmp .f
.done:
    leave_p

p_colchunk:
    enter_p
.f:
    nextfield .done
    on 3, .meta
    call skip
    jmp .f
.meta:
    call p_colmeta
    jmp .f
.done:
    leave_p

p_rowgroup:
    enter_p
.f:
    nextfield .done
    on 1, .cols
    on 3, .rows
    call skip
    jmp .f
.rows:
    call zz
    mov [rdi+RG_ROWS], rax
    jmp .f
.cols:
    call listhdr
    mov r12, rcx
    imul rcx, rcx, CC_SIZE
    call alloc
    mov [rdi+RG_COLS], rax
    mov r13, rax
.col1:
    test r12, r12
    jz .f
    mov rdi, r13
    call p_colchunk
    mov rdi, [rsp+32]
    add r13, CC_SIZE
    dec r12
    jmp .col1
.done:
    leave_p

; rdi = pq
p_filemeta:
    enter_p
.f:
    nextfield .done
    on 2, .schema
    on 3, .rows
    on 4, .rgs
    on 6, .created
    call skip
    jmp .f
.rows:
    call zz
    mov [rdi+PQ_ROWS], rax
    jmp .f
.created:
    call bin
    mov [rdi+PQ_CREATED], rax
    mov [rdi+PQ_CREATEDLEN], rcx
    jmp .f
.schema:
    call listhdr
    mov [rdi+PQ_NSCHEMA], rcx
    mov r12, rcx
    imul rcx, rcx, SE_SIZE
    call alloc
    mov [rdi+PQ_SCHEMA], rax
    mov r13, rax
.se1:
    test r12, r12
    jz .f
    mov rdi, r13
    call p_schema
    mov rdi, [rsp+32]
    add r13, SE_SIZE
    dec r12
    jmp .se1
.rgs:
    call listhdr
    mov [rdi+PQ_NRG], rcx
    mov r12, rcx
    imul rcx, rcx, RG_SIZE
    call alloc
    mov [rdi+PQ_RG], rax
    mov r13, rax
.rg1:
    test r12, r12
    jz .f
    mov rdi, r13
    call p_rowgroup
    mov rdi, [rsp+32]
    add r13, RG_SIZE
    dec r12
    jmp .rg1
.done:
    leave_p

; walks the schema to find the leaf columns. elements come depth first and
; num_children says how many of the following ones belong to a group.
; max def level = optional/repeated nodes on the way down, max rep = repeated ones
; rdi = pq
leaves:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rcx, [rdi+PQ_NSCHEMA]
    imul rcx, rcx, LF_SIZE
    call alloc
    mov [rdi+PQ_LEAF], rax
    mov rsi, rax                ; next leaf to fill
    mov rbx, [rdi+PQ_SCHEMA]
    lea r12, [stk]              ; top of the depth stack
    mov eax, [rbx+SE_NCHILD]
    mov [r12+ST_LEFT], rax
    xor eax, eax
    mov [r12+ST_DEF], eax
    mov [r12+ST_REP], eax
    mov [r12+ST_PLEN], rax
    mov dword [rbx+SE_DEPTH], 0
    mov r13d, 1
.next:
    cmp r13, [rdi+PQ_NSCHEMA]
    jae .done
    add rbx, SE_SIZE
    inc r13
.pop:
    cmp qword [r12+ST_LEFT], 0
    jne .have
    sub r12, 32
    jmp .pop
.have:
    dec qword [r12+ST_LEFT]
    mov rax, r12
    lea rcx, [stk]
    sub rax, rcx
    shr eax, 5
    inc eax
    mov [rbx+SE_DEPTH], eax
    mov eax, [r12+ST_DEF]
    mov edx, [r12+ST_REP]
    mov ecx, [rbx+SE_REP]
    test ecx, ecx
    jz .levels
    inc eax
    cmp ecx, 2
    jne .levels
    inc edx
.levels:
    mov [rsp+32], eax
    mov [rsp+36], edx
    ; path = parent path + "." + name
    lea r8, [pathbuf]
    add r8, [r12+ST_PLEN]
    cmp qword [r12+ST_PLEN], 0
    je .name
    mov byte [r8], '.'
    inc r8
.name:
    mov r9, [rbx+SE_NAME]
    mov rcx, [rbx+SE_NLEN]
.copy:
    test rcx, rcx
    jz .copied
    mov al, [r9]
    mov [r8], al
    inc r8
    inc r9
    dec rcx
    jmp .copy
.copied:
    mov byte [r8], 0
    lea rax, [pathbuf]
    sub r8, rax                 ; path length
    cmp dword [rbx+SE_NCHILD], 0
    je .leaf
    add r12, 32                 ; a group: go down a level
    lea rax, [stk + (MAXDEPTH-1)*32]
    cmp r12, rax
    jae .deep
    mov eax, [rbx+SE_NCHILD]
    mov [r12+ST_LEFT], rax
    mov eax, [rsp+32]
    mov [r12+ST_DEF], eax
    mov eax, [rsp+36]
    mov [r12+ST_REP], eax
    mov [r12+ST_PLEN], r8
    jmp .next
.leaf:
    mov [rsp+40], r8
    lea rcx, [r8+1]
    call alloc
    mov [rsi+LF_PATH], rax
    mov rcx, [rsp+40]
    inc rcx
    lea rdx, [pathbuf]
.lcopy:
    mov r8b, [rdx]
    mov [rax], r8b
    inc rax
    inc rdx
    dec rcx
    jnz .lcopy
    mov [rsi+LF_SE], rbx
    mov eax, [rsp+32]
    mov [rsi+LF_MAXDEF], eax
    mov eax, [rsp+36]
    mov [rsi+LF_MAXREP], eax
    add rsi, LF_SIZE
    inc qword [rdi+PQ_NCOL]
    jmp .next
.done:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.deep:
    lea rcx, [e_deep]
    call fatal

; rcx = pq struct (PQ_SIZEOF bytes), rdx = path. eax = 1 if it opened
global pq_open
pq_open:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rdi, rcx
    mov rbx, rdx
    mov [pq_cur], rdi
    xor eax, eax                ; start clean, the struct may have held another file
    mov ecx, PQ_SIZEOF / 8
    rep stosq
    mov rdi, [pq_cur]
    mov rcx, rdi
    mov edx, 1 << 30            ; just address space, commits as it fills
    call arena_init
    mov rcx, rbx
    call file_map
    test rax, rax
    jz .fail
    mov [rdi+PQ_BASE], rax
    mov [rdi+PQ_SIZE], rdx
    cmp rdx, 12
    jb .bad
    cmp dword [rax], 'PAR1'
    jne .bad
    cmp dword [rax+rdx-4], 'PAR1'
    jne .bad
    ; ... footer, then its length (4 bytes), then PAR1
    mov ecx, [rax+rdx-8]
    lea rsi, [rax+rdx-8]
    sub rsi, rcx
    call p_filemeta
    call leaves
    mov eax, 1
    jmp .done
.bad:
    lea rcx, [e_magic]
    call fatal
.fail:
    xor eax, eax
.done:
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = pq
global pq_close
pq_close:
    push rbx
    sub rsp, 32
    mov rbx, rcx
    mov rcx, [rbx+PQ_BASE]
    call file_unmap
    mov rcx, [rbx+PQ_ARENA+AR_BASE]
    call mem_free
    add rsp, 32
    pop rbx
    ret

; rcx = pq, rdx = dotted column path. rax = leaf index, -1 if there's no such column
global pq_leaf
pq_leaf:
    mov r8, [rcx+PQ_LEAF]
    mov r9, [rcx+PQ_NCOL]
    xor eax, eax
.next:
    cmp rax, r9
    jae .none
    mov r10, [r8+LF_PATH]
    xor r11d, r11d
.cmp:
    mov cl, [rdx+r11]
    cmp cl, [r10+r11]
    jne .skip
    inc r11
    test cl, cl
    jnz .cmp
    ret
.skip:
    add r8, LF_SIZE
    inc rax
    jmp .next
.none:
    mov rax, -1
    ret

; ---- pages

; rdi = PH
p_pagehdr:
    enter_p
.f:
    nextfield .done
    on 1, .type
    on 2, .usize
    on 3, .csize
    on 5, .v1
    on 7, .dict
    on 8, .v2
    call skip
    jmp .f
.type:
    call zz
    mov [rdi+PH_TYPE], eax
    jmp .f
.usize:
    call zz
    mov [rdi+PH_USIZE], eax
    jmp .f
.csize:
    call zz
    mov [rdi+PH_CSIZE], eax
    jmp .f
.v1:
    call p_dph
    jmp .f
.dict:
    call p_dph                  ; same first two fields: num_values, encoding
    jmp .f
.v2:
    call p_dph2
    jmp .f
.done:
    leave_p

p_dph:
    enter_p
.f:
    nextfield .done
    on 1, .nval
    on 2, .enc
    call skip
    jmp .f
.nval:
    call zz
    mov [rdi+PH_NVAL], eax
    jmp .f
.enc:
    call zz
    mov [rdi+PH_ENC], eax
    jmp .f
.done:
    leave_p

p_dph2:
    enter_p
.f:
    nextfield .done
    on 1, .nval
    on 2, .nnull
    on 3, .nrows
    on 4, .enc
    on 5, .deflen
    on 6, .replen
    on 7, .comp
    call skip
    jmp .f
.nval:
    call zz
    mov [rdi+PH_NVAL], eax
    jmp .f
.nnull:
    call zz
    mov [rdi+PH_NNULL], eax
    jmp .f
.nrows:
    call zz
    mov [rdi+PH_NROWS], eax
    jmp .f
.enc:
    call zz
    mov [rdi+PH_ENC], eax
    jmp .f
.deflen:
    call zz
    mov [rdi+PH_DEFLEN], eax
    jmp .f
.replen:
    call zz
    mov [rdi+PH_REPLEN], eax
    jmp .f
.comp:
    xor ecx, ecx
    cmp eax, 1                  ; compact bools live in the type: 1 true, 2 false
    sete cl
    mov [rdi+PH_COMP], ecx
    jmp .f
.done:
    leave_p

; rcx = page header bytes, rdx = PH to fill. rax = where the page data starts
global pq_pagehdr
pq_pagehdr:
    push rsi
    push rdi
    sub rsp, 40
    mov rsi, rcx
    mov rdi, rdx
    xor eax, eax
    mov [rdi], rax
    mov [rdi+8], rax
    mov [rdi+16], rax
    mov [rdi+24], rax
    mov [rdi+32], rax
    mov [rdi+40], rax
    mov dword [rdi+PH_COMP], 1
    call p_pagehdr
    mov rax, rsi
    add rsp, 40
    pop rdi
    pop rsi
    ret

; RLE / bit-packed hybrid, what parquet uses for levels and dictionary indices.
; rcx = src, rdx = src bytes, r8d = bit width (0-32), r9 = out (u32 each),
; [rsp+40] = how many values. returns rax = where it stopped reading
global rle_decode
rle_decode:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    mov rsi, rcx
    lea r12, [rcx+rdx]
    mov ebx, r8d
    mov rdi, r9
    mov r13, [rsp+48+40]
    lea r14d, [rbx+7]
    shr r14d, 3                 ; bytes per rle value
.run:
    test r13, r13
    jz .done
    cmp rsi, r12
    jae .bad
    xor eax, eax                ; uleb128 run header
    xor ecx, ecx
.hdr:
    movzx edx, byte [rsi]
    inc rsi
    mov r8d, edx
    and r8d, 0x7f
    shl r8, cl
    or rax, r8
    add ecx, 7
    test dl, 0x80
    jnz .hdr
    shr rax, 1                  ; low bit: 0 = rle run, 1 = bit-packed
    jc .packed
    mov rcx, rax
    cmp rcx, r13
    cmova rcx, r13
    sub r13, rcx
    mov eax, [rsi]
    lea edx, [r14*8]
    bzhi eax, eax, edx
    add rsi, r14
    rep stosd
    jmp .run
.packed:
    lea rcx, [rax*8]            ; groups of 8 values
    imul rax, rbx               ; groups * width = bytes
    mov r8, rsi
    add rsi, rax
    cmp rcx, r13
    cmova rcx, r13              ; the last group can have padding past the count
    sub r13, rcx
    xor r9d, r9d                ; bit position, low bits first
.bit:
    test rcx, rcx
    jz .run
    mov rax, r9
    shr rax, 3
    mov rax, [r8+rax]
    mov edx, r9d
    and edx, 7
    shrx rax, rax, rdx
    bzhi eax, eax, ebx
    stosd
    add r9, rbx
    dec rcx
    jmp .bit
.done:
    cmp rsi, r12
    ja .bad
    mov rax, rsi
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.bad:
    and rsp, -16
    sub rsp, 32
    lea rcx, [e_rle]
    call fatal

; rdx = bytes, from the column's arena (r12 = col). a little slack past the end
; so decoders can read and write in whole words
colalloc:
    sub rsp, 40
    add rdx, 64
    mov rcx, [r12+COL_ARENA]
    mov r8d, 16
    call arena_alloc
    add rsp, 40
    ret

; rcx = compressed, rdx = compressed size, r8 = uncompressed size.
; r12 = col, r13 = column chunk (for the codec). rax = uncompressed data
decomp:
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    mov rsi, rcx
    mov rdi, rdx
    mov rbx, r8
    mov eax, [r13+CC_CODEC]
    test eax, eax
    jz .raw
    mov rdx, rbx
    call colalloc
    mov [rsp+40], rax
    mov eax, [r13+CC_CODEC]
    cmp eax, C_SNAPPY
    je .snappy
    cmp eax, C_ZSTD
    je .zstd
    lea rcx, [e_codec]
    call fatal
.snappy:
    mov rcx, [rsp+40]
    mov rdx, rbx
    mov r8, rsi
    mov r9, rdi
    call snappy_decompress
    jmp .check
.zstd:
    mov rcx, [r12+COL_ZSTD]
    mov rdx, [rsp+40]
    mov r8, rbx
    mov r9, rsi
    mov [rsp+32], rdi
    call zstd_decompress
.check:
    cmp rax, rbx
    jne .bad
    mov rax, [rsp+40]
    jmp .done
.raw:
    mov rax, rsi
.done:
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret
.bad:
    lea rcx, [e_size]
    call fatal

; plain byte arrays: u32 length then the bytes, over and over.
; rcx = data, rdx = end, r8 = out (ptr, len) pairs, r9 = count. rax = where it stopped
plain_ba:
    test r9, r9
    jz .done
    lea rax, [rcx+4]
    cmp rax, rdx
    ja .bad
    mov eax, [rcx]
    add rcx, 4
    mov [r8], rcx
    mov [r8+8], rax
    add rcx, rax
    cmp rcx, rdx
    ja .bad
    add r8, 16
    dec r9
    jmp plain_ba
.done:
    mov rax, rcx
    ret
.bad:
    sub rsp, 40
    lea rcx, [e_vals]
    call fatal

; locals for pq_chunk, above the stack arg slots
L_PH    equ 48
L_END   equ 96
L_DICT  equ 104
L_NDICT equ 112
L_PAY   equ 120
L_P     equ 128
L_PEND  equ 136
L_NN    equ 144
L_IDX   equ 152
L_FRAME equ 168

; bit width for levels up to eax
%macro width 0
    lzcnt eax, eax
    neg eax
    add eax, 32
%endmacro

; decodes a whole column chunk into levels and (ptr, len) values, see COL_*.
; values point into decompressed pages (or the dictionary), all in COL_ARENA.
; rcx = pq, rdx = col, r8 = row group, r9 = column
global pq_chunk
pq_chunk:
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, L_FRAME
    mov rbx, rcx
    mov r12, rdx
    mov r14, [rbx+PQ_LEAF]
    imul rax, r9, LF_SIZE
    add r14, rax
    mov r13, [rbx+PQ_RG]
    imul r8, r8, RG_SIZE
    mov r13, [r13+r8+RG_COLS]
    imul r9, r9, CC_SIZE
    add r13, r9

    mov rax, [r13+CC_NVAL]
    mov [r12+COL_N], rax
    xor eax, eax
    mov [r12+COL_REP], rax
    mov [r12+COL_DEF], rax
    mov [rsp+L_DICT], rax
    mov [rsp+L_NDICT], rax
    cmp dword [r14+LF_MAXREP], 0
    je .norep
    mov rdx, [r13+CC_NVAL]
    shl rdx, 2
    call colalloc
    mov [r12+COL_REP], rax
.norep:
    cmp dword [r14+LF_MAXDEF], 0
    je .nodef
    mov rdx, [r13+CC_NVAL]
    shl rdx, 2
    call colalloc
    mov [r12+COL_DEF], rax
.nodef:
    mov rdx, [r13+CC_NVAL]
    shl rdx, 4
    call colalloc
    mov [r12+COL_VALS], rax

    ; the dictionary page comes first, if there is one
    mov rsi, [r13+CC_DATA]
    mov rax, [r13+CC_DICT]
    test rax, rax
    jz .start
    cmp rax, rsi
    cmovb rsi, rax
.start:
    add rsi, [rbx+PQ_BASE]
    mov rax, rsi
    add rax, [r13+CC_CSIZE]
    mov [rsp+L_END], rax
    xor r15d, r15d              ; level entries so far
    xor ebp, ebp                ; values so far

.page:
    cmp rsi, [rsp+L_END]
    jae .done
    mov rcx, rsi
    lea rdx, [rsp+L_PH]
    call pq_pagehdr
    mov [rsp+L_PAY], rax
    mov rsi, rax
    mov eax, [rsp+L_PH+PH_CSIZE]
    add rsi, rax                ; next page
    mov eax, [rsp+L_PH+PH_TYPE]
    test eax, eax
    jz .v1
    cmp eax, 2
    je .dict
    cmp eax, 3
    je .v2
    jmp .page                   ; index pages, nothing for us

.dict:
    mov rcx, [rsp+L_PAY]
    mov edx, [rsp+L_PH+PH_CSIZE]
    mov r8d, [rsp+L_PH+PH_USIZE]
    call decomp
    mov [rsp+L_P], rax
    mov edx, [rsp+L_PH+PH_NVAL]
    mov [rsp+L_NDICT], rdx
    shl rdx, 4
    call colalloc
    mov [rsp+L_DICT], rax
    mov rcx, [rsp+L_P]
    mov edx, [rsp+L_PH+PH_USIZE]
    add rdx, rcx
    mov r8, [rsp+L_DICT]
    mov r9, [rsp+L_NDICT]
    call plain_ba
    jmp .page

.v1:
    ; rep levels, def levels (each with a u32 length), values. all compressed together
    mov rcx, [rsp+L_PAY]
    mov edx, [rsp+L_PH+PH_CSIZE]
    mov r8d, [rsp+L_PH+PH_USIZE]
    call decomp
    mov [rsp+L_P], rax
    mov ecx, [rsp+L_PH+PH_USIZE]
    add rcx, rax
    mov [rsp+L_PEND], rcx
    cmp dword [r14+LF_MAXREP], 0
    je .v1def
    mov rax, [rsp+L_P]
    mov edx, [rax]
    lea rcx, [rax+4]
    lea rax, [rcx+rdx]
    mov [rsp+L_P], rax
    mov eax, [r14+LF_MAXREP]
    width
    mov r8d, eax
    mov r9, [r12+COL_REP]
    lea r9, [r9+r15*4]
    mov eax, [rsp+L_PH+PH_NVAL]
    mov [rsp+32], rax
    call rle_decode
.v1def:
    cmp dword [r14+LF_MAXDEF], 0
    je .levels
    mov rax, [rsp+L_P]
    mov edx, [rax]
    lea rcx, [rax+4]
    lea rax, [rcx+rdx]
    mov [rsp+L_P], rax
    mov eax, [r14+LF_MAXDEF]
    width
    mov r8d, eax
    mov r9, [r12+COL_DEF]
    lea r9, [r9+r15*4]
    mov eax, [rsp+L_PH+PH_NVAL]
    mov [rsp+32], rax
    call rle_decode
    jmp .levels

.v2:
    ; levels first and never compressed, no length prefixes, then the values
    mov rax, [rsp+L_PAY]
    mov [rsp+L_P], rax
    cmp dword [r14+LF_MAXREP], 0
    je .v2def
    mov rcx, rax
    mov edx, [rsp+L_PH+PH_REPLEN]
    mov eax, [r14+LF_MAXREP]
    width
    mov r8d, eax
    mov r9, [r12+COL_REP]
    lea r9, [r9+r15*4]
    mov eax, [rsp+L_PH+PH_NVAL]
    mov [rsp+32], rax
    call rle_decode
.v2def:
    mov eax, [rsp+L_PH+PH_REPLEN]
    add [rsp+L_P], rax
    cmp dword [r14+LF_MAXDEF], 0
    je .v2vals
    mov rcx, [rsp+L_P]
    mov edx, [rsp+L_PH+PH_DEFLEN]
    mov eax, [r14+LF_MAXDEF]
    width
    mov r8d, eax
    mov r9, [r12+COL_DEF]
    lea r9, [r9+r15*4]
    mov eax, [rsp+L_PH+PH_NVAL]
    mov [rsp+32], rax
    call rle_decode
.v2vals:
    mov eax, [rsp+L_PH+PH_DEFLEN]
    add [rsp+L_P], rax
    mov edx, [rsp+L_PH+PH_CSIZE]
    mov r8d, [rsp+L_PH+PH_USIZE]
    mov eax, [rsp+L_PH+PH_REPLEN]
    add eax, [rsp+L_PH+PH_DEFLEN]
    sub edx, eax
    sub r8d, eax
    cmp dword [rsp+L_PH+PH_COMP], 0
    je .v2raw
    mov rcx, [rsp+L_P]
    mov [rsp+L_PEND], r8        ; stash the size across the call
    call decomp
    mov [rsp+L_P], rax
    add rax, [rsp+L_PEND]
    mov [rsp+L_PEND], rax
    jmp .levels
.v2raw:
    mov rax, [rsp+L_P]
    add rax, rdx
    mov [rsp+L_PEND], rax

.levels:
    ; values are the entries at max def level
    mov eax, [rsp+L_PH+PH_NVAL]
    cmp dword [r14+LF_MAXDEF], 0
    je .nn
    mov rcx, [r12+COL_DEF]
    lea rcx, [rcx+r15*4]
    mov edx, [r14+LF_MAXDEF]
    xor r8d, r8d
    mov r9d, eax
.cnt:
    test r9d, r9d
    jz .counted
    xor r10d, r10d
    cmp [rcx], edx
    sete r10b
    add r8d, r10d
    add rcx, 4
    dec r9d
    jmp .cnt
.counted:
    mov eax, r8d
.nn:
    mov [rsp+L_NN], rax
    mov eax, [rsp+L_PH+PH_NVAL]
    add r15, rax

    mov eax, [rsp+L_PH+PH_ENC]
    cmp eax, E_PLAIN
    je .plain
    cmp eax, E_RLE_DICT
    je .dictvals
    cmp eax, E_PLAIN_DICT
    je .dictvals
    lea rcx, [e_enc]
    call fatal

.plain:
    mov rcx, [rsp+L_P]
    mov rdx, [rsp+L_PEND]
    mov r8, rbp
    shl r8, 4
    add r8, [r12+COL_VALS]
    mov r9, [rsp+L_NN]
    call plain_ba
    add rbp, [rsp+L_NN]
    jmp .page

.dictvals:
    ; a byte of bit width, then rle/bit-packed indices into the dictionary
    mov rdx, [rsp+L_NN]
    shl rdx, 2
    call colalloc
    mov [rsp+L_IDX], rax
    mov rcx, [rsp+L_P]
    movzx r8d, byte [rcx]
    inc rcx
    mov rdx, [rsp+L_PEND]
    sub rdx, rcx
    mov r9, rax
    mov rax, [rsp+L_NN]
    mov [rsp+32], rax
    call rle_decode
    mov rcx, [rsp+L_NN]
    mov rdi, rbp
    shl rdi, 4
    add rdi, [r12+COL_VALS]
    mov r8, [rsp+L_IDX]
    mov r9, [rsp+L_DICT]
    mov r10, [rsp+L_NDICT]
.dv:
    test rcx, rcx
    jz .dvdone
    mov eax, [r8]
    cmp rax, r10
    jae .baddict
    shl rax, 4
    mov r11, [r9+rax]
    mov [rdi], r11
    mov r11, [r9+rax+8]
    mov [rdi+8], r11
    add r8, 4
    add rdi, 16
    dec rcx
    jmp .dv
.dvdone:
    add rbp, [rsp+L_NN]
    jmp .page

.done:
    cmp r15, [r12+COL_N]
    jne .badcount
    mov [r12+COL_NV], rbp
    add rsp, L_FRAME
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret
.baddict:
    lea rcx, [e_dict]
    call fatal
.badcount:
    lea rcx, [e_count]
    call fatal
