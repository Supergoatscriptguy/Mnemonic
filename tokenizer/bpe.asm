; byte-level bpe training.
;   1. every doc goes through the pre-tokenizer and the chunks ("words") get
;      counted, each thread into its own table, then merged into one
;   2. each unique word becomes a run of u16 tokens (its bytes) in one big array,
;      words separated by a sentinel so no pair spans two words
;   3. merge loop: take the most frequent adjacent pair (ties: smaller pair id),
;      make it a new token, rewrite every word that has it
; pair counts are kept up to date incrementally. rewriting a word only changes the
; pairs touching a merged spot, so each word reports exactly those as +/- deltas.
; the best pair comes off a max-heap with lazy deletion. finding the words to
; rewrite is a plain avx2 scan over all the tokens, split across the threads.
; naive mode recounts every pair for every merge instead, to check the fast one
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"

WTBITS  equ 22                  ; per thread word table, 4M slots
GWBITS  equ 24                  ; merged word table, 16M slots
MAPBITS equ 18                  ; per thread delta map
MAPSZ   equ 1 << MAPBITS
EMPTY   equ 0xffffffff
SENT    equ 0xffff              ; between words in the token array, never part of a pair
HCHUNK  equ 1 << 16             ; heap grows this many entries at a time

; per thread
T_WT    equ 0                   ; word table: u64 hash, u64 ptr, u32 len, u32 count
T_WTN   equ 8
T_KEYS  equ 16                  ; delta map: u32 pair keys
T_DELTA equ 24                  ;   i64 deltas
T_USED  equ 32                  ;   u32 slots in use, to clear them fast
T_NUSED equ 40
T_MARK  equ 48                  ; per word scratch: 1/2 = first/second half of a merge
T_MADE  equ 56                  ;   1 = new token here
T_DENSE equ 64                  ; u64 x 65536, first round of byte pair counts
T_SIZE  equ 128

; a pair table: u32 keys (a << 16 | b), i64 counts
TB_KEYS  equ 0
TB_CNTS  equ 8
TB_MASK  equ 16
TB_SHIFT equ 24
TB_USED  equ 32
TB_SIZE  equ 40

section .rdata
e_words  db "too many unique words for the table, use a smaller sample", 0
e_map    db "bpe delta map overflowed", 0
e_pairs  db "bpe pair table overflowed", 0

section .bss
alignb 8
job      resq 1
t0       resq 1
thr      resb T_SIZE * 64
nthr     resq 1                 ; threads with state, at least 1
gw       resq 1                 ; merged word table (32 byte slots)
gwn      resq 1
nwords   resq 1
npos     resq 1
wstart   resq 1                 ; u32 per word, plus one past the end
wlen     resq 1                 ; u32
wcnt     resq 1                 ; u64
toks     resq 1                 ; u16 per position
wid      resq 1                 ; u32 per position: which word it's in
pt       resb TB_SIZE           ; the pair counts
vt       resb TB_SIZE           ; a fresh recount, for checking
harena   resb ARENA_SIZE
heap     resq 1                 ; entries: i64 count, u32 key, pad
hsize    resq 1
hcap     resq 1
plist    resq 1                 ; keys whose count went up this merge
tsoff    resq 1                 ; token strings, for progress output
tslen    resq 1
tsblob   resq 1
tsused   resq 1
lastshow resq 1
ma       resw 1                 ; the merge being applied
mb       resw 1
mc       resw 1

section .text

; ---- word counting

; par_for: docs rdx..r8, thread r9
count_task:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov r12, rdx
    mov r13, r8
    imul rbx, r9, T_SIZE
    lea rax, [thr]
    add rbx, rax
    cmp qword [rbx+T_WT], 0
    jne .doc
    mov rcx, (1 << WTBITS) * 24
    call mem_alloc
    mov [rbx+T_WT], rax
.doc:
    cmp r12, r13
    jae .done
    mov rax, [job]
    mov rax, [rax+BT_DOCS]
    mov rcx, r12
    shl rcx, 4
    mov rsi, [rax+rcx]
    mov r14, [rax+rcx+8]
    add r14, rsi
.chunk:
    cmp rsi, r14
    jae .ndoc
    mov rcx, rsi
    mov rdx, r14
    call pretok_next
    mov r15, rax
    mov rdx, rax
    sub rdx, rsi
    cmp rdx, MAXWORD
    ja .skip                    ; giant chunks (base64 and such) aren't worth learning from
    mov rcx, rsi
    call wt_add
.skip:
    mov rsi, r15
    jmp .chunk
.ndoc:
    inc r12
    jmp .doc
.done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = chunk, rdx = len, rbx = thread. count it in the thread's word table
wt_add:
    push rsi
    push rdi
    push r12
    mov rsi, rcx
    mov rdi, rdx
    call whash
    mov r12, rax
    mov rcx, rax
    shr rcx, 64 - WTBITS
    mov r8, [rbx+T_WT]
.probe:
    lea r9, [rcx+rcx*2]
    lea r9, [r8+r9*8]
    mov rax, [r9]
    test rax, rax
    jz .new
    cmp rax, r12
    jne .next
    cmp [r9+16], edi
    jne .next
    mov r10, [r9+8]
    mov r11, rsi
    mov rdx, rdi
    call memeq
    je .found
.next:
    inc rcx
    and rcx, (1 << WTBITS) - 1
    jmp .probe
