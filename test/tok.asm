; stage 3 test: pre-tokenizer splits, fast bpe training against the naive
; version, the encoder (cached vs not, round trips), and whole .tok files decoded
; back against their .docs. the data parts skip if the files aren't there
; uses: tokenizer\pretok tokenizer\bpe tokenizer\tok tokenizer\render
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"
%include "data/docs.inc"
%include "test/check.inc"

NM       equ 600                ; merges for the fast vs naive run
ROUND    equ 3000               ; docs for the encode round trips

section .rdata
f_docs0  db "datasets\fineweb\shard_00000.docs", 0
f_docs1  db "datasets\fineweb\shard_00001.docs", 0
f_tok0   db "datasets\fineweb\shard_00000.tok", 0
f_sdocs  db "datasets\smoltalk\test-00000-of-00001.docs", 0
f_stok   db "datasets\smoltalk\test-00000-of-00001.tok", 0
f_tokz   db "datasets\tokenizer.bin", 0
s_the    db " the"
s_bos    db "<|bos|>"

section .bss
alignb 8
bta      resb BT_SIZE
btb      resb BT_SIZE
dlist    resq 1
ctx1     resq 1
ctx2     resq 1
enc1     resq 1
enc2     resq 1
decb     resq 1
d        resq 1                 ; a mapped .docs
tk       resq 1                 ; a mapped .tok
bad      resq 1

section .text

; rcx = text, rdx = len. writes its chunks into tbuf joined by |, rax = end
joined:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov r12, rcx
    lea rbx, [rcx+rdx]
    lea rdi, [tbuf]
.next:
    cmp rsi, rbx
    jae .done
    cmp rsi, r12
    je .first
    mov byte [rdi], '|'
    inc rdi
.first:
    mov rcx, rsi
    mov rdx, rbx
    call pretok_next
    mov rcx, rax
    sub rcx, rsi
    rep movsb                   ; leaves rsi at the end of the chunk
    jmp .next
.done:
    mov rax, rdi
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; split %1 and expect %2 (chunks joined by |)
%macro split 2
    section .rdata
    %%s db %1
    %%n equ $ - %%s
    section .text
    lea rcx, [%%s]
    mov edx, %%n
    call joined
    expect %2
%endmacro

global start
start:
    sub rsp, 40
    call lib_init

    say "pre-tokenizer", 13, 10
    split "Hello world", "Hello| world"
    split "don't", "don|'t"
    split "I'll WE'RE they've", "I|'ll| WE|'RE| they|'ve"
    split "'sam", "'s|am"
    split "123456", "12|34|56"
    split "$9.99", "$|9|.|99"
    split "  hello", " | hello"
    split "hello!!!", "hello|!!!"
    split "(test)", "(test|)"
    split "a... b", "a|...| b"
    split {"a", 10, 10, "b"}, {"a|", 10, 10, "|b"}
    split {"x  ", 10, "  y"}, {"x|  ", 10, "| | y"}
    split {"end.", 10, 10, "Next"}, {"end|.", 10, 10, "|Next"}
    split {9, "tab"}, {9, "tab"}
    split "x 123", "x| |12|3"
    split "hi  ", "hi|  "
    split {"caf", 0xc3, 0xa9, " na", 0xc3, 0xaf, "ve"}, {"caf", 0xc3, 0xa9, "| na", 0xc3, 0xaf, "ve"}
    split {0xe2, 0x80, 0x9c, "quoted", 0xe2, 0x80, 0x9d}, {0xe2, 0x80, 0x9c, "quoted|", 0xe2, 0x80, 0x9d}
    split {"a", 0xe2, 0x80, 0x94, "b"}, {"a|", 0xe2, 0x80, 0x94, "b"}
    split "x = y;", "x| =| y|;"

    lea rcx, [f_docs0]
    call file_exists
    test eax, eax
    jnz .bpe
    say "  (no fineweb .docs, skipping the rest. download + extract shard 0)", 13, 10
    jmp t_done

.bpe:
    say "bpe training, fast vs naive (2 MB, "
    mov ecx, NM
    call print_dec
    say " merges)", 13, 10
    xor ecx, ecx
    call pool_init
    lea rcx, [f_docs0]
    call file_map
    mov [d], rax
    ; docs until we have 2 MB
    mov ecx, 4096 * 16
    call mem_alloc
    mov [dlist], rax
    mov rbx, [d]
    mov rsi, [rbx+DH_OFFS]
    add rsi, rbx
    mov rdi, [dlist]
    xor ecx, ecx
    xor edx, edx                ; bytes
