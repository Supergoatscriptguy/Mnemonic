; zstd decompression (RFC 8878). frames, raw/rle/compressed blocks, huffman
; literals, fse sequences. no dictionaries, and the checksum gets skipped.
; needs BMI2 (shrx/shlx/bzhi) for the bit reading
default rel
bits 64
%include "lib.inc"

; context, ZSTD_CTX bytes, caller allocated
ZS_LLT    equ 0                 ; fse tables. 8 byte entries: u16 next state base,
ZS_MLT    equ 4096              ;   u8 bits for the next state, u8 extra bits (or the
ZS_OFT    equ 8192              ;   symbol, for huffman weights), u32 base value
ZS_LLDEF  equ 10240             ; the predefined ones, built by zstd_init
ZS_MLDEF  equ 10752
ZS_OFDEF  equ 11264
ZS_HUF    equ 11520             ; huffman: 2048 x u16, symbol | bits << 8
ZS_HWT    equ 15616             ; fse table for the huffman weights
ZS_LLP    equ 16128             ; tables in use (own or predefined)
ZS_MLP    equ 16136
ZS_OFP    equ 16144
ZS_LLLOG  equ 16152
ZS_MLLOG  equ 16156
ZS_OFLOG  equ 16160
ZS_HUFLOG equ 16164             ; 0 = no huffman table yet
ZS_REP    equ 16168             ; repeat offsets, 3 qwords
ZS_LITP   equ 16192             ; this block's literals
ZS_LITN   equ 16200
ZS_OSTART equ 16208             ; output: where this frame started, and the hard end
ZS_OEND   equ 16216
ZS_NORM   equ 16256             ; s16 x 64, scratch
ZS_NEXT   equ 16384             ; u16 x 64, scratch
ZS_WTS    equ 16512             ; u8 x 256 huffman weights
ZS_RANK   equ 16768             ; u32 x 16
ZS_LIT    equ 16896             ; decoded literals, 128K + slack

; per sequence table kind (literal lengths, offsets, match lengths)
K_TAB     equ 0
K_DEF     equ 8
K_PTR     equ 16
K_LOG     equ 24
K_DLOG    equ 32
K_MAXSYM  equ 40
K_MAXLOG  equ 48
K_BITS    equ 56
K_BASE    equ 64
K_SIZE    equ 72

section .rdata
align 8
kinds    dq ZS_LLT, ZS_LLDEF, ZS_LLP, ZS_LLLOG, 6, 36, 9, ll_bits, ll_base
         dq ZS_OFT, ZS_OFDEF, ZS_OFP, ZS_OFLOG, 5, 32, 8, 0, 0
         dq ZS_MLT, ZS_MLDEF, ZS_MLP, ZS_MLLOG, 6, 53, 9, ml_bits, ml_base
ll_base  dd 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
         dd 16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 0x80, 0x100, 0x200, 0x400
         dd 0x800, 0x1000, 0x2000, 0x4000, 0x8000, 0x10000
ml_base  dd 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18
         dd 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34
         dd 35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 0x83, 0x103, 0x203
         dd 0x403, 0x803, 0x1003, 0x2003, 0x4003, 0x8003, 0x10003
ll_norm  dw 4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1
         dw 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1
         dw -1, -1, -1, -1
ml_norm  dw 1, 4, 3, 2, 2, 2, 2, 2, 2
         times 37 dw 1
         times 7 dw -1
of_norm  dw 1, 1, 1, 1, 1, 1, 2, 2, 2
         times 15 dw 1
         times 5 dw -1
ll_bits  db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
         db 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
ml_bits  times 32 db 0
         db 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
didsz    db 0, 1, 2, 4          ; dictionary id bytes, by flag

section .bss
global zstd_err
zstd_err resd 1                 ; .text offset of the last check that failed, for debugging
                                ; (look it up in a listing: nasm -l zstd.lst)
section .text

; bail to .bad on condition %1, noting where
%macro failif 1
%%here:
    j%-1 %%ok
    cmp dword [zstd_err], 0
    jne .bad                    ; keep the innermost one
    mov dword [zstd_err], %%here - $$
    jmp .bad
%%ok:
%endmacro

; rax = next ecx bits of a backward bitstream. r8 = its first byte, r9 = bit position
; (counts down). bits below the start read as zero. uses rdx
%macro getbits 0
    sub r9, rcx
    js %%neg
    mov rdx, r9
    shr rdx, 3
    mov rax, [r8+rdx]
    mov edx, r9d
    and edx, 7
    shrx rax, rax, rdx
    bzhi rax, rax, rcx
    jmp %%done
%%neg:
    mov rax, [r8]
    mov rdx, r9
    neg rdx
    shlx rax, rax, rdx
    bzhi rax, rax, rcx
%%done:
%endmacro

