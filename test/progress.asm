; stage 1 demo: a fake training loop with the progress bar, log file, autosave,
; ctrl+c and resume. run from the repo root:
;   bin\progress.exe               settings from test\progress.cfg
;   bin\progress.exe steps=2000    key=value args override the cfg
; ctrl+c once: finish the step, save, exit 2. twice: exit right away, 130.
; run it again after a stop and it picks up where it left off.
default rel
bits 64
%include "lib.inc"

extern Sleep, ExitProcess

TOKS equ 1024                   ; pretend tokens per step, ~40 TFLOPS at 20 ms/step

; saved state
SV_STEP    equ 0
SV_SEEN    equ 8
SV_ELAPSED equ 16
SV_RNG     equ 24
SV_LOSS    equ 56               ; for a stop on the last step: the resume goes straight to the end
SV_SIZE    equ 64

section .rdata
cfgpath  db "test\progress.cfg", 0
state    db "logs\demo.state", 0
statetmp db "logs\demo.state.tmp", 0
donepath db "logs\demo.done", 0
logpath  db "logs\demo.log", 0
logsdir  db "logs", 0
k_steps  db "steps", 0
k_ms     db "step_ms", 0
k_lr     db "lr", 0
k_warm   db "warmup", 0
k_val    db "val_every", 0
k_log    db "log_every", 0
k_save   db "save_every", 0
k_seed   db "seed", 0
m_saved  db "saved at step ", 0
m_resume db "resuming from step ", 0
align 8
d_lr     dq 3e-4
c_nan    dq 0x7ff8000000000000
c_half   dq 0.5
c_one    dq 1.0
c_pi     dq 3.141592653589793
c_tenth  dq 0.1
c_09     dq 0.9
c_04     dq 0.4
c_two    dq 2.0
c_eight  dq 8.0
c_decay  dq -0.006666666666666667  ; -1/150
c_noise  dq 0.03
c_vbias  dq 0.08
c_flops  dq 7.56e-4             ; 6 * 126M params / 1e12, TFLOPS per token/s
vram     dq 12133049958         ; ~11.3 GiB, made up
vramtot  dq 17094934528         ; 16 GB card

section .bss
alignb 8
stats    resb PS_SIZE
rng      resb RNG_SIZE
sv       resb SV_SIZE
steps    resq 1
step_ms  resq 1
warmup   resq 1
val_ev   resq 1
log_ev   resq 1
save_ev  resq 1
seed     resq 1
max_lr   resq 1
logh     resq 1
msg      resb 128

section .text

%macro cfgi 3                   ; dest, key, default
    lea rcx, [%2]
    mov edx, %3
    call cfg_int
    mov [%1], rax
%endmacro

; zf set if step is a multiple of [%1]
%macro every 1
    mov rax, [stats+PS_STEP]
    xor edx, edx
    div qword [%1]
    test rdx, rdx
%endmacro

global start
start:
    sub rsp, 40
    call lib_init
    lea rcx, [cfgpath]
    call cfg_load
    call cfg_args
    cfgi steps, k_steps, 400
    cfgi step_ms, k_ms, 20
    cfgi warmup, k_warm, 40
    cfgi val_ev, k_val, 100
    cfgi log_ev, k_log, 50
    cfgi save_ev, k_save, 100
    cfgi seed, k_seed, 1234
    lea rcx, [k_lr]
    movsd xmm1, [d_lr]
    call cfg_float
    movsd [max_lr], xmm0

    call ctrlc_init
    lea rcx, [logsdir]
    call make_dir

    mov rax, [steps]
    mov [stats+PS_TOTAL], rax
    mov rax, [c_nan]
    mov [stats+PS_VLOSS], rax
    mov rax, [vram]
    mov [stats+PS_VRAM], rax
    mov rax, [vramtot]
    mov [stats+PS_VRAMTOT], rax
    lea rcx, [rng]
    mov rdx, [seed]
    call rng_seed

    ; a state file means a run got interrupted, carry on from it
    lea rcx, [state]
    call file_read_all
    test rax, rax
    jz .fresh
    mov rcx, [rax+SV_STEP]
    mov [stats+PS_STEP], rcx
    mov rcx, [rax+SV_SEEN]
    mov [stats+PS_SEEN], rcx
    mov rcx, [rax+SV_ELAPSED]
    mov [stats+PS_ELAPSED0], rcx
    movdqu xmm0, [rax+SV_RNG]
    movdqu [rng], xmm0
    movdqu xmm0, [rax+SV_RNG+16]
    movdqu [rng+16], xmm0
    mov rcx, [rax+SV_LOSS]
    mov [stats+PS_LOSS], rcx
    mov rcx, rax
    call mem_free
    lea rcx, [m_resume]
    call print_z
    mov rcx, [stats+PS_STEP]
    call print_dec
    say 13, 10
