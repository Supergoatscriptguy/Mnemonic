; gguf checkpoint.ckpt out.gguf [q8_0|q4_0|f16|f32] [tok=datasets\tokenizer.bin] [rope_base=10000] [name=Mnemonic]
; a training checkpoint -> a gguf file, for llama.cpp and ollama. mnemonic is already laid
; out like llama (rope on (2i, 2i+1) pairs, kv head = q head / group size, gate first in
; w13), so it goes in as arch "llama" with qkv and w13 cut into their parts. there's no
; output.weight: the embeddings are tied and llama.cpp falls back to token_embd.
; the vocab is gpt2-style byte-level bpe. llama.cpp has no pre-tokenizer that splits
; digits 1-2 at a time like ours, "llama-bpe" (1-3) is the closest, so numbers with 3+
; digits get tokenized a bit differently than in training. everything else matches
; uses: chat\quant tokenizer\tok tokenizer\pretok
default rel
bits 64
%include "lib.inc"
%include "tokenizer/tok.inc"
%include "train/train.inc"
%include "chat/model.inc"

extern ExitProcess

; gguf value types
GV_U32   equ 4
GV_I32   equ 5
GV_F32   equ 6
GV_BOOL  equ 7
GV_STR   equ 8
GV_ARR   equ 9
; ggml tensor types
TY_F32   equ 0
TY_F16   equ 1
TY_Q4_0  equ 2
TY_Q8_0  equ 8
GALIGN    equ 32
; a tensor to write
TE_NAME  equ 0
TE_NE0   equ 8                  ; columns, the contiguous dim
TE_NE1   equ 16                 ; rows, 0 for a vector
TE_TYPE  equ 24
TE_SRC   equ 32                 ; its f32 data in the checkpoint
TE_SIZE  equ 40
TE_LEN   equ 48
MAXT     equ 1024
CHUNK    equ 8192               ; floats per qx_vec call
METASZ   equ 16 << 20

section .rdata
k_tok    db "tok", 0
k_rope   db "rope_base", 0
k_name   db "name", 0
d_tok    db "datasets\tokenizer.bin", 0
d_name   db "Mnemonic", 0
e_usage  db "usage: gguf checkpoint.ckpt out.gguf [q8_0|q4_0|f16|f32]", 0
e_ckpt   db "not a checkpoint: ", 0
e_write  db "couldn't write ", 0
e_tok    db "can't load the tokenizer", 0
e_cols   db "every matrix width has to be a multiple of 32", 0
; per mode: f32, f16, q8_0, q4_0
m_names  db "f32", 0, 0, "f16", 0, 0, "q8_0", 0, "q4_0", 0
m_type   dd TY_F32, TY_F16, TY_Q8_0, TY_Q4_0
m_ftype  dd 0, 1, 7, 2          ; general.file_type: all f32, mostly f16 / q8_0 / q4_0
; keys
g_arch   db "general.architecture", 0
g_name   db "general.name", 0
g_author db "general.author", 0
g_url    db "general.url", 0
g_ftype  db "general.file_type", 0
g_qver   db "general.quantization_version", 0
l_ctx    db "llama.context_length", 0
l_emb    db "llama.embedding_length", 0
l_blocks db "llama.block_count", 0
l_ffn    db "llama.feed_forward_length", 0
l_heads  db "llama.attention.head_count", 0
l_kvh    db "llama.attention.head_count_kv", 0
l_rdim   db "llama.rope.dimension_count", 0
l_vocab  db "llama.vocab_size", 0
l_base   db "llama.rope.freq_base", 0
l_eps    db "llama.attention.layer_norm_rms_epsilon", 0
t_model  db "tokenizer.ggml.model", 0
t_pre    db "tokenizer.ggml.pre", 0
t_tokens db "tokenizer.ggml.tokens", 0
t_types  db "tokenizer.ggml.token_type", 0
t_merges db "tokenizer.ggml.merges", 0
t_bos    db "tokenizer.ggml.bos_token_id", 0
t_eos    db "tokenizer.ggml.eos_token_id", 0
t_eot    db "tokenizer.ggml.eot_token_id", 0
t_addbos db "tokenizer.ggml.add_bos_token", 0
t_addeos db "tokenizer.ggml.add_eos_token", 0
t_tmpl   db "tokenizer.chat_template", 0
; values
v_llama  db "llama", 0
v_gpt2   db "gpt2", 0
v_pre    db "llama-bpe", 0
v_author db "Supergoatscriptguy", 0
v_url    db "https://github.com/Supergoatscriptguy/Mnemonic", 0
v_tmpl   db "{% for message in messages %}{{ '<|' + message['role'] + '|>' + message['content'] + '<|end|>' }}{% endfor %}"
         db "{% if add_generation_prompt %}{{ '<|assistant|>' }}{% endif %}", 0