.new:
    mov [r9], r12
    mov [r9+8], rsi
    mov [r9+16], edi
    mov dword [r9+20], 1
    inc qword [rbx+T_WTN]
    cmp qword [rbx+T_WTN], (3 << WTBITS) / 4
    jb .ret
    and rsp, -16
    sub rsp, 32
    lea rcx, [e_words]
    call fatal
.found:
    inc dword [r9+20]
.ret:
    pop r12
    pop rdi
    pop rsi
    ret

; folds every thread's table into one (32 byte slots: hash, ptr, len, count u64)
merge_words:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rcx, (1 << GWBITS) * 32
    call mem_alloc
    mov [gw], rax
    mov qword [gwn], 0
    xor r12d, r12d
.thread:
    cmp r12, [nthr]
    jae .done
    imul rbx, r12, T_SIZE
    lea rax, [thr]
    add rbx, rax
    mov r13, [rbx+T_WT]
    test r13, r13
    jz .tnext
    xor r14d, r14d
.slot:
    cmp r14, 1 << WTBITS
    jae .tfree
    lea rax, [r14+r14*2]
    lea rsi, [r13+rax*8]
    cmp qword [rsi], 0
    je .snext
    ; find it in the big table
    mov rcx, [rsi]
    shr rcx, 64 - GWBITS
    mov r15, [gw]
.probe:
    mov rdi, rcx
    shl rdi, 5
    add rdi, r15
    mov rax, [rdi]
    test rax, rax
    jz .new
    cmp rax, [rsi]
    jne .pnext
    mov eax, [rsi+16]
    cmp [rdi+16], eax
    jne .pnext
    mov r10, [rdi+8]
    mov r11, [rsi+8]
    mov edx, [rsi+16]
    call memeq
    je .add
.pnext:
    inc rcx
    and rcx, (1 << GWBITS) - 1
    jmp .probe
.new:
    mov rax, [rsi]
    mov [rdi], rax
    mov rax, [rsi+8]
    mov [rdi+8], rax
    mov eax, [rsi+16]
    mov [rdi+16], eax
    inc qword [gwn]
    cmp qword [gwn], (3 << GWBITS) / 4
    jb .add
    lea rcx, [e_words]
    call fatal
.add:
    mov eax, [rsi+20]
    add [rdi+24], rax
.snext:
    inc r14
    jmp .slot
.tfree:
    mov rcx, r13
    call mem_free
    mov qword [rbx+T_WT], 0
    mov qword [rbx+T_WTN], 0
.tnext:
    inc r12
    jmp .thread
.done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; lays the words out as tokens: bytes, then a sentinel
build_words:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    ; sizes first
    mov rax, [gwn]
    mov [nwords], rax
    xor r12d, r12d
    mov rsi, [gw]
    mov rcx, 1 << GWBITS
.sz:
    cmp qword [rsi], 0
    je .sz1
    mov eax, [rsi+16]
    lea r12, [r12+rax+1]
.sz1:
    add rsi, 32
    dec rcx
    jnz .sz
    mov [npos], r12
    mov rcx, [nwords]
    lea rcx, [rcx*4+4]
    call mem_alloc
    mov [wstart], rax
    mov rcx, [nwords]
    shl rcx, 2
    call mem_alloc
    mov [wlen], rax
    mov rcx, [nwords]
    shl rcx, 3
    call mem_alloc
    mov [wcnt], rax
    lea rcx, [r12*2+128]
    call mem_alloc
    mov [toks], rax
    lea rcx, [r12*4+256]
    call mem_alloc
    mov [wid], rax
    ; fill
    mov rsi, [gw]
    xor r13d, r13d              ; word
    xor r14d, r14d              ; position
    mov r15, 1 << GWBITS
.w:
    cmp qword [rsi], 0
    je .wnext
    mov rax, [wstart]
    mov [rax+r13*4], r14d
    mov ecx, [rsi+16]
    mov rax, [wlen]
    mov [rax+r13*4], ecx
    mov rax, [rsi+24]
    mov rdx, [wcnt]
    mov [rdx+r13*8], rax
    mov r8, [rsi+8]             ; the bytes
    mov r9, [toks]
    mov r10, [wid]
.b:
    movzx eax, byte [r8]
    mov [r9+r14*2], ax
    mov [r10+r14*4], r13d
    inc r8
    inc r14
    dec ecx
    jnz .b
    mov word [r9+r14*2], SENT
    mov [r10+r14*4], r13d
    inc r14
    inc r13
.wnext:
    add rsi, 32
    dec r15
    jnz .w
    mov rax, [wstart]
    mov [rax+r13*4], r14d
    ; the avx2 scan reads a little past the end
    mov r9, [toks]
    mov ecx, 64
.pad:
    mov word [r9+r14*2], SENT
    inc r14
    dec ecx
    jnz .pad
    mov rcx, [gw]
    call mem_free
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- pair tables

; r11 = table, ecx = log2 of its size
tb_init:
    push rbx
    push rdi
    sub rsp, 40
    mov rbx, r11
    mov eax, 1
    shl rax, cl
    lea rdx, [rax-1]
    mov [rbx+TB_MASK], rdx
    mov edx, 32
    sub edx, ecx
    mov [rbx+TB_SHIFT], rdx
    mov qword [rbx+TB_USED], 0
    mov [rsp+32], rax
    lea rcx, [rax*4]
    call mem_alloc
    mov [rbx+TB_KEYS], rax
    mov rdi, rax
    mov rcx, [rsp+32]
    mov eax, EMPTY
    rep stosd
    mov rcx, [rsp+32]
    shl rcx, 3
    call mem_alloc
    mov [rbx+TB_CNTS], rax
    mov r11, rbx
    add rsp, 40
    pop rdi
    pop rbx
    ret

