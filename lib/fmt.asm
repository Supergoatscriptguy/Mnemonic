; number formatting into buffers, and parsing numbers out of text.
; fmt_* take rcx = dst and return rax = end of what they wrote
default rel
bits 64
%include "lib.inc"

section .rdata
align 8
pow10    dq 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11
         dq 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22
pow10i   dq 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000
         dq 1000000000, 10000000000, 100000000000, 1000000000000
         dq 10000000000000, 100000000000000, 1000000000000000
         dq 10000000000000000, 100000000000000000, 1000000000000000000
two63    dq 9223372036854775808.0
one      dq 1.0
ten      dq 10.0
hundred  dq 100.0
thousand dq 1000.0
hexdig   db "0123456789abcdef"
sfx      db "KMBT", 0

section .text

; rdx = zero terminated source
global fmt_str
fmt_str:
    mov al, [rdx]
    test al, al
    jz .done
    mov [rcx], al
    inc rcx
    inc rdx
    jmp fmt_str
.done:
    mov rax, rcx
    ret

; rdx = unsigned value
global fmt_dec
fmt_dec:
    mov r8d, 1
    ; fall through

; rdx = unsigned value, r8 = min width, zero padded
global fmt_dec0
fmt_dec0:
    sub rsp, 32                 ; digit scratch, written backwards
    mov [rsp+40], rcx           ; dst, in our home slot
    lea r9, [rsp+32]
    mov r10, r9
    mov rax, rdx
    mov r11, 0xcccccccccccccccd ; ceil(2^67 / 10): x/10 = (x * this) >> 67
.digit:
    mov rcx, rax
    mul r11
    shr rdx, 3
    lea rax, [rdx+rdx*4]
    add rax, rax
    sub rcx, rax                ; x - (x/10)*10
    add cl, '0'
    dec r10
    mov [r10], cl
    mov rax, rdx
    test rax, rax
    jnz .digit

    mov rcx, [rsp+40]
    mov rax, r9
    sub rax, r10                ; digits we have
.pad:
    cmp rax, r8
    jae .copy
    mov byte [rcx], '0'
    inc rcx
    inc rax
    jmp .pad
.copy:
    mov dl, [r10]
    mov [rcx], dl
    inc rcx
    inc r10
    cmp r10, r9
    jb .copy
    mov rax, rcx
    add rsp, 32
    ret

; rdx = signed value
global fmt_int
fmt_int:
    test rdx, rdx
    jns fmt_dec
    mov byte [rcx], '-'
    inc rcx
    neg rdx                     ; INT64_MIN stays 0x8000.. which is right as unsigned
    jmp fmt_dec

; rdx = value, r8 = number of hex digits
global fmt_hex
fmt_hex:
    lea r9, [hexdig]
    lea rax, [rcx+r8]
    mov r10, rax
.loop:
    mov r11d, edx
    and r11d, 15
    mov r11b, [r9+r11]
    dec r10
    mov [r10], r11b
    shr rdx, 4
    cmp r10, rcx
    ja .loop
    ret

; xmm1 = value, r8 = decimals (0-17). like 3.1416
global fmt_fixed
fmt_fixed:
    movq rax, xmm1
    btr rax, 63
    mov r9, 0x7ff0000000000000
    cmp rax, r9
    jae fmt_sci                 ; inf/nan, fmt_sci knows how to print those
    movq xmm2, rax
    lea r9, [pow10]
    mulsd xmm2, [r9+r8*8]
    comisd xmm2, [two63]
    jae fmt_sci                 ; too big to do in an integer, go scientific

    sub rsp, 56
    movmskpd r10d, xmm1
    test r10d, 1
    jz .pos
    mov byte [rcx], '-'
    inc rcx
.pos:
    cvtsd2si rax, xmm2          ; |v| * 10^d, rounded to nearest
    lea r9, [pow10i]
    xor edx, edx
    div qword [r9+r8*8]         ; rax = whole part, rdx = fraction digits
    mov [rsp+32], r8
    mov [rsp+40], rdx
    mov rdx, rax
    call fmt_dec
    mov r8, [rsp+32]
    test r8, r8
    jz .done
    mov byte [rax], '.'
    lea rcx, [rax+1]
    mov rdx, [rsp+40]
    call fmt_dec0               ; width = decimals keeps the leading zeros
