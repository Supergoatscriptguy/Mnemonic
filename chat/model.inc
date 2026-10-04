; cpu inference: the model file, the matrices in memory, the engine.
; include after lib.inc

extern mf_size, q8_row, q4_row, q4_row_fit, qx_vec
extern kern_pick, kern_set, kern_name, mv_run, exp8
extern eng_load, eng_reset, eng_step, eng_nll, eng, eng_mx
extern samp_pick, samp_temp, samp_topp

; model file: this header, then the tensors, each starting on 64 bytes:
;   E [V][D]                                  (tied: input embedding and output)
;   per layer: Wqkv [QKV][D], Wo [D][QD], W13 [2F][D], W2 [D][F]
;   the norm weights, f32: n1, n2 for every layer, then the final one
; a matrix is stored by type:
;   QT_F32: f32 [rows][cols]
;   QT_Q8:  int8 [rows][cols], then f32 scale per row
;   QT_Q4:  per group of 32 along a row, 16 bytes: byte j = (q_j+8) | (q_{j+16}+8) << 4,
;           then f32 scale per group ([rows][cols/32])
MF_MAGIC_V equ 'MNMODEL1'
MF_MAGIC   equ 0
MF_L       equ 8
MF_D       equ 16
MF_H       equ 24
MF_KVH     equ 32
MF_HD      equ 40
MF_F       equ 48
MF_V       equ 56
MF_T       equ 64
MF_ROPE    equ 72               ; f64
MF_QT      equ 80
MF_TOKHASH equ 88
MF_SIZE    equ 4096

QT_F32     equ 0
QT_Q8      equ 1
QT_Q4      equ 2
GROUP      equ 32               ; q4 weight groups, and activation groups

; a matrix in memory
MX_Q       equ 0                ; weights
MX_S       equ 8                ; scales (q8: per row, q4: per group)
MX_R       equ 16               ; rows
MX_C       equ 24               ; cols
MX_T       equ 32               ; QT_*
MX_SIZE    equ 40

; the engine (one model loaded at a time)
EN_L       equ 0
EN_D       equ 8
EN_H       equ 16
EN_KVH     equ 24
EN_HD      equ 32
EN_F       equ 40
EN_V       equ 48
EN_T       equ 56
EN_QD      equ 64
EN_KVD     equ 72
EN_QKV     equ 80
EN_QT      equ 88
EN_POS     equ 96               ; tokens in the kv cache
EN_NORMS   equ 104              ; f32 norm weights: n1, n2 per layer, then final
EN_E       equ 112              ; MX_SIZE, the embedding
EN_LAYERS  equ 152              ; -> L x 4 matrices (qkv, o, 13, 2)
EN_KC      equ 160              ; kv cache, f32 [L][T][KVD]
EN_VC      equ 168
EN_ROPE    equ 176              ; [T][hd/2] (cos, sin)
EN_X       equ 184              ; residual stream [D]
EN_XN      equ 192              ; normed [max(D, F)]
EN_QKVB    equ 200              ; [QKV]
EN_Y       equ 208              ; attention out [QD]
EN_HB      equ 216              ; [2F]
EN_G       equ 224              ; [F]
EN_LOGITS  equ 232              ; [V]
EN_XQ      equ 240              ; quantized activations: int8 [max in], scales [max in/32]
EN_XS      equ 248
EN_ATT     equ 256              ; scores, per head [H][T]
EN_TOKHASH equ 264
EN_BASE    equ 272              ; the mapped file
EN_TMP     equ 280              ; a matrix output that gets added into x [D]
EN_PROBS   equ 288              ; sampling [V]
EN_BYTES   equ 296              ; file size
EN_SIZE    equ 304