.fresh:
    lea rcx, [logpath]
    call file_append
    mov [logh], rax
    lea rcx, [stats]
    call prog_begin

.loop:
    mov rax, [stats+PS_STEP]
    cmp rax, [steps]
    jae .finished
    mov rcx, [step_ms]
    call Sleep                  ; the "training"
    inc qword [stats+PS_STEP]
    add qword [stats+PS_SEEN], TOKS
    call fake

    every val_ev
    jnz .noval
    call val
.noval:
    every log_ev
    jnz .nolog
    lea rcx, [stats]
    mov rdx, [logh]
    call prog_line
    cmp dword [con_tty], 0
    jne .nolog
    lea rcx, [stats]            ; redirected, so there's no bar. print the line instead
    mov rdx, [con_out]
    call prog_line
.nolog:
    every save_ev
    jnz .nosave
    call save
.nosave:
    lea rcx, [stats]
    xor edx, edx
    call prog_draw
    cmp dword [stop_flag], 0
    je .loop

    ; ctrl+c: the step is done, save and get out
    call save
    lea rcx, [stats]
    call prog_end
    say "stopped, run it again to resume", 13, 10
    call con_restore
    mov ecx, 2
    call ExitProcess

.finished:
    lea rcx, [stats]
    call prog_end
    ; final step, loss and rng for ctrltest to compare against
    mov rax, [stats+PS_STEP]
    mov [sv], rax
    mov rax, [stats+PS_LOSS]
    mov [sv+8], rax
    movdqu xmm0, [rng]
    movdqu [sv+16], xmm0
    movdqu xmm0, [rng+16]
    movdqu [sv+32], xmm0
    lea rcx, [donepath]
    call file_create
    mov rbx, rax
    mov rcx, rax
    lea rdx, [sv]
    mov r8d, 48
    call file_write
    mov rcx, rbx
    call file_close
    lea rcx, [state]
    call file_delete            ; finished, next run starts fresh
    mov rcx, [logh]
    call file_close
    call con_restore
    xor ecx, ecx
    call ExitProcess

; makes up this step's numbers. always the same number of rng draws per step,
; so a resumed run comes out identical to one that never stopped
fake:
    sub rsp, 40
    ; lr: linear warmup, then cosine down to 10%
    mov rax, [stats+PS_STEP]
    cmp rax, [warmup]
    jae .cos
    cvtsi2sd xmm0, rax
    cvtsi2sd xmm1, qword [warmup]
    divsd xmm0, xmm1
    mulsd xmm0, [max_lr]
    jmp .lr
.cos:
    sub rax, [warmup]
    cvtsi2sd xmm0, rax
    mov rax, [steps]
    sub rax, [warmup]
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    mulsd xmm0, [c_pi]
    call math_cos
    addsd xmm0, [c_one]
    mulsd xmm0, [c_half]
    mulsd xmm0, [c_09]
    addsd xmm0, [c_tenth]
    mulsd xmm0, [max_lr]
