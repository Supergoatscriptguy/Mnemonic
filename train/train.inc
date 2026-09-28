; the trainer's parts: the data loader (train/data.asm) and checkpoints (train/ckpt.asm)

extern ld_init, ld_rows, ld_val, ld_file, ld_off, ld_nfiles, ld_chat, ld_ctx
extern ck_save, ck_load, ck_latest, ck_prune

; checkpoint file: this header, then the f32 master weights, adam m, adam v
CK_MAGIC_V equ 'MNCKPT01'
CK_MAGIC   equ 0
CK_L       equ 8                ; the model's shape, has to match on load
CK_D       equ 16
CK_H       equ 24
CK_KVH     equ 32
CK_F       equ 40
CK_V       equ 48
CK_T       equ 56
CK_NP      equ 64
CK_STEP    equ 72               ; steps done
CK_SEEN    equ 80               ; tokens trained on
CK_FILE    equ 88               ; where the next step's data starts
CK_OFF     equ 96
CK_ELAPSED equ 104              ; f64 seconds, over all sessions
CK_VLOSS   equ 112              ; f64, latest val loss
CK_RNG     equ 120              ; sampling rng, 32 bytes
CK_TOTAL   equ 152              ; steps planned (just for the record)
CK_SIZE    equ 4096             ; the weights start on a page
