; pre-tokenizer: splits text into the chunks bpe works inside of. this is the
; gpt-4 split pattern done by hand (with 1-2 digit groups, like nanochat):
;   '(?i:[sdmt]|ll|ve|re) | [^\r\n\p{L}\p{N}]?\p{L}+ | \p{N}{1,2}
;   | ' '?[^\s\p{L}\p{N}]+[\r\n]* | \s*[\r\n] | \s+(?!\S) | \s+
; unicode is simplified: non-ascii counts as a letter, except the blocks that
; are mostly punctuation and symbols (U+0080-00BF, U+2000-2FFF, U+3000-303F, emoji)
default rel
bits 64

C_L  equ 0                      ; letter
C_N  equ 1                      ; digit
C_S  equ 2                      ; space, tab, \v, \f
C_NL equ 3                      ; \r \n
C_P  equ 4                      ; anything else
C_AP equ 5                      ; ' (contractions, otherwise punctuation)

section .rdata
ascii_cls:
%assign i 0
%rep 128
  %if (i >= 'a' && i <= 'z') || (i >= 'A' && i <= 'Z')
    db C_L
  %elif i >= '0' && i <= '9'
    db C_N
  %elif i == ' ' || i == 9 || i == 11 || i == 12
    db C_S
  %elif i == 10 || i == 13
    db C_NL
  %elif i == 39
    db C_AP
  %else
    db C_P
  %endif
  %assign i i+1
%endrep

section .text

; class of the character at rsi (r11 = end of text). eax = class, ecx = its length.
; touches rax, rcx, rdx only
cls:
    movzx eax, byte [rsi]
    mov ecx, 1
    cmp eax, 0x80
    jae .hi
    lea rdx, [ascii_cls]
    movzx eax, byte [rdx+rax]
    ret
.hi:
    mov edx, eax
    mov eax, C_L
    cmp edx, 0xc0
    jb .done                    ; stray continuation byte, call it a letter
    cmp edx, 0xe0
    jb .two
    cmp edx, 0xf0
    jb .three
    mov ecx, 4
    cmp edx, 0xf0
    jne .clip
    lea rdx, [rsi+1]
    cmp rdx, r11
    jae .clip
    cmp byte [rsi+1], 0x9f      ; U+1F000-1FFFF, emoji and friends
    jne .clip
    mov eax, C_P
    jmp .clip
.three:
    mov ecx, 3
    cmp edx, 0xe2               ; U+2000-2FFF: punctuation, symbols, arrows, box drawing
    je .punct
    cmp edx, 0xe3
    jne .clip
    lea rdx, [rsi+1]
    cmp rdx, r11
    jae .clip
    cmp byte [rsi+1], 0x80      ; U+3000-303F, cjk punctuation
    jne .clip
.punct:
    mov eax, C_P
    jmp .clip
.two:
    mov ecx, 2
    cmp edx, 0xc2               ; U+0080-00BF, latin-1 punctuation and symbols
    jne .clip
    mov eax, C_P
.clip:
    lea rdx, [rsi+rcx]
    cmp rdx, r11
    jbe .done
    mov rcx, r11                ; a sequence cut off by the end of the text
    sub rcx, rsi
.done:
    ret

; rcx = start of a chunk, rdx = end of the text. rax = end of the chunk
global pretok_next
pretok_next:
    push rbx
    push rsi
    push rdi
    mov rsi, rcx
    mov r11, rdx
    mov rdi, rcx
    call cls
    cmp eax, C_L
    je .letters
    cmp eax, C_N
    je .digits
    cmp eax, C_NL
    je .space
    cmp eax, C_S
    je .sp
    cmp eax, C_AP
    jne .punct

    ; contractions: 's 't 'd 'm 'll 've 're, any case, whatever comes after
    lea rdx, [rsi+1]
    cmp rdx, r11
    jae .punct
    movzx edx, byte [rsi+1]
    or edx, 0x20
    cmp edx, 's'
    je .c2
    cmp edx, 't'
    je .c2
    cmp edx, 'd'
    je .c2
    cmp edx, 'm'
    je .c2
    lea rax, [rsi+2]
    cmp rax, r11
    jae .punct
    movzx eax, byte [rsi+2]
    or eax, 0x20
    cmp edx, 'l'
    jne .ve
    cmp eax, 'l'
    je .c3
    jmp .punct
.ve:
    cmp edx, 'v'
    je .re
    cmp edx, 'r'
    jne .punct
.re:
    cmp eax, 'e'
    jne .punct
.c3:
    lea rax, [rsi+3]
    jmp .ret
.c2:
    lea rax, [rsi+2]
    jmp .ret

