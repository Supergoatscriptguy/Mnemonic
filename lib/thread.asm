; thread pool with a parallel for. work is handed out in chunks off one atomic
; counter, so fast P cores just grab more chunks than the E cores.
; workers spin for a while after a job before they go to sleep: the chat engine
; runs ~80 tiny jobs per token, and waking sleeping threads cost more than the jobs
default rel
bits 64
%include "lib.inc"

extern CreateThread, CreateEventA, SetEvent, CloseHandle
extern WaitForSingleObject, GetActiveProcessorCount, Sleep

MAXT   equ 64
SPIN   equ 1 << 20              ; tsc ticks a worker spins before sleeping, ~0.3 ms
CLOSED equ 0xffffffff           ; ticket index once a job is over

section .bss
alignb 8
nthreads resq 1                 ; counting the main thread
go_ev    resq MAXT              ; auto-reset, for waking a sleeping worker
gen      resq 1                 ; jobs so far, only the main thread touches it
job_fn   resq 1
job_ctx  resq 1
job_n    resq 1
job_chunk resq 1
; hammered by every thread, each on its own cache line
alignb 64
ticket   resq 8                 ; job gen << 32 | next index, claimed with cmpxchg
alignb 64
done     resq 8                 ; items finished in the current job
alignb 64
asleep   resb MAXT              ; worker i is in (or about to be in) its wait

section .text

; ecx = threads including this one, 0 = one per logical cpu
global pool_init
pool_init:
    push rbx
    push rsi
    sub rsp, 56
    mov ebx, ecx
    test ebx, ebx
    jnz .have
    mov ecx, 0xffff             ; ALL_PROCESSOR_GROUPS
    call GetActiveProcessorCount
    mov ebx, eax
.have:
    mov eax, MAXT
    cmp ebx, eax
    cmova ebx, eax
    mov [nthreads], rbx
    mov esi, 1                  ; 0 is the main thread
.spawn:
    cmp esi, ebx
    jae .done
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call CreateEventA
    lea rcx, [go_ev]
    mov [rcx+rsi*8], rax
    xor ecx, ecx
    xor edx, edx
    lea r8, [worker]
    mov r9, rsi                 ; its index
    mov qword [rsp+32], 0
    mov qword [rsp+40], 0
    call CreateThread
    mov rcx, rax
    call CloseHandle            ; the thread keeps running, we just don't need the handle
    inc esi
    jmp .spawn
.done:
    add rsp, 56
    pop rsi
    pop rbx
    ret

; rcx = thread index
worker:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
    xor esi, esi                ; the last job we saw (jobs start at 1)
.idle:
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov rdi, rax
.spin:
    mov rax, [ticket]
    shr rax, 32
    cmp rax, rsi
    jne .job
    pause
    rdtsc
    shl rdx, 32
    or rax, rdx
    sub rax, rdi
    cmp rax, SPIN
    jb .spin
    ; nothing for a while, sleep. the flag goes up before one last look at the
    ; ticket, and par_for publishes the ticket before it reads the flags, so a new
    ; job can't slip in between unnoticed
    mov al, 1
    lea rcx, [asleep]
    xchg [rcx+rbx], al
    mov rax, [ticket]
    shr rax, 32
    cmp rax, rsi
    jne .woke
    lea rax, [go_ev]
    mov rcx, [rax+rbx*8]
    mov edx, -1                 ; INFINITE
    call WaitForSingleObject
.woke:
    xor eax, eax
    lea rcx, [asleep]
    xchg [rcx+rbx], al
    jmp .idle                   ; a stale wakeup just spins and sleeps again
.job:
    mov rcx, rbx
    call run_chunks
    mov rsi, rax
    jmp .idle

; rcx = thread index. claims chunks until the job runs out. rax = the job it saw last.
; a worker can show up late, when its job is long over and the fields already belong
; to the next one. the cmpxchg only goes through if the ticket hasn't moved since we
; read it, and par_for closes the ticket before it rewrites the fields, so a claim
; that succeeds always used fields from the right job
run_chunks:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, rcx
.grab:
    mov rsi, [ticket]
    mov r12, [job_n]
    mov rdi, [job_chunk]
    mov r14, [job_fn]
    mov r15, [job_ctx]
    mov eax, esi                ; next index
    cmp rax, r12
    jae .out
    lea r13, [rax+rdi]          ; our end
    lea rdx, [rsi+rdi]
    mov rax, rsi
    lock cmpxchg [ticket], rdx
    jne .grab
    cmp r13, r12
    cmova r13, r12
    mov rcx, r15
    mov edx, esi
    mov r8, r13
    mov r9, rbx
    call r14
    mov eax, esi
    sub r13, rax
    lock add [done], r13
    jmp .grab
.out:
    mov rax, rsi
    shr rax, 32
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = fn, rdx = ctx, r8 = count (under 2^32), r9 = chunk size.
; calls fn(ctx, start, end, thread) over [0, count) on every thread, returns when all done
global par_for
par_for:
    push rbx
    push rsi
    sub rsp, 40
    mov [job_fn], rcx
    mov [job_ctx], rdx
    mov [job_n], r8
    mov [job_chunk], r9
    mov qword [done], 0
    mov rax, [gen]
    inc rax
    mov [gen], rax
    shl rax, 32
    xchg [ticket], rax          ; publish. xchg is a full barrier, the fields are out first
    mov ebx, 1
.wake:
    cmp rbx, [nthreads]
    jae .work
    lea rax, [asleep]
    cmp byte [rax+rbx], 0
    je .next
    lea rax, [go_ev]
    mov rcx, [rax+rbx*8]
    call SetEvent
.next:
    inc ebx
    jmp .wake
.work:
    xor ecx, ecx
    call run_chunks             ; main thread pitches in too
    ; wait for the items, not the threads: a worker the os parked somewhere
    ; doesn't hold anyone up, whatever it claimed is all that's waited for.
    ; spin at first, then sleep between looks (long jobs like downloads)
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov rsi, rax
.wait:
    mov rax, [done]
    cmp rax, [job_n]
    jae .close
    pause
    rdtsc
    shl rdx, 32
    or rax, rdx
    sub rax, rsi
    cmp rax, SPIN * 4
    jb .wait
    mov ecx, 1
    call Sleep
    jmp .wait
.close:
    mov rax, [gen]
    shl rax, 32
    mov ecx, CLOSED             ; not an imm in the or, that would sign extend over the gen
    or rax, rcx
    mov [ticket], rax
    add rsp, 40
    pop rsi
    pop rbx
    ret
