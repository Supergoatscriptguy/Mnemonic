; the ptx sources, built right into the exe. gpu_module adds the header and hands
; them to the driver's jit
default rel
bits 64

section .rdata

%macro ptx 2
global %1, %1_end
%1:
    incbin %2
%1_end:
%endmacro

ptx ptx_basic, "gpu/basic.ptx"
ptx ptx_gemm, "gpu/gemm.ptx"
ptx ptx_bench, "gpu/bench.ptx"
ptx ptx_bench8, "gpu/bench8.ptx"
ptx ptx_benchmx, "gpu/benchmx.ptx"
ptx ptx_mx, "gpu/mx.ptx"
ptx ptx_ops, "model/ops.ptx"
ptx ptx_attn, "model/attn.ptx"
