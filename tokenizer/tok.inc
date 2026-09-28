; tokenizer: constants and shared declarations. include after lib.inc

extern pretok_next, whash, memeq
extern bpe_train
extern tok_load, tok_encode, tok_encode_chunk, tok_decode, tok_bytes
extern tok_nmerges, tok_hash, tok_cache_new
extern render_doc, render_conv

VOCAB      equ 32768
NSPECIAL   equ 16
SPECIAL0   equ VOCAB - NSPECIAL ; specials sit at the top of the vocab
TOK_BOS    equ SPECIAL0 + 0
TOK_USER   equ SPECIAL0 + 1
TOK_ASSIST equ SPECIAL0 + 2
TOK_SYSTEM equ SPECIAL0 + 3
TOK_END    equ SPECIAL0 + 4     ; end of a turn
NMERGES    equ SPECIAL0 - 256   ; 32496
MASKBIT    equ 0x8000           ; chat .tok files: this token is a training target
MAXWORD    equ 256              ; longest chunk that bpe training looks at

; encode context (tok_cache_new), one per thread
TC_CACHE   equ 0
TC_WORK    equ 8
TC_NOCACHE equ 16               ; set to 1 to skip the cache (for checking it)
TC_SIZE    equ 64

; tokenizer file: header, then u32 merges (a | b << 16), merge i makes token 256+i
TK_MAGIC     equ 'MNTOKZR1'
TKH_MAGIC    equ 0
TKH_VOCAB    equ 8              ; u32
TKH_NMERGES  equ 12             ; u32
TKH_SPECIAL0 equ 16             ; u32
TKH_NSPECIAL equ 20             ; u32
TKH_HASH     equ 24             ; u64, of the merges. .tok files carry it
TKH_SIZE     equ 32

; .tok files: header, then u16 tokens
TF_MAGIC_V equ 'MNTOKEN1'
TF_MAGIC   equ 0
TF_NTOK    equ 8
TF_NDOCS   equ 16
TF_VOCAB   equ 24
TF_HASH    equ 32               ; tokenizer that made it
TF_FLAGS   equ 40               ; 1 = chat: MASKBIT marks the targets
TF_SIZE    equ 64

; bpe_train
BT_DOCS    equ 0                ; -> (ptr, len) per doc
BT_NDOCS   equ 8
BT_NMERGES equ 16
BT_NAIVE   equ 24               ; 1 = recount every pair for every merge (slow, for checking)
BT_VERBOSE equ 32
BT_MERGES  equ 40               ; -> u32 per merge, a | b << 16 (filled in)
BT_COUNTS  equ 48               ; -> u64 per merge, how often that pair occurred
BT_DONE    equ 56               ; merges actually done
BT_WORDS   equ 64               ; unique words seen
BT_BAD     equ 72               ; verification problems, should be 0
BT_SIZE    equ 80