; tensors
n_embd   db "token_embd.weight", 0
n_onorm  db "output_norm.weight", 0
n_anorm  db "attn_norm.weight", 0
n_q      db "attn_q.weight", 0
n_k      db "attn_k.weight", 0
n_v      db "attn_v.weight", 0
n_o      db "attn_output.weight", 0
n_fnorm  db "ffn_norm.weight", 0
n_gate   db "ffn_gate.weight", 0
n_up     db "ffn_up.weight", 0
n_down   db "ffn_down.weight", 0
specials db "<|bos|>", 0, "<|user|>", 0, "<|assistant|>", 0, "<|system|>", 0, "<|end|>", 0
s_resv   db "<|reserved_", 0
s_resv2  db "|>", 0
s_space  db " ", 0
align 32
absmask  times 8 dd 0x7fffffff
c_eps    dd 1e-5
c_m8     dd -8.0
c_85     dd 8.5
c_one    dd 1.0
align 8
c_rope   dq 10000.0
c_mb     dq 9.5367431640625e-07

section .bss
alignb 8
ck       resq 1                 ; the mapped checkpoint
tokf     resq 1                 ; the mapped tokenizer, for its merges
mode     resq 1
outh     resq 1
meta     resq 1                 ; everything before the tensor data gets built here
wp       resq 1                 ; write pointer into it
nkv      resq 1
names    resq 1
np       resq 1
ntens    resq 1
dbuf     resq 1                 ; one converted tensor
tq       resq 1                 ; qx_vec's output
tsc      resq 1
written  resq 1
L        resq 1
D        resq 1
H        resq 1
KVH      resq 1
HD       resq 1
F        resq 1
V        resq 1
T        resq 1
QD       resq 1
KVD      resq 1
QKV      resq 1
ropef    resd 1
b2u      resd 256               ; gpt-2's byte -> unicode char, as utf-8: b0, b1, length
numbuf   resb 32
zeros    resb GALIGN
tens     resb MAXT * TE_LEN

section .text

global start
start:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    call lib_init
    cmp qword [argc], 3
    jae .args
    lea rcx, [e_usage]
    call print_z
    say 13, 10
    mov ecx, 1
    call ExitProcess
.args:
    ; the type: the 3rd arg if it isn't a key=value
    mov qword [mode], 2
    cmp qword [argc], 4
    jb .moded
    mov rax, [argv+24]
    movzx eax, word [rax]
    xor ecx, ecx
    cmp ax, 'f3'
    je .m
    inc ecx
    cmp ax, 'f1'
    je .m
    mov ecx, 3
    cmp ax, 'q4'
    jne .moded
.m:
    mov [mode], rcx
.moded:
    call cfg_args
    mov rcx, [argv+8]
    call file_map
    test rax, rax
    jz .badck
    mov [ck], rax
    mov rcx, CK_MAGIC_V
    cmp [rax+CK_MAGIC], rcx
    jne .badck
%macro dim 2
    mov rcx, [rax+%2]
    mov [%1], rcx
