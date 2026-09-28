; stage 1 test: number formatting and parsing
default rel
bits 64
%include "lib.inc"
%include "test/check.inc"

; run a fmt_* into tbuf and compare
%macro tint 3+                  ; fn, value, expected
    lea rcx, [tbuf]
    mov rdx, %2
    call %1
    expect %3
%endmacro

%macro tw 4+                    ; fn, value, width/digits, expected
    lea rcx, [tbuf]
    mov rdx, %2
    mov r8d, %3
    call %1
    expect %4
%endmacro

%macro tflt 4+                  ; fn, value, decimals, expected
    section .rdata
    align 8
    %%v dq %2
    section .text
    lea rcx, [tbuf]
    movsd xmm1, [%%v]
    mov r8d, %3
    call %1
    expect %4
%endmacro

; parse_float has to land on exactly the same double as nasm's own parser
%macro tparse 2
    section .rdata
    align 8
    %%e dq %2
    %%s db %1, 0
    section .text
    lea rcx, [%%s]
    call parse_float
    movq rax, xmm0
    cmp rax, [%%e]
    check e, "parse_float ", %1
%endmacro

section .rdata
s_int   db "-123xyz", 0

section .text
global start
start:
    sub rsp, 40
    call lib_init

    say "integers", 13, 10
    tint fmt_dec, 0, "0"
    tint fmt_dec, 1234567890, "1234567890"
    tint fmt_dec, 18446744073709551615, "18446744073709551615"
    tw   fmt_dec0, 42, 5, "00042"
    tw   fmt_dec0, 123456, 3, "123456"
    tint fmt_int, -42, "-42"
    tint fmt_int, -9223372036854775808, "-9223372036854775808"
    tw   fmt_hex, 0xdeadbeef, 8, "deadbeef"
    tw   fmt_hex, 0xab, 4, "00ab"

    say "fixed", 13, 10
    tflt fmt_fixed, 3.14159, 2, "3.14"
    tflt fmt_fixed, 3.4127, 4, "3.4127"
    tflt fmt_fixed, -0.5, 1, "-0.5"
    tflt fmt_fixed, 0.0, 3, "0.000"
    tflt fmt_fixed, 0.05, 3, "0.050"
    tflt fmt_fixed, 99.99, 1, "100.0"
    tflt fmt_fixed, 123456789.0, 0, "123456789"
    tflt fmt_fixed, 1e20, 2, "1.00e+20"
    tflt fmt_fixed, 0x7ff8000000000000, 2, "nan"
    tflt fmt_fixed, 0xfff0000000000000, 2, "-inf"

    say "scientific", 13, 10
    tflt fmt_sci, 3e-4, 2, "3.00e-04"
    tflt fmt_sci, 12345.678, 3, "1.235e+04"
    tflt fmt_sci, 9.999, 2, "1.00e+01"
    tflt fmt_sci, 0.0, 2, "0.00e+00"
    tflt fmt_sci, -2.5e-10, 1, "-2.5e-10"
    tflt fmt_sci, 1e300, 2, "1.00e+300"
    tflt fmt_sci, 1.0, 0, "1e+00"
    tflt fmt_sci, 0x7ff0000000000000, 2, "inf"

    say "counts and times", 13, 10
    tint fmt_count, 999, "999"
    tint fmt_count, 1234, "1.23K"
    tint fmt_count, 45678, "45.7K"
    tint fmt_count, 1000000, "1.00M"
    tint fmt_count, 1234567890, "1.23B"
    tint fmt_count, 5000000000000, "5.00T"
    tint fmt_hms, 0, "00:00:00"
    tint fmt_hms, 3725, "01:02:05"
    tint fmt_hms, 360000, "100:00:00"

    say "parsing", 13, 10
    lea rcx, [s_int]
    call parse_int
    mov rbx, rdx                ; check calls trash rdx
    cmp rax, -123
    check e, "parse_int -123"
    cmp byte [rbx], 'x'
    check e, "parse_int stops at the first non-digit"
    tparse "3e-4", 3e-4
    tparse "0.1", 0.1
    tparse "2.5E-5", 2.5e-5
    tparse "-1.5", -1.5
    tparse "1e10", 1e10
    tparse "6.02e23", 6.02e23
    tparse "123.456", 123.456
    tparse "5", 5.0
    tparse "1.0e+2", 100.0

    jmp t_done