; r11 = table: all keys empty, all counts 0
tb_clear:
    push rdi
    mov rdi, [r11+TB_KEYS]
    mov rcx, [r11+TB_MASK]
    inc rcx
    mov eax, EMPTY
    rep stosd
    mov rdi, [r11+TB_CNTS]
    mov rcx, [r11+TB_MASK]
    inc rcx
    xor eax, eax
    rep stosq
    mov qword [r11+TB_USED], 0
    pop rdi
    ret

; r11 = table
tb_free:
    push rbx
    sub rsp, 32
    mov rbx, r11
    mov rcx, [rbx+TB_KEYS]
    call mem_free
    mov rcx, [rbx+TB_CNTS]
    call mem_free
    mov r11, rbx
    add rsp, 32
    pop rbx
    ret

; ecx = key, r11 = table. rax = its slot, made if it's new. touches rdx, r8
tb_slot:
    mov eax, ecx
    mov edx, 0x9e3779b1
    imul eax, edx
    mov edx, [r11+TB_SHIFT]
    shrx eax, eax, edx
    mov r8, [r11+TB_KEYS]
.probe:
    mov edx, [r8+rax*4]
    cmp edx, ecx
    je .ret
    cmp edx, EMPTY
    je .new
    inc eax
    and eax, [r11+TB_MASK]
    jmp .probe
.new:
    mov [r8+rax*4], ecx
    mov rdx, [r11+TB_USED]
    inc rdx
    mov [r11+TB_USED], rdx
    mov r8, [r11+TB_MASK]
    shr r8, 1
    add r8, rdx
    cmp r8, [r11+TB_MASK]       ; past 1/2 full, probing gets slow. treat it as full
    jae .full
.ret:
    ret
.full:
    and rsp, -16
    sub rsp, 32
    lea rcx, [e_pairs]
    call fatal

; ecx = key, r11 = table. rax = its count, 0 if it isn't there. touches rdx, r8
tb_get:
    mov eax, ecx
    mov edx, 0x9e3779b1
    imul eax, edx
    mov edx, [r11+TB_SHIFT]
    shrx eax, eax, edx
    mov r8, [r11+TB_KEYS]
.probe:
    mov edx, [r8+rax*4]
    cmp edx, ecx
    je .hit
    cmp edx, EMPTY
    je .none
    inc eax
    and eax, [r11+TB_MASK]
    jmp .probe
.hit:
    mov r8, [r11+TB_CNTS]
    mov rax, [r8+rax*8]
    ret
.none:
    xor eax, eax
    ret

; r11 = table: count every pair in every word from scratch
recount:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    xor r12d, r12d
.w:
    cmp r12, [nwords]
    jae .done
    mov rax, [wstart]
    mov esi, [rax+r12*4]
    shl rsi, 1
    add rsi, [toks]
    mov rax, [wlen]
    mov r13d, [rax+r12*4]
    mov rax, [wcnt]
    mov r14, [rax+r12*8]
    xor edi, edi
.p:
    lea eax, [rdi+1]
    cmp eax, r13d
    jae .wnext
    movzx ecx, word [rsi+rdi*2]
    shl ecx, 16
    mov cx, [rsi+rdi*2+2]
    call tb_slot
    mov r8, [r11+TB_CNTS]
    add [r8+rax*8], r14
    inc edi
    jmp .p
.wnext:
    inc r12
    jmp .w
.done:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- heap: biggest count on top, smaller key first on ties

; is entry at %1 above (count %2, key %3)? jumps to %4 if so
%macro above 4
    cmp [%1], %2
    jg %4
    jl %%no
    cmp [%1+8], %3
    jb %4
%%no:
%endmacro

; rcx = count, edx = key
hpush:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov edi, edx
    mov rax, [hsize]
    cmp rax, [hcap]
    jb .room
    lea rcx, [harena]
    mov edx, HCHUNK * 16
    mov r8d, 16
    call arena_alloc
    cmp qword [hcap], 0
    jne .grown
    mov [heap], rax
.grown:
    add qword [hcap], HCHUNK
.room:
    mov rbx, [heap]
    mov rcx, [hsize]
    inc qword [hsize]
.up:
    test rcx, rcx
    jz .put
    lea rdx, [rcx-1]
    shr rdx, 1
    mov r8, rdx
    shl r8, 4
    add r8, rbx
    above r8, rsi, edi, .put
    mov r9, rcx
    shl r9, 4
    mov rax, [r8]
    mov [rbx+r9], rax
    mov rax, [r8+8]
    mov [rbx+r9+8], rax
    mov rcx, rdx
    jmp .up
.put:
    shl rcx, 4
    mov [rbx+rcx], rsi
    mov [rbx+rcx+8], rdi
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; drops the top entry
hpop:
    push rbx
    push rsi
    push rdi
    push r12
    mov rbx, [heap]
    mov r12, [hsize]
    dec r12
    mov [hsize], r12
    mov rax, r12
    shl rax, 4
    mov rsi, [rbx+rax]          ; the last one, sinking from the top
    mov edi, [rbx+rax+8]
    xor ecx, ecx