%endmacro
    dim L, CK_L
    dim D, CK_D
    dim H, CK_H
    dim KVH, CK_KVH
    dim F, CK_F
    dim V, CK_V
    dim T, CK_T
    mov rax, [D]
    xor edx, edx
    div qword [H]
    mov [HD], rax
    mov rcx, rax
    imul rax, [H]
    mov [QD], rax
    imul rcx, [KVH]
    mov [KVD], rcx
    lea rax, [rax+rcx*2]
    mov [QKV], rax
    mov rax, [D]
    or rax, [F]
    or rax, [QD]
    test eax, 31
    jz .cols
    lea rcx, [e_cols]
    call fatal
.cols:
    lea rcx, [k_rope]
    movsd xmm1, [c_rope]
    call cfg_float
    cvtsd2ss xmm0, xmm0
    movd [ropef], xmm0
    ; the tokenizer: tok_bytes for the token texts, the file itself for the merges
    lea rcx, [k_tok]
    lea rdx, [d_tok]
    call cfg_str
    mov rbx, rax
    mov rcx, rax
    call tok_load
    test eax, eax
    jz .badtok
    mov rcx, rbx
    call file_map
    test rax, rax
    jz .badtok
    mov [tokf], rax

    mov ecx, METASZ
    call mem_alloc
    mov [meta], rax
    mov [wp], rax
    mov ecx, 65536
    call mem_alloc
    mov [names], rax
    mov [np], rax
    mov rcx, [V]
    imul rcx, [D]
    lea rcx, [rcx*4+64]         ; the biggest tensor as f32
    call mem_alloc
    mov [dbuf], rax
    mov ecx, CHUNK
    call mem_alloc
    mov [tq], rax
    mov ecx, CHUNK / 8
    call mem_alloc
    mov [tsc], rax
    call bytemap

    ; header: magic, version, tensor count and kv count (both patched in later)
    mov ecx, 'GGUF'
    call pu32
    mov ecx, 3
    call pu32
    xor ecx, ecx
    call pu64
    xor ecx, ecx
    call pu64
    call metadata
    call tensors
    call infos
    mov rax, [meta]
    mov rcx, [ntens]
    mov [rax+8], rcx
    mov rcx, [nkv]
    mov [rax+16], rcx
    ; the tensor data starts on the alignment
    mov rdi, [wp]
.pad:
    mov rax, rdi
    sub rax, [meta]
    test eax, GALIGN - 1
    jz .padded
    mov byte [rdi], 0
    inc rdi
    jmp .pad
.padded:
    mov [wp], rdi

    mov rcx, [argv+16]
    call file_create
    cmp rax, -1
    jne .made
    lea rcx, [e_write]
    call print_z
    mov rcx, [argv+16]
    call fatal
.made:
    mov [outh], rax
    mov rdx, [meta]
    mov r8, [wp]
    sub r8, rdx
    call out
    call writedata
    mov rcx, [outh]
    call file_close

    say "  "
    mov rcx, [argv+16]
    call print_z
    say ": "
    mov rax, [mode]
    lea rcx, [m_names]
    lea rax, [rax+rax*4]
    add rcx, rax
    call print_z
    say ", "
    mov rcx, [ntens]
    call print_dec
    say " tensors, "
    cvtsi2sd xmm0, qword [written]
    mulsd xmm0, [c_mb]
    mov edx, 1
    call print_fixed
    say " MB", 13, 10
    xor ecx, ecx
    call ExitProcess
.badck:
    lea rcx, [e_ckpt]
    call print_z
    mov rcx, [argv+8]
    call fatal
.badtok:
    lea rcx, [e_tok]
    call fatal

; gpt-2's byte -> unicode map: printable bytes stand for themselves, the other 68 get
; 256, 257, ... in order. every token and merge string is written in those chars
bytemap:
    xor ecx, ecx
    xor edx, edx
    lea r8, [b2u]
.b:
    mov eax, ecx
    cmp ecx, 33
    jb .other
    cmp ecx, 126
    jbe .utf8
    cmp ecx, 161
    jb .other
    cmp ecx, 172
    jbe .utf8
    cmp ecx, 174
    jae .utf8
