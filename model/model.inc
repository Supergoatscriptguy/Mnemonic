; the transformer: config, sizes, buffers. include after lib.inc and gpu/cuda.inc

extern model_config, model_setup, model_init, model_cast, model_fwd, model_bwd
extern model_zero, model_step, model_sort, model_loss, model_summary
extern mdl, mdl_fast, mdl_streams, mdl_fp8, lp, d_params, d_bf, d_grad, d_adm, d_adv, d_logits, d_loss, d_gn
extern k_f2bf, mm_ref_f, mm_tc_f

; mdl: the config plus everything derived from it. all u64
MD_L      equ 0
MD_D      equ 8
MD_H      equ 16                ; query heads
MD_KVH    equ 24
MD_HD     equ 32                ; head dim, D / H
MD_F      equ 40                ; ffn hidden size
MD_V      equ 48
MD_T      equ 56                ; context
MD_B      equ 64                ; rows per micro-batch, activations are sized for B*T
MD_QD     equ 72                ; H*HD
MD_KVD    equ 80
MD_QKV    equ 88                ; QD + 2 KVD, one row of the fused qkv projection
MD_M      equ 96                ; B*T
MD_ES     equ 104               ; bytes per activation: 2 (bf16) or 4 (f32, for gradient checks)
MD_NP     equ 112               ; params
MD_NDEC   equ 120               ; params [0, NDEC) are matrices, they get weight decay
MD_LSIZE  equ 128               ; params per layer (matrices only)
MD_ACTL   equ 136               ; activation bytes per layer
MD_ROPE   equ 144               ; rope base (f64)
MD_NAIVE  equ 152               ; 1 = allocate the naive attention scratch
MD_FLOPS  equ 160               ; training flops per token at full context (f64)
MD_SIZE   equ 168

; per layer pointers, lp + l*LP_SIZE. layer L is the final norm (X, XN1, RS1, N1, GN1)
LP_WQKV   equ 0                 ; weights as the matmuls see them (bf16 copy, or f32 master)
LP_WO     equ 8
LP_W13    equ 16                ; gate and up stacked: rows [0, F) gate, [F, 2F) up
LP_W2     equ 24
LP_GQKV   equ 32                ; their gradients, f32
LP_GO     equ 40
LP_G13    equ 48
LP_G2     equ 56
LP_N1     equ 64                ; rmsnorm weights, f32 master
LP_N2     equ 72
LP_GN1    equ 80
LP_GN2    equ 88
LP_X      equ 96                ; activations saved for backward
LP_XN1    equ 104
LP_RS1    equ 112
LP_QKV    equ 120
LP_Y      equ 128
LP_LSE    equ 136
LP_X2     equ 144
LP_XN2    equ 152
LP_RS2    equ 160
LP_H      equ 168
LP_G      equ 176
LP_SIZE   equ 192

; one micro-batch, as model_fwd/bwd want it
MB_TOK    equ 0                 ; device u16 [B][T+1]
MB_POS    equ 8                 ; device u32 [B*T], row indices sorted by token (for the embedding backward)
MB_UTOK   equ 16                ; device u32, the distinct tokens in order
MB_UST    equ 24                ; device u32 [nu+1], where each one's rows start in POS
MB_NU     equ 32                ; distinct tokens
MB_B      equ 40
MB_T      equ 48
MB_SCALE  equ 56                ; f32, 1 / targets in the whole step (the loss is a mean)
MB_FLAGS  equ 60                ; 1 = chat: only MASKBIT tokens are targets
MB_SIZE   equ 64

; model_fwd modes
FW_LOGITS equ 0                 ; stop at the logits
FW_LOSS   equ 1                 ; loss only
FW_GRAD   equ 2                 ; loss and dlogits, ready for model_bwd

; mm flags (both matmul kernels)
MM_TA     equ 1                 ; A stored [K][M]
MM_TB     equ 2                 ; B stored [K][N]
MM_BF     equ 4                 ; C is bf16
MM_F32    equ 8                 ; A and B are f32 (mm_ref only)
MM_X8     equ 16                ; may run in mxfp8 (with fp8=1). the other kernels ignore it

; model_step's settings, f64
OP_LR     equ 0
OP_B1     equ 8
OP_B2     equ 16
OP_EPS    equ 24
OP_WD     equ 32
OP_CLIP   equ 40
OP_SIZE   equ 48
