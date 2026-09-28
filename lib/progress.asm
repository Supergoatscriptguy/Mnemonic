; live progress display for long runs: a few lines redrawn in place with VT
; escapes. prog_line writes the same numbers as key=value text for log files
default rel
bits 64
%include "lib.inc"

BARW   equ 30
NLINES equ 4                    ; the "[4A" cursor-ups below have to match

%define DIM 27, "[90m"
%define RST 27, "[0m"
%define EOL 27, "[K", 13, 10    ; clear whatever the last draw left on the line

section .rdata
align 8
c_tenth dq 0.1
c_one   dq 1.0
c_100   dq 100.0
c_bar8  dq 240.0                ; BARW * 8, the bar has 1/8 cell steps
c_gib   dq 9.313225746154785e-10  ; 2^-30

section .bss
line    resb 1024

section .text

; append a number at rdi. put fmt_fn, value / putf fmt_fn, fvalue, decimals
%macro put 2
    mov rcx, rdi
    mov rdx, %2
    call %1
    mov rdi, rax
%endmacro

%macro putf 3
    mov rcx, rdi
    movsd xmm1, %2
    mov r8d, %3
    call %1
    mov rdi, rax
%endmacro

; rcx = stats, call once before the loop (after filling in STEP, TOTAL, ELAPSED0)
global prog_begin
prog_begin:
    push rbx
    sub rsp, 32
    mov rbx, rcx
    call time_now
    mov [rbx+PS_T0], rax
    mov rax, [rbx+PS_STEP]
    mov [rbx+PS_STEP0], rax
    xor eax, eax
    mov [rbx+PS_LAST], rax
    mov [rbx+PS_LINES], rax
    cmp dword [con_tty], 0
    je .done
    say 27, "[?25l"             ; hide the cursor, it flickers otherwise
.done:
    add rsp, 32
    pop rbx
    ret

; rcx = stats, edx = 1 to force it. otherwise at most 10 redraws a second
global prog_draw
prog_draw:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    mov rbx, rcx
    mov r12d, edx
    mov rcx, [rbx+PS_LAST]
    call time_since
    test r12d, r12d
    jnz .go
    comisd xmm0, [c_tenth]
    jb .done
.go:
    call time_now
    mov [rbx+PS_LAST], rax
    mov rcx, [rbx+PS_T0]
    call time_since
    movsd [rsp+32], xmm0        ; this session
    addsd xmm0, [rbx+PS_ELAPSED0]
    movsd [rbx+PS_ELAPSED], xmm0
    cmp dword [con_tty], 0
    je .done                    ; redirected: no bar, the log has the numbers

    lea rdi, [line]
    cmp qword [rbx+PS_LINES], 0
    je .l1
    emit 27, "[4A"              ; back up over the last draw
.l1:
    emit "  ", DIM, "step ", RST
    put fmt_dec, [rbx+PS_STEP]
    emit DIM, "/", RST
    put fmt_dec, [rbx+PS_TOTAL]
    emit "  ", 27, "[32m"

    xorpd xmm0, xmm0
    mov rax, [rbx+PS_TOTAL]
    test rax, rax
    jz .frac
    cvtsi2sd xmm0, qword [rbx+PS_STEP]
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    minsd xmm0, [c_one]
.frac:
    movsd [rsp+40], xmm0
    mulsd xmm0, [c_bar8]
    cvttsd2si eax, xmm0         ; eighths of a cell filled
    mov ecx, eax
    shr ecx, 3                  ; whole cells
    and eax, 7
    mov edx, BARW
    sub edx, ecx
.full:
    test ecx, ecx
    jz .part
    mov dword [rdi], 0x8896e2   ; U+2588 full block, utf-8 e2 96 88
    add rdi, 3
    dec ecx
    jmp .full
.part:
    test eax, eax
    jz .rest
    mov word [rdi], 0x96e2
    mov cl, 0x90
    sub cl, al                  ; U+258F..U+2589 are the 1/8..7/8 blocks
    mov [rdi+2], cl
    add rdi, 3
    dec edx
.rest:
    emit DIM
.shade:
    test edx, edx
    jz .pct
    mov dword [rdi], 0x9196e2   ; U+2591 light shade
    add rdi, 3
    dec edx
    jmp .shade
.pct:
    emit RST, " "
    movsd xmm0, [rsp+40]
    mulsd xmm0, [c_100]
    putf fmt_fixed, xmm0, 1
    emit "%", EOL

    emit "  ", DIM, "loss ", RST
    putf fmt_fixed, [rbx+PS_LOSS], 4
    emit "   ", DIM, "val ", RST
    movsd xmm0, [rbx+PS_VLOSS]
    ucomisd xmm0, xmm0
    jp .noval                   ; nan: no val run yet
    putf fmt_fixed, xmm0, 4
    jmp .lr