.other:
    lea eax, [edx+256]
    inc edx
.utf8:
    cmp eax, 128
    jae .two
    mov [r8+rcx*4], al
    mov byte [r8+rcx*4+2], 1
    jmp .n
.two:
    mov r9d, eax
    shr r9d, 6
    or r9d, 0xc0
    mov [r8+rcx*4], r9b
    and eax, 63
    or eax, 0x80
    mov [r8+rcx*4+1], al
    mov byte [r8+rcx*4+2], 2
.n:
    inc ecx
    cmp ecx, 256
    jb .b
    ret

; ---- writing into the metadata buffer

; ecx = value
pu32:
    mov rax, [wp]
    mov [rax], ecx
    add qword [wp], 4
    ret

; rcx = value
pu64:
    mov rax, [wp]
    mov [rax], rcx
    add qword [wp], 8
    ret

; rcx = zero-terminated string, appended as is
praw:
    mov rax, [wp]
.c:
    mov dl, [rcx]
    test dl, dl
    jz .d
    mov [rax], dl
    inc rax
    inc rcx
    jmp .c
.d:
    mov [wp], rax
    ret

; rcx = bytes, rdx = count, appended through the byte map
pmap:
    mov r8, [wp]
    lea r9, [b2u]
.c:
    test rdx, rdx
    jz .d
    movzx eax, byte [rcx]
    mov r10d, [r9+rax*4]
    mov [r8], r10w              ; 2 bytes, the second is junk for 1 byte chars
    shr r10d, 16
    and r10d, 0xff
    add r8, r10
    inc rcx
    dec rdx
    jmp .c
.d:
    mov [wp], r8
    ret

; rcx = zero-terminated string, as a gguf string (u64 length, bytes)
pstr:
    push rbx
    sub rsp, 32
    mov rbx, [wp]
    add qword [wp], 8
    call praw
    mov rax, [wp]
    sub rax, rbx
    sub rax, 8
    mov [rbx], rax
    add rsp, 32
    pop rbx
    ret

; rcx = key, edx = value type
pkey:
    push rbx
    sub rsp, 32
    mov ebx, edx
    call pstr
    mov ecx, ebx
    call pu32
    inc qword [nkv]
    add rsp, 32
    pop rbx
    ret

; rcx = key, edx = value (f32 bits for kv_f32)
kv_u32:
    mov r8d, GV_U32
    jmp kv4
kv_f32:
    mov r8d, GV_F32
kv4:
    push rbx
    sub rsp, 32
    mov ebx, edx
    mov edx, r8d
    call pkey
    mov ecx, ebx
    call pu32
    add rsp, 32
    pop rbx
    ret

; rcx = key, dl = 0 or 1
kv_bool:
    push rbx
    sub rsp, 32
    movzx ebx, dl
    mov edx, GV_BOOL
    call pkey
    mov rax, [wp]
    mov [rax], bl
    inc qword [wp]
    add rsp, 32
    pop rbx
    ret

; rcx = key, rdx = zero-terminated value
kv_str:
    push rbx
    sub rsp, 32
    mov rbx, rdx
    mov edx, GV_STR
    call pkey
    mov rcx, rbx
    call pstr
    add rsp, 32
    pop rbx
    ret

; rcx = key, edx = element type, r8 = count. the rest is up to the caller
kv_arr:
    push rbx
    push rsi
    sub rsp, 40
    mov ebx, edx
    mov rsi, r8
    mov edx, GV_ARR
    call pkey
    mov ecx, ebx
    call pu32
    mov rcx, rsi
    call pu64
    add rsp, 40
    pop rsi
    pop rbx
    ret

%macro u32kv 2
    lea rcx, [%1]
    mov edx, %2
    call kv_u32
%endmacro