; r8 = stream start, rcx = its size: set r9 to the bit position just under the
; marker (the highest set bit of the last byte). jumps to %1 if there's no marker
%macro backward 1
    test rcx, rcx
    failif z
    movzx eax, byte [r8+rcx-1]
    test eax, eax
    failif z
    bsr eax, eax
    lea r9, [rcx*8-8]
    add r9, rax
%endmacro

; fse decoding table from normalized counts.
; rcx = ctx (scratch), rdx = table, r8 = counts (s16), r9d = symbols, [rsp+40] = accuracy log
fse_build:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov rdi, rdx
    mov rsi, r8
    mov r12d, r9d
    lea r15, [rcx+ZS_NEXT]
    mov ecx, [rsp+56+40]
    mov ebx, ecx
    mov r13d, 1
    shl r13d, cl                ; table size
    lea r14d, [r13-1]           ; top free slot
    ; "less than 1" symbols (-1) get a slot each, from the top down
    xor ecx, ecx
.low:
    cmp ecx, r12d
    jae .spread
    movsx eax, word [rsi+rcx*2]
    cmp eax, -1
    jne .low1
    mov [rdi+r14*8+3], cl
    dec r14d
    mov eax, 1
.low1:
    mov [r15+rcx*2], ax
    inc ecx
    jmp .low
.spread:
    ; everyone else gets spread over the table with an odd step
    mov r8d, r13d
    shr r8d, 1
    mov eax, r13d
    shr eax, 3
    add r8d, eax
    add r8d, 3
    lea r9d, [r13-1]
    xor edx, edx
    xor ecx, ecx
.sym:
    cmp ecx, r12d
    jae .states
    movsx eax, word [rsi+rcx*2]
.put:
    test eax, eax
    jle .nextsym
    mov [rdi+rdx*8+3], cl
.step:
    add edx, r8d
    and edx, r9d
    cmp edx, r14d
    ja .step                    ; those belong to the -1 symbols
    dec eax
    jmp .put
.nextsym:
    inc ecx
    jmp .sym
.states:
    xor ecx, ecx
.st:
    cmp ecx, r13d
    jae .done
    movzx eax, byte [rdi+rcx*8+3]
    movzx edx, word [r15+rax*2]
    lea r8d, [rdx+1]
    mov [r15+rax*2], r8w
    bsr r8d, edx
    mov r9d, ebx
    sub r9d, r8d                ; bits = log - highbit(x)
    mov [rdi+rcx*8+2], r9b
    shlx r8d, edx, r9d
    sub r8d, r13d               ; next state base = (x << bits) - size
    mov [rdi+rcx*8], r8w
    inc ecx
    jmp .st
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; reads an fse table description, forward bits.
; rcx = ctx, rdx = src, r8d = max symbols, r9d = max accuracy log.
; fills ZS_NORM. returns rax = bytes used (0 = bad), edx = accuracy log, r8d = symbols
fse_readnorm:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    lea rdi, [rcx+ZS_NORM]
    mov rsi, rdx
    mov r12d, r8d
    xor ebx, ebx                ; bit position
%macro fpeek 0                  ; rax = bits from rbx on
    mov rax, rbx
    shr rax, 3
    mov rax, [rsi+rax]
    mov ecx, ebx
    and ecx, 7
    shr rax, cl
%endmacro
    fpeek
    and eax, 15
    add eax, 5
    cmp eax, r9d
    failif a
    mov r13d, eax
    add ebx, 4
    mov ecx, r13d
    mov r14d, 1
    shl r14d, cl                ; threshold
    lea r15d, [r14+1]           ; remaining + 1
    lea r9d, [r13+1]            ; bits per count right now
    xor r8d, r8d                ; symbol
    xor r10d, r10d              ; last count was 0
.loop:
    cmp r15d, 1
    jbe .end
    cmp r8d, r12d
    failif ae
    test r10d, r10d
    jz .count
.zeros:
    ; after a 0, 2 bit flags say how many more zeros. 3 means 3 and keep reading
    fpeek
    and eax, 3
    add ebx, 2
    lea edx, [r8+rax]
    cmp edx, r12d
    failif a
.z1:
    cmp r8d, edx
    jae .z2
    mov word [rdi+r8*2], 0
    inc r8d
    jmp .z1
.z2:
    cmp eax, 3
    je .zeros
    cmp r8d, r12d
    failif ae
.count:
    fpeek
    lea r11d, [r14*2-1]
    sub r11d, r15d              ; small values save a bit
    lea ecx, [r14-1]
    mov edx, eax
    and edx, ecx
    cmp edx, r11d
    jae .big
    lea ecx, [r9-1]
    add ebx, ecx
    jmp .got
.big:
    lea ecx, [r14*2-1]
    mov edx, eax
    and edx, ecx
    add ebx, r9d
    cmp edx, r14d
    jb .got
    sub edx, r11d
.got:
    dec edx                     ; stored as count + 1, so -1 fits
    mov [rdi+r8*2], dx
    inc r8d
    mov eax, edx
    test eax, eax
    jns .abs
    neg eax