.lr:
    movsd [stats+PS_LR], xmm0

    ; loss = 2 + 8 exp(-step/150) + noise
    cvtsi2sd xmm0, qword [stats+PS_STEP]
    mulsd xmm0, [c_decay]
    call math_exp
    mulsd xmm0, [c_eight]
    addsd xmm0, [c_two]
    movsd [stats+PS_LOSS], xmm0
    lea rcx, [rng]
    call rng_normal
    mulsd xmm0, [c_noise]
    addsd xmm0, [stats+PS_LOSS]
    movsd [stats+PS_LOSS], xmm0

    ; grad norm = 0.4 + 0.1 |noise|
    lea rcx, [rng]
    call rng_normal
    movq rax, xmm0
    btr rax, 63
    movq xmm0, rax
    mulsd xmm0, [c_tenth]
    addsd xmm0, [c_04]
    movsd [stats+PS_GNORM], xmm0

    ; throughput over this session
    mov rcx, [stats+PS_T0]
    call time_since
    mov rax, [stats+PS_STEP]
    sub rax, [stats+PS_STEP0]
    imul rax, rax, TOKS
    cvtsi2sd xmm1, rax
    divsd xmm1, xmm0
    movsd [stats+PS_TOKS], xmm1
    mulsd xmm1, [c_flops]
    movsd [stats+PS_TFLOPS], xmm1
    add rsp, 40
    ret

; fake validation: a bit above train loss
val:
    sub rsp, 40
    movsd xmm0, [stats+PS_LOSS]
    addsd xmm0, [c_vbias]
    movsd [stats+PS_VLOSS], xmm0
    lea rcx, [msg]
    lea rdx, [m_val]
    call fmt_str
    mov rcx, rax
    movsd xmm1, [stats+PS_VLOSS]
    mov r8d, 4
    call fmt_fixed
    mov rcx, rax
    lea rdx, [m_at]
    call fmt_str
    mov rcx, rax
    mov rdx, [stats+PS_STEP]
    call fmt_dec
    mov word [rax], 0x0a0d
    add rax, 2
    lea rdx, [msg]
    mov r8, rax
    sub r8, rdx
    lea rcx, [stats]
    call prog_msg
    add rsp, 40
    ret

; checkpoint: write a temp file, flush, then rename it over the real one,
; so a crash mid-write never costs us the last good state
save:
    push rbx
    sub rsp, 32
    mov rax, [stats+PS_STEP]
    mov [sv+SV_STEP], rax
    mov rax, [stats+PS_SEEN]
    mov [sv+SV_SEEN], rax
    mov rcx, [stats+PS_T0]
    call time_since
    addsd xmm0, [stats+PS_ELAPSED0]
    movsd [sv+SV_ELAPSED], xmm0
    movdqu xmm0, [rng]
    movdqu [sv+SV_RNG], xmm0
    movdqu xmm0, [rng+16]
    movdqu [sv+SV_RNG+16], xmm0
    mov rax, [stats+PS_LOSS]
    mov [sv+SV_LOSS], rax

    lea rcx, [statetmp]
    call file_create
    mov rbx, rax
    mov rcx, rax
    lea rdx, [sv]
    mov r8d, SV_SIZE
    call file_write
    mov rcx, rbx
    call file_flush
    mov rcx, rbx
    call file_close
    lea rcx, [statetmp]
    lea rdx, [state]
    call file_replace

    lea rcx, [msg]
    lea rdx, [m_saved]
    call fmt_str
    mov rcx, rax
    mov rdx, [stats+PS_STEP]
    call fmt_dec
    mov word [rax], 0x0a0d
    add rax, 2
    lea rdx, [msg]
    mov r8, rax
    sub r8, rdx
    lea rcx, [stats]
    call prog_msg
    add rsp, 32
    pop rbx
    ret

section .rdata
m_val    db "val loss ", 0
m_at     db " at step ", 0