metadata:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    lea rcx, [g_arch]
    lea rdx, [v_llama]
    call kv_str
    lea rcx, [k_name]
    lea rdx, [d_name]
    call cfg_str
    lea rcx, [g_name]
    mov rdx, rax
    call kv_str
    lea rcx, [g_author]
    lea rdx, [v_author]
    call kv_str
    lea rcx, [g_url]
    lea rdx, [v_url]
    call kv_str
    mov rax, [mode]
    lea rcx, [m_ftype]
    mov eax, [rcx+rax*4]
    u32kv g_ftype, eax
    u32kv g_qver, 2
    u32kv l_ctx, [T]
    u32kv l_emb, [D]
    u32kv l_blocks, [L]
    u32kv l_ffn, [F]
    u32kv l_heads, [H]
    u32kv l_kvh, [KVH]
    u32kv l_rdim, [HD]
    u32kv l_vocab, [V]
    lea rcx, [l_base]
    mov edx, [ropef]
    call kv_f32
    lea rcx, [l_eps]
    mov edx, [c_eps]
    call kv_f32
    lea rcx, [t_model]
    lea rdx, [v_gpt2]
    call kv_str
    lea rcx, [t_pre]
    lea rdx, [v_pre]
    call kv_str

    ; the vocab
    lea rcx, [t_tokens]
    mov edx, GV_STR
    mov r8, [V]
    call kv_arr
    xor ebx, ebx
.tok:
    cmp rbx, [V]
    jae .types
    mov ecx, ebx
    call tokstr
    inc ebx
    jmp .tok
.types:
    ; 1 = normal, 3 = control
    lea rcx, [t_types]
    mov edx, GV_I32
    mov r8, [V]
    call kv_arr
    xor ebx, ebx
.ty:
    cmp rbx, [V]
    jae .merges
    mov ecx, 1
    cmp ebx, SPECIAL0
    jb .t1
    mov ecx, 3
.t1:
    call pu32
    inc ebx
    jmp .ty
.merges:
    ; "left right", in merge order (the order is the rank). the file has a | b << 16
    mov rax, [tokf]
    mov r12d, [rax+TKH_NMERGES]
    lea rcx, [t_merges]
    mov edx, GV_STR
    mov r8, r12
    call kv_arr
    mov rsi, [tokf]
    add rsi, TKH_SIZE
    xor ebx, ebx
.mg:
    cmp ebx, r12d
    jae .specials
    mov rdi, [wp]               ; the length goes here
    add qword [wp], 8
    movzx ecx, word [rsi+rbx*4]
    call tok_bytes
    mov rcx, rax
    call pmap
    lea rcx, [s_space]
    call praw
    movzx ecx, word [rsi+rbx*4+2]
    call tok_bytes
    mov rcx, rax
    call pmap
    mov rax, [wp]
    sub rax, rdi
    sub rax, 8
    mov [rdi], rax
    inc ebx
    jmp .mg
.specials:
    u32kv t_bos, TOK_BOS
    u32kv t_eos, TOK_END
    u32kv t_eot, TOK_END
    lea rcx, [t_addbos]
    mov dl, 1
    call kv_bool
    lea rcx, [t_addeos]
    xor edx, edx
    call kv_bool
    lea rcx, [t_tmpl]
    lea rdx, [v_tmpl]
    call kv_str
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ecx = token. its text as a gguf string: its bytes through the byte map, or the
; special's name. the reserved ones get numbers, llama.cpp wants every text unique
tokstr:
    push rbx
    push rsi
    sub rsp, 40
    mov ebx, ecx
    mov rsi, [wp]
    add qword [wp], 8
    cmp ebx, SPECIAL0
    jae .sp
    call tok_bytes
    mov rcx, rax
    call pmap
    jmp .len
.sp:
    sub ebx, SPECIAL0
    cmp ebx, 5
    jae .resv
    lea rcx, [specials]
.find:
    test ebx, ebx
    jz .named
.skip:
    inc rcx
    cmp byte [rcx-1], 0
    jne .skip
    dec ebx
    jmp .find