.down:
    lea rdx, [rcx*2+1]
    cmp rdx, r12
    jae .put
    mov r8, rdx
    shl r8, 4
    add r8, rbx
    lea r9, [rdx+1]
    cmp r9, r12
    jae .pick
    mov r10, r9
    shl r10, 4
    add r10, rbx
    mov rax, [r10]
    mov r11d, [r10+8]
    above r8, rax, r11d, .pick
    mov rdx, r9
    mov r8, r10
.pick:
    above r8, rsi, edi, .move
    jmp .put
.move:
    mov r9, rcx
    shl r9, 4
    mov rax, [r8]
    mov [rbx+r9], rax
    mov rax, [r8+8]
    mov [rbx+r9+8], rax
    mov rcx, rdx
    jmp .down
.put:
    shl rcx, 4
    mov [rbx+rcx], rsi
    mov [rbx+rcx+8], rdi
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; best pair by the heap. rax = count (0 = none left), edx = key
fast_best:
    push rbx
    push rsi
    sub rsp, 40
.top:
    cmp qword [hsize], 0
    je .none
    mov rax, [heap]
    mov rbx, [rax]
    mov esi, [rax+8]
    lea r11, [pt]
    mov ecx, esi
    call tb_get
    cmp rbx, rax
    je .good
    jl .older                   ; a newer, bigger entry for this pair is in there
    ; count dropped since this went in: put it back with the real one
    mov [rsp+32], rax
    call hpop
    mov rcx, [rsp+32]
    test rcx, rcx
    jz .top
    mov edx, esi
    call hpush
    jmp .top
.older:
    call hpop
    jmp .top
.good:
    call hpop
    mov rax, rbx
    mov edx, esi
    jmp .ret
.none:
    xor eax, eax
.ret:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; best pair by counting everything. rax = count, edx = key
naive_best:
    push rbx
    push rsi
    sub rsp, 40
    lea r11, [pt]
    call tb_clear
    call recount
    xor eax, eax                ; best count
    mov edx, EMPTY              ; its key
    mov r8, [pt+TB_KEYS]
    mov r9, [pt+TB_CNTS]
    xor ecx, ecx
.s:
    cmp rcx, [pt+TB_MASK]
    ja .done
    mov r10d, [r8+rcx*4]
    cmp r10d, EMPTY
    je .n
    mov r11, [r9+rcx*8]
    cmp r11, rax
    jg .take
    jl .n
    cmp r10d, edx
    jae .n
.take:
    mov rax, r11
    mov edx, r10d
.n:
    inc rcx
    jmp .s
.done:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; ---- merging

; ecx = pair key, rax = amount, rbx = thread. adds into its delta map. touches r8-r11
delta:
    mov r8d, ecx
    mov r9d, 0x9e3779b1
    imul r8d, r9d
    shr r8d, 32 - MAPBITS
    mov r9, [rbx+T_KEYS]
.probe:
    mov r10d, [r9+r8*4]
    cmp r10d, ecx
    je .hit
    cmp r10d, EMPTY
    je .new
    inc r8d
    and r8d, MAPSZ - 1
    jmp .probe
.new:
    mov [r9+r8*4], ecx
    mov r10, [rbx+T_DELTA]
    mov qword [r10+r8*8], 0
    mov r10, [rbx+T_USED]
    mov r11, [rbx+T_NUSED]
    mov [r10+r11*4], r8d
    inc r11
    mov [rbx+T_NUSED], r11
    cmp r11, MAPSZ * 3 / 4
    jae .full
.hit:
    mov r10, [rbx+T_DELTA]
    add [r10+r8*8], rax
    ret
.full:
    and rsp, -16
    sub rsp, 32
    lea rcx, [e_map]
    call fatal

; applies the merge to word ecx, reporting the pairs that change. rbx = thread
do_word:
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r15d, ecx
    mov rax, [wstart]
    mov eax, [rax+r15*4]
    mov r12, [toks]
    lea r12, [r12+rax*2]
    mov rax, [wlen]
    mov r13d, [rax+r15*4]
    mov rax, [wcnt]
    mov r14, [rax+r15*8]
    mov rsi, [rbx+T_MARK]
    mov rdi, [rbx+T_MADE]
    xor eax, eax
    xor edx, edx
.clr:
    cmp edx, r13d
    jae .find
    mov [rsi+rdx], al
    inc edx
    jmp .clr
.find:
    ; left to right, no overlaps: "a a a" merging (a,a) is [aa] a
    movzx r8d, word [ma]
    movzx r9d, word [mb]
    xor edx, edx
.f:
    lea eax, [rdx+1]
    cmp eax, r13d
    jae .old
    cmp [r12+rdx*2], r8w
    jne .f1
    cmp [r12+rdx*2+2], r9w
    jne .f1
    mov byte [rsi+rdx], 1
    mov byte [rsi+rdx+1], 2
    add edx, 2
    jmp .f
.f1:
    inc edx
    jmp .f
.old:
    ; every old pair touching a merged spot goes away
    mov rax, r14
    neg rax
    xor edx, edx
.o:
    lea ecx, [rdx+1]
    cmp ecx, r13d
    jae .rw
    movzx ecx, byte [rsi+rdx]
    or cl, [rsi+rdx+1]
    jz .o1
    movzx ecx, word [r12+rdx*2]
    shl ecx, 16
    mov cx, [r12+rdx*2+2]
    call delta
