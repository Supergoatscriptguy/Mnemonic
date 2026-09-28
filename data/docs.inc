; .docs files: extracted text, ready to memory map. all little endian.
;   header (64 bytes), then
;   u64 offsets[ndocs+1]    doc i is text[offsets[i] .. offsets[i+1])
;   u8  roles[ndocs]        chat only: 0 system, 1 user, 2 assistant, 3 other
;   u64 convs[nconv+1]      chat only: conversation j is docs convs[j] .. convs[j+1]
;   text
; the file offsets of each part are in the header, 8 byte aligned

DOCS_MAGIC    equ 'MNDOCS1'         ; 8 bytes with the trailing 0

DH_MAGIC      equ 0
DH_NDOCS      equ 8
DH_NCONV      equ 16            ; 0 for plain text
DH_BYTES      equ 24
DH_OFFS       equ 32            ; file offset of offsets[]
DH_ROLES      equ 40            ; 0 if no roles
DH_CONVS      equ 48            ; 0 if no conversations
DH_TEXT       equ 56
DH_SIZE       equ 64

ROLE_SYSTEM   equ 0
ROLE_USER     equ 1
ROLE_ASSIST   equ 2
ROLE_OTHER    equ 3