.named:
    call praw
    jmp .len
.resv:
    lea rcx, [s_resv]
    call praw
    lea rcx, [numbuf]
    mov edx, ebx
    call fmt_dec
    mov byte [rax], 0
    lea rcx, [numbuf]
    call praw
    lea rcx, [s_resv2]
    call praw
.len:
    mov rax, [wp]
    sub rax, rsi
    sub rax, 8
    mov [rsi], rax
    add rsp, 40
    pop rsi
    pop rbx
    ret

; ---- the tensors

; ecx = layer, rdx = suffix. rax = "blk.<layer>.<suffix>", kept in the names buffer
mkname:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov ebx, ecx
    mov rsi, rdx
    mov rdi, [np]
    mov dword [rdi], 'blk.'
    lea rcx, [rdi+4]
    mov edx, ebx
    call fmt_dec
    mov byte [rax], '.'
    lea rdi, [rax+1]
.c:
    lodsb
    stosb
    test al, al
    jnz .c
    mov rax, [np]
    mov [np], rdi
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = name, rdx = f32 source, r8 = columns, r9 = rows (0 = a vector), [rsp+40] = type
addt:
    mov rax, [ntens]
    imul rax, TE_LEN
    lea r10, [tens]
    add r10, rax
    mov [r10+TE_NAME], rcx
    mov [r10+TE_SRC], rdx
    mov [r10+TE_NE0], r8
    mov [r10+TE_NE1], r9
    mov eax, [rsp+40]
    mov [r10+TE_TYPE], rax
    mov r11, r9
    test r11, r11
    jnz .m
    mov r11d, 1
.m:
    imul r11, r8                ; elements
    cmp eax, TY_F16
    je .f16
    cmp eax, TY_Q8_0
    je .q8
    cmp eax, TY_Q4_0
    je .q4
    shl r11, 2
    jmp .sz
.f16:
    add r11, r11
    jmp .sz
.q8:
    shr r11, 5
    imul r11, 34
    jmp .sz
.q4:
    shr r11, 5
    imul r11, 18
.sz:
    mov [r10+TE_SIZE], r11
    inc qword [ntens]
    ret

; inside tensors, whose [rsp+48] is the matrix type. mkname trashes rax, so the
; source can't be in it
%macro mat 5                    ; layer, name, source, rows, cols
    mov ecx, %1
    lea rdx, [%2]
    call mkname
    mov rcx, rax
    mov rdx, %3
    mov r8, %5
    mov r9, %4
    mov eax, [rsp+48]
    mov [rsp+32], eax
    call addt
%endmacro
%macro vec 3                    ; layer, name, source
    mov ecx, %1
    lea rdx, [%2]
    call mkname
    mov rcx, rax
    mov rdx, %3
    mov r8, [D]
    xor r9d, r9d
    mov dword [rsp+32], TY_F32
    call addt
%endmacro

; the table of tensors to write, in llama.cpp's usual order
tensors:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 64                 ; [rsp+48] = the matrix type
    mov rax, [mode]
    lea rcx, [m_type]
    mov eax, [rcx+rax*4]
    mov [rsp+48], eax
    ; token_embd doubles as the output layer, so a q4 file keeps it at q8_0
    mov ecx, eax
    cmp ecx, TY_Q4_0
    jne .e
    mov ecx, TY_Q8_0
.e:
    mov [rsp+32], ecx
    lea rcx, [n_embd]
    mov rdx, [ck]
    add rdx, CK_SIZE
    mov r8, [D]
    mov r9, [V]
    call addt
    ; the norms sit after all the matrices: n1, n2 per layer, then the final one
    mov rsi, [ck]
    add rsi, CK_SIZE
    mov rax, [V]
    imul rax, [D]
    lea rsi, [rsi+rax*4]        ; layer 0's matrices
    mov r12, [QKV]
    imul r12, [D]
    mov rax, [D]
    imul rax, [QD]
    add r12, rax
    mov rax, [F]
    imul rax, [D]
    lea r12, [r12+rax*2]
    add r12, rax
    shl r12, 2                  ; bytes of matrices per layer
    mov r13, r12
    imul r13, [L]
    add r13, rsi                ; the norms
    xor ebx, ebx