.punct:
    ; one punctuation char right before letters sticks to them, like "(word"
    add rsi, rcx
    cmp rsi, r11
    jae .ret_rsi
    call cls
    cmp eax, C_L
    je .letters
.prun:
    ; otherwise a run of punctuation, plus newlines straight after it
    cmp rsi, r11
    jae .ret_rsi
    call cls
    cmp eax, C_P
    je .padv
    cmp eax, C_AP
    jne .nls
.padv:
    add rsi, rcx
    jmp .prun
.nls:
    cmp rsi, r11
    jae .ret_rsi
    movzx eax, byte [rsi]
    cmp eax, 10
    je .nl1
    cmp eax, 13
    jne .ret_rsi
.nl1:
    inc rsi
    jmp .nls

.sp:
    ; space or tab: in front of letters it joins them, a plain space also
    ; leads punctuation. anything else is the whitespace rules
    lea rbx, [rsi+1]
    cmp rbx, r11
    jae .space
    mov rsi, rbx
    call cls
    mov rsi, rdi
    cmp eax, C_L
    jne .sp2
    mov rsi, rbx
    jmp .letters
.sp2:
    cmp byte [rdi], ' '
    jne .space
    cmp eax, C_P
    je .sppunct
    cmp eax, C_AP
    jne .space
.sppunct:
    mov rsi, rbx
    jmp .prun

.letters:
    add rsi, rcx
    cmp rsi, r11
    jae .ret_rsi
    call cls
    cmp eax, C_L
    je .letters
    jmp .ret_rsi

.digits:
    add rsi, rcx
    cmp rsi, r11
    jae .ret_rsi
    call cls
    cmp eax, C_N
    jne .ret_rsi
    add rsi, rcx
    jmp .ret_rsi

.space:
    ; a whitespace run. with newlines in it: up to the last newline. otherwise
    ; all but the last char, which goes with the word after (unless it's the end)
    mov rsi, rdi
    xor ebx, ebx
.wloop:
    cmp rsi, r11
    jae .wend
    movzx eax, byte [rsi]
    cmp eax, 10
    je .wnl
    cmp eax, 13
    je .wnl
    cmp eax, ' '
    je .wsp
    cmp eax, 9
    je .wsp
    cmp eax, 11
    je .wsp
    cmp eax, 12
    jne .wend
.wsp:
    inc rsi
    jmp .wloop
.wnl:
    lea rbx, [rsi+1]
    inc rsi
    jmp .wloop
.wend:
    test rbx, rbx
    jz .nonl
    mov rax, rbx
    jmp .ret
.nonl:
    cmp rsi, r11
    jae .ret_rsi
    lea rax, [rsi-1]
    cmp rax, rdi
    ja .ret
.ret_rsi:
    mov rax, rsi
.ret:
    pop rdi
    pop rsi
    pop rbx
    ret

; hash of a chunk. rcx = ptr, rdx = len (1+). rax = hash, never 0.
; touches rcx, rdx, r10, r11. the tail load reads a few bytes before the chunk,
; which is always fine for text in a buffer or a mapped .docs file
global whash
whash:
    mov rax, 0x9e3779b97f4a7c15
    xor rax, rdx
    mov r11, 0xbf58476d1ce4e5b9
.blk:
    cmp rdx, 8
    jb .tail
    xor rax, [rcx]
    imul rax, r11
    mov r10, rax
    shr r10, 29
    xor rax, r10
    add rcx, 8
    sub rdx, 8
    jmp .blk
.tail:
    test rdx, rdx
    jz .fin
    mov r10, [rcx+rdx-8]        ; the 8 bytes ending at the end, shift off the extra
    neg rdx
    lea rdx, [rdx*8+64]
    shrx r10, r10, rdx
    xor rax, r10
    imul rax, r11
.fin:
    mov r10, rax
    shr r10, 32
    xor rax, r10
    imul rax, r11
    mov r10, rax
    shr r10, 29
    xor rax, r10
    or rax, 1
    ret

; r10, r11 = two chunks, rdx = len (1+). ZF set if they're equal. touches rax, rdx, r10, r11
global memeq
memeq:
    cmp rdx, 8
    jb .short
.blk:
    cmp rdx, 8
    jbe .last
    mov rax, [r10]
    cmp rax, [r11]
    jne .ret
    add r10, 8
    add r11, 8
    sub rdx, 8
    jmp .blk
.last:
    mov rax, [r10+rdx-8]        ; the last 8, overlapping what we already did
    cmp rax, [r11+rdx-8]
.ret:
    ret
.short:
    mov rax, [r10+rdx-8]
    xor rax, [r11+rdx-8]
    neg rdx
    lea rdx, [rdx*8+64]
    shrx rax, rax, rdx          ; the chunk is the top len bytes of that load
    test rax, rax
    ret