.abs:
    sub r15d, eax
    xor r10d, r10d
    test edx, edx
    setz r10b
.shrink:
    cmp r15d, r14d
    jae .loop
    dec r9d
    shr r14d, 1
    jmp .shrink
.end:
    cmp r15d, 1
    failif ne
    lea rax, [rbx+7]
    shr rax, 3
    mov edx, r13d
    jmp .ret
.bad:
    xor eax, eax
.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = ctx, rdx = table, r8d = entries, r9 = kind. turns symbols into extra bits + base
seqconv:
    mov r10, [r9+K_BITS]
    mov r11, [r9+K_BASE]
.e:
    test r8d, r8d
    jz .done
    movzx eax, byte [rdx+3]
    test r10, r10
    jz .of
    movzx ecx, byte [r10+rax]
    mov [rdx+3], cl
    mov ecx, [r11+rax*4]
    mov [rdx+4], ecx
    jmp .n
.of:
    mov ecx, 1                  ; offset code n: n extra bits on top of 1 << n
    shlx ecx, ecx, eax
    mov [rdx+4], ecx
.n:
    add rdx, 8
    dec r8d
    jmp .e
.done:
    ret

; sets up one sequence table. rcx = ctx, edx = kind (0 ll, 1 of, 2 ml),
; r8d = mode, r9 = where its description would be. rax = past it, 0 = bad
settable:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 48
    mov rbx, rcx
    lea r12, [kinds]
    imul edx, edx, K_SIZE
    add r12, rdx
    mov rsi, r9
    cmp r8d, 1
    jb .predef
    je .rle
    cmp r8d, 2
    je .fse
    mov rax, rsi                ; 3: repeat, keep the last block's
    jmp .ret
.predef:
    mov rax, [r12+K_DEF]
    add rax, rbx
    mov rcx, [r12+K_PTR]
    mov [rbx+rcx], rax
    mov eax, [r12+K_DLOG]
    mov rcx, [r12+K_LOG]
    mov [rbx+rcx], eax
    mov rax, rsi
    jmp .ret
.rle:
    ; one symbol every time, reading no bits: a one entry table
    movzx eax, byte [rsi]
    inc rsi
    cmp rax, [r12+K_MAXSYM]
    failif ae
    mov rdi, [r12+K_TAB]
    add rdi, rbx
    mov qword [rdi], 0
    mov [rdi+3], al
    mov rcx, rbx
    mov rdx, rdi
    mov r8d, 1
    mov r9, r12
    call seqconv
    mov rcx, [r12+K_PTR]
    mov [rbx+rcx], rdi
    mov rcx, [r12+K_LOG]
    mov dword [rbx+rcx], 0
    mov rax, rsi
    jmp .ret
.fse:
    mov rcx, rbx
    mov rdx, rsi
    mov r8d, [r12+K_MAXSYM]
    mov r9d, [r12+K_MAXLOG]
    call fse_readnorm
    test rax, rax
    failif z
    add rsi, rax
    mov r13d, edx
    mov [rsp+32], rdx
    mov r9d, r8d
    lea r8, [rbx+ZS_NORM]
    mov rdi, [r12+K_TAB]
    add rdi, rbx
    mov rdx, rdi
    mov rcx, rbx
    call fse_build
    mov ecx, r13d
    mov r8d, 1
    shl r8d, cl
    mov rcx, rbx
    mov rdx, rdi
    mov r9, r12
    call seqconv
    mov rcx, [r12+K_PTR]
    mov [rbx+rcx], rdi
    mov rcx, [r12+K_LOG]
    mov [rbx+rcx], r13d
    mov rax, rsi
    jmp .ret
.bad:
    xor eax, eax
.ret:
    add rsp, 48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; huffman tree description -> ZS_HUF table.
; rcx = ctx, rdx = src, r8 = bytes available. rax = bytes used, 0 = bad
huf_read:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rbx, rcx
    mov rsi, rdx
    lea rdi, [rbx+ZS_WTS]
    movzx eax, byte [rsi]
    cmp eax, 128
    jb .fse
    lea r12d, [rax-127]         ; weights stored directly, 4 bits each
    lea r13d, [r12+1]
    shr r13d, 1
    inc r13d
    cmp r13, r8
    failif a
    xor ecx, ecx
.direct:
    cmp ecx, r12d
    jae .weights
    mov edx, ecx
    shr edx, 1
    movzx eax, byte [rsi+rdx+1]
    test ecx, 1
    jnz .low
    shr eax, 4
.low:
    and eax, 15
    mov [rdi+rcx], al
    inc ecx
    jmp .direct