.layer:
    cmp rbx, [L]
    jae .final
    mov rdi, rbx
    imul rdi, [D]
    shl rdi, 3
    add rdi, r13                ; this layer's n1, n2
    vec ebx, n_anorm, rdi
    ; wqkv: q rows, then k, then v
    mat ebx, n_q, rsi, [QD], [D]
    mov r12, [QD]               ; r12 is free now, and mkname leaves it alone
    imul r12, [D]
    lea r12, [rsi+r12*4]
    mat ebx, n_k, r12, [KVD], [D]
    mov r12, [QD]
    add r12, [KVD]
    imul r12, [D]
    lea r12, [rsi+r12*4]
    mat ebx, n_v, r12, [KVD], [D]
    mov rax, [QKV]
    imul rax, [D]
    lea rsi, [rsi+rax*4]
    mat ebx, n_o, rsi, [D], [QD]
    mov rax, [D]
    imul rax, [QD]
    lea rsi, [rsi+rax*4]
    mov r12, [D]
    lea r12, [rdi+r12*4]
    vec ebx, n_fnorm, r12
    ; w13: gate rows, then up
    mat ebx, n_gate, rsi, [F], [D]
    mov r12, [F]
    imul r12, [D]
    lea r12, [rsi+r12*4]
    mat ebx, n_up, r12, [F], [D]
    mov rax, [F]
    imul rax, [D]
    lea rsi, [rsi+rax*8]
    mat ebx, n_down, rsi, [D], [F]
    mov rax, [D]
    imul rax, [F]
    lea rsi, [rsi+rax*4]
    inc rbx
    jmp .layer
.final:
    mov rdi, [L]
    imul rdi, [D]
    lea rdi, [r13+rdi*8]
    lea rcx, [n_onorm]
    mov rdx, rdi
    mov r8, [D]
    xor r9d, r9d
    mov dword [rsp+32], TY_F32
    call addt
    add rsp, 64
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; tensor infos: name, dims (fastest first), type, offset into the data
infos:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    xor ebx, ebx
    xor edi, edi                ; offset
.t:
    cmp rbx, [ntens]
    jae .done
    mov rsi, rbx
    imul rsi, TE_LEN
    lea rax, [tens]
    add rsi, rax
    mov rcx, [rsi+TE_NAME]
    call pstr
    mov ecx, 1
    cmp qword [rsi+TE_NE1], 0
    je .d
    mov ecx, 2
.d:
    call pu32
    mov rcx, [rsi+TE_NE0]
    call pu64
    mov rcx, [rsi+TE_NE1]
    test rcx, rcx
    jz .ty
    call pu64
.ty:
    mov ecx, [rsi+TE_TYPE]
    call pu32
    mov rcx, rdi
    call pu64
    mov rax, [rsi+TE_SIZE]
    add rax, GALIGN - 1
    and rax, -GALIGN
    add rdi, rax
    inc rbx
    jmp .t
.done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

writedata:
    push rbx
    push rsi
    sub rsp, 40
    xor ebx, ebx
.t:
    cmp rbx, [ntens]
    jae .done
    mov rsi, rbx
    imul rsi, TE_LEN
    lea rax, [tens]
    add rsi, rax
    mov rdx, [rsi+TE_NE1]
    test rdx, rdx
    jnz .m
    mov edx, 1
.m:
    imul rdx, [rsi+TE_NE0]
    mov rcx, [rsi+TE_SRC]
    mov r8d, [rsi+TE_TYPE]
    mov r9, [dbuf]
    call conv
    mov rdx, [dbuf]
    mov r8, [rsi+TE_SIZE]
    call out
    mov r8, [rsi+TE_SIZE]
    neg r8
    and r8, GALIGN - 1
    jz .n
    lea rdx, [zeros]
    call out
