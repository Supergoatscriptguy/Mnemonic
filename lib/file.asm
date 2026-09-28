; file helpers. paths are plain ascii, handles come back as -1 on failure
default rel
bits 64
%include "lib.inc"

extern CreateFileA, ReadFile, WriteFile, GetFileSizeEx, FlushFileBuffers, CloseHandle
extern CreateFileMappingA, MapViewOfFile, UnmapViewOfFile
extern MoveFileExA, DeleteFileA, GetFileAttributesA, CreateDirectoryA

GENERIC_READ  equ 0x80000000
GENERIC_WRITE equ 0x40000000
APPEND_DATA   equ 4
CREATE_ALWAYS equ 2
OPEN_EXISTING equ 3
OPEN_ALWAYS   equ 4
CHUNK         equ 1 << 30       ; ReadFile/WriteFile sizes are 32-bit

section .text

; rcx = path, edx = access, r8d = disposition
opener:
    sub rsp, 56
    mov [rsp+32], r8
    mov qword [rsp+40], 0x80    ; FILE_ATTRIBUTE_NORMAL
    mov qword [rsp+48], 0
    mov r8d, 3                  ; others can read/write while we have it open
    xor r9d, r9d
    call CreateFileA
    add rsp, 56
    ret

global file_open
file_open:
    mov edx, GENERIC_READ
    mov r8d, OPEN_EXISTING
    jmp opener

global file_create
file_create:
    mov edx, GENERIC_WRITE
    mov r8d, CREATE_ALWAYS
    jmp opener

; creates it if needed, every write lands at the end
global file_append
file_append:
    mov edx, APPEND_DATA
    mov r8d, OPEN_ALWAYS
    jmp opener

; rcx = handle, rdx = buf, r8 = size. returns bytes read
global file_read
file_read:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 56
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    xor r12d, r12d
.loop:
    test rdi, rdi
    jz .done
    mov r8, rdi
    mov eax, CHUNK
    cmp r8, rax
    cmova r8, rax
    mov rcx, rbx
    mov rdx, rsi
    lea r9, [rsp+40]
    mov qword [rsp+32], 0
    mov dword [rsp+40], 0
    call ReadFile
    test eax, eax
    jz .done
    mov eax, [rsp+40]
    test eax, eax
    jz .done                    ; eof
    add rsi, rax
    add r12, rax
    sub rdi, rax
    jmp .loop
.done:
    mov rax, r12
    add rsp, 56
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = handle, rdx = buf, r8 = size. eax = 1 if it all got written
global file_write
file_write:
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
.loop:
    test rdi, rdi
    jz .ok
    mov r8, rdi
    mov eax, CHUNK
    cmp r8, rax
    cmova r8, rax
    mov rcx, rbx
    mov rdx, rsi
    lea r9, [rsp+40]
    mov qword [rsp+32], 0
    call WriteFile
    test eax, eax
    jz .done
    mov eax, [rsp+40]
    add rsi, rax
    sub rdi, rax
    jmp .loop
.ok:
    mov eax, 1
.done:
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = handle
global file_size
file_size:
    sub rsp, 40
    lea rdx, [rsp+32]
    call GetFileSizeEx
    mov rax, [rsp+32]
    add rsp, 40
    ret

; push it to the disk, before a rename makes it official
global file_flush
file_flush:
    jmp FlushFileBuffers

global file_close
file_close:
    jmp CloseHandle

; rcx = path. rax = buffer with a 0 after the data (mem_free it), rdx = size.
; rax = 0 if the file isn't there
global file_read_all
file_read_all:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    call file_open
    cmp rax, -1
    je .none
    mov rbx, rax
    mov rcx, rax
    call file_size
    mov rsi, rax
    lea rcx, [rax+1]
    call mem_alloc
    mov rdi, rax
    mov rcx, rbx
    mov rdx, rdi
    mov r8, rsi
    call file_read
    mov rcx, rbx
    call file_close
    mov rax, rdi
    mov rdx, rsi
    jmp .done
.none:
    xor eax, eax
    xor edx, edx
.done:
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = path. read-only view of the whole file: rax = ptr (0 on failure), rdx = size
global file_map
file_map:
    push rbx
    push rsi
    push rdi
    sub rsp, 48
    call file_open
    cmp rax, -1
    je .fail
    mov rbx, rax
    mov rcx, rax
    call file_size
    mov rsi, rax
    xor edi, edi
    test rax, rax
    jz .close                   ; empty files can't be mapped
    mov rcx, rbx
    xor edx, edx
    mov r8d, 2                  ; PAGE_READONLY
    xor r9d, r9d
    mov qword [rsp+32], 0
    mov qword [rsp+40], 0
    call CreateFileMappingA
    test rax, rax
    jz .close
    mov rdi, rax
    mov rcx, rax
    mov edx, 4                  ; FILE_MAP_READ
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 0
    call MapViewOfFile
    mov rcx, rdi
    mov rdi, rax
    call CloseHandle            ; the view keeps the mapping alive on its own
.close:
    mov rcx, rbx
    call file_close
    mov rax, rdi
    mov rdx, rsi
    jmp .done
.fail:
    xor eax, eax
    xor edx, edx
.done:
    add rsp, 48
    pop rdi
    pop rsi
    pop rbx
    ret

global file_unmap
file_unmap:
    jmp UnmapViewOfFile

; rcx = from, rdx = to. atomically replaces "to", so a crash leaves either the old or the new file
global file_replace
file_replace:
    mov r8d, 9                  ; MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH
    jmp MoveFileExA

global file_delete
file_delete:
    jmp DeleteFileA

; rcx = path. eax = 1 if it exists
global file_exists
file_exists:
    sub rsp, 40
    call GetFileAttributesA
    xor ecx, ecx
    cmp eax, -1
    setne cl
    mov eax, ecx
    add rsp, 40
    ret

; rcx = path. fine if it's already there
global make_dir
make_dir:
    xor edx, edx
    jmp CreateDirectoryA