.o1:
    inc edx
    jmp .o
.rw:
    ; rewrite it in place
    movzx r9d, word [mc]
    xor edx, edx
    xor r8d, r8d
.r:
    cmp edx, r13d
    jae .rwd
    cmp byte [rsi+rdx], 1
    jne .copy
    mov [r12+r8*2], r9w
    mov byte [rdi+r8], 1
    add edx, 2
    inc r8d
    jmp .r
.copy:
    movzx eax, word [r12+rdx*2]
    mov [r12+r8*2], ax
    mov byte [rdi+r8], 0
    inc edx
    inc r8d
    jmp .r
.rwd:
    mov ecx, r8d
.tail:
    cmp ecx, r13d
    jae .tdone
    mov word [r12+rcx*2], SENT
    inc ecx
    jmp .tail
.tdone:
    mov r13d, r8d
    mov rax, [wlen]
    mov [rax+r15*4], r13d
    ; and every new pair touching the new token appears
    mov rax, r14
    xor edx, edx
.n:
    lea ecx, [rdx+1]
    cmp ecx, r13d
    jae .done
    movzx ecx, byte [rdi+rdx]
    or cl, [rdi+rdx+1]
    jz .n1
    movzx ecx, word [r12+rdx*2]
    shl ecx, 16
    mov cx, [r12+rdx*2+2]
    call delta
.n1:
    inc edx
    jmp .n
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    ret

; par_for: words rdx..r8, thread r9. scans their tokens for the pair 16 at a time
merge_task:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    imul rbx, r9, T_SIZE
    lea rax, [thr]
    add rbx, rax
    mov r12, [wstart]
    mov esi, [r12+rdx*4]
    mov edi, [r12+r8*4]
    mov r13, [toks]
    mov r14, [wid]
    vpbroadcastw ymm1, [ma]
    vpbroadcastw ymm2, [mb]
.scan:
    cmp rsi, rdi
    jae .done
    vmovdqu ymm0, [r13+rsi*2]
    vpcmpeqw ymm0, ymm0, ymm1
    vmovdqu ymm3, [r13+rsi*2+2]
    vpcmpeqw ymm3, ymm3, ymm2
    vpand ymm0, ymm0, ymm3
    vpmovmskb eax, ymm0
    test eax, eax
    jnz .hit
    add rsi, 16
    jmp .scan
.hit:
    tzcnt eax, eax
    shr eax, 1                  ; 2 mask bits per u16
    add rax, rsi
    cmp rax, rdi
    jae .done
    mov r15d, [r14+rax*4]
    mov ecx, r15d
    call do_word                ; doesn't touch the ymm registers
    mov esi, [r12+r15*4+4]      ; carry on after that word
    jmp .scan
.done:
    vzeroupper
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; folds every thread's deltas into the pair table, then pushes the pairs that grew
apply_deltas:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    lea r11, [pt]
    xor r15d, r15d
    xor ebx, ebx
.t:
    cmp rbx, [nthr]
    jae .push
    imul rax, rbx, T_SIZE
    lea r13, [thr]
    add r13, rax
    mov r12, [r13+T_USED]
    mov r14, [r13+T_KEYS]
    mov rsi, [r13+T_DELTA]
    xor edi, edi
.u:
    cmp rdi, [r13+T_NUSED]
    jae .tnext
    mov eax, [r12+rdi*4]
    mov ecx, [r14+rax*4]
    mov dword [r14+rax*4], EMPTY
    mov r9, [rsi+rax*8]
    test r9, r9
    jz .unext
    call tb_slot
    mov r8, [pt+TB_CNTS]
    add [r8+rax*8], r9
    test r9, r9
    jle .unext
    mov r8, [plist]
    mov [r8+r15*4], ecx
    inc r15
.unext:
    inc rdi
    jmp .u
.tnext:
    mov qword [r13+T_NUSED], 0
    inc rbx
    jmp .t
.push:
    xor ebx, ebx
.p:
    cmp rbx, r15
    jae .done
    mov rax, [plist]
    mov esi, [rax+rbx*4]
    lea r11, [pt]
    mov ecx, esi
    call tb_get
    test rax, rax
    jle .pn
    mov rcx, rax
    mov edx, esi
    call hpush
.pn:
    inc rbx
    jmp .p
.done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; naive mode: the deltas are just thrown away
clear_deltas:
    xor ecx, ecx
.t:
    cmp rcx, [nthr]
    jae .done
    imul rax, rcx, T_SIZE
    lea r8, [thr]
    add r8, rax
    mov r9, [r8+T_USED]
    mov r10, [r8+T_KEYS]
    xor edx, edx
.u:
    cmp rdx, [r8+T_NUSED]
    jae .tn
    mov eax, [r9+rdx*4]
    mov dword [r10+rax*4], EMPTY
    inc rdx
    jmp .u
.tn:
    mov qword [r8+T_NUSED], 0
    inc rcx
    jmp .t
.done:
    ret

; par_for: words rdx..r8, thread r9. counts byte pairs into the thread's dense array
pairs_task:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov r12, rdx
    mov r13, r8
    imul rbx, r9, T_SIZE
    lea rax, [thr]
    add rbx, rax
    cmp qword [rbx+T_DENSE], 0
    jne .w
    mov ecx, 65536 * 8
    call mem_alloc
    mov [rbx+T_DENSE], rax
