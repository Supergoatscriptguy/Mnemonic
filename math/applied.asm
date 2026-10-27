; mathgen's everyday math: converting units, money (discounts, tax, tips, change,
; prices, simple interest), percent change and going back from a percent, and
; probability with bags, dice, coins and cards. the questions here are templates
; with @ codes in them (see fill)
default rel
bits 64
%include "lib.inc"
%include "math/math.inc"

section .rdata
s_plus  db " + ", 0
s_minus db " - ", 0

; ---- units: plural, singular, short (0 when there isn't one)
%macro defu 3-4 0
u_%1 db %2, 0
u_%1_1 db %3, 0
%ifidn %4, 0
u_%1_a equ 0
%else
u_%1_a db %4, 0
%endif
%endmacro
defu km, "kilometers", "kilometer", "km"
defu m, "meters", "meter", "m"
defu cm, "centimeters", "centimeter", "cm"
defu mm, "millimeters", "millimeter", "mm"
defu kg, "kilograms", "kilogram", "kg"
defu g, "grams", "gram", "g"
defu mg, "milligrams", "milligram", "mg"
defu l, "liters", "liter", "L"
defu ml, "milliliters", "milliliter", "mL"
defu ft, "feet", "foot", "ft"
defu in, "inches", "inch"
defu yd, "yards", "yard", "yd"
defu mi, "miles", "mile", "mi"
defu lb, "pounds", "pound", "lb"
defu oz, "ounces", "ounce", "oz"
defu gal, "gallons", "gallon", "gal"
defu qt, "quarts", "quart", "qt"
defu pt, "pints", "pint", "pt"
defu cup, "cups", "cup"
defu h, "hours", "hour"
defu min, "minutes", "minute", "min"
defu s, "seconds", "second"
defu day, "days", "day"
defu wk, "weeks", "week"
defu yr, "years", "year"
defu mo, "months", "month"

; a big unit, a small one, how many smalls make a big (v, places), and 1 if it's only
; ever asked big to small
%macro cv 3-5 0, 0
    dq u_%1, u_%1_1, u_%1_a, u_%2, u_%2_1, u_%2_a, %3, %4, %5
%endmacro
align 8
convs:
    cv km, m, 1000
    cv m, cm, 100
    cv cm, mm, 10
    cv m, mm, 1000
    cv kg, g, 1000
    cv g, mg, 1000
    cv l, ml, 1000
    cv ft, in, 12
    cv yd, ft, 3
    cv yd, in, 36
    cv mi, ft, 5280, 0, 1
    cv lb, oz, 16
    cv gal, qt, 4
    cv qt, pt, 2
    cv pt, cup, 2
    cv gal, pt, 8
    cv h, min, 60
    cv min, s, 60
    cv h, s, 3600, 0, 1
    cv day, h, 24
    cv wk, day, 7
    cv yr, mo, 12
    cv day, min, 1440, 0, 1
    cv in, cm, 254, 2, 1
NCONV equ ($ - convs) / 72
udens dq 1, 1, 2, 4, 5, 10       ; small to big answers: something over one of these

uq0 db "How many @w are in @v @u?", 0
uq1 db "Convert @v @u to @w.", 0
uq2 db "@v @u is how many @w?", 0
uq3 db "What is @v @u in @w?", 0
uq4 db "How many @w is @v @u?", 0
uq5 db "Change @v @u into @w.", 0
align 8
qunit dq uq0, uq1, uq2, uq3, uq4, uq5
NQUNIT equ 6

section .bss
alignb 8
fa   resq 1                     ; what fill puts in for the @ codes
fb   resq 1
fc   resq 1
fpc  resq 1
fn   resq 1
fk   resq 1
ft   resq 1
fi   resq 1
fj   resq 1
fu   resq 1
fw   resq 1
fvv  resq 1
fvd  resq 1

section .rdata
fcode db "abcpnktijuwv"
align 8
fslot dq fa, fb, fc, fpc, fn, fk, ft, fi, fj, fu, fw, fvv

section .text

global units_one, askt, fi, fn, fk

; rcx = a template, copied to rdi with its @ codes filled in: @a @b @c money (fa fb fc,
; in cents), @p @n @k @t numbers (fpc fn fk ft), @i @j @u @w strings (fi fj fu fw),
; @v the decimal fvv / 10^fvd, @m fn signed
fill:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
.l:
    movzx eax, byte [rbx]
    inc rbx
    test eax, eax
    jz .r
    cmp eax, '@'
    je .at
    mov [rdi], al
    inc rdi
    jmp .l
.at:
    movzx eax, byte [rbx]
    inc rbx
    cmp eax, 'm'
    jne .code
    sint [fn]
    jmp .l
.code:
    lea rcx, [fcode]
    xor edx, edx
.f:
    cmp al, [rcx+rdx]
    je .got
    inc edx
    jmp .f
.got:
    lea rcx, [fslot]
    mov rcx, [rcx+rdx*8]
    mov rcx, [rcx]
    cmp edx, 3
    jb .money
    cmp edx, 7
    jb .num
    cmp edx, 11
    jb .str
    mov rcx, [fvv]
    mov rdx, [fvd]
    call pdec
    jmp .l
.money:
    call amt
    jmp .l
.num:
    num rcx
    jmp .l
.str:
    call emz
    jmp .l
.r:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = a table of qwords, edx = how many. rax = one of them
pick8:
    push rbx
    sub rsp, 32
    mov rbx, rcx
    lea rdx, [rdx-1]
    xor ecx, ecx
    call rnd
    mov rax, [rbx+rax*8]
    add rsp, 32
    pop rbx
    ret

; rcx = a table of templates, edx = how many: "user: " and one of them, filled in
askt:
    push rsi
    sub rsp, 48
    call pick8
    mov [rsp+32], rax
    emit "user: "
    mov rcx, [rsp+32]
    call fill
    emit 10
    add rsp, 48
    pop rsi
    ret

; rcx = cents: 68 or 21.08
amt:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    mov rax, rcx
    xor edx, edx
    mov ecx, 100
    div rcx
    test rdx, rdx
    jnz .c
    num rax
    jmp .r
.c:
    mov rcx, rbx
    mov edx, 2
    call pdec
.r:
    add rsp, 40
    pop rsi
    pop rbx
    ret

; rcx = v, rdx = d: pdec, and " = " the short way when that's different (150.0 = 150)
pdc:
    push rbx
    push r12
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    call pdec
    test r12, r12
    jz .r
    mov rax, rbx
    xor edx, edx
    mov ecx, 10
    div rcx
    test rdx, rdx
    jnz .r
    mov dword [rdi], ' = '
    add rdi, 3
    mov rcx, rbx
    mov rdx, r12
    call pdecs
.r:
    add rsp, 40
    pop r12
    pop rbx
    ret

; rcx = n: " place" or " places"
places:
    mov dword [rdi], ' pla'
    mov word [rdi+4], 'ce'
    add rdi, 6
    cmp rcx, 1
    je .r
    mov byte [rdi], 's'
    inc rdi
.r:
    ret

; rcx = a unit's names, rdx = 0 plural, 1 singular, 2 short
uname:
    mov rax, [rcx+rdx*8]
    mov rcx, rax
    jmp emz

; ---- units

; a conversion from convs, one way or the other, the value whole or with a point
units_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72
    xor ecx, ecx
    mov edx, NCONV - 1
    call rnd
    imul r12, rax, 72
    lea rax, [convs]
    add r12, rax                ; the conversion
    xor r13d, r13d              ; 0 big to small (times), 1 small to big
    cmp qword [r12+64], 0
    jne .dir
    call coin
    mov r13, rax
.dir:
    ; f a power of 10? then r14 = how many 0s
    xor r14d, r14d
    mov rax, [r12+48]
    cmp qword [r12+56], 0
    jne .vals
.p10:
    cmp rax, 1
    je .isp
    xor edx, edx
    mov ecx, 10
    div rcx
    test rdx, rdx
    jnz .notp
    inc r14
    jmp .p10
.notp:
    xor r14d, r14d
    jmp .vals
.isp:
.vals:
    test r13, r13
    jnz .small
    ; big to small: a whole number, or one with a point 2 times in 5
    mov qword [fvd], 0
    xor ecx, ecx
    mov edx, 4
    call rnd
    cmp eax, 2
    jb .dec
    mov ecx, 1
    mov edx, 100
    cmp qword [r12+48], 1000
    jb .w
    mov edx, 30
.w:
    call rnd
    mov [fvv], rax
    jmp .ask
.dec:
    call coin
    inc rax
    mov [fvd], rax              ; 1 or 2 places
.dfr:
    lea rdx, [pow10]
    mov rdx, [rdx+rax*8]
    dec rdx
    mov ecx, 1
    call rnd
    mov rbx, rax
    xor edx, edx
    mov ecx, 10
    div rcx
    test rdx, rdx
    jnz .dok
    mov rax, [fvd]
    jmp .dfr
.dok:
    xor ecx, ecx
    mov edx, 20
    cmp qword [r12+48], 1000
    jb .dw
    mov edx, 9
.dw:
    call rnd
    mov rcx, [fvd]
    lea rdx, [pow10]
    imul rax, [rdx+rcx*8]
    add rax, rbx
    mov [fvv], rax
    jmp .ask
.small:
    mov qword [fvd], 0
    test r14, r14
    jz .frac
    mov ecx, 4                  ; any whole number, the point moves
    call upto
    mov [fvv], rax
    jmp .ask
.frac:
    ; the answer a/den, den going into 100, and the question a × f / den whole
    xor ecx, ecx
    mov edx, 5
    call rnd
    lea rcx, [udens]
    mov rbx, [rcx+rax*8]
    mov r15d, 20                ; tries before den goes back to 1
.fa:
    mov ecx, 1
    mov edx, 60
    call rnd
    mov [rsp+32], rax
    dec r15
    jnz .ft
    mov ebx, 1
.ft:
    mov rcx, rax
    mov rdx, rbx
    call gcd
    cmp rax, 1
    jne .fa
    mov rax, [rsp+32]
    imul rax, [r12+48]
    xor edx, edx
    div rbx
    test rdx, rdx
    jnz .fa
    mov [fvv], rax
.ask:
    ; the names: short ones a quarter of the time, when both have them
    lea rax, [r12+24]
    lea rcx, [r12]
    test r13, r13
    jz .nm
    xchg rax, rcx
.nm:
    mov [rsp+40], rcx           ; from
    mov [rsp+48], rax           ; to
    mov rcx, [rcx+16]
    mov rax, [rax+16]
    mov [fu], rcx
    mov [fw], rax
    test rcx, rcx
    jz .long
    test rax, rax
    jz .long
    xor ecx, ecx
    mov edx, 3
    call rnd
    test eax, eax
    jz .named
.long:
    mov rcx, [rsp+40]
    call isone
    mov rcx, [rsp+40]
    mov rcx, [rcx+rax*8]
    mov [fu], rcx
    mov rax, [rsp+48]
    mov rax, [rax]
    mov [fw], rax
.named:
    lea rcx, [qunit]
    mov edx, NQUNIT
    call askt
    ; how many in one
    emit "assistant: "
    test r13, r13
    jnz .s1
    emit "1 "
    mov rcx, r12
    mov edx, 1
    call uname
    emit " = "
    call pfac
    emit " "
    lea rcx, [r12+24]
    xor edx, edx
    call uname
    emit ", so multiply by "
    call pfac
    emit ".", 10
    jmp .work
.s1:
    call pfac
    emit " "
    lea rcx, [r12+24]
    xor edx, edx
    call uname
    emit " = 1 "
    mov rcx, r12
    mov edx, 1
    call uname
    emit ", so divide by "
    call pfac
    emit ".", 10
.work:
    mov rbx, [fvv]
    mov r15, [fvd]
    test r13, r13
    jnz .wdiv
    test r14, r14
    jz .wm
    test r15, r15
    jnz .wmp
    num rbx                     ; 3 × 1000 = 3000
    emit " × "
    call pfac
    emit " = "
    mov rax, rbx
    imul rax, [r12+48]
    mov [rsp+56], rax
    mov qword [rsp+64], 0
    num rax
    emit 10
    jmp .fin
.wmp:
    emit "Multiplying by "
    call pfac
    emit " moves the point "
    num r14
    mov rcx, r14
    call places
    emit " to the right: "
    mov rcx, rbx
    mov rdx, r15
    call pdec
    emit " × "
    call pfac
    emit " = "
    mov rax, rbx
    imul rax, [r12+48]
    mov [rsp+56], rax
    mov [rsp+64], r15
    mov rcx, rax
    mov rdx, r15
    call pdecs
    emit ".", 10
    jmp .fin
.wm:
    mov rax, r15
    or rax, [r12+56]
    jnz .wmd
    mov rcx, rbx                ; whole times whole
    mov rdx, [r12+48]
    call mulstep
    mov [rsp+56], rax
    mov qword [rsp+64], 0
    jmp .fin
.wmd:
    emit "Multiply without the point"
    mov rax, r15
    test rax, rax
    jz .pt1
    cmp qword [r12+56], 0
    je .pt1
    emit "s"
.pt1:
    emit ": "
    num rbx
    emit " × "
    num [r12+48]
    emit ".", 10
    mov rcx, rbx
    mov rdx, [r12+48]
    call mulstep
    mov [rsp+56], rax
    mov rax, r15
    add rax, [r12+56]
    mov [rsp+64], rax
    test r15, r15
    jz .only
    cmp qword [r12+56], 0
    je .onlyv
    emit "The decimal places add up: "
    num r15
    emit " + "
    num [r12+56]
    emit " = "
    num [rsp+64]
    emit ", so put the point "
    jmp .put
.onlyv:
    mov rcx, rbx
    mov rdx, r15
    call pdec
    emit " has "
    num r15
    emit " decimal"
    mov rcx, r15
    call places
    emit ", so put the point back "
    jmp .put
.only:
    call pfac
    emit " has "
    num [r12+56]
    emit " decimal"
    mov rcx, [r12+56]
    call places
    emit ", so put the point "
.put:
    num [rsp+64]
    mov rcx, [rsp+64]
    call places
    emit " from the right: "
    mov rcx, [rsp+56]
    mov rdx, [rsp+64]
    call pdc
    emit ".", 10
    jmp .fin
.wdiv:
    mov qword [rsp+64], 0
    test r14, r14
    jz .wd
    emit "Dividing by "
    call pfac
    emit " moves the point "
    num r14
    mov rcx, r14
    call places
    emit " to the left: "
    num rbx
    emit " ÷ "
    call pfac
    emit " = "
    mov [rsp+56], rbx
    mov [rsp+64], r14
    mov rcx, rbx
    mov rdx, r14
    call pdecs
    emit ".", 10
    jmp .fin
.wd:
    mov rax, rbx
    xor edx, edx
    div qword [r12+48]
    test rdx, rdx
    jnz .wdd
    mov rcx, rbx
    mov rdx, [r12+48]
    call divstep
    mov [rsp+56], rax
    jmp .fin
.wdd:
    mov rcx, rbx
    xor edx, edx
    mov r8, [r12+48]
    call ddivw
    mov [rsp+56], rax
    mov [rsp+64], rdx
    num rbx
    emit " ÷ "
    num [r12+48]
    emit " = "
    mov rcx, [rsp+56]
    mov rdx, [rsp+64]
    call pdec
    emit 10
.fin:
    ; 2.5 hours = 150 minutes
    mov rcx, rbx
    mov rdx, r15
    call pdec
    emit " "
    mov [fvv], rbx
    mov [fvd], r15
    mov rcx, [rsp+40]
    call isone
    mov rcx, [rsp+40]
    mov rdx, rax
    call uname
    emit " = "
    mov rcx, [rsp+56]
    mov rdx, [rsp+64]
    call pdecs
    emit " "
    mov rcx, [rsp+56]
    mov rdx, [rsp+64]
    call canonv
    mov [fvv], rax
    mov [fvd], rdx
    mov rcx, [rsp+48]
    call isone
    mov rcx, [rsp+48]
    mov rdx, rax
    call uname
    emit 10
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; how many smalls in a big, from units_one's r12: 60 or 2.54
pfac:
    sub rsp, 40
    mov rcx, [r12+48]
    mov rdx, [r12+56]
    call pdec
    add rsp, 40
    ret

; rax = 1 (singular) if fvv / 10^fvd is exactly 1, else 0 (plural)
isone:
    xor eax, eax
    cmp qword [fvv], 1
    jne .r
    cmp qword [fvd], 0
    sete al
.r:
    ret

; rcx = v, rdx = d: without the trailing 0s. rax = v, rdx = d
canonv:
    mov rax, rcx
    mov r8, rdx
.l:
    test r8, r8
    jz .r
    mov r10, rax
    xor edx, edx
    mov r9d, 10
    div r9
    test rdx, rdx
    jnz .back
    dec r8
    jmp .l
.back:
    mov rax, r10
.r:
    mov rdx, r8
    ret

; ---- money

section .rdata
it0  db "shirt", 0
it1  db "jacket", 0
it2  db "book", 0
it3  db "lamp", 0
it4  db "backpack", 0
it5  db "video game", 0
it6  db "watch", 0
it7  db "bike", 0
it8  db "phone case", 0
it9  db "chair", 0
it10 db "toaster", 0
it11 db "pair of shoes", 0
it12 db "sandwich", 0
it13 db "hat", 0
it14 db "board game", 0
it15 db "drink", 0
align 8
items dq it0, it1, it2, it3, it4, it5, it6, it7, it8, it9, it10, it11, it12, it13, it14, it15
NITEM equ 16
cp0 db "notebooks", 0, "notebook", 0
cp1 db "pens", 0, "pen", 0
cp2 db "apples", 0, "apple", 0
cp3 db "tickets", 0, "ticket", 0
cp4 db "cupcakes", 0, "cupcake", 0
cp5 db "pencils", 0, "pencil", 0
cp6 db "stickers", 0, "sticker", 0
cp7 db "candles", 0, "candle", 0
cp8 db "cookies", 0, "cookie", 0
cp9 db "bottles of water", 0, "bottle of water", 0
align 8
counted dq cp0, cp0 + 10, cp1, cp1 + 5, cp2, cp2 + 7, cp3, cp3 + 8, cp4, cp4 + 9
        dq cp5, cp5 + 8, cp6, cp6 + 9, cp7, cp7 + 8, cp8, cp8 + 8, cp9, cp9 + 17
NCOUNTED equ 10
pdisc dq 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 60, 70, 75, 80
NPDISC equ 14
ptax  dq 4, 5, 6, 7, 8, 9, 10, 12, 13, 15, 20
NPTAX equ 11
ptip  dq 10, 12, 15, 18, 20, 22, 25
NPTIP equ 7
bills dq 500, 1000, 2000, 5000, 10000
irates dq 2, 3, 4, 5, 6, 8, 10, 12

md0 db "A @i costs $@a and is @p% off. What is the sale price?", 0
md1 db "What is @p% off $@a?", 0
md2 db "How much is a $@a @i after a @p% discount?", 0
md3 db "A $@a @i is on sale for @p% off. How much does it cost now?", 0
md4 db "$@a with a @p% discount is how much?", 0
md5 db "What's the price of a $@a @i after @p% off?", 0
ms0 db "A $@a @i is @p% off. How much do you save?", 0
ms1 db "How much is a @p% discount on $@a?", 0
ms2 db "A @i is $@a. How much money is @p% off?", 0
mt0 db "A @i costs $@a plus @p% sales tax. What is the total?", 0
mt1 db "What is $@a with @p% tax added?", 0
mt2 db "How much is $@a after @p% sales tax?", 0
mt3 db "The price is $@a and the sales tax is @p%. What do you pay in all?", 0
mx0 db "How much is @p% sales tax on $@a?", 0
mx1 db "What is the tax on a $@a @i if the tax rate is @p%?", 0
mp0 db "What is a @p% tip on a $@a bill?", 0
mp1 db "How much is a @p% tip on $@a?", 0
mp2 db "Work out a @p% tip on a $@a meal.", 0
mq0 db "A meal costs $@a. What is the total with a @p% tip?", 0
mq1 db "The bill is $@a and you leave a @p% tip. How much do you pay in all?", 0
mr0 db "After a @p% discount a @i costs $@a. What was the original price?", 0
mr1 db "A @i is $@a after @p% off. What did it cost before the sale?", 0
mr2 db "You paid $@a for a @i that was @p% off. What was the full price?", 0
mc0 db "You buy a @i for $@a and a @j for $@b and pay with $@c. How much change do you get?", 0
mc1 db "You spend $@a and $@b and hand over $@c. What is your change?", 0
mc2 db "A @i costs $@a. You pay with $@c. How much change do you get?", 0
mc3 db "You pay for a $@a @i with $@c. What is your change?", 0
mc4 db "Something costs $@a and you pay with $@c. How much change do you get?", 0
mc5 db "If you pay $@c for something that costs $@a, how much change do you get?", 0
mn0 db "@n @u cost $@a each. What is the total?", 0
mn1 db "How much do @n @u cost at $@a each?", 0
mn2 db "One @w costs $@a. How much are @n of them?", 0
mu0 db "A pack of @n @u costs $@a. How much is each one?", 0
mu1 db "@n @u cost $@a in all. What is the price of one?", 0
mi0 db "How much simple interest does $@a earn in @t years at @p% a year?", 0
mi1 db "What is the simple interest on $@a at @p% for @t years?", 0
mi2 db "You put $@a in a savings account that pays @p% simple interest a year. How much is in it after @t years?", 0
mi3 db "$@a is invested at @p% simple interest. What is it worth after @t years?", 0
align 8
qmd dq md0, md1, md2, md3, md4, md5
qms dq ms0, ms1, ms2
qmt dq mt0, mt1, mt2, mt3
qmx dq mx0, mx1
qmp dq mp0, mp1, mp2
qmq dq mq0, mq1
mtab dq qmd, 6, qms, 3, qmt, 4, qmx, 2, qmp, 3, qmq, 2
qmr dq mr0, mr1, mr2
qmc2 dq mc0, mc1
qmc1 dq mc2, mc3, mc4, mc5
qmn dq mn0, mn1, mn2
qmu dq mu0, mu1
qmi dq mi0, mi1
qmi2 dq mi2, mi3

section .text

global money_one

; rcx = cents: always with 2 places, 80.00
amt2:
    mov edx, 2
    jmp pdec

; rcx = a, rdx = b (cents), r8 = 0 for a + b, 1 for a - b (a >= b). in dollars when
; there are no cents, as whole numbers of cents when there are. rax = the result
mop:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    lea rax, [s_plus]
    test r8, r8
    jz .o
    lea rax, [s_minus]
.o:
    mov r13, rax
    mov rax, rbx
    xor edx, edx
    mov ecx, 100
    div rcx
    mov [rsp+32], rax
    mov r8, rdx
    mov rax, r12
    xor edx, edx
    div rcx
    or r8, rdx
    jnz .cents
    mov rcx, [rsp+32]
    mov rdx, rax
    call .step
    imul rax, rax, 100
    jmp .r
.cents:
    mov rcx, rbx
    call amt2
    mov rcx, r13
    call emz
    mov rcx, r12
    call amt2
    emit " is "
    num rbx
    mov rcx, r13
    call emz
    num r12
    emit " with the point put back 2 places from the right.", 10
    mov rcx, rbx
    mov rdx, r12
    call .step
    mov [rsp+32], rax
    emit "So "
    mov rcx, rbx
    call amt2
    mov rcx, r13
    call emz
    mov rcx, r12
    call amt2
    emit " = "
    mov rcx, [rsp+32]
    call amt2
    emit ".", 10
    mov rax, [rsp+32]
.r:
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret
.step:
    lea rax, [s_plus]
    cmp r13, rax
    je addstep
    jmp substep

; rcx = an amount (cents), rdx = p: p% of it, rounded to the cent. rax = cents
pctof:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov r12, rdx
    num r12
    emit "% of "
    mov rcx, rbx
    call amt
    emit " is "
    mov rcx, rbx
    call amt
    emit " × "
    num r12
    emit " ÷ 100.", 10
    mov rax, rbx
    xor edx, edx
    mov ecx, 100
    div rcx
    test rdx, rdx
    jnz .c
    mov rcx, rax                ; whole dollars: dollars × p is the cents
    mov rdx, r12
    call mulstep
    mov r13, rax
    num r13
    emit " ÷ 100 = "
    mov rcx, r13
    call amt
    emit 10
    mov rax, r13
    jmp .r
.c:
    emit "Without the point that's "
    num rbx
    emit " × "
    num r12
    emit ".", 10
    mov rcx, rbx
    mov rdx, r12
    call mulstep
    mov r13, rax                ; ten-thousandths of a dollar
    mov rcx, rbx
    call amt
    emit " has 2 decimal places and ÷ 100 moves the point 2 more, so it goes 4 places from the right: "
    mov rcx, r13
    mov edx, 4
    call pdec
    mov rax, r13
    xor edx, edx
    mov ecx, 100
    div rcx
    mov rbx, rax                ; whole cents
    test rdx, rdx
    jnz .round
    emit " = "
    mov rcx, rbx
    call amt
    emit ".", 10
    mov rax, rbx
    jmp .r
.round:
    mov rax, rdx
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r12, rax                ; the digit after the cents
    emit ".", 10
    emit "To the nearest cent: the next digit is "
    num r12
    cmp r12, 5
    jae .up
    emit ", so it rounds down to "
    jmp .pr
.up:
    emit ", so it rounds up to "
    inc rbx
.pr:
    mov rcx, rbx
    call amt2
    emit ".", 10
    mov rax, rbx
.r:
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rax = a price in cents: whole dollars 7 times in 10 (5 to 200, now and then up
; to 2000), otherwise with cents, often .99, .50 or a quarter
price:
    push rbx
    sub rsp, 32
    xor ecx, ecx
    mov edx, 9
    call rnd
    cmp eax, 7
    jae .cents
    mov ecx, 5
    mov edx, 200
    cmp eax, 6
    jne .w
    mov ecx, 200
    mov edx, 2000
.w:
    call rnd
    imul rax, rax, 100
    jmp .r
.cents:
    mov ecx, 1
    mov edx, 99
    call rnd
    imul rbx, rax, 100
    xor ecx, ecx
    mov edx, 3
    call rnd
    mov ecx, 99
    test eax, eax
    jz .add
    mov ecx, 50
    cmp eax, 1
    je .add
    cmp eax, 2
    jne .any
    mov ecx, 1
    mov edx, 3
    call rnd
    imul ecx, eax, 25
    jmp .add
.any:
    mov ecx, 1
    mov edx, 99
    call rnd
    mov ecx, eax
.add:
    lea rax, [rbx+rcx]
.r:
    add rsp, 32
    pop rbx
    ret

; rcx = lo, rdx = hi (dollars): rax = cents, whole dollars half the time
smallprice:
    push rbx
    sub rsp, 32
    call rnd
    imul rbx, rax, 100
    call coin
    test eax, eax
    jz .r
    mov ecx, 1
    mov edx, 99
    call rnd
    add rbx, rax
.r:
    mov rax, rbx
    add rsp, 32
    pop rbx
    ret

; fi and fj = two different things to buy
item:
    sub rsp, 40
    lea rcx, [items]
    mov edx, NITEM
    call pick8
    mov [fi], rax
.j:
    lea rcx, [items]
    mov edx, NITEM
    call pick8
    cmp rax, [fi]
    je .j
    mov [fj], rax
    add rsp, 40
    ret

; fu, fw = something counted, plural and one
counted1:
    sub rsp, 40
    xor ecx, ecx
    mov edx, NCOUNTED - 1
    call rnd
    lea rcx, [counted]
    shl rax, 4
    mov rdx, [rcx+rax]
    mov [fu], rdx
    mov rdx, [rcx+rax+8]
    mov [fw], rdx
    add rsp, 40
    ret

; "Answer: $X" for rcx = cents
answer:
    push rbx
    push rsi
    sub rsp, 40
    mov rbx, rcx
    emit "Answer: $"
    mov rcx, rbx
    call amt
    emit 10
    add rsp, 40
    pop rsi
    pop rbx
    ret

; discounts, sales tax, tips, the price before a discount, change, totals, the price
; of one, simple interest
money_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    xor ecx, ecx
    mov edx, 10
    call rnd
    mov r15, rax
    cmp r15, 6
    jb .pct
    je .rev
    cmp r15, 8
    jb .chg
    je .items
    cmp r15, 9
    je .unit
    jmp .int
.pct:
    call price
    mov [fa], rax
    lea rcx, [pdisc]
    mov edx, NPDISC
    cmp r15, 2
    jb .pp
    lea rcx, [ptax]
    mov edx, NPTAX
    cmp r15, 4
    jb .pp
    lea rcx, [ptip]
    mov edx, NPTIP
.pp:
    call pick8
    mov [fpc], rax
    call item
    lea rax, [mtab]
    mov rcx, r15
    shl rcx, 4
    mov rdx, [rax+rcx+8]
    mov rcx, [rax+rcx]
    call askt
    emit "assistant: "
    test r15, r15
    jz .off
    cmp r15, 2
    je .on
    cmp r15, 5
    je .on
    mov rcx, [fa]               ; just how much the percent is
    mov rdx, [fpc]
    call pctof
    mov rcx, rax
    call answer
    jmp .r
.off:
    emit "First find "
    num [fpc]
    emit "% of "
    mov rcx, [fa]
    call amt
    emit ", then take it off.", 10
    mov rcx, [fa]
    mov rdx, [fpc]
    call pctof
    mov rcx, [fa]
    mov rdx, rax
    mov r8d, 1
    call mop
    mov rcx, rax
    call answer
    jmp .r
.on:
    emit "First find "
    num [fpc]
    emit "% of "
    mov rcx, [fa]
    call amt
    emit ", then add it on.", 10
    mov rcx, [fa]
    mov rdx, [fpc]
    call pctof
    mov rcx, [fa]
    mov rdx, rax
    xor r8d, r8d
    call mop
    mov rcx, rax
    call answer
    jmp .r

.rev:
    lea rcx, [pdisc]
    mov edx, NPDISC
    call pick8
    mov [fpc], rax
    mov r12d, 100
    sub r12, rax                ; the percent you pay
    mov rcx, r12
    mov edx, 100
    call gcd
    mov rcx, rax
    mov rax, r12
    xor edx, edx
    div rcx
    mov r13, rax                ; top
    mov eax, 100
    xor edx, edx
    div rcx
    mov r14, rax                ; bottom
    mov eax, 600
    xor edx, edx
    div r14
    mov ecx, 2
    mov rdx, rax
    call rnd
    mov rbx, rax
    imul rbx, r14               ; the price before, in dollars
    imul rax, r13               ; what it costs now
    mov r12, rax
    imul rax, rax, 100
    mov [fa], rax
    call item
    lea rcx, [qmr]
    mov edx, 3
    call askt
    emit "assistant: After "
    num [fpc]
    emit "% off you pay the rest of the price: 100 - "
    num [fpc]
    emit " = "
    mov eax, 100
    sub rax, [fpc]
    mov [rsp+32], rax
    num rax
    emit ", so "
    num r12
    emit " is "
    num [rsp+32]
    emit "% of the price before.", 10
    num [rsp+32]
    emit "% means "
    num [rsp+32]
    emit "/100.", 10
    mov rcx, [rsp+32]
    mov edx, 100
    call simp
    emit "So "
    mov rcx, r13
    mov rdx, r14
    call pfrac
    emit " of the price is "
    num r12
    emit ", and the price is "
    num r12
    cmp r13, 1
    je .r1
    emit " ÷ "
    num r13
.r1:
    emit " × "
    num r14
    emit ".", 10
    mov rax, r12
    cmp r13, 1
    je .r2
    mov rcx, r12
    mov rdx, r13
    call divstep
.r2:
    mov rcx, rax
    mov rdx, r14
    call mulstep
    imul rcx, rax, 100
    call answer
    jmp .r

.chg:
    mov ecx, 1
    mov edx, 30
    call smallprice
    mov [fa], rax
    mov qword [fb], 0
    call item
    call coin
    mov r12, rax                ; 1 = two things
    test r12, r12
    jz .c1
    mov ecx, 1
    mov edx, 20
    call smallprice
    mov [fb], rax
.c1:
    mov rbx, [fa]
    add rbx, [fb]
    xor r13d, r13d              ; the smallest bill that covers it, sometimes the next one up
.bill:
    lea rax, [bills]
    cmp [rax+r13*8], rbx
    ja .bok
    inc r13
    jmp .bill
.bok:
    cmp r13, 4
    jae .bset
    xor ecx, ecx
    mov edx, 3
    call rnd
    test eax, eax
    jnz .bset
    inc r13
.bset:
    lea rax, [bills]
    mov rax, [rax+r13*8]
    mov [fc], rax
    lea rcx, [qmc1]
    mov edx, 4
    test r12, r12
    jz .cq
    lea rcx, [qmc2]
    mov edx, 2
.cq:
    call askt
    emit "assistant: "
    test r12, r12
    jnz .c2
    emit "Take "
    mov rcx, [fa]
    call amt
    emit " from "
    mov rcx, [fc]
    call amt
    emit ".", 10
    mov rcx, [fc]
    mov rdx, [fa]
    mov r8d, 1
    call mop
    mov rcx, rax
    call answer
    jmp .r
.c2:
    emit "First add up what you spend, then take it from "
    mov rcx, [fc]
    call amt
    emit ".", 10
    mov rcx, [fa]
    mov rdx, [fb]
    xor r8d, r8d
    call mop
    mov rcx, [fc]
    mov rdx, rax
    mov r8d, 1
    call mop
    mov rcx, rax
    call answer
    jmp .r

.items:
    mov ecx, 2
    mov edx, 12
    call rnd
    mov [fn], rax
    mov ecx, 1
    mov edx, 40
    call smallprice
    mov [fa], rax
    call counted1
    lea rcx, [qmn]
    mov edx, 3
    call askt
    emit "assistant: That's "
    mov rcx, [fa]
    call amt
    emit " × "
    num [fn]
    emit ".", 10
    mov rax, [fa]
    xor edx, edx
    mov ecx, 100
    div rcx
    test rdx, rdx
    jnz .icents
    mov rcx, rax
    mov rdx, [fn]
    call mulstep
    imul rcx, rax, 100
    call answer
    jmp .r
.icents:
    emit "Without the point that's "
    num [fa]
    emit " × "
    num [fn]
    emit ".", 10
    mov rcx, [fa]
    mov rdx, [fn]
    call mulstep
    mov rbx, rax
    emit "Put the point back 2 places from the right: "
    mov rcx, rbx
    call amt2
    emit ".", 10
    mov rcx, rbx
    call answer
    jmp .r

.unit:
    mov ecx, 2
    mov edx, 24
    call rnd
    mov [fn], rax
    mov ecx, 5
    mov edx, 400
    call rnd
    mov rbx, rax                ; one of them, in cents
    imul rax, [fn]
    mov [fa], rax
    call counted1
    lea rcx, [qmu]
    mov edx, 2
    call askt
    emit "assistant: Divide the total by "
    num [fn]
    emit ".", 10
    mov rax, [fa]               ; whole dollars that divide evenly: just a division
    xor edx, edx
    mov ecx, 100
    div rcx
    test rdx, rdx
    jnz .ud
    mov r12, rax
    xor edx, edx
    div qword [fn]
    test rdx, rdx
    jnz .ud
    mov rcx, r12
    mov rdx, [fn]
    call divstep
    jmp .uans
.ud:
    mov rcx, [fa]               ; the total as a decimal, as short as it goes
    mov edx, 2
    call canonv
    mov r12, rax
    mov r13, rdx
    mov rcx, rax
    mov r8, [fn]
    call ddivw
    mov [rsp+32], rax
    mov [rsp+40], rdx
    mov rcx, r12
    mov rdx, r13
    call pdec
    emit " ÷ "
    num [fn]
    emit " = "
    mov rcx, [rsp+32]
    mov rdx, [rsp+40]
    call pdec
    emit 10
.uans:
    mov rcx, rbx
    call answer
    jmp .r

.int:
    mov ecx, 2
    mov edx, 10
    call rnd
    mov [ft], rax
    xor ecx, ecx
    mov edx, 7
    call rnd
    lea rcx, [irates]
    mov rax, [rcx+rax*8]
    mov [fpc], rax
    mov rcx, rax                ; the amount a multiple of 100 / gcd, so a year's is whole
    mov edx, 100
    call gcd
    mov rcx, rax
    mov eax, 100
    xor edx, edx
    div rcx
    mov r12, rax
    mov eax, 5000
    xor edx, edx
    div r12
    mov ecx, 1
    mov rdx, rax
    call rnd
    imul rax, r12
    cmp rax, 50
    jb .int
    imul rax, rax, 100
    mov [fa], rax
    call coin
    mov r13, rax                ; 1 = the total, not just the interest
    lea rcx, [qmi]
    test r13, r13
    jz .iq
    lea rcx, [qmi2]
.iq:
    mov edx, 2
    call askt
    emit "assistant: Each year it earns "
    num [fpc]
    emit "% of "
    mov rcx, [fa]
    call amt
    emit ".", 10
    mov rcx, [fa]
    mov rdx, [fpc]
    call pctof
    mov rbx, rax
    emit "For "
    num [ft]
    emit " years:", 10
    mov rax, rbx
    xor edx, edx
    mov ecx, 100
    div rcx
    mov rcx, rax
    mov rdx, [ft]
    call mulstep
    imul rbx, rax, 100
    test r13, r13
    jz .ians
    emit "Add it to what was put in.", 10
    mov rcx, [fa]
    mov rdx, rbx
    xor r8d, r8d
    call mop
    mov rbx, rax
.ians:
    mov rcx, rbx
    call answer
.r:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; ---- percent change, and back from a percent

section .rdata
ci0 db "What is the percent increase from @n to @k?", 0
ci1 db "A price went from $@n to $@k. What is the percent increase?", 0
ci2 db "@n went up to @k. By what percent did it increase?", 0
ci3 db "A town grew from @n people to @k. What was the percent increase?", 0
ci4 db "By what percent is @k bigger than @n?", 0
cd0 db "What is the percent decrease from @n to @k?", 0
cd1 db "A price dropped from $@n to $@k. What is the percent decrease?", 0
cd2 db "@n went down to @k. By what percent did it decrease?", 0
cd3 db "A school had @n students and now has @k. What was the percent decrease?", 0
cd4 db "By what percent is @k smaller than @n?", 0
cc0 db "What is the percent change from @n to @k?", 0
cc1 db "Find the percent change when @n becomes @k.", 0
co0 db "@k is @p% of what number?", 0
co1 db "@p% of a number is @k. What is the number?", 0
co2 db "If @p% of x is @k, what is x?", 0
co3 db "@k is @p% of a number. Find the number.", 0
co4 db "@k is @p% of what?", 0
cu0 db "After a @p% increase a price is $@k. What was it before?", 0
cu1 db "A number goes up by @p% to @k. What was the number?", 0
cu2 db "After growing by @p%, a town has @k people. How many did it have before?", 0
cw0 db "After a @p% decrease a price is $@k. What was it before?", 0
cw1 db "A number goes down by @p% to @k. What was the number?", 0
cw2 db "A car lost @p% of its value and is now worth $@k. What was it worth before?", 0
align 8
qcinc dq ci0, ci1, ci2, ci3, ci4, cc0, cc1
qcdec dq cd0, cd1, cd2, cd3, cd4, cc0, cc1
qcof  dq co0, co1, co2, co3, co4
qcup  dq cu0, cu1, cu2
qcdn  dq cw0, cw1, cw2

section .text

global change_one

; the percent something went up or down by, p% of what is m, and what it was before
; it went up or down by p%
change_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    xor ecx, ecx
    mov edx, 3
    call rnd
    mov r15, rax                ; 0 up, 1 down, 2 p% of what, 3 back from a change
    cmp r15, 2
    je .of
    ja .back
    ; the change is a whole percent: the start a multiple of p/100's bottom
.pc:
    mov ecx, 1
    mov edx, 90
    test r15, r15
    jnz .pc2
    mov edx, 150
.pc2:
    call rnd
    mov r12, rax                ; p
    cmp rax, 100
    je .pc
    mov rcx, rax
    mov edx, 100
    call gcd
    mov rcx, rax
    mov eax, 100
    xor edx, edx
    div rcx
    mov r13, rax                ; the bottom
    mov eax, 2000
    xor edx, edx
    div r13
    mov ecx, 1
    mov rdx, rax
    call rnd
    imul rax, r13
    mov rbx, rax                ; from
    imul rax, r12
    xor edx, edx
    mov ecx, 100
    div rcx
    mov r14, rax                ; the change
    mov [fn], rbx
    mov rax, rbx
    add rax, r14
    test r15, r15
    jz .to
    mov rax, rbx
    sub rax, r14
.to:
    mov [fk], rax
    lea rcx, [qcinc]
    test r15, r15
    jz .cq
    lea rcx, [qcdec]
.cq:
    mov edx, 7
    call askt
    emit "assistant: First the change:", 10
    mov rcx, [fk]
    mov rdx, [fn]
    test r15, r15
    jz .sub
    xchg rcx, rdx
.sub:
    call substep
    emit "As a fraction of where it started that's "
    num r14
    emit "/"
    num rbx
    emit ", and a percent is out of 100.", 10
    mov rcx, r14
    mov rdx, rbx
    call simp
    mov [rsp+32], rax
    mov [rsp+40], rdx
    emit "100 ÷ "
    num [rsp+40]
    emit " = "
    mov eax, 100
    xor edx, edx
    div qword [rsp+40]
    num rax
    emit 10
    mov rcx, [rsp+32]
    mov rdx, [rsp+40]
    mov r8d, 100
    call scale
    mov rbx, rax
    emit "The percent "
    test r15, r15
    jnz .dn
    emit "increase is "
    jmp .pct
.dn:
    emit "decrease is "
.pct:
    num rbx
    emit "%.", 10
    jmp .r

.of:
    call pctfrac                ; r12 = p, r13/r14 = p/100 in lowest terms
    mov eax, 2000               ; the number a multiple of the bottom
    xor edx, edx
    div r14
    mov ecx, 1
    mov rdx, rax
    call rnd
    mov rbx, rax
    imul rbx, r14               ; the number
    imul rax, r13
    mov [fk], rax               ; p% of it
    mov [fpc], r12
    lea rcx, [qcof]
    mov edx, 5
    call askt
    emit "assistant: "
    num r12
    emit "% means "
    num r12
    emit "/100.", 10
    mov rcx, r12
    mov edx, 100
    call simp
    emit "So "
    mov rcx, r13
    mov rdx, r14
    call pfrac
    emit " of the number is "
    num [fk]
    emit ", and the number is "
    call back
    emit "The number is "
    num rax
    emit ".", 10
    jmp .r

.back:
    call coin
    mov r15, rax                ; 0 it went up, 1 down
.bp:
    mov ecx, 5
    mov edx, 60
    call rnd
    mov r12, rax
    mov rcx, 100
    add rcx, rax
    test r15, r15
    jz .bpc
    mov rcx, 100
    sub rcx, rax
.bpc:
    mov [rsp+32], rcx           ; the percent it is now
    mov edx, 100
    call gcd
    mov rcx, rax
    mov rax, [rsp+32]
    xor edx, edx
    div rcx
    mov r13, rax
    cmp r13, 99                 ; the top has to be small enough to divide by
    ja .bp
    mov eax, 100
    xor edx, edx
    div rcx
    mov r14, rax
    mov eax, 1000
    xor edx, edx
    div r14
    mov ecx, 2
    mov rdx, rax
    call rnd
    mov rbx, rax
    imul rbx, r14               ; before
    imul rax, r13
    mov [fk], rax               ; after
    mov [fpc], r12
    lea rcx, [qcup]
    test r15, r15
    jz .bq
    lea rcx, [qcdn]
.bq:
    mov edx, 3
    call askt
    emit "assistant: Now it's 100 "
    test r15, r15
    jnz .bm
    emit "+ "
    jmp .bn
.bm:
    emit "- "
.bn:
    num r12
    emit " = "
    num [rsp+32]
    emit " percent of what it was before.", 10
    num [rsp+32]
    emit "% means "
    num [rsp+32]
    emit "/100.", 10
    mov rcx, [rsp+32]
    mov edx, 100
    call simp
    emit "So "
    mov rcx, r13
    mov rdx, r14
    call pfrac
    emit " of what it was is "
    num [fk]
    emit ", and what it was is "
    call back
    emit "Before, it was "
    num rax
    emit ".", 10
.r:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; r12 = a percent from 1 to 99, r13/r14 = it over 100 in lowest terms
pctfrac:
    sub rsp, 40
    mov ecx, 1
    mov edx, 99
    call rnd
    mov r12, rax
    mov rcx, rax
    mov edx, 100
    call gcd
    mov rcx, rax
    mov rax, r12
    xor edx, edx
    div rcx
    mov r13, rax
    mov eax, 100
    xor edx, edx
    div rcx
    mov r14, rax
    add rsp, 40
    ret

; "m ÷ t × b." and the working, for m = fk and t/b = r13/r14. rax = the answer
back:
    push rsi
    sub rsp, 32
    num [fk]
    cmp r13, 1
    je .t1
    emit " ÷ "
    num r13
.t1:
    emit " × "
    num r14
    emit ".", 10
    mov rax, [fk]
    cmp r13, 1
    je .m
    mov rcx, rax
    mov rdx, r13
    call divstep
.m:
    mov rcx, rax
    mov rdx, r14
    call mulstep
    add rsp, 32
    pop rsi
    ret

; ---- probability

section .rdata
col0 db "red", 0
col1 db "blue", 0
col2 db "green", 0
col3 db "yellow", 0
col4 db "white", 0
col5 db "black", 0
col6 db "purple", 0
col7 db "pink", 0
align 8
cols dq col0, col1, col2, col3, col4, col5, col6, col7
ob0 db "marbles", 0
ob1 db "balls", 0
ob2 db "socks", 0
ob3 db "candies", 0
ob4 db "beads", 0
ob5 db "cubes", 0
align 8
objs dq ob0, ob1, ob2, ob3, ob4, ob5
NOBJ equ 6

pb0 db "A bag has @i @u. What is the probability of picking a @j one?", 0
pb1 db "A bag holds @i @u. If you pick one at random, what's the chance it's @j?", 0
pb2 db "There are @i @u in a box. One is picked at random. What is the probability it is @j?", 0
pn0 db "A bag has @i @u. What is the probability that one picked at random is not @j?", 0
pn1 db "A box holds @i @u. If you pick one, what's the chance it isn't @j?", 0
po0 db "A bag has @i @u. What is the probability of picking a @j or a @w one?", 0
po1 db "There are @i @u in a jar. If one is taken at random, what's the chance it is @j or @w?", 0
pd0 db "If you roll @i, what is the probability of getting @j?", 0
pd1 db "You roll @i. What's the chance of rolling @j?", 0
pd2 db "What is the probability of rolling @j on @i?", 0
pd3 db "Roll @i once. What is the probability of @j?", 0
ps0 db "Two dice are rolled. What is the probability that the sum is @n?", 0
ps1 db "If you roll two dice, what's the chance they add up to @n?", 0
ps2 db "What is the probability of getting a total of @n with two dice?", 0
pv0 db "What is the probability of rolling doubles with two dice?", 0
pv1 db "Two dice are rolled. What's the chance both show the same number?", 0
pa0 db "A coin is flipped @n times. What is the probability of getting all @u?", 0
pa1 db "If you flip @n coins, what's the chance they all land on @u?", 0
pa2 db "What is the probability of getting @u @n times in a row?", 0
pe0 db "You flip a coin @n times. What is the probability of getting exactly @k heads?", 0
pe1 db "@n coins are tossed. What's the chance of exactly @k heads?", 0
pl0 db "What is the probability of getting at least one @w in @n coin flips?", 0
pl1 db "A coin is tossed @n times. What's the chance of at least one @w?", 0
pw0 db "A bag has @i @u. You take one out, don't put it back, and take another. What is the probability that both are @j?", 0
pw1 db "A bag has @i @u. Two are picked without replacement. What's the chance both are @j?", 0
pr0 db "A bag has @i @u. You pick one, put it back, then pick again. What is the probability that both are @j?", 0
pr1 db "A bag has @i @u. Two are drawn with replacement. What's the probability both are @j?", 0
px0 db "A bag has @i @u. You pick two without putting the first back. What is the probability that the first is @j and the second is @w?", 0
py0 db "A bag has @i @u. You pick one and put it back, then pick another. What's the chance the first is @j and the second is @w?", 0
pc0 db "What is the probability of drawing @j from a standard deck of 52 cards?", 0
pc1 db "You draw one card from a shuffled 52-card deck. What's the chance it's @j?", 0
pc2 db "A card is picked at random from a deck of 52. What is the probability that it is @j?", 0
pc3 db "What's the probability of drawing @j from a 52 card deck?", 0
px1 db "A coin is flipped @n times. About how many heads would you expect?", 0
px2 db "If you toss a coin @n times, about how many times should it land on tails?", 0
px3 db "A die is rolled @n times. About how many times would you expect to roll a @k?", 0
px4 db "A bag has @i @u. You pick one and put it back, @n times. About how many times would you expect a @j one?", 0
align 8
qpb dq pb0, pb1, pb2
qpn dq pn0, pn1
qpo dq po0, po1
qpd dq pd0, pd1, pd2, pd3
qps dq ps0, ps1, ps2
qpv dq pv0, pv1
qpa dq pa0, pa1, pa2
qpe dq pe0, pe1
qpl dq pl0, pl1
qpw dq pw0, pw1
qpr dq pr0, pr1
qpab dq px0
qpab2 dq py0
qpx dq px1, px2
qpx3t dq px3
qpx4t dq px4

s_heads db "heads", 0
s_tails db "tails", 0
s_head  db "head", 0
s_tail  db "tail", 0
s_die   db "a die", 0

; cards: what's drawn, how many there are, and why
kc0  db "a heart", 0
kc1  db "a diamond", 0
kc2  db "a club", 0
kc3  db "a spade", 0
kc4  db "a king", 0
kc5  db "a queen", 0
kc6  db "a jack", 0
kc7  db "an ace", 0
kc8  db "a red card", 0
kc9  db "a black card", 0
kc10 db "a face card", 0
kc11 db "the queen of spades", 0
kc12 db "the ace of hearts", 0
kc13 db "the 7 of clubs", 0
kc14 db "a red king", 0
kc15 db "a black ace", 0
kf0  db "13 of them are hearts.", 0
kf1  db "13 of them are diamonds.", 0
kf2  db "13 of them are clubs.", 0
kf3  db "13 of them are spades.", 0
kf4  db "Each suit has one king, so there are 4.", 0
kf5  db "Each suit has one queen, so there are 4.", 0
kf6  db "Each suit has one jack, so there are 4.", 0
kf7  db "Each suit has one ace, so there are 4.", 0
kf8  db "Hearts and diamonds are red: 13 + 13 = 26.", 0
kf9  db "Clubs and spades are black: 13 + 13 = 26.", 0
kf10 db "Each suit has 3 face cards (jack, queen, king): 3 × 4 = 12.", 0
kf11 db "There's only one queen of spades.", 0
kf12 db "There's only one ace of hearts.", 0
kf13 db "There's only one 7 of clubs.", 0
kf14 db "The red kings are the king of hearts and the king of diamonds: 2.", 0
kf15 db "The black aces are the ace of clubs and the ace of spades: 2.", 0
align 8
cards dq kc0, kf0, 13,  kc1, kf1, 13,  kc2, kf2, 13,  kc3, kf3, 13
      dq kc4, kf4, 4,  kc5, kf5, 4,  kc6, kf6, 4,  kc7, kf7, 4
      dq kc8, kf8, 26,  kc9, kf9, 26,  kc10, kf10, 12
      dq kc11, kf11, 1,  kc12, kf12, 1,  kc13, kf13, 1,  kc14, kf14, 2,  kc15, kf15, 2
NCARD equ 16
qpc dq pc0, pc1, pc2, pc3

section .bss
alignb 8
bc    resq 4                    ; a bag: how many of each color
bk    resq 4                    ;  and the colors
nbk   resq 1
lbuf  resb 256                  ; what's in it, written out
ebuf  resb 64
dbuf  resb 64

section .text

global prob_one

; ecx = colors, edx = the most of one, r8 = the least: a bag in bc / bk, written out
; in lbuf ("3 red, 5 blue and 2 green"), fi -> lbuf and fu = what's in it
bag:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov [nbk], rcx
    mov r12, rdx
    mov r13, r8
    xor ebx, ebx
.c:
    cmp rbx, [nbk]
    jae .cd
.pk:
    xor ecx, ecx
    mov edx, 7
    call rnd
    lea rcx, [cols]
    mov rax, [rcx+rax*8]
    xor ecx, ecx
.dup:
    cmp rcx, rbx
    jae .new
    lea rdx, [bk]
    cmp [rdx+rcx*8], rax
    je .pk
    inc rcx
    jmp .dup
.new:
    lea rdx, [bk]
    mov [rdx+rbx*8], rax
    mov rcx, r13
    mov rdx, r12
    call rnd
    lea rdx, [bc]
    mov [rdx+rbx*8], rax
    inc rbx
    jmp .c
.cd:
    lea rdi, [lbuf]
    xor ebx, ebx
.w:
    lea rax, [bc]
    num [rax+rbx*8]
    mov byte [rdi], ' '
    inc rdi
    lea rax, [bk]
    mov rcx, [rax+rbx*8]
    call emz
    inc rbx
    mov rax, [nbk]
    cmp rbx, rax
    jae .wd
    dec rax
    cmp rbx, rax
    je .and
    emit ", "
    jmp .w
.and:
    emit " and "
    jmp .w
.wd:
    mov byte [rdi], 0
    lea rax, [lbuf]
    mov [fi], rax
    xor ecx, ecx
    mov edx, NOBJ - 1
    call rnd
    lea rcx, [objs]
    mov rax, [rcx+rax*8]
    mov [fu], rax
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; "There are 3 + 5 + 2 = 10 marbles in all." rax = the total
bagsum:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    emit "There are "
    xor ebx, ebx
    xor r12d, r12d
.l:
    test rbx, rbx
    jz .f
    emit " + "
.f:
    lea rax, [bc]
    mov rax, [rax+rbx*8]
    add r12, rax
    num rax
    inc rbx
    cmp rbx, [nbk]
    jb .l
    emit " = "
    num r12
    emit " "
    mov rcx, [fu]
    call emz
    emit " in all.", 10
    mov rax, r12
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = c, rdx = n: "So the probability is c/n.", in lowest terms, and the answer
pfin:
    push rbx
    push rsi
    push r12
    sub rsp, 32
    mov rbx, rcx
    mov r12, rdx
    emit "So the probability is "
    num rbx
    emit "/"
    num r12
    emit ".", 10
    cmp rbx, 1
    je .one
    mov rcx, rbx
    mov rdx, r12
    call simp
    mov rbx, rax
    mov r12, rdx
.one:
    emit "The probability is "
    mov rcx, rbx
    mov rdx, r12
    call pfrac
    emit ".", 10
    add rsp, 32
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = a/b, rdx = c/d as (a << 32 | b), the same: "a/b × c/d = (a × c)/(b × d) = x/y."
; rax = x, rdx = y
fmul:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    mov rbx, rcx
    shr rbx, 32
    mov r12d, ecx
    mov r13, rdx
    shr r13, 32
    mov r14d, edx
    num rbx
    emit "/"
    num r12
    emit " × "
    num r13
    emit "/"
    num r14
    emit " = ("
    num rbx
    emit " × "
    num r13
    emit ")/("
    num r12
    emit " × "
    num r14
    emit ") = "
    imul rbx, r13
    imul r12, r14
    num rbx
    emit "/"
    num r12
    emit ".", 10
    mov rax, rbx
    mov rdx, r12
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; bags, dice, two dice, coins, two picks from a bag, cards, and how many to expect
prob_one:
    push rbx
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    xor ecx, ecx
    mov edx, 19
    call rnd
    cmp eax, 4
    jb .bag
    cmp eax, 9
    jb .die
    cmp eax, 11
    jb .dice
    cmp eax, 14
    jb .coins
    cmp eax, 17
    jb .two
    cmp eax, 19
    jb .cards
    jmp .expect

.bag:
    mov ecx, 2
    mov edx, 4
    call rnd
    mov rcx, rax
    mov edx, 12
    mov r8d, 1
    call bag
    xor ecx, ecx
    mov rdx, [nbk]
    dec rdx
    call rnd
    mov r12, rax                ; the color asked about
    lea rcx, [bk]
    mov rax, [rcx+r12*8]
    mov [fj], rax
    xor ecx, ecx
    mov edx, 2
    cmp qword [nbk], 3
    jae .be
    mov edx, 1
.be:
    call rnd
    mov r13, rax                ; 0 it, 1 not it, 2 it or another
    lea rcx, [qpb]
    mov edx, 3
    test r13, r13
    jz .bq
    lea rcx, [qpn]
    mov edx, 2
    cmp r13, 1
    je .bq
    mov r14, r12                ; the other one
.bo:
    inc r14
    cmp r14, [nbk]
    jb .bo2
    xor r14d, r14d
.bo2:
    lea rax, [bk]
    mov rax, [rax+r14*8]
    mov [fw], rax
    lea rcx, [qpo]
    mov edx, 2
.bq:
    call askt
    emit "assistant: "
    call bagsum
    mov r15, rax
    lea rax, [bc]
    mov rbx, [rax+r12*8]
    test r13, r13
    jnz .b1
    num rbx
    emit " of them are "
    mov rcx, [fj]
    call emz
    emit ".", 10
    jmp .bfin
.b1:
    cmp r13, 1
    jne .b2
    mov rbx, r15
    lea rax, [bc]
    sub rbx, [rax+r12*8]
    cmp qword [nbk], 2
    jne .bn
    emit "The "                 ; just one other color
    num rbx
    emit " "
    xor eax, eax
    cmp r12, 0
    jne .bn1
    inc eax
.bn1:
    lea rcx, [bk]
    mov rcx, [rcx+rax*8]
    call emz
    emit " ones aren't "
    mov rcx, [fj]
    call emz
    emit ".", 10
    jmp .bfin
.bn:
    emit "The ones that aren't "
    mov rcx, [fj]
    call emz
    emit ": "
    xor r14d, r14d
    xor r13d, r13d              ; said one yet
.bl:
    cmp r14, [nbk]
    jae .ble
    cmp r14, r12
    je .bln
    test r13, r13
    jz .bl1
    emit " + "
.bl1:
    mov r13d, 1
    lea rax, [bc]
    num [rax+r14*8]
.bln:
    inc r14
    jmp .bl
.ble:
    emit " = "
    num rbx
    emit ".", 10
    jmp .bfin
.b2:
    emit "The ones that are "
    mov rcx, [fj]
    call emz
    emit " or "
    mov rcx, [fw]
    call emz
    emit ": "
    num rbx
    emit " + "
    lea rax, [bc]
    num [rax+r14*8]
    emit " = "
    lea rax, [bc]
    add rbx, [rax+r14*8]
    num rbx
    emit ".", 10
.bfin:
    mov rcx, rbx
    mov rdx, r15
    call pfin
    jmp .r

.die:
    mov r12d, 6                 ; sides
    xor ecx, ecx
    mov edx, 9
    call rnd
    cmp eax, 5
    jb .dn
    sub eax, 5
    lea rcx, [dsides]
    mov r12, [rcx+rax*8]
.dn:
    mov [fn], r12
    xor ecx, ecx
    mov edx, 8
    cmp r12, 12
    jbe .de
    mov edx, 6
.de:
    call rnd
    mov r13, rax                ; the event
    cmp r13, 8                  ; multiples need 6 sides at least
    jne .die1
    cmp r12, 6
    jae .die1
    mov r13d, 1
.die1:
    mov [rsp+40], rdi
    cmp r12, 6
    jne .dsd
    call coin
    lea rcx, [s_die]
    test eax, eax
    jz .dsset
.dsd:
    lea rdi, [dbuf]
    emit "a "
    num r12
    emit "-sided die", 0
    lea rcx, [dbuf]
.dsset:
    mov [fi], rcx
    ; the event, and how many sides it is
    lea rdi, [ebuf]
    cmp r13, 1
    jb .e0
    je .e1
    cmp r13, 3
    jb .e2
    je .e3
    cmp r13, 5
    jb .e4
    je .e5
    cmp r13, 7
    jb .e6
    je .e7
    ; a multiple of k, k from 3 up to half the sides
    mov rdx, r12
    shr rdx, 1
    mov ecx, 3
    cmp rdx, 5
    jbe .mk
    mov edx, 5
.mk:
    call rnd
    mov r14, rax
    emit "a multiple of "
    num r14
    mov rax, r12
    xor edx, edx
    div r14
    mov rbx, rax
    jmp .ed
.e0:
    mov ecx, 1
    mov rdx, r12
    call rnd
    mov r14, rax
    call article
    num r14
    mov ebx, 1
    jmp .ed
.e1:
    emit "an even number"
    jmp .half
.e2:
    emit "an odd number"
.half:
    mov rbx, r12
    shr rbx, 1
    jmp .ed
.e3:
    mov ecx, 1
    lea rdx, [r12-1]
    call rnd
    mov r14, rax
    emit "a number greater than "
    num r14
    mov rbx, r12
    sub rbx, r14
    jmp .ed
.e4:
    mov ecx, 2
    mov rdx, r12
    call rnd
    mov r14, rax
    emit "a number less than "
    num r14
    lea rbx, [r14-1]
    jmp .ed
.e5:
    mov ecx, 2
    mov rdx, r12
    call rnd
    mov r14, rax
    call article
    num r14
    emit " or higher"
    mov rbx, r12
    sub rbx, r14
    inc rbx
    jmp .ed
.e6:
    mov ecx, 1
    lea rdx, [r12-1]
    call rnd
    mov r14, rax
    call article
    num r14
    emit " or lower"
    mov rbx, r14
    jmp .ed
.e7:
    emit "a prime number"
    xor ebx, ebx
.pc:
    lea rax, [primes]
    mov rax, [rax+rbx*8]
    cmp rax, r12
    ja .ed
    inc rbx
    jmp .pc
.ed:
    mov byte [rdi], 0
    mov rdi, [rsp+40]
    lea rax, [ebuf]
    mov [fj], rax
    lea rcx, [qpd]
    mov edx, 4
    call askt
    emit "assistant: The die has "
    num r12
    emit " sides, all equally likely.", 10
    cmp r13, 1
    jb .w0
    cmp r13, 3
    jb .w1
    je .w3
    cmp r13, 5
    jb .w4
    je .w5
    cmp r13, 7
    jb .w6
    je .w7
    emit "The multiples of "
    num r14
    emit " up to "
    num r12
    emit " are "
    mov rcx, r14
    mov rdx, r14
    call steps
    emit ". That's "
    num rbx
    emit ".", 10
    jmp .dfin
.w0:
    emit "Only one side is "
    lea rcx, [ebuf]
    call emz
    emit ".", 10
    jmp .dfin
.w1:
    emit "Half of them are "
    lea rcx, [s_even]
    cmp r13, 1
    je .wh
    lea rcx, [s_odd]
.wh:
    call emz
    emit ": "
    num r12
    emit " ÷ 2 = "
    num rbx
    emit ".", 10
    jmp .dfin
.w3:
    cmp rbx, 1
    jne .w3m
    emit "Only "
    num r12
    emit " is greater than "
    num r14
    emit ".", 10
    jmp .dfin
.w3m:
    emit "Greater than "
    num r14
    emit " means "
    lea rax, [r14+1]
    num rax
    emit " to "
    num r12
    emit ": "
    num r12
    emit " - "
    num r14
    emit " = "
    num rbx
    emit ".", 10
    jmp .dfin
.w4:
    cmp rbx, 1
    jne .w4m
    emit "Only 1 is less than 2.", 10
    jmp .dfin
.w4m:
    emit "Less than "
    num r14
    emit " means 1 to "
    num rbx
    emit ": "
    num r14
    emit " - 1 = "
    num rbx
    emit ".", 10
    jmp .dfin
.w5:
    cmp rbx, 1
    jne .w5m
    emit "Only "
    num r12
    emit " is "
    num r14
    emit " or higher.", 10
    jmp .dfin
.w5m:
    num r14
    emit " or higher means "
    num r14
    emit " to "
    num r12
    emit ": "
    num r12
    emit " - "
    num r14
    emit " + 1 = "
    num rbx
    emit ".", 10
    jmp .dfin
.w6:
    cmp rbx, 1
    jne .w6m
    emit "Only 1 is 1 or lower.", 10
    jmp .dfin
.w6m:
    num r14
    emit " or lower means 1 to "
    num r14
    emit ", which is "
    num rbx
    emit " of them.", 10
    jmp .dfin
.w7:
    emit "The primes up to "
    num r12
    emit " are "
    xor r14d, r14d
.wp:
    test r14, r14
    jz .wp1
    emit ", "
.wp1:
    lea rax, [primes]
    num [rax+r14*8]
    inc r14
    cmp r14, rbx
    jb .wp
    emit ". That's "
    num rbx
    emit ".", 10
.dfin:
    mov rcx, rbx
    mov rdx, r12
    call pfin
    jmp .r

.dice:
    xor ecx, ecx
    mov edx, 4
    call rnd
    mov r13, rax                ; 0 = doubles
    test r13, r13
    jz .dq
    mov ecx, 2
    mov edx, 12
    call rnd
    mov r12, rax
    mov [fn], rax
    lea rcx, [qps]
    mov edx, 3
    jmp .dq2
.dq:
    lea rcx, [qpv]
    mov edx, 2
.dq2:
    call askt
    emit "assistant: Two dice have 6 × 6 = 36 outcomes, all equally likely.", 10
    test r13, r13
    jnz .ds
    emit "The doubles: (1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6). That's 6.", 10
    mov ebx, 6
    jmp .dfin2
.ds:
    emit "The ones that add up to "
    num r12
    emit ": "
    xor ebx, ebx
    mov r14d, 1
.dp:
    cmp r14, 6
    ja .dpe
    mov rax, r12
    sub rax, r14
    cmp rax, 1
    jl .dpn
    cmp rax, 6
    jg .dpn
    test rbx, rbx
    jz .dp1
    emit ", "
.dp1:
    inc rbx
    emit "("
    num r14
    emit ", "
    mov rax, r12
    sub rax, r14
    num rax
    emit ")"
.dpn:
    inc r14
    jmp .dp
.dpe:
    emit ". That's "
    num rbx
    emit ".", 10
.dfin2:
    mov rcx, rbx
    mov edx, 36
    call pfin
    jmp .r

.coins:
    mov ecx, 2
    mov edx, 4
    call rnd
    mov r12, rax
    mov [fn], rax
    mov r15d, 1
    mov rcx, r12
    shl r15, cl                 ; outcomes
    xor ecx, ecx
    mov edx, 2
    call rnd
    mov r13, rax                ; 0 all the same, 1 exactly k heads, 2 at least one
    call coin
    mov r14, rax                ; 0 heads, 1 tails
    lea rax, [s_heads]
    lea rcx, [s_head]
    test r14, r14
    jz .ch
    lea rax, [s_tails]
    lea rcx, [s_tail]
.ch:
    mov [fu], rax
    mov [fw], rcx
    lea rcx, [qpa]
    mov edx, 3
    test r13, r13
    jz .cq
    lea rcx, [qpl]
    mov edx, 2
    cmp r13, 2
    je .cq
    mov ecx, 1
    lea rdx, [r12-1]
    call rnd
    mov [fk], rax
    lea rcx, [qpe]
    mov edx, 2
.cq:
    call askt
    emit "assistant: There are 2"
    mov rbx, r12
.c2:
    dec rbx
    jz .c3
    emit " × 2"
    jmp .c2
.c3:
    emit " = "
    num r15
    emit " outcomes, all equally likely"
    cmp r13, 1
    je .cx
    ja .cl
    emit ", and only "
    mov rcx, r14
    call hts
    emit " is all "
    mov rcx, [fu]
    call emz
    emit ".", 10
    mov ecx, 1
    mov rdx, r15
    call pfin
    jmp .r
.cl:
    emit ", and only "
    mov rcx, r14
    xor rcx, 1
    call hts
    emit " has no "
    mov rcx, [fu]
    call emz
    emit ".", 10
    emit "That leaves "
    num r15
    emit " - 1 = "
    lea rax, [r15-1]
    num rax
    emit " with at least one "
    mov rcx, [fw]
    call emz
    emit ".", 10
    lea rcx, [r15-1]
    mov rdx, r15
    call pfin
    jmp .r
.cx:
    emit ":", 10
    xor ebx, ebx
.co:
    test rbx, rbx
    jz .co1
    emit ", "
.co1:
    mov rcx, rbx
    call outcome
    inc rbx
    cmp rbx, r15
    jb .co
    emit ".", 10
    emit "With exactly "
    num [fk]
    emit " heads: "
    xor ebx, ebx
    xor r13d, r13d              ; how many
.ck:
    mov rax, rbx                ; the tails are the 1 bits
    popcnt rax, rax
    mov rcx, r12
    sub rcx, rax
    cmp rcx, [fk]
    jne .ckn
    test r13, r13
    jz .ck1
    emit ", "
.ck1:
    inc r13
    mov rcx, rbx
    call outcome
.ckn:
    inc rbx
    cmp rbx, r15
    jb .ck
    emit ". That's "
    num r13
    emit ".", 10
    mov rcx, r13
    mov rdx, r15
    call pfin
    jmp .r

.two:
    mov ecx, 2
    mov edx, 8
    mov r8d, 2
    call bag
    mov rax, [bc]
    add rax, [bc+8]
    cmp rax, 12
    ja .two
    mov r15, rax                ; all of them
    call coin
    mov r12, rax                ; the color asked about first
    lea rcx, [bk]
    mov rax, [rcx+r12*8]
    mov [fj], rax
    mov rax, r12
    xor rax, 1
    mov rax, [rcx+rax*8]
    mov [fw], rax
    xor ecx, ecx
    mov edx, 3
    call rnd
    mov r13, rax                ; bit 0: put back, bit 1: then the other color
    lea rcx, [qpw]
    mov edx, 2
    cmp r13, 1
    jb .tq
    lea rcx, [qpr]
    je .tq
    lea rcx, [qpab]
    mov edx, 1
    cmp r13, 2
    je .tq
    lea rcx, [qpab2]
.tq:
    call askt
    emit "assistant: "
    call bagsum
    lea rax, [bc]
    mov rbx, [rax+r12*8]        ; the first color's
    mov rax, r12
    xor rax, 1
    lea rcx, [bc]
    mov r14, [rcx+rax*8]        ; the other's
    test r13, 1
    jnz .back
    emit "The first is "
    mov rcx, [fj]
    call emz
    emit " with chance "
    num rbx
    emit "/"
    num r15
    emit ". That leaves "
    test r13, 2
    jnz .tab
    lea rax, [rbx-1]
    num rax
    emit " "
    mov rcx, [fj]
    call emz
    emit " out of "
    lea rax, [r15-1]
    num rax
    emit ", so the second is "
    mov rcx, [fj]
    call emz
    emit " with chance "
    lea rax, [rbx-1]
    num rax
    emit "/"
    lea rax, [r15-1]
    num rax
    emit ".", 10
    lea rdx, [rbx-1]
    jmp .tm
.tab:
    lea rax, [r15-1]
    num rax
    emit ", with all "
    num r14
    emit " "
    mov rcx, [fw]
    call emz
    emit " still in, so the second is "
    mov rcx, [fw]
    call emz
    emit " with chance "
    num r14
    emit "/"
    lea rax, [r15-1]
    num rax
    emit ".", 10
    mov rdx, r14
.tm:
    shl rdx, 32                 ; the second pick out of one fewer
    lea rax, [r15-1]
    or rdx, rax
    jmp .tmul
.back:
    emit "It goes back each time, so "
    test r13, 2
    jnz .bab
    emit "each pick is "
    mov rcx, [fj]
    call emz
    emit " with chance "
    num rbx
    emit "/"
    num r15
    emit ".", 10
    mov rdx, rbx
    jmp .bm
.bab:
    emit "the first is "
    mov rcx, [fj]
    call emz
    emit " with chance "
    num rbx
    emit "/"
    num r15
    emit " and the second is "
    mov rcx, [fw]
    call emz
    emit " with chance "
    num r14
    emit "/"
    num r15
    emit ".", 10
    mov rdx, r14
.bm:
    shl rdx, 32
    or rdx, r15
.tmul:
    mov [rsp+32], rdx
    emit "Both: "
    mov rcx, rbx
    shl rcx, 32
    or rcx, r15
    mov rdx, [rsp+32]
    call fmul
    mov rcx, rax
    call pfin
    jmp .r

.cards:
    xor ecx, ecx
    mov edx, NCARD - 1
    call rnd
    imul rbx, rax, 24
    lea rax, [cards]
    add rbx, rax
    mov rax, [rbx]
    mov [fj], rax
    lea rcx, [qpc]
    mov edx, 4
    call askt
    emit "assistant: A deck has 52 cards, 13 in each of 4 suits: hearts, diamonds, clubs and spades.", 10
    mov rcx, [rbx+8]
    call emz
    emit 10
    mov rcx, [rbx+16]
    mov edx, 52
    call pfin
    jmp .r

.expect:
    xor ecx, ecx
    mov edx, 2
    call rnd
    test eax, eax
    jz .xc
    cmp eax, 1
    je .xd
    mov ecx, 2                  ; a bag, with putting it back
    mov edx, 9
    mov r8d, 1
    call bag
    mov rax, [bk]
    mov [fj], rax
    mov r15, [bc]
    add r15, [bc+8]
    mov ecx, 2
    mov edx, 30
    call rnd
    imul rax, r15
    mov [fn], rax
    lea rcx, [qpx4t]
    mov edx, 1
    call askt
    emit "assistant: "
    call bagsum
    emit "So "
    mov rcx, [fj]
    call emz
    emit " comes up "
    num [bc]
    emit " times in "
    num r15
    emit ": "
    num [fn]
    emit " ÷ "
    num r15
    emit " × "
    num [bc]
    emit ".", 10
    mov rcx, [fn]
    mov rdx, r15
    call divstep
    mov rcx, rax
    mov rdx, [bc]
    call mulstep
    mov rbx, rax
    jmp .xa
.xc:
    mov ecx, 5
    mov edx, 500
    call rnd
    add rax, rax
    mov [fn], rax
    call coin
    mov r12, rax
    lea rcx, [qpx]
    lea rcx, [rcx+r12*8]
    mov edx, 1
    call askt
    emit "assistant: It lands on "
    lea rcx, [s_heads]
    test r12, r12
    jz .xh
    lea rcx, [s_tails]
.xh:
    call emz
    emit " half the time, so divide by 2.", 10
    mov rcx, [fn]
    mov edx, 2
    call divstep
    mov rbx, rax
    jmp .xa
.xd:
    mov ecx, 1
    mov edx, 6
    call rnd
    mov [fk], rax
    mov ecx, 2
    mov edx, 100
    call rnd
    imul rax, rax, 6
    mov [fn], rax
    lea rcx, [qpx3t]
    mov edx, 1
    call askt
    emit "assistant: A "
    num [fk]
    emit " comes up 1 time in 6, so divide by 6.", 10
    mov rcx, [fn]
    mov edx, 6
    call divstep
    mov rbx, rax
.xa:
    emit "About "
    num rbx
    emit ".", 10
.r:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; "a " or "an " for r14 (an 8, an 11, an 18)
article:
    cmp r14, 8
    je .an
    cmp r14, 11
    je .an
    cmp r14, 18
    je .an
    mov word [rdi], 'a '
    add rdi, 2
    ret
.an:
    mov word [rdi], 'an'
    mov byte [rdi+2], ' '
    add rdi, 3
    ret

; rcx = from, rdx = step: from, from + step, ... up to r12, joined by ", "
steps:
    push rbx
    push rsi
    push r12
    push r13
    sub rsp, 40
    mov rbx, rcx
    mov r13, rdx
.l:
    num rbx
    add rbx, r13
    cmp rbx, r12
    ja .r
    emit ", "
    jmp .l
.r:
    add rsp, 40
    pop r13
    pop r12
    pop rsi
    pop rbx
    ret

; rcx = all heads (0) or all tails (1), for coins' r12 flips: HHH or TTT
hts:
    mov al, 'H'
    test rcx, rcx
    jz .h
    mov al, 'T'
.h:
    mov rcx, r12
.l:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .l
    ret

; rcx = an outcome of r12 flips as bits, the first flip on top, 1 = tails
outcome:
    mov r8, r12
.l:
    dec r8
    bt rcx, r8
    mov al, 'H'
    jnc .h
    mov al, 'T'
.h:
    mov [rdi], al
    inc rdi
    test r8, r8
    jnz .l
    ret

section .rdata
align 8
dsides dq 4, 8, 10, 12, 20
s_even db "even", 0
s_odd  db "odd", 0