.n:
    inc rbx
    jmp .t
.done:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = f32 source, rdx = count, r8d = type, r9 = destination
conv:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov rsi, rcx
    mov r12, rdx
    mov rdi, r9
    cmp r8d, TY_F16
    je .f16
    cmp r8d, TY_Q8_0
    je .q8
    cmp r8d, TY_Q4_0
    je .q4
    mov rcx, r12
    rep movsd
    jmp .done
.f16:
    vmovups ymm0, [rsi]
    vcvtps2ph [rdi], ymm0, 0
    add rsi, 32
    add rdi, 16
    sub r12, 8
    jnz .f16
    jmp .done

.q8:
    ; qx_vec does the math (scale = max |x| / 127, round), this just regroups it
    ; into 34 byte blocks: the scale as f16, then the 32 int8s
    test r12, r12
    jz .done
    mov r13, r12
    cmp r13, CHUNK
    jbe .c
    mov r13d, CHUNK
.c:
    mov rcx, rsi
    mov rdx, r13
    mov r8, [tq]
    mov r9, [tsc]
    call qx_vec
    mov rcx, r13
    shr rcx, 5
    mov r8, [tq]
    mov r9, [tsc]
.blk:
    vmovss xmm0, [r9]
    vcvtps2ph xmm0, xmm0, 0
    vmovd eax, xmm0
    mov [rdi], ax
    vmovdqu ymm0, [r8]
    vmovdqu [rdi+2], ymm0
    add r8, 32
    add r9, 4
    add rdi, 34
    dec rcx
    jnz .blk
    lea rsi, [rsi+r13*4]
    sub r12, r13
    jmp .q8

.q4:
    ; llama.cpp's q4_0: d = (the value with the biggest magnitude) / -8, so it uses
    ; all 16 levels. nibble j of a block is x_j (low) and x_{j+16} (high), stored + 8
    test r12, r12
    jz .done
    vxorps xmm0, xmm0, xmm0     ; biggest |x|
    vxorps xmm1, xmm1, xmm1     ; that x
    xor ecx, ecx
.mx:
    vmovss xmm2, [rsi+rcx*4]
    vandps xmm3, xmm2, [absmask]
    vcomiss xmm3, xmm0
    jbe .mn
    vmovaps xmm0, xmm3
    vmovaps xmm1, xmm2
.mn:
    inc ecx
    cmp ecx, 32
    jb .mx
    vdivss xmm1, xmm1, [c_m8]
    vcvtps2ph xmm4, xmm1, 0
    vmovd eax, xmm4
    mov [rdi], ax
    vxorps xmm2, xmm2, xmm2
    vcomiss xmm1, xmm2
    je .id
    vmovss xmm2, [c_one]
    vdivss xmm2, xmm2, xmm1
.id:
    xor ecx, ecx
.j:
    vmulss xmm3, xmm2, [rsi+rcx*4]
    vaddss xmm3, xmm3, [c_85]
    vcvttss2si eax, xmm3
    cmp eax, 15
    jbe .lo
    mov eax, 15
.lo:
    vmulss xmm3, xmm2, [rsi+rcx*4+64]
    vaddss xmm3, xmm3, [c_85]
    vcvttss2si edx, xmm3
    cmp edx, 15
    jbe .hi
    mov edx, 15
.hi:
    shl edx, 4
    or eax, edx
    mov [rdi+rcx+2], al
    inc ecx
    cmp ecx, 16
    jb .j
    add rsi, 128
    add rdi, 18
    sub r12, 32
    jmp .q4

.done:
    vzeroupper
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rdx = data, r8 = bytes
out:
    sub rsp, 40
    add [written], r8
    mov rcx, [outh]
    call file_write
    test eax, eax
    jnz .ok
    lea rcx, [e_write]
    call print_z
    mov rcx, [argv+16]
    call fatal
.ok:
    add rsp, 40
    ret