.w:
    cmp r12, r13
    jae .done
    mov rax, [wstart]
    mov esi, [rax+r12*4]
    shl rsi, 1
    add rsi, [toks]
    mov rax, [wlen]
    mov r14d, [rax+r12*4]
    mov rax, [wcnt]
    mov r8, [rax+r12*8]
    mov r9, [rbx+T_DENSE]
    xor edi, edi
.p:
    lea eax, [rdi+1]
    cmp eax, r14d
    jae .wn
    movzx ecx, word [rsi+rdi*2]
    shl ecx, 8
    or cx, [rsi+rdi*2+2]
    add [r9+rcx*8], r8
    inc edi
    jmp .p
.wn:
    inc r12
    jmp .w
.done:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- progress

; ecx = token. appends its bytes, escaped, at rdi
put_tok:
    push rsi
    mov rax, [tsoff]
    mov esi, [rax+rcx*4]
    add rsi, [tsblob]
    mov rax, [tslen]
    movzx edx, word [rax+rcx*2]
    mov byte [rdi], "'"
    inc rdi
.c:
    test edx, edx
    jz .end
    movzx eax, byte [rsi]
    inc rsi
    dec edx
    cmp eax, 10
    je .nl
    cmp eax, 9
    je .tab
    cmp eax, 32
    jb .hex
    cmp eax, 127
    je .hex
    mov [rdi], al
    inc rdi
    jmp .c
.nl:
    mov word [rdi], '\n'
    add rdi, 2
    jmp .c
.tab:
    mov word [rdi], '\t'
    add rdi, 2
    jmp .c
.hex:
    mov word [rdi], '\x'
    mov r8d, eax
    shr r8d, 4
    lea r9, [hexd]
    mov r8b, [r9+r8]
    mov [rdi+2], r8b
    and eax, 15
    mov al, [r9+rax]
    mov [rdi+3], al
    add rdi, 4
    jmp .c
.end:
    mov byte [rdi], "'"
    inc rdi
    pop rsi
    ret