.done:
    add rsp, 56
    ret

; xmm1 = value, r8 = decimals (0-17). like 3.00e-04
global fmt_sci
fmt_sci:
    sub rsp, 56
    movq rax, xmm1
    mov rdx, rax
    btr rdx, 63
    mov r9, 0x7ff0000000000000
    cmp rdx, r9
    jae .special
    test rax, rax
    jns .pos
    mov byte [rcx], '-'
    inc rcx
.pos:
    movq xmm1, rdx
    xor r10d, r10d              ; decimal exponent
    test rdx, rdx
    jz .digits
    ; walk it into [1, 10). piles up a few ulps, fine for printing
    movsd xmm2, [ten]
.up:
    comisd xmm1, xmm2
    jb .down
    divsd xmm1, xmm2
    inc r10d
    jmp .up
.down:
    comisd xmm1, [one]
    jae .digits
    mulsd xmm1, xmm2
    dec r10d
    jmp .down
.digits:
    lea r9, [pow10]
    mulsd xmm1, [r9+r8*8]
    cvtsd2si rax, xmm1          ; 1 + decimals digits
    lea r9, [pow10i]
    cmp rax, [r9+r8*8+8]
    jb .split
    xor edx, edx                ; 9.996 rounded up to 10.00
    mov r11d, 10
    div r11
    inc r10d
.split:
    mov [rsp+32], r10
    xor edx, edx
    div qword [r9+r8*8]         ; rax = lead digit, rdx = the rest
    add al, '0'
    mov [rcx], al
    inc rcx
    test r8, r8
    jz .exp
    mov byte [rcx], '.'
    inc rcx
    call fmt_dec0
    mov rcx, rax
.exp:
    mov byte [rcx], 'e'
    mov byte [rcx+1], '+'
    movsxd rdx, dword [rsp+32]
    test rdx, rdx
    jns .epos
    mov byte [rcx+1], '-'
    neg rdx
.epos:
    add rcx, 2
    mov r8d, 2
    call fmt_dec0
    jmp .done
.special:
    cmp rdx, r9
    ja .nan
    test rax, rax
    jns .inf
    mov byte [rcx], '-'
    inc rcx
.inf:
    mov dword [rcx], 'inf'
    lea rax, [rcx+3]
    jmp .done
.nan:
    mov dword [rcx], 'nan'
    lea rax, [rcx+3]
.done:
    add rsp, 56
    ret

; rdx = count. 999, 1.23K, 45.6M, 789B, 3 significant digits
global fmt_count
fmt_count:
    cmp rdx, 1000
    jb fmt_dec
    sub rsp, 40
    cvtsi2sd xmm1, rdx
    lea r10, [sfx]
    movsd xmm2, [thousand]
.scale:
    divsd xmm1, xmm2
    comisd xmm1, xmm2
    jb .pick
    cmp byte [r10+1], 0
    je .pick
    inc r10
    jmp .scale
.pick:
    mov r8d, 2
    comisd xmm1, [ten]
    jb .go
    dec r8d
    comisd xmm1, [hundred]
    jb .go
    dec r8d
.go:
    mov [rsp+32], r10
    call fmt_fixed
    mov r10, [rsp+32]
    mov dl, [r10]
    mov [rax], dl
    inc rax
    add rsp, 40
    ret

; rdx = seconds. hh:mm:ss, hours keep growing past 99
global fmt_hms
fmt_hms:
    sub rsp, 56
    mov rax, rdx
    mov r9d, 60
    xor edx, edx
    div r9
    mov [rsp+32], rdx           ; seconds
    xor edx, edx
    div r9
    mov [rsp+40], rdx           ; minutes
    mov rdx, rax
    mov r8d, 2
    call fmt_dec0
    mov byte [rax], ':'
    lea rcx, [rax+1]
    mov rdx, [rsp+40]
    mov r8d, 2
    call fmt_dec0
    mov byte [rax], ':'
    lea rcx, [rax+1]
    mov rdx, [rsp+32]
    mov r8d, 2
    call fmt_dec0
    add rsp, 56
    ret