.fse:
    ; weights fse-compressed: a table description, then two states taking turns
    lea r13d, [rax+1]
    cmp r13, r8
    failif a
    mov rcx, rbx
    lea rdx, [rsi+1]
    mov r8d, 16
    mov r9d, 6
    call fse_readnorm
    test rax, rax
    failif z
    mov r14, rax
    mov r15d, edx
    mov [rsp+32], rdx
    mov r9d, r8d
    lea r8, [rbx+ZS_NORM]
    lea rdx, [rbx+ZS_HWT]
    mov rcx, rbx
    call fse_build
    lea r8, [rsi+1+r14]
    lea rcx, [r13-1]
    sub rcx, r14
    failif le
    backward .bad
    lea r10, [rbx+ZS_HWT]
    mov ecx, r15d
    getbits
    mov r11, rax
    mov ecx, r15d
    getbits
    mov r14, rax
    xor r12d, r12d
    ; decode until the stream runs dry, then each state has one more symbol
.w:
    mov al, [r10+r11*8+3]
    mov [rdi+r12], al
    inc r12d
    movzx ecx, byte [r10+r11*8+2]
    getbits
    movzx edx, word [r10+r11*8]
    lea r11, [rax+rdx]
    test r9, r9
    js .last2
    mov al, [r10+r14*8+3]
    mov [rdi+r12], al
    inc r12d
    movzx ecx, byte [r10+r14*8+2]
    getbits
    movzx edx, word [r10+r14*8]
    lea r14, [rax+rdx]
    test r9, r9
    js .last1
    cmp r12d, 255               ; a byte alphabet has at most 255 stated weights
    failif a
    jmp .w
.last2:
    mov al, [r10+r14*8+3]
    mov [rdi+r12], al
    inc r12d
    jmp .weights
.last1:
    mov al, [r10+r11*8+3]
    mov [rdi+r12], al
    inc r12d
.weights:
    ; sum of 2^(w-1). the missing last weight makes it a power of 2, which sets the depth
    cmp r12d, 255
    failif a
    xor ecx, ecx
    xor edx, edx
.sum:
    cmp ecx, r12d
    jae .summed
    movzx eax, byte [rdi+rcx]
    test eax, eax
    jz .s0
    cmp eax, 12
    failif ae
    dec eax
    mov r8d, 1
    shlx r8d, r8d, eax
    add edx, r8d
.s0:
    inc ecx
    jmp .sum
.summed:
    test edx, edx
    failif z
    bsr ecx, edx
    inc ecx
    cmp ecx, 11
    failif a
    mov [rbx+ZS_HUFLOG], ecx
    mov eax, 1
    shl eax, cl
    sub eax, edx
    bsr edx, eax
    mov r8d, 1
    shlx r8d, r8d, edx
    cmp r8d, eax
    failif ne
    inc edx
    mov [rdi+r12], dl
    inc r12d                    ; symbols
    ; lowest weights (longest codes) get the lowest table slots
    lea r10, [rbx+ZS_RANK]
    xor eax, eax
    mov [r10], rax
    mov [r10+8], rax
    mov [r10+16], rax
    mov [r10+24], rax
    mov [r10+32], rax
    mov [r10+40], rax
    mov [r10+48], rax
    mov [r10+56], rax
    xor ecx, ecx
.cnt:
    cmp ecx, r12d
    jae .starts
    movzx eax, byte [rdi+rcx]
    inc dword [r10+rax*4]
    inc ecx
    jmp .cnt
.starts:
    xor edx, edx
    mov ecx, 1
    mov r11d, [rbx+ZS_HUFLOG]
.st:
    cmp ecx, r11d
    ja .fill0
    mov eax, [r10+rcx*4]
    mov [r10+rcx*4], edx
    lea r8d, [rcx-1]
    shlx eax, eax, r8d
    add edx, eax
    inc ecx
    jmp .st
.fill0:
    lea r9, [rbx+ZS_HUF]
    xor ecx, ecx
.fill:
    cmp ecx, r12d
    jae .ok
    movzx eax, byte [rdi+rcx]
    test eax, eax
    jz .fnext
    lea r8d, [r11+1]
    sub r8d, eax                ; code length
    shl r8d, 8
    or r8d, ecx
    mov edx, [r10+rax*4]
    lea r14d, [rax-1]
    mov r15d, 1
    shlx r15d, r15d, r14d
    add [r10+rax*4], r15d
.f1:
    mov [r9+rdx*2], r8w
    inc edx
    dec r15d
    jnz .f1
.fnext:
    inc ecx
    jmp .fill
.ok:
    mov rax, r13
    jmp .ret
.bad:
    xor eax, eax
.ret:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; one huffman stream. rcx = ctx, rdx = src, r8 = size, r9 = out, [rsp+40] = symbols.
; eax = 1 if the stream got used up exactly
huf_stream:
    push rbx
    push rsi
    push rdi
    mov rbx, [rsp+24+40]
    lea r10, [rcx+ZS_HUF]
    mov r11d, [rcx+ZS_HUFLOG]
    mov rdi, r9
    mov rcx, r8
    mov r8, rdx
    backward .bad
    mov rsi, r8
    test rbx, rbx
    jz .end