; r12 = merges done so far. a status line, plus a line to keep for the first few
; and every 2500th, so you can watch what it learns
progress:
    push rsi
    push rdi
    sub rsp, 2088
    mov rax, [job]
    cmp qword [rax+BT_VERBOSE], 0
    je .ret
    cmp r12, 24
    jb .keep
    mov rax, r12
    xor edx, edx
    mov ecx, 2500
    div rcx
    test rdx, rdx
    jz .keep
    ; status line, at most 10 a second, only on a console
    cmp dword [con_tty], 0
    je .ret
    mov rcx, [lastshow]
    call time_since
    mov rax, 0x3fb999999999999a     ; 0.1
    movq xmm1, rax
    comisd xmm0, xmm1
    jb .ret
    call time_now
    mov [lastshow], rax
    lea rdi, [rsp+32]
    mov byte [rdi], 13
    inc rdi
    call line
    mov dword [rdi], 0x4b5b1b   ; esc [ K
    add rdi, 3
    jmp .print
.keep:
    lea rdi, [rsp+32]
    cmp dword [con_tty], 0
    je .k1
    mov dword [rdi], 0x4b5b1b0d ; \r esc [ K
    add rdi, 4
.k1:
    call line
    mov word [rdi], 0x0a0d
    add rdi, 2
.print:
    lea rcx, [rsp+32]
    mov rdx, rdi
    sub rdx, rcx
    call print
.ret:
    add rsp, 2088
    pop rdi
    pop rsi
    ret

; the text of a progress line at rdi: merge n/total, the new token, how often, time
line:
    push rbx
    sub rsp, 32
    mov dword [rdi], '  me'
    mov dword [rdi+4], 'rge '
    add rdi, 8
    mov rcx, rdi
    lea rdx, [r12+1]
    mov r8d, 5
    call fmt_dec0
    mov rdi, rax
    mov byte [rdi], '/'
    inc rdi
    mov rcx, rdi
    mov rax, [job]
    mov rdx, [rax+BT_NMERGES]
    call fmt_dec
    mov rdi, rax
    mov word [rdi], '  '
    add rdi, 2
    lea ecx, [r12d+256]
    call put_tok
    mov dword [rdi], '  x '
    add rdi, 3
    mov rcx, rdi
    mov rax, [job]
    mov rax, [rax+BT_COUNTS]
    mov rdx, [rax+r12*8]
    call fmt_count
    mov rdi, rax
    mov dword [rdi], '    '
    add rdi, 4
    mov rcx, [t0]
    call time_since
    movapd xmm1, xmm0
    mov rcx, rdi
    mov r8d, 1
    call fmt_fixed
    mov rdi, rax
    mov byte [rdi], 's'
    inc rdi
    add rsp, 32
    pop rbx
    ret

; rcx = what just finished. in verbose mode prints it with the time so far
stamp:
    push rbx
    sub rsp, 32
    mov rbx, rcx
    mov rax, [job]
    cmp qword [rax+BT_VERBOSE], 0
    je .ret
    say "  "
    mov rcx, rbx
    call print_z
    say ": "
    mov rcx, [t0]
    call time_since
    mov edx, 1
    call print_fixed
    say " s", 13, 10
.ret:
    add rsp, 32
    pop rbx
    ret

; token strings for token r12+256 from its two halves
add_string:
    push rsi
    push rdi
    movzx eax, word [ma]
    movzx edx, word [mb]
    mov r8, [tsoff]
    mov r9, [tslen]
    mov rdi, [tsblob]
    add rdi, [tsused]
    lea ecx, [r12d+256]
    mov r10, [tsused]
    mov [r8+rcx*4], r10d
    movzx r10d, word [r9+rax*2]
    movzx r11d, word [r9+rdx*2]
    add r10d, r11d
    mov [r9+rcx*2], r10w
    add [tsused], r10
    mov esi, [r8+rax*4]
    add rsi, [tsblob]
    movzx ecx, word [r9+rax*2]
    rep movsb
    mov esi, [r8+rdx*4]
    add rsi, [tsblob]
    movzx ecx, word [r9+rdx*2]
    rep movsb
    pop rdi
    pop rsi
    ret

section .rdata
m_counted db "counted words", 0
m_merged  db "merged the per-thread tables", 0
m_built   db "laid out the tokens", 0
m_pairs   db "counted the pairs", 0
hexd db "0123456789abcdef"
m_words db "  words: ", 0
m_uniq  db " unique, from ", 0
m_docs  db " docs", 13, 10, 0
m_ver   db "  checking the incremental counts against a full recount: ", 0
section .text

; ---- the whole thing

; rcx = params (BT_*)
global bpe_train
bpe_train:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov [job], rcx
    call time_now
    mov [t0], rax
    mov [lastshow], rax
    mov rax, [job]
    mov qword [rax+BT_BAD], 0
    mov qword [rax+BT_DONE], 0

    ; per thread state, kept between runs
    mov rax, [nthreads]
    cmp rax, 1
    jae .nt
    mov eax, 1
.nt:
    mov [nthr], rax
    xor r12d, r12d
.ts:
    cmp r12, [nthr]
    jae .tsd
    imul rbx, r12, T_SIZE
    lea rax, [thr]
    add rbx, rax
    cmp qword [rbx+T_KEYS], 0
    jne .tsn
    mov ecx, MAPSZ * 4
    call mem_alloc
    mov [rbx+T_KEYS], rax
    mov rdi, rax
    mov ecx, MAPSZ
    mov eax, EMPTY
    rep stosd
    mov ecx, MAPSZ * 8
    call mem_alloc
    mov [rbx+T_DELTA], rax
    mov ecx, MAPSZ * 4
    call mem_alloc
    mov [rbx+T_USED], rax
    mov ecx, MAXWORD + 64
    call mem_alloc
    mov [rbx+T_MARK], rax
    mov ecx, MAXWORD + 64
    call mem_alloc
    mov [rbx+T_MADE], rax
.tsn:
    inc r12
    jmp .ts
.tsd:
    cmp qword [harena+AR_BASE], 0
    jne .ha
    lea rcx, [harena]
    mov rdx, 1 << 36
    call arena_init
.ha:
    lea rcx, [harena]
    call arena_reset
    xor eax, eax
    mov [hsize], rax
    mov [hcap], rax
    mov rcx, [nthr]
    imul rcx, rcx, MAPSZ * 4
    call mem_alloc
    mov [plist], rax

    ; token strings, bytes to start with
    mov ecx, VOCAB * 4
    call mem_alloc
    mov [tsoff], rax
    mov ecx, VOCAB * 2
    call mem_alloc
    mov [tslen], rax
    mov ecx, VOCAB * MAXWORD
    call mem_alloc
    mov [tsblob], rax
    mov qword [tsused], 256
    xor ecx, ecx
.bytes:
    mov rax, [tsoff]
    mov [rax+rcx*4], ecx
    mov rax, [tslen]
    mov word [rax+rcx*2], 1
    mov rax, [tsblob]
    mov [rax+rcx], cl
    inc ecx
    cmp ecx, 256
    jb .bytes

    ; 1. words
    lea rcx, [count_task]
    xor edx, edx
    mov rax, [job]
    mov r8, [rax+BT_NDOCS]
    mov r9d, 64
    call par_for
    lea rcx, [m_counted]
    call stamp
    call merge_words
    lea rcx, [m_merged]
    call stamp
    call build_words
    lea rcx, [m_built]
    call stamp
    mov rax, [job]
    mov rcx, [nwords]
    mov [rax+BT_WORDS], rcx
    cmp qword [rax+BT_VERBOSE], 0
    je .pairs
    lea rcx, [m_words]
    call print_z
    mov rcx, [nwords]
    call print_dec
    lea rcx, [m_uniq]
    call print_z
    mov rax, [job]
    mov rcx, [rax+BT_NDOCS]
    call print_dec
    lea rcx, [m_docs]
    call print_z

.pairs:
    ; 2. pair table, counted up front unless we're in naive mode
    lea r11, [pt]
    mov ecx, 25
    mov rax, [job]
    cmp qword [rax+BT_NAIVE], 0
    je .ptsize
    mov ecx, 20
.ptsize:
    call tb_init
    mov rax, [job]
    cmp qword [rax+BT_NAIVE], 0
    jne .loop0
    lea rcx, [pairs_task]
    xor edx, edx
    mov r8, [nwords]
    mov r9d, 4096
    call par_for
    xor r12d, r12d              ; byte pair a << 8 | b
.dense:
    cmp r12d, 65536
    jae .densed
    xor r13d, r13d
    xor r14d, r14d
.dsum:
    cmp r14, [nthr]
    jae .dput
    imul rax, r14, T_SIZE
    lea rcx, [thr]
    mov rax, [rcx+rax+T_DENSE]
    test rax, rax
    jz .dnext
    add r13, [rax+r12*8]
.dnext:
    inc r14
    jmp .dsum
.dput:
    test r13, r13
    jz .dn
    mov ecx, r12d
    shr ecx, 8
    shl ecx, 16
    mov eax, r12d
    and eax, 255
    or ecx, eax
    mov esi, ecx
    lea r11, [pt]
    call tb_slot
    mov r8, [pt+TB_CNTS]
    mov [r8+rax*8], r13
    mov rcx, r13
    mov edx, esi
    call hpush
.dn:
    inc r12d
    jmp .dense
.densed:
    xor r14d, r14d
.dfree:
    cmp r14, [nthr]
    jae .loop0
    imul rax, r14, T_SIZE
    lea rbx, [thr]
    add rbx, rax
    mov rcx, [rbx+T_DENSE]
    test rcx, rcx
    jz .dfn
    call mem_free
    mov qword [rbx+T_DENSE], 0
.dfn:
    inc r14
    jmp .dfree

.loop0:
    lea rcx, [m_pairs]
    call stamp
    ; 3. merges
    xor r12d, r12d
    mov r13, -1                 ; the last count. it should never go up
.merge:
    mov rax, [job]
    cmp r12, [rax+BT_NMERGES]
    jae .merged
    cmp qword [rax+BT_NAIVE], 0
    jne .nb
    call fast_best
    jmp .gotbest
.nb:
    call naive_best
.gotbest:
    test rax, rax
    jle .merged
    cmp rax, r13
    jbe .mono
    mov rcx, [job]
    inc qword [rcx+BT_BAD]
.mono:
    mov r13, rax
    mov rcx, [job]
    mov r8, [rcx+BT_COUNTS]
    mov [r8+r12*8], rax
    mov r8, [rcx+BT_MERGES]
    mov r14d, edx
    rol edx, 16                 ; stored as a | b << 16
    mov [r8+r12*4], edx
    mov eax, r14d
    shr eax, 16
    mov [ma], ax
    mov [mb], r14w
    lea eax, [r12d+256]
    mov [mc], ax
    call add_string
    lea rcx, [merge_task]
    xor edx, edx
    mov r8, [nwords]
    mov r9d, 4096
    call par_for
    mov rax, [job]
    cmp qword [rax+BT_NAIVE], 0
    jne .nclear
    call apply_deltas
    lea r11, [pt]               ; that pair should be all gone now
    mov ecx, r14d
    call tb_get
    test rax, rax
    jz .shown
    mov rcx, [job]
    inc qword [rcx+BT_BAD]
    jmp .shown
.nclear:
    call clear_deltas
.shown:
    call progress
    inc r12
    jmp .merge

.merged:
    mov rax, [job]
    mov [rax+BT_DONE], r12
    cmp qword [rax+BT_VERBOSE], 0
    je .verify
    cmp dword [con_tty], 0
    je .verify
    say 13, 27, "[K"
.verify:
    ; 4. the incremental counts have to match a recount from scratch
    mov rax, [job]
    cmp qword [rax+BT_NAIVE], 0
    jne .free
    lea r11, [vt]
    mov ecx, 25
    call tb_init
    lea r11, [vt]
    call recount
    xor r12d, r12d              ; every recounted pair, same count in pt
.v1:
    cmp r12, [vt+TB_MASK]
    ja .v2
    mov rax, [vt+TB_KEYS]
    mov ecx, [rax+r12*4]
    cmp ecx, EMPTY
    je .v1n
    mov rax, [vt+TB_CNTS]
    mov r13, [rax+r12*8]
    lea r11, [pt]
    call tb_get
    cmp rax, r13
    je .v1n
    mov rax, [job]
    inc qword [rax+BT_BAD]
.v1n:
    inc r12
    jmp .v1
.v2:
    xor r12d, r12d              ; and every nonzero pair in pt, same count in the recount
.v2l:
    cmp r12, [pt+TB_MASK]
    ja .vdone
    mov rax, [pt+TB_KEYS]
    mov ecx, [rax+r12*4]
    cmp ecx, EMPTY
    je .v2n
    mov rax, [pt+TB_CNTS]
    mov r13, [rax+r12*8]
    test r13, r13
    jz .v2n
    lea r11, [vt]
    call tb_get
    cmp rax, r13
    je .v2n
    mov rax, [job]
    inc qword [rax+BT_BAD]
.v2n:
    inc r12
    jmp .v2l
.vdone:
    lea r11, [vt]
    call tb_free
    mov rax, [job]
    cmp qword [rax+BT_VERBOSE], 0
    je .free
    lea rcx, [m_ver]
    call print_z
    mov rax, [job]
    cmp qword [rax+BT_BAD], 0
    jne .vbad
    say "exact", 13, 10
    jmp .free
.vbad:
    mov rax, [job]
    mov rcx, [rax+BT_BAD]
    call print_dec
    say " MISMATCHES", 13, 10

.free:
    lea r11, [pt]
    call tb_free
    mov rcx, [toks]
    call mem_free
    mov rcx, [wid]
    call mem_free
    mov rcx, [wstart]
    call mem_free
    mov rcx, [wlen]
    call mem_free
    mov rcx, [wcnt]
    call mem_free
    mov rcx, [plist]
    call mem_free
    mov rcx, [tsoff]
    call mem_free
    mov rcx, [tslen]
    call mem_free
    mov rcx, [tsblob]
    call mem_free
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
