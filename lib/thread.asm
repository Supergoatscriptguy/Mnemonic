; thread pool with a parallel for. work is handed out in chunks off one atomic
; counter, so fast P cores just grab more chunks than the E cores
default rel
bits 64
%include "lib.inc"

extern CreateThread, CreateEventA, SetEvent, CloseHandle
extern WaitForSingleObject, WaitForMultipleObjects, GetActiveProcessorCount

MAXT equ 64                     ; WaitForMultipleObjects tops out at 64 handles

section .bss
alignb 8
nthreads resq 1                 ; counting the main thread
go_ev    resq MAXT              ; auto-reset, one SetEvent wakes exactly one worker
done_ev  resq MAXT
job_fn   resq 1
job_ctx  resq 1
job_n    resq 1
job_chunk resq 1
alignb 64
job_next resq 8                 ; hammered by every thread, keep it on its own cache line

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
    xor r8d, r8d
    xor r9d, r9d
    call CreateEventA
    lea rcx, [done_ev]
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
    sub rsp, 32
    mov rbx, rcx
.wait:
    lea rax, [go_ev]
    mov rcx, [rax+rbx*8]
    mov edx, -1                 ; INFINITE
    call WaitForSingleObject
    mov rcx, rbx
    call run_chunks
    lea rax, [done_ev]
    mov rcx, [rax+rbx*8]
    call SetEvent
    jmp .wait

; rcx = thread index. grab chunks until there are none left
run_chunks:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rbx, rcx
.grab:
    mov rsi, [job_chunk]
    mov rax, rsi
    lock xadd [job_next], rax   ; rax = our start
    mov rdi, [job_n]
    cmp rax, rdi
    jae .out
    lea r8, [rax+rsi]
    cmp r8, rdi
    cmova r8, rdi
    mov rdx, rax
    mov rcx, [job_ctx]
    mov r9, rbx
    call [job_fn]
    jmp .grab
.out:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = fn, rdx = ctx, r8 = count, r9 = chunk size.
; calls fn(ctx, start, end, thread) over [0, count) on every thread, returns when all done
global par_for
par_for:
    push rbx
    sub rsp, 32
    mov [job_fn], rcx
    mov [job_ctx], rdx
    mov [job_n], r8
    mov [job_chunk], r9
    mov qword [job_next], 0
    mov ebx, 1
.wake:
    cmp rbx, [nthreads]
    jae .work
    lea rax, [go_ev]
    mov rcx, [rax+rbx*8]
    call SetEvent               ; also a full barrier, so the job fields are visible
    inc ebx
    jmp .wake
.work:
    xor ecx, ecx
    call run_chunks             ; main thread pitches in too
    mov rcx, [nthreads]
    cmp rcx, 1
    jbe .done
    dec rcx
    lea rdx, [done_ev+8]
    mov r8d, 1                  ; wait for all of them
    mov r9d, -1
    call WaitForMultipleObjects
.done:
    add rsp, 32
    pop rbx
    ret