.take:
    cmp rdx, 2000000
    jae .took
    mov rax, [rsi+rcx*8]
    mov r8, [rsi+rcx*8+8]
    sub r8, rax
    add rax, [rbx+DH_TEXT]
    add rax, rbx
    mov [rdi], rax
    mov [rdi+8], r8
    add rdi, 16
    add rdx, r8
    inc rcx
    jmp .take
.took:
    mov r12, rcx
    lea rbx, [bta]
    call setup_bt
    lea rbx, [btb]
    call setup_bt
    mov qword [btb+BT_NAIVE], 1
    lea rcx, [bta]
    call bpe_train
    lea rcx, [btb]
    call bpe_train
    cmp qword [bta+BT_DONE], NM
    check e, "fast run did every merge"
    cmp qword [bta+BT_BAD], 0
    check e, "incremental counts match a recount, counts never go up"
    mov rsi, [bta+BT_MERGES]
    mov rdi, [btb+BT_MERGES]
    mov ecx, NM
    repe cmpsd
    check e, "same merges as the naive trainer"
    mov rsi, [bta+BT_COUNTS]
    mov rdi, [btb+BT_COUNTS]
    mov ecx, NM
    repe cmpsq
    check e, "same pair counts as the naive trainer"

    lea rcx, [f_tokz]
    call file_exists
    test eax, eax
    jnz .enc
    say "  (no datasets\tokenizer.bin, skipping the encoder. run bpetrain)", 13, 10
    jmp t_done

.enc:
    say "encoder", 13, 10
    lea rcx, [f_tokz]
    call tok_load
    call tok_cache_new
    mov [ctx1], rax
    call tok_cache_new
    mov [ctx2], rax
    mov dword [rax+TC_NOCACHE], 1
    ; " the" is one token
    mov rcx, [ctx1]
    lea rdx, [s_the]
    mov r8d, 4
    lea r9, [tbuf]
    call tok_encode
    cmp rax, 1
    check e, "' the' is a single token"
    mov ecx, TOK_BOS
    call tok_bytes
    mov rsi, rax
    lea rdi, [s_bos]
    mov ecx, 7
    repe cmpsb
    check e, "<|bos|> decodes to its name"
    mov ecx, 1 << 23            ; the round trips and the .tok walk both decode here
    call mem_alloc
    mov [decb], rax

    ; round trips over a few thousand docs of a shard the tokenizer didn't train on
    lea rcx, [f_docs1]
    call file_exists
    test eax, eax
    jz .tokfile
    lea rcx, [f_docs1]
    call file_map
    mov [d], rax
    mov ecx, 1 << 24
    call mem_alloc
    mov [enc1], rax
    mov ecx, 1 << 24
    call mem_alloc
    mov [enc2], rax
    mov qword [bad], 0
    xor r12d, r12d
    xor r13d, r13d              ; docs where the cache made a difference
.rt:
    cmp r12, ROUND
    jae .rtdone
    mov rbx, [d]
    mov rax, [rbx+DH_OFFS]
    add rax, rbx
    mov rsi, [rax+r12*8]
    mov r14, [rax+r12*8+8]
    sub r14, rsi                ; len
    add rsi, [rbx+DH_TEXT]
    add rsi, rbx
    mov rcx, [ctx1]
    mov rdx, rsi
    mov r8, r14
    mov r9, [enc1]
    call tok_encode
    mov r15, rax
    mov rcx, [ctx2]
    mov rdx, rsi
    mov r8, r14
    mov r9, [enc2]
    call tok_encode
    cmp rax, r15
    jne .diff
    push rsi
    mov rsi, [enc1]
    mov rdi, [enc2]
    mov rcx, r15
    repe cmpsw
    pop rsi
    je .same
.diff:
    inc r13
.same:
    mov rcx, [enc1]
    mov rdx, r15
    mov r8, [decb]
    call tok_decode
    cmp rax, r14
    jne .rtbad
    mov rdi, [decb]
    mov rcx, r14
    repe cmpsb
    je .rtn
.rtbad:
    inc qword [bad]
.rtn:
    inc r12
    jmp .rt
.rtdone:
    test r13, r13
    check z, "cached encoder = uncached encoder on 3000 unseen docs"
    cmp qword [bad], 0
    check e, "decode(encode(doc)) == doc for all of them"

