; parquet reader structures. include after lib.inc

extern pq_open, pq_close, pq_leaf, pq_pagehdr, pq_chunk, rle_decode
extern snappy_decompress, zstd_init, zstd_decompress, zstd_err

ZSTD_CTX      equ 256 * 1024    ; bytes for one zstd_decompress context

; one open file. everything it points to lives in its arena
PQ_ARENA      equ 0             ; ARENA_SIZE bytes
PQ_BASE       equ 32            ; the mapped file
PQ_SIZE       equ 40
PQ_ROWS       equ 48
PQ_NSCHEMA    equ 56
PQ_SCHEMA     equ 64            ; -> SE entries, depth first like in the file
PQ_NRG        equ 72
PQ_RG         equ 80            ; -> RG entries
PQ_NCOL       equ 88            ; leaf columns
PQ_LEAF       equ 96            ; -> LF entries, one per leaf column
PQ_CREATED    equ 104           ; created_by, not terminated
PQ_CREATEDLEN equ 112
PQ_SIZEOF     equ 120

; schema element
SE_NAME       equ 0
SE_NLEN       equ 8
SE_TYPE       equ 16            ; physical type, -1 for groups
SE_REP        equ 20            ; 0 required, 1 optional, 2 repeated
SE_NCHILD     equ 24
SE_CONV       equ 28            ; converted type, -1 if none
SE_DEPTH      equ 32            ; root is 0
SE_SIZE       equ 40

; leaf column
LF_PATH       equ 0             ; like "messages.list.element.content", zero terminated
LF_SE         equ 8             ; its schema element
LF_MAXDEF     equ 16
LF_MAXREP     equ 20
LF_SIZE       equ 24

; row group
RG_ROWS       equ 0
RG_COLS       equ 8             ; -> CC entries, one per leaf column
RG_SIZE       equ 16

; column chunk
CC_TYPE       equ 0
CC_CODEC      equ 4
CC_ENC        equ 8             ; bit n set = encoding n shows up
CC_NVAL       equ 16
CC_USIZE      equ 24
CC_CSIZE      equ 32            ; page headers included
CC_DATA       equ 40            ; file offset of the first data page
CC_DICT       equ 48            ; dictionary page offset, 0 if none
CC_SIZE       equ 56

; page header
PH_TYPE       equ 0             ; 0 data v1, 1 index, 2 dictionary, 3 data v2
PH_USIZE      equ 4
PH_CSIZE      equ 8
PH_NVAL       equ 12            ; level entries, nulls included
PH_ENC        equ 16            ; value encoding
PH_NNULL      equ 20            ; v2 only
PH_NROWS      equ 24            ; v2 only
PH_DEFLEN     equ 28            ; v2: level bytes, stored uncompressed before the values
PH_REPLEN     equ 32
PH_COMP       equ 36            ; v2: are the values compressed
PH_SIZE       equ 48

; one decoded column chunk. the caller fills in ARENA and ZSTD, pq_chunk the rest
COL_ARENA     equ 0             ; -> arena everything gets allocated from
COL_ZSTD      equ 8             ; -> zstd context, ZSTD_CTX bytes
COL_N         equ 16            ; level entries
COL_REP       equ 24            ; -> u32 per entry, 0 if the column never repeats
COL_DEF       equ 32            ; -> u32 per entry, 0 if it's required
COL_NV        equ 40            ; values, i.e. entries whose def is the max
COL_VALS      equ 48            ; -> (ptr, len) per value
COL_SIZE      equ 56

; physical types
T_BOOLEAN     equ 0
T_INT32       equ 1
T_INT64       equ 2
T_BYTE_ARRAY  equ 6

; codecs
C_NONE        equ 0
C_SNAPPY      equ 1
C_GZIP        equ 2
C_ZSTD        equ 6

; encodings
E_PLAIN       equ 0
E_PLAIN_DICT  equ 2
E_RLE         equ 3
E_RLE_DICT    equ 8
