; mathgen's files share this: the number macros, and everyone's routines. they all
; write at rdi like emit does, and the rest of the conventions are in mathgen.asm

; mathgen.asm
extern rnd, ndig, digits, emz, ask, askpre, askpre3, letr, mono, pmono, sterm, poly, lin
extern mulwork, divwork, addcols, factwork, quadwork, quadp, twobin, binom
extern letter, cf, fp, fe, nf, primes, nprimes, pow10, letters, empty
; arith.asm
extern mulstep, mulsmall, divstep, addstep, substep, subcols, euclid, simp, pfrac, gcd
extern sadd, coin, upto
extern add_one, sub_one, signed_one, gcd_one, frac_one, pow_one, root_one, pct_one
extern order_one, word_one
; algebra.asm
extern sys_one, expand_one, like_one, evalp_one, qeq_one
; decimal.asm
extern dec_one, stats_one, ratio_one, pdec, pdecs
; geometry.asm, algebra2.asm
extern geo_one
extern ineq_one, seq_one, line_one, fac2_one, abs_one, expeq_one

; the number in %1 at rdi
%macro num 1
    mov rdx, %1
    mov rcx, rdi
    call fmt_dec
    mov rdi, rax
%endmacro

; the same, signed
%macro sint 1
    mov rdx, %1
    mov rcx, rdi
    call fmt_int
    mov rdi, rax
%endmacro

; signed, in brackets if it's negative: 3 × (-5)
%macro pint 1
    mov rdx, %1
    test rdx, rdx
    jns %%pos
    mov byte [rdi], '('
    inc rdi
    mov rcx, rdi
    call fmt_int
    mov byte [rax], ')'
    lea rdi, [rax+1]
    jmp %%done
%%pos:
    mov rcx, rdi
    call fmt_dec
    mov rdi, rax
%%done:
%endmacro
