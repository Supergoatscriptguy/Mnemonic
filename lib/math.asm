; scalar exp/log/cos/sin on the old x87 unit. it has these built in, which saves
; writing polynomials. slow-ish (~100 cycles) but they're for per-step stuff like
; the lr schedule. the hot paths get proper vector versions later.
; x87 stack has to be empty at every call boundary, so each one pops everything.
; args/results in xmm0, the home slot at [rsp+8] is the bounce buffer
default rel
bits 64

section .text

global math_log
math_log:
    movsd [rsp+8], xmm0
    fldln2
    fld qword [rsp+8]
    fyl2x                       ; ln2 * log2(x)
    fstp qword [rsp+8]
    movsd xmm0, [rsp+8]
    ret

global math_exp
math_exp:
    movsd [rsp+8], xmm0
    fldl2e
    fmul qword [rsp+8]          ; t = x * log2(e), e^x = 2^t
    fld st0
    frndint                     ; n = round(t)
    fsub st1, st0               ; st1 = t - n, within +-0.5
    fxch st1
    f2xm1                       ; 2^f - 1, only valid for |f| <= 1
    fld1
    faddp st1, st0
    fscale                      ; * 2^n
    fstp st1
    fstp qword [rsp+8]
    movsd xmm0, [rsp+8]
    ret

global math_cos
math_cos:
    movsd [rsp+8], xmm0
    fld qword [rsp+8]
    fcos
    fstp qword [rsp+8]
    movsd xmm0, [rsp+8]
    ret

global math_sin
math_sin:
    movsd [rsp+8], xmm0
    fld qword [rsp+8]
    fsin
    fstp qword [rsp+8]
    movsd xmm0, [rsp+8]
    ret
