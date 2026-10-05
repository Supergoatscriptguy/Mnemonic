; checkpoints: a header (train/train.inc), then the f32 weights, adam's m and v.
; written to a temp file, flushed, then renamed over the real name, so a crash
; mid-save leaves the previous checkpoint alone. the bf16 copy isn't saved, it
; gets rebuilt from the weights on load. m and v are f32 in the file even when
; adam16 keeps them in bf16, so a run can switch either way
default rel
bits 64
%include "lib.inc"
%include "gpu/cuda.inc"
%include "model/model.inc"
%include "train/train.inc"

LISTSZ equ 1 << 20

section .rdata
e_write db "couldn't write the checkpoint (disk full?)", 0
e_read  db "couldn't read the checkpoint", 0
e_shape db "that checkpoint is for a different model shape", 0

section .bss
alignb 8
stage   resq 1                  ; host copy of one parameter-sized array

section .text

; rax = the staging buffer, allocated the first time
staging:
    mov rax, [stage]
    test rax, rax
    jnz .have
    sub rsp, 40
    mov rcx, [mdl+MD_NP]
    shl rcx, 2
    call mem_alloc
    mov [stage], rax
    add rsp, 40
.have:
    ret

; rcx = header (CK_SIZE bytes), rdx = path, r8 = temp path
global ck_save
ck_save:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 32
    mov rsi, rcx
    mov r12, rdx
    mov r13, r8
    call staging
    mov rdi, rax
    mov rcx, r13
    call file_create
    cmp rax, -1
    je .bad
    mov rbx, rax
    mov rcx, rbx
    mov rdx, rsi
    mov r8d, CK_SIZE
    call file_write
    test eax, eax
    jz .bad
    lea rsi, [d_params]
    call .arr
    lea rsi, [d_adm]
    call .mom
    lea rsi, [d_adv]
    call .mom
    mov rcx, rbx
    call file_flush
    mov rcx, rbx
    call file_close
    mov rcx, r13
    mov rdx, r12
    call file_replace
    test eax, eax
    jz .bad
    add rsp, 32
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.arr:                           ; one array: rsi -> its device pointer
    sub rsp, 40
    mov rcx, rdi
    mov rdx, [rsi]
    mov r8, [mdl+MD_NP]
    shl r8, 2
    call gpu_down
    mov rcx, rbx
    mov rdx, rdi
    mov r8, [mdl+MD_NP]
    shl r8, 2
    call file_write
    add rsp, 40
    test eax, eax
    jz .bad
    ret
.mom:                           ; a moment: bf16 ones get widened, back to front
    cmp dword [mdl_adam16], 0
    je .arr
    sub rsp, 40
    mov rcx, rdi
    mov rdx, [rsi]
    mov r8, [mdl+MD_NP]
    add r8, r8
    call gpu_down
    mov rcx, [mdl+MD_NP]
.w:
    dec rcx
    js .wd
    movzx eax, word [rdi+rcx*2]
    shl eax, 16
    mov [rdi+rcx*4], eax
    jmp .w
.wd:
    mov rcx, rbx
    mov rdx, rdi
    mov r8, [mdl+MD_NP]
    shl r8, 2
    call file_write
    add rsp, 40
    test eax, eax
    jz .bad
    ret
.bad:
    lea rcx, [e_write]
    call fatal

; rcx = path, rdx = header buffer (CK_SIZE). checks the shape, loads everything
global ck_load
ck_load:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov r12, rdx
    call file_open
    cmp rax, -1
    je .bad
    mov rbx, rax
    mov rcx, rbx
    mov rdx, r12
    mov r8d, CK_SIZE
    call file_read
    cmp rax, CK_SIZE
    jne .bad
    mov rax, CK_MAGIC_V
    cmp [r12+CK_MAGIC], rax
    jne .bad
    ; same shape?
    lea rsi, [shape]
.s:
    mov rax, [rsi]
    cmp rax, -1
    je .shaped
    mov rcx, [rsi+8]
    lea rdx, [mdl]
    mov rcx, [rdx+rcx]
    cmp [r12+rax], rcx
    jne .wrong
    add rsi, 16
    jmp .s
.shaped:
    call staging
    mov rdi, rax
    lea rsi, [d_params]
    call .arr
    lea rsi, [d_adm]
    call .mom
    lea rsi, [d_adv]
    call .mom
    mov rcx, rbx
    call file_close
    call model_cast
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
.arr:
    sub rsp, 40
    mov rcx, rbx
    mov rdx, rdi
    mov r8, [mdl+MD_NP]
    shl r8, 2
    call file_read
    mov rcx, [mdl+MD_NP]
    shl rcx, 2
    cmp rax, rcx
    jne .bad
    mov rcx, [rsi]
    mov rdx, rdi
    mov r8, [mdl+MD_NP]
    shl r8, 2
    call gpu_up
    add rsp, 40
    ret
.mom:                           ; a moment: rounded to bf16 for adam16, front to back
    cmp dword [mdl_adam16], 0
    je .arr
    sub rsp, 40
    mov rcx, rbx
    mov rdx, rdi
    mov r8, [mdl+MD_NP]
    shl r8, 2
    call file_read
    mov rcx, [mdl+MD_NP]
    shl rcx, 2
    cmp rax, rcx
    jne .bad
    xor ecx, ecx
.n:
    cmp rcx, [mdl+MD_NP]
    jae .nd
    mov eax, [rdi+rcx*4]
    mov edx, eax
    shr edx, 16
    and edx, 1
    lea eax, [rax+rdx+0x7fff]
    shr eax, 16
    mov [rdi+rcx*2], ax
    inc rcx
    jmp .n
.nd:
    mov rcx, [rsi]
    mov rdx, rdi
    mov r8, [mdl+MD_NP]
    add r8, r8
    call gpu_up
    add rsp, 40
    ret
.bad:
    lea rcx, [e_read]
    call fatal
.wrong:
    lea rcx, [e_shape]
    call fatal

section .rdata
align 8
shape   dq CK_L, MD_L, CK_D, MD_D, CK_H, MD_H, CK_KVH, MD_KVH, CK_F, MD_F
        dq CK_V, MD_V, CK_T, MD_T, CK_NP, MD_NP, -1
section .text

; rcx = pattern (checkpoints\run\step_*.ckpt), rdx = where the newest one's path
; goes. eax = 1 if there is one. zero padded step numbers sort by name
global ck_latest
ck_latest:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    mov ecx, LISTSZ
    call mem_alloc
    mov rbx, rax
    mov rcx, rsi
    mov rdx, rbx
    mov r8d, LISTSZ
    call file_find
    xor esi, esi
    test rax, rax
    jz .done
    mov rsi, [rdx+rax*8-8]
.cp:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .cp
    mov esi, 1
.done:
    mov rcx, rbx
    call mem_free
    mov eax, esi
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = pattern, rdx = how many to keep. deletes the older ones
global ck_prune
ck_prune:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 40
    mov rsi, rcx
    mov r12, rdx
    mov ecx, LISTSZ
    call mem_alloc
    mov rbx, rax
    mov rcx, rsi
    mov rdx, rbx
    mov r8d, LISTSZ
    call file_find
    mov rsi, rdx
    sub rax, r12
    jbe .done
    mov rdi, rax                ; this many go
.del:
    mov rcx, [rsi]
    call file_delete
    add rsi, 8
    dec rdi
    jnz .del
.done:
    mov rcx, rbx
    call mem_free
    add rsp, 40
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