.noval:
    emit "-"
.lr:
    emit "   ", DIM, "lr ", RST
    putf fmt_sci, [rbx+PS_LR], 2
    emit "   ", DIM, "gnorm ", RST
    putf fmt_fixed, [rbx+PS_GNORM], 3
    emit EOL

    emit "  "
    cvttsd2si rax, qword [rbx+PS_TOKS]
    put fmt_count, rax
    emit DIM, " tok/s   ", RST
    putf fmt_fixed, [rbx+PS_TFLOPS], 1
    emit DIM, " TFLOPS   ", RST
    put fmt_count, [rbx+PS_SEEN]
    emit DIM, " tokens", RST
    cmp qword [rbx+PS_VRAMTOT], 0
    je .l3end
    emit "   ", DIM, "vram ", RST
    cvtsi2sd xmm0, qword [rbx+PS_VRAM]
    mulsd xmm0, [c_gib]
    putf fmt_fixed, xmm0, 1
    emit DIM, "/", RST
    cvtsi2sd xmm0, qword [rbx+PS_VRAMTOT]
    mulsd xmm0, [c_gib]
    putf fmt_fixed, xmm0, 1
    emit DIM, " GiB", RST
.l3end:
    emit EOL

    emit "  ", DIM, "elapsed ", RST
    cvttsd2si rax, qword [rbx+PS_ELAPSED]
    put fmt_hms, rax
    emit "   ", DIM, "eta ", RST
    ; eta from this session's pace, so a resume doesn't skew it
    mov rax, [rbx+PS_STEP]
    sub rax, [rbx+PS_STEP0]
    jbe .noeta
    cvtsi2sd xmm1, rax
    movsd xmm0, [rsp+32]
    divsd xmm0, xmm1            ; seconds per step
    mov rax, [rbx+PS_TOTAL]
    sub rax, [rbx+PS_STEP]
    jae .left
    xor eax, eax
.left:
    cvtsi2sd xmm1, rax
    mulsd xmm0, xmm1
    cvttsd2si rax, xmm0
    put fmt_hms, rax
    jmp .l4end
.noeta:
    emit "--:--:--"
.l4end:
    emit EOL

    lea rcx, [line]
    mov rdx, rdi
    sub rdx, rcx
    call print                  ; one write for the whole thing, no tearing
    mov qword [rbx+PS_LINES], NLINES
.done:
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = stats, rdx = text, r8 = len. prints a message above the bar (include the newline)
global prog_msg
prog_msg:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    cmp dword [con_tty], 0
    je .print
    cmp qword [rbx+PS_LINES], 0
    je .print
    say 27, "[4A", 27, "[J"     ; up to where the bar starts and wipe it
    mov qword [rbx+PS_LINES], 0
.print:
    mov rcx, rsi
    mov rdx, rdi
    call print
    mov rcx, rbx
    mov edx, 1
    call prog_draw
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = stats. last draw, cursor back
global prog_end
prog_end:
    sub rsp, 40
    mov edx, 1
    call prog_draw
    cmp dword [con_tty], 0
    je .done
    say 27, "[?25h"
.done:
    add rsp, 40
    ret

; rcx = stats, rdx = file handle. one key=value line of the current numbers
global prog_line
prog_line:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    lea rdi, [line]
    emit "step="
    put fmt_dec, [rbx+PS_STEP]
    emit " loss="
    putf fmt_fixed, [rbx+PS_LOSS], 4
    emit " val="
    putf fmt_fixed, [rbx+PS_VLOSS], 4
    emit " lr="
    putf fmt_sci, [rbx+PS_LR], 3
    emit " gnorm="
    putf fmt_fixed, [rbx+PS_GNORM], 4
    emit " tok/s="
    cvttsd2si rax, qword [rbx+PS_TOKS]
    put fmt_dec, rax
    emit " tflops="
    putf fmt_fixed, [rbx+PS_TFLOPS], 2
    emit " tokens="
    put fmt_dec, [rbx+PS_SEEN]
    emit " vram="
    put fmt_dec, [rbx+PS_VRAM]
    emit " elapsed="
    putf fmt_fixed, [rbx+PS_ELAPSED], 1
    emit 13, 10
    mov rcx, r12
    lea rdx, [line]
    mov r8, rdi
    sub r8, rdx
    call file_write
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