.tokfile:
    lea rcx, [f_tok0]
    call file_exists
    test eax, eax
    jz .chat
    say "shard_00000.tok, decoded back against shard_00000.docs", 13, 10
    lea rcx, [f_docs0]
    call file_map
    mov [d], rax
    lea rcx, [f_tok0]
    call file_map
    mov [tk], rax
    mov rbx, rax
    mov rax, TF_MAGIC_V
    cmp [rbx+TF_MAGIC], rax
    check e, ".tok magic"
    mov rax, [rbx+TF_HASH]
    cmp rax, [tok_hash]
    check e, "made by this tokenizer (hash matches)"
    ; walk it: each <|bos|> starts the next doc, decode up to the next one
    lea r13, [rbx+TF_SIZE]      ; token cursor
    mov r14, [rbx+TF_NTOK]
    lea r14, [r13+r14*2]        ; end
    xor r12d, r12d              ; doc
    mov qword [bad], 0
.tdoc:
    cmp r13, r14
    jae .tend
    cmp word [r13], TOK_BOS
    jne .tfail
    add r13, 2
    mov r15, r13
.tscan:
    cmp r15, r14
    jae .tgot
    cmp word [r15], TOK_BOS
    je .tgot
    add r15, 2
    jmp .tscan
.tgot:
    mov rcx, r13
    mov rdx, r15
    sub rdx, r13
    shr rdx, 1
    mov r8, [decb]
    call tok_decode
    mov rbx, [d]
    mov rcx, [rbx+DH_OFFS]
    add rcx, rbx
    mov rsi, [rcx+r12*8]
    mov rdx, [rcx+r12*8+8]
    sub rdx, rsi
    cmp rax, rdx
    jne .tfail
    add rsi, [rbx+DH_TEXT]
    add rsi, rbx
    mov rdi, [decb]
    mov rcx, rdx
    repe cmpsb
    je .tok1
.tfail:
    inc qword [bad]
.tok1:
    inc r12
    mov r13, r15
    jmp .tdoc
.tend:
    mov rbx, [d]
    cmp r12, [rbx+DH_NDOCS]
    check e, "one <|bos|> per doc"
    cmp qword [bad], 0
    check e, "every doc decodes back byte for byte"

.chat:
    lea rcx, [f_stok]
    call file_exists
    test eax, eax
    jz .end
    say "smoltalk .tok: chat template and loss mask", 13, 10
    lea rcx, [f_stok]
    call file_map
    mov rbx, rax
    cmp qword [rbx+TF_FLAGS], 1
    check e, "marked as a chat file"
    ; targets are exactly: after <|assistant|>, up to and including its <|end|>
    lea r13, [rbx+TF_SIZE]
    mov r14, [rbx+TF_NTOK]
    lea r14, [r13+r14*2]
    xor r15d, r15d              ; inside an assistant turn?
    mov qword [bad], 0
    xor r12d, r12d              ; assistant turns seen
.ct:
    cmp r13, r14
    jae .cend
    movzx eax, word [r13]
    mov ecx, eax
    and ecx, MASKBIT - 1
    test eax, MASKBIT
    setnz dl
    movzx edx, dl
    cmp edx, r15d
    je .cok
    inc qword [bad]
.cok:
    cmp ecx, TOK_ASSIST
    jne .cend1
    test eax, MASKBIT
    jz .cstart
    inc qword [bad]             ; the role token itself isn't a target
.cstart:
    mov r15d, 1
    inc r12
    jmp .cnext
.cend1:
    cmp ecx, TOK_END
    jne .cnext
    xor r15d, r15d
.cnext:
    add r13, 2
    jmp .ct
.cend:
    cmp r12, 0
    check a, "has assistant turns"
    cmp qword [bad], 0
    check e, "MASKBIT on exactly the assistant content + its <|end|>"
.end:
    jmp t_done

; rbx = BT struct to fill for the fast/naive comparison (r12 = docs)
setup_bt:
    sub rsp, 40
    mov rax, [dlist]
    mov [rbx+BT_DOCS], rax
    mov [rbx+BT_NDOCS], r12
    mov qword [rbx+BT_NMERGES], NM
    mov qword [rbx+BT_NAIVE], 0
    mov qword [rbx+BT_VERBOSE], 0
    mov ecx, NM * 4
    call mem_alloc
    mov [rbx+BT_MERGES], rax
    mov ecx, NM * 8
    call mem_alloc
    mov [rbx+BT_COUNTS], rax
    add rsp, 40
    ret