.loop:
    mov rcx, r9                 ; peek the top huflog bits, the table knows how many to take
    sub rcx, r11
    js .neg
    mov rdx, rcx
    shr rdx, 3
    mov rax, [rsi+rdx]
    and ecx, 7
    shrx rax, rax, rcx
    bzhi eax, eax, r11d
    jmp .look
.neg:
    mov rax, [rsi]
    neg rcx
    shlx rax, rax, rcx
    bzhi eax, eax, r11d
.look:
    movzx eax, word [r10+rax*2]
    mov [rdi], al
    inc rdi
    shr eax, 8
    sub r9, rax
    dec rbx
    jnz .loop
.end:
    xor eax, eax
    test r9, r9
    sete al
    jmp .ret
.bad:
    xor eax, eax
.ret:
    pop rdi
    pop rsi
    pop rbx
    ret

; literals section. rcx = ctx, rdx = block, r8 = block size.
; sets ZS_LITP / ZS_LITN, returns rax = bytes used, 0 = bad
lit_section:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rbx, rcx
    mov rsi, rdx
    mov r12, r8
    movzx eax, byte [rsi]
    mov ecx, eax
    and ecx, 3                  ; 0 raw, 1 rle, 2 huffman, 3 huffman with the last tree
    mov edx, eax
    shr edx, 2
    and edx, 3                  ; size format
    cmp ecx, 2
    jae .huf
    ; raw / rle: 5, 12 or 20 bit size
    test edx, 1
    jnz .sz12
    shr eax, 3
    mov r13d, 1
    jmp .rawrle
.sz12:
    cmp edx, 1
    jne .sz20
    movzx eax, word [rsi]
    shr eax, 4
    mov r13d, 2
    jmp .rawrle
.sz20:
    mov eax, [rsi]
    and eax, 0xffffff
    shr eax, 4
    mov r13d, 3
.rawrle:
    cmp rax, 128 * 1024         ; a block's literals are 128K at most, all ZS_LIT has room for
    failif a
    mov [rbx+ZS_LITN], rax
    cmp ecx, 1
    je .rle
    lea rdx, [rsi+r13]          ; raw: use them right where they are
    mov [rbx+ZS_LITP], rdx
    add rax, r13
    cmp rax, r12
    failif a
    jmp .ret
.rle:
    lea rdx, [r13+1]            ; its one byte has to be in the block
    cmp rdx, r12
    failif a
    movzx edx, byte [rsi+r13]
    lea rdi, [rbx+ZS_LIT]
    mov [rbx+ZS_LITP], rdi
    mov rcx, rax
    mov eax, edx
    rep stosb
    lea rax, [r13+1]
    jmp .ret
.huf:
    mov r14d, ecx
    mov [rsp+40], rdx
    mov rax, [rsi]
    shr rax, 4
    cmp edx, 2
    je .f14
    ja .f18
    mov r13d, 3                 ; 10 + 10 bits, 1 stream for format 0, 4 for 1
    mov ecx, 10
    jmp .fsz
.f14:
    mov r13d, 4
    mov ecx, 14
    jmp .fsz
.f18:
    mov r13d, 5
    mov ecx, 18
.fsz:
    bzhi r8, rax, rcx           ; regenerated size
    shrx rax, rax, rcx
    bzhi rax, rax, rcx          ; compressed size
    mov [rbx+ZS_LITN], r8
    cmp r8, 128 * 1024
    failif a
    lea r10, [rax+r13]
    cmp r10, r12
    failif a
    mov r12, r10                ; bytes used, what we return
    mov rdi, rax
    add rsi, r13
    lea rax, [rbx+ZS_LIT]
    mov [rbx+ZS_LITP], rax
    cmp r14d, 2
    jne .treeless
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    call huf_read
    test rax, rax
    failif z
    add rsi, rax
    sub rdi, rax
    jmp .streams
.treeless:
    cmp dword [rbx+ZS_HUFLOG], 0
    failif e
.streams:
    cmp qword [rsp+40], 0
    jne .four
    mov rax, [rbx+ZS_LITN]
    mov [rsp+32], rax
    mov rcx, rbx
    mov rdx, rsi
    mov r8, rdi
    lea r9, [rbx+ZS_LIT]
    call huf_stream
    test eax, eax
    failif z
    mov rax, r12
    jmp .ret
.four:
    ; 6 byte jump table: sizes of streams 1-3, the 4th is the rest.
    ; each decodes a quarter (rounded up), the last one gets what's left
    cmp rdi, 6
    failif b
    mov rax, [rbx+ZS_LITN]
    add rax, 3
    shr rax, 2
    mov r14, rax
    lea r13, [rsi+6]
    sub rdi, 6
    xor r15d, r15d