; rcx = text. returns rax = value, rdx = where it stopped
global parse_int
parse_int:
    xor eax, eax
    xor r8d, r8d
    cmp byte [rcx], '-'
    jne .plus
    inc r8d
    inc rcx
    jmp .digits
.plus:
    cmp byte [rcx], '+'
    jne .digits
    inc rcx
.digits:
    movzx edx, byte [rcx]
    sub edx, '0'
    cmp edx, 9
    ja .end
    imul rax, rax, 10
    add rax, rdx
    inc rcx
    jmp .digits
.end:
    test r8d, r8d
    jz .ret
    neg rax
.ret:
    mov rdx, rcx
    ret

; rcx = text like -1.5, 3e-4, 2.5E+10. returns xmm0 = value, rax = where it stopped.
; digits go into an integer, then one multiply or divide by a power of ten, so
; anything with <= 15 digits and a small exponent comes out correctly rounded
global parse_float
parse_float:
    xor eax, eax                ; mantissa digits
    xor r8d, r8d                ; negative?
    xor r9d, r9d                ; decimal exponent
    xor r10d, r10d              ; digits kept
    cmp byte [rcx], '-'
    jne .plus
    inc r8d
    inc rcx
    jmp .int
.plus:
    cmp byte [rcx], '+'
    jne .int
    inc rcx
.int:
    movzx edx, byte [rcx]
    sub edx, '0'
    cmp edx, 9
    ja .dot
    inc rcx
    cmp r10d, 18
    jae .drop                   ; more digits than fit, they only scale
    imul rax, rax, 10
    add rax, rdx
    inc r10d
    jmp .int
.drop:
    inc r9d
    jmp .int
.dot:
    cmp byte [rcx], '.'
    jne .exp
    inc rcx
.frac:
    movzx edx, byte [rcx]
    sub edx, '0'
    cmp edx, 9
    ja .exp
    inc rcx
    cmp r10d, 18
    jae .frac
    imul rax, rax, 10
    add rax, rdx
    inc r10d
    dec r9d
    jmp .frac
.exp:
    mov dl, [rcx]
    or dl, 0x20
    cmp dl, 'e'
    jne .build
    inc rcx
    xor r10d, r10d              ; exponent sign now
    xor r11d, r11d
    cmp byte [rcx], '-'
    jne .eplus
    inc r10d
    inc rcx
    jmp .edig
.eplus:
    cmp byte [rcx], '+'
    jne .edig
    inc rcx
.edig:
    movzx edx, byte [rcx]
    sub edx, '0'
    cmp edx, 9
    ja .edone
    imul r11d, r11d, 10
    add r11d, edx
    inc rcx
    jmp .edig
.edone:
    test r10d, r10d
    jz .eadd
    neg r11d
.eadd:
    add r9d, r11d
.build:
    cvtsi2sd xmm0, rax
    lea r11, [pow10]
    test r9d, r9d
    jz .sign
    js .neg
.pos:
    cmp r9d, 22
    jbe .p1
    mulsd xmm0, [r11+22*8]
    sub r9d, 22
    jmp .pos
.p1:
    mulsd xmm0, [r11+r9*8]
    jmp .sign
.neg:
    neg r9d
.n0:
    cmp r9d, 22
    jbe .n1
    divsd xmm0, [r11+22*8]
    sub r9d, 22
    jmp .n0
.n1:
    divsd xmm0, [r11+r9*8]      ; dividing by an exact 10^k rounds once, multiplying by 10^-k wouldn't
.sign:
    test r8d, r8d
    jz .ret
    movq rax, xmm0
    btc rax, 63
    movq xmm0, rax
.ret:
    mov rax, rcx
    ret
