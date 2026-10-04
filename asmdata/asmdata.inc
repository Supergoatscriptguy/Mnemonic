; the NASM lesson tools: verify.asm (answers, tests, building and running a
; candidate) and json.asm. %include after lib.inc

extern js_ws, js_skip, js_get, js_at, js_str, js_put
extern vf_init, vf_new, vf_run, vf_tests, vf_inc, vf_verify, vf_note, vf_stage
extern trim, strip_cr, sections, code_of, code_check, has_global, int_of, parse_test
extern istarts, ieq, hasword

; vf_verify's answer
ST_OK       equ 0
ST_ASM      equ 1
ST_INTERNAL equ 2
ST_LINK     equ 3
ST_TESTS    equ 4
ST_ABI      equ 5
ST_CRASH    equ 6
ST_TIMEOUT  equ 7

; sections: 6 x (ptr, len), 0 when it's missing
SEC_TASK    equ 0
SEC_SIG     equ 16
SEC_CODE    equ 32
SEC_EXPL    equ 48
SEC_TESTS   equ 64
SEC_WRONG   equ 80
SEC_SIZE    equ 96

; a context, one per thread
VC_DIR      equ 0               ; the work directory, full path
VC_PATH     equ 512             ; scratch: a file in it
VC_CMD      equ 1024            ; scratch: a command line
VC_ERR      equ 3072            ; what vf_tests didn't like, zero terminated
VC_NT       equ 3584            ; tests parsed
VC_BUSED    equ 3592            ; bytes used in VC_BYTES
VC_OLEN     equ 3600            ; output of the last run
VC_NLEN     equ 3608            ; and of vf_note
VC_OUT      equ 3616            ; -> 64K
VC_TESTS    equ 3624            ; -> MAXTESTS records
VC_BYTES    equ 3632            ; -> the tests' buffers
VC_FILE     equ 3640            ; -> tests.inc while it's written
VC_NOTE     equ 3648            ; -> 64K
VC_SIZE     equ 4096

; a test: name(args) -> result ; argN = expected
TS_FN       equ 0
TS_FNLEN    equ 8
TS_NARG     equ 16
TS_HASRET   equ 24
TS_RET      equ 32
TS_NCHK     equ 40
TS_ARG      equ 48              ; 4 x (kind 0 int / 1 buffer, value or ptr, len)
TS_CHK      equ 144             ; MAXCHK x (arg index, ptr, len)
TS_SIZE     equ 336
MAXTESTS    equ 64
MAXCHK      equ 8