.s:
    cmp r15d, 3
    je .slast
    movzx r8d, word [rsi+r15*2]
    mov rax, r14
    jmp .sgo
.slast:
    mov r8, rdi
    mov rax, [rbx+ZS_LITN]
    imul rcx, r14, 3
    sub rax, rcx
    failif s
.sgo:
    cmp r8, rdi
    failif a
    mov [rsp+32], rax
    mov rcx, rbx
    mov rdx, r13
    sub rdi, r8
    add r13, r8
    lea r9, [rbx+ZS_LIT]
    mov rax, r14
    imul rax, r15
    add r9, rax
    call huf_stream
    test eax, eax
    failif z
    inc r15d
    cmp r15d, 4
    jb .s
    mov rax, r12
    jmp .ret
.bad:
    xor eax, eax
.ret:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; locals for zblock
Z_P      equ 32
Z_END    equ 40
Z_LITEND equ 48
Z_OFV    equ 56
Z_ML     equ 64
Z_LL     equ 72
Z_OFF    equ 80
Z_TMP    equ 88
Z_FRAME  equ 104

; a compressed block. rcx = ctx, rdx = block, r8 = size, r9 = out.
; rax = new out position, 0 = bad
zblock:
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, Z_FRAME
    mov rbx, rcx
    mov rdi, r9
    mov [rsp+Z_P], rdx
    lea rax, [rdx+r8]
    mov [rsp+Z_END], rax
    call lit_section
    test rax, rax
    failif z
    add [rsp+Z_P], rax
    mov rsi, [rbx+ZS_LITP]
    mov rax, rsi
    add rax, [rbx+ZS_LITN]
    mov [rsp+Z_LITEND], rax

    ; number of sequences: 1, 2 or 3 bytes
    mov rdx, [rsp+Z_P]
    movzx eax, byte [rdx]
    inc rdx
    cmp eax, 128
    jb .nseq
    cmp eax, 255
    je .n3
    sub eax, 128
    shl eax, 8
    movzx ecx, byte [rdx]
    inc rdx
    add eax, ecx
    jmp .nseq
.n3:
    movzx eax, word [rdx]
    add rdx, 2
    add eax, 0x7f00
.nseq:
    mov ebp, eax
    test ebp, ebp
    jz .tail                    ; literals only

    ; table modes, 2 bits each: literal lengths, offsets, match lengths
    movzx eax, byte [rdx]
    inc rdx
    mov [rsp+Z_P], rdx
    mov [rsp+Z_TMP], rax
    mov rcx, rbx
    xor edx, edx
    mov r8d, eax
    shr r8d, 6
    mov r9, [rsp+Z_P]
    call settable
    test rax, rax
    failif z
    mov [rsp+Z_P], rax
    mov rcx, rbx
    mov edx, 1
    mov r8, [rsp+Z_TMP]
    shr r8d, 4
    and r8d, 3
    mov r9, [rsp+Z_P]
    call settable
    test rax, rax
    failif z
    mov [rsp+Z_P], rax
    mov rcx, rbx
    mov edx, 2
    mov r8, [rsp+Z_TMP]
    shr r8d, 2
    and r8d, 3
    mov r9, [rsp+Z_P]
    call settable
    test rax, rax
    failif z

    ; the rest of the block is one backward bitstream
    mov r8, rax
    mov rcx, [rsp+Z_END]
    sub rcx, r8
    failif le
    backward .bad
    mov r10, [rbx+ZS_LLP]
    mov r11, [rbx+ZS_MLP]
    mov r12, [rbx+ZS_OFP]
    mov ecx, [rbx+ZS_LLLOG]
    getbits
    mov r13, rax
    mov ecx, [rbx+ZS_OFLOG]
    getbits
    mov r15, rax
    mov ecx, [rbx+ZS_MLLOG]
    getbits
    mov r14, rax

.seq:
    ; extra bits come offset, match length, literal length
    movzx ecx, byte [r12+r15*8+3]
    getbits
    mov edx, [r12+r15*8+4]
    add rax, rdx
    mov [rsp+Z_OFV], rax
    movzx ecx, byte [r11+r14*8+3]
    getbits
    mov edx, [r11+r14*8+4]
    add rax, rdx
    mov [rsp+Z_ML], rax
    movzx ecx, byte [r10+r13*8+3]
    getbits
    mov edx, [r10+r13*8+4]
    add rax, rdx
    mov [rsp+Z_LL], rax
    cmp ebp, 1
    je .nostate                 ; the last sequence doesn't move the states
    ; next states go literal length, match length, offset
    movzx ecx, byte [r10+r13*8+2]
    getbits
    movzx edx, word [r10+r13*8]
    lea r13, [rax+rdx]
    movzx ecx, byte [r11+r14*8+2]
    getbits
    movzx edx, word [r11+r14*8]
    lea r14, [rax+rdx]
    movzx ecx, byte [r12+r15*8+2]
    getbits
    movzx edx, word [r12+r15*8]
    lea r15, [rax+rdx]
.nostate:

    ; offset values 1-3 are repeat codes, shifted by one when there are no literals
    mov rax, [rsp+Z_OFV]
    cmp rax, 3
    ja .newoff
    cmp qword [rsp+Z_LL], 0
    jne .rep
    inc rax
.rep:
    cmp rax, 1
    je .rep0
    cmp rax, 4
    je .rep0m1
    mov rdx, [rbx+ZS_REP-8+rax*8]
    cmp rax, 3
    jne .rot2
    mov rcx, [rbx+ZS_REP+8]
    mov [rbx+ZS_REP+16], rcx
.rot2:
    mov rcx, [rbx+ZS_REP]
    mov [rbx+ZS_REP+8], rcx
    mov [rbx+ZS_REP], rdx
    mov rax, rdx
    jmp .off
.rep0m1:
    mov rax, [rbx+ZS_REP]
    dec rax
    jmp .push
.newoff:
    sub rax, 3
.push:
    mov rcx, [rbx+ZS_REP+8]
    mov [rbx+ZS_REP+16], rcx
    mov rcx, [rbx+ZS_REP]
    mov [rbx+ZS_REP+8], rcx
    mov [rbx+ZS_REP], rax
    jmp .off
.rep0:
    mov rax, [rbx+ZS_REP]
.off:
    test rax, rax
    failif z
    mov [rsp+Z_OFF], rax

    ; literals, then the match
    mov rcx, [rsp+Z_LL]
    lea rax, [rsi+rcx]
    cmp rax, [rsp+Z_LITEND]
    failif a
    mov rax, [rsp+Z_ML]
    add rax, rcx
    add rax, rdi
    cmp rax, [rbx+ZS_OEND]
    failif a
    xor edx, edx                ; 16 at a time, both sides have slack
.lc:
    cmp rdx, rcx
    jae .lcd
    movdqu xmm0, [rsi+rdx]
    movdqu [rdi+rdx], xmm0
    add rdx, 16
    jmp .lc
.lcd:
    add rsi, rcx
    add rdi, rcx
    mov rax, [rsp+Z_OFF]
    mov rdx, rdi
    sub rdx, [rbx+ZS_OSTART]
    cmp rax, rdx
    ja .bad                     ; reaches back before the frame
    mov rcx, [rsp+Z_ML]
    mov rdx, rdi
    sub rdx, rax
    cmp rax, 16
    jb .near
    xor eax, eax                ; far enough back that 16 byte chunks never overlap
.mc:
    cmp rax, rcx
    jae .mcd
    movdqu xmm0, [rdx+rax]
    movdqu [rdi+rax], xmm0
    add rax, 16
    jmp .mc
.mcd:
    add rdi, rcx
    jmp .nextseq
.near:
    mov [rsp+Z_TMP], rsi        ; overlapping: rep movsb copies byte by byte, repeating the pattern
    mov rsi, rdx
    rep movsb
    mov rsi, [rsp+Z_TMP]
.nextseq:
    dec ebp
    jnz .seq
    test r9, r9
    jnz .bad                    ; every bit has to be used, no more, no less

.tail:
    mov rcx, [rsp+Z_LITEND]
    sub rcx, rsi
    lea rax, [rdi+rcx]
    cmp rax, [rbx+ZS_OEND]
    failif a
    rep movsb
    mov rax, rdi
    jmp .ret
.bad:
    xor eax, eax
.ret:
    add rsp, Z_FRAME
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret

; rcx = ctx. builds the predefined tables, call once per context
global zstd_init
zstd_init:
    push rbx
    sub rsp, 48
    mov rbx, rcx
    mov qword [rsp+32], 6
    mov rcx, rbx
    lea rdx, [rbx+ZS_LLDEF]
    lea r8, [ll_norm]
    mov r9d, 36
    call fse_build
    mov rcx, rbx
    lea rdx, [rbx+ZS_LLDEF]
    mov r8d, 64
    lea r9, [kinds]
    call seqconv
    mov qword [rsp+32], 5
    mov rcx, rbx
    lea rdx, [rbx+ZS_OFDEF]
    lea r8, [of_norm]
    mov r9d, 29
    call fse_build
    mov rcx, rbx
    lea rdx, [rbx+ZS_OFDEF]
    mov r8d, 32
    lea r9, [kinds+K_SIZE]
    call seqconv
    mov qword [rsp+32], 6
    mov rcx, rbx
    lea rdx, [rbx+ZS_MLDEF]
    lea r8, [ml_norm]
    mov r9d, 53
    call fse_build
    mov rcx, rbx
    lea rdx, [rbx+ZS_MLDEF]
    mov r8d, 64
    lea r9, [kinds+2*K_SIZE]
    call seqconv
    lea rax, [rbx+ZS_LLDEF]
    mov [rbx+ZS_LLP], rax
    lea rax, [rbx+ZS_OFDEF]
    mov [rbx+ZS_OFP], rax
    lea rax, [rbx+ZS_MLDEF]
    mov [rbx+ZS_MLP], rax
    mov dword [rbx+ZS_LLLOG], 6
    mov dword [rbx+ZS_OFLOG], 5
    mov dword [rbx+ZS_MLLOG], 6
    add rsp, 48
    pop rbx
    ret

; rcx = ctx, rdx = dst, r8 = dst capacity, r9 = src, [rsp+40] = src size.
; rax = bytes written, -1 if the data is bad or doesn't fit.
; dst needs 16 bytes of slack past the capacity, the copies go in whole chunks
global zstd_decompress
zstd_decompress:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 56
    mov dword [zstd_err], 0
    mov rbx, rcx
    mov rdi, rdx
    mov r12, rdx
    lea rax, [rdx+r8]
    mov [rbx+ZS_OEND], rax
    mov rsi, r9
    mov r13, [rsp+48+56+40]
    add r13, r9
.frame:
    cmp rsi, r13
    jae .done
    mov eax, [rsi]
    mov ecx, eax
    and ecx, 0xfffffff0
    cmp ecx, 0x184d2a50
    je .skippable
    cmp eax, 0xfd2fb528
    failif ne
    add rsi, 4
    movzx eax, byte [rsi]       ; frame header descriptor
    inc rsi
    test eax, 8
    jnz .bad                    ; reserved bit
    mov r14d, eax
    test eax, 0x20
    jnz .onesegment
    inc rsi                     ; window descriptor, we don't need it
.onesegment:
    mov ecx, eax
    and ecx, 3
    lea rdx, [didsz]
    movzx ecx, byte [rdx+rcx]
    add rsi, rcx
    ; content size: 0 (or 1 with single segment), 2 (+256), 4 or 8 bytes
    mov ecx, r14d
    shr ecx, 6
    jnz .fcs
    test r14d, 0x20
    jz .nofcs
    movzx eax, byte [rsi]
    inc rsi
    jmp .havefcs
.fcs:
    cmp ecx, 1
    jne .fcs4
    movzx eax, word [rsi]
    add rsi, 2
    add eax, 256
    jmp .havefcs
.fcs4:
    cmp ecx, 2
    jne .fcs8
    mov eax, [rsi]
    add rsi, 4
    jmp .havefcs
.fcs8:
    mov rax, [rsi]
    add rsi, 8
.havefcs:
    lea rcx, [rdi+rax]
    cmp rcx, [rbx+ZS_OEND]
    failif a
    mov [rsp+32], rax
    jmp .blocks
.nofcs:
    mov qword [rsp+32], -1
.blocks:
    ; a new frame starts clean
    mov [rbx+ZS_OSTART], rdi
    mov qword [rbx+ZS_REP], 1
    mov qword [rbx+ZS_REP+8], 4
    mov qword [rbx+ZS_REP+16], 8
    mov dword [rbx+ZS_HUFLOG], 0
.block:
    mov eax, [rsi]
    and eax, 0xffffff
    add rsi, 3
    mov ecx, eax
    shr ecx, 3                  ; size
    mov edx, eax
    shr edx, 1
    and edx, 3                  ; 0 raw, 1 rle, 2 compressed
    and eax, 1
    mov [rsp+40], rax           ; last block?
    lea r8, [rsi+rcx]
    cmp edx, 1
    je .rle                     ; rle's size is its output size, not input
    cmp r8, r13
    failif a
    test edx, edx
    jz .raw
    cmp edx, 2
    failif ne
    mov rdx, rsi
    add rsi, rcx
    mov r8, rcx
    mov rcx, rbx
    mov r9, rdi
    call zblock
    test rax, rax
    failif z
    mov rdi, rax
    jmp .next
.raw:
    lea rax, [rdi+rcx]
    cmp rax, [rbx+ZS_OEND]
    failif a
    rep movsb
    jmp .next
.rle:
    lea rax, [rdi+rcx]
    cmp rax, [rbx+ZS_OEND]
    failif a
    movzx eax, byte [rsi]
    inc rsi
    rep stosb
.next:
    cmp qword [rsp+40], 0
    je .block
    mov rax, [rsp+32]
    cmp rax, -1
    je .nocheck
    mov rcx, rdi
    sub rcx, [rbx+ZS_OSTART]
    cmp rcx, rax
    jne .bad                    ; frame has to match its stated size
.nocheck:
    test r14d, 4
    jz .frame
    add rsi, 4                  ; content checksum, not checked
    jmp .frame
.skippable:
    mov eax, [rsi+4]
    lea rsi, [rsi+rax+8]
    jmp .frame
.done:
    mov rax, rdi
    sub rax, r12
    jmp .ret
.bad:
    mov rax, -1
.ret:
    add rsp, 56
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
