;; mnemonic in the browser: the tokenizer and the chat engine, in webassembly.
;; same math and the same model files as chat\engine.asm.
;;
;; every worker instantiates this module on one shared memory. one of them drives
;; (eng_step, samp_pick, ...), the rest sit in $helper and take chunks of the big
;; loops, like par_for in lib\thread.asm. globals belong to one instance, so all
;; the state lives in memory at the addresses below
(module
  (import "env" "mem" (memory 1 65536 shared))
  (type $job (func (param i32 i32)))
  (table 4 funcref)
  (elem (i32.const 0) func $mvf32 $mvq8 $mvq4 $att)   ;; indexed by the quant type, then attention

  ;; the thread pool. the hammered words get their own cache lines
  (global $GEN i32 (i32.const 64))      ;; bumped for every job, helpers wait on it
  (global $NEXT i32 (i32.const 128))    ;; next item to hand out
  (global $LEFT i32 (i32.const 192))    ;; helpers still busy with this job
  (global $READY i32 (i32.const 320))   ;; helpers that have started
  (global $FN i32 (i32.const 256))
  (global $N i32 (i32.const 260))
  (global $CHUNK i32 (i32.const 264))
  (global $NHELP i32 (i32.const 268))   ;; helpers taking part

  ;; the engine
  (global $L i32 (i32.const 512))
  (global $D i32 (i32.const 516))
  (global $H i32 (i32.const 520))
  (global $KVH i32 (i32.const 524))
  (global $HD i32 (i32.const 528))
  (global $F i32 (i32.const 532))
  (global $V i32 (i32.const 536))
  (global $T i32 (i32.const 540))
  (global $QD i32 (i32.const 544))
  (global $KVD i32 (i32.const 548))
  (global $QKV i32 (i32.const 552))
  (global $QT i32 (i32.const 556))
  (global $POS i32 (i32.const 560))     ;; tokens in the kv cache
  (global $NORMS i32 (i32.const 564))
  (global $LAYERS i32 (i32.const 568))  ;; 4 matrices per layer, 32 bytes each
  (global $KC i32 (i32.const 572))      ;; kv cache, f32 [layer][pos][kvd]
  (global $VC i32 (i32.const 576))
  (global $ROPE i32 (i32.const 580))    ;; (cos, sin) [pos][hd/2]
  (global $X i32 (i32.const 584))
  (global $XN i32 (i32.const 588))
  (global $QKVB i32 (i32.const 592))
  (global $Y i32 (i32.const 596))
  (global $HB i32 (i32.const 600))
  (global $G i32 (i32.const 604))
  (global $LOGITS i32 (i32.const 608))
  (global $PROBS i32 (i32.const 612))
  (global $TMP i32 (i32.const 616))
  (global $ATT i32 (i32.const 620))
  (global $XQ i32 (i32.const 624))      ;; the vector quantized to int8, kept as int16
  (global $XS i32 (i32.const 628))      ;; its group scales
  (global $SCALE i32 (i32.const 632))   ;; f32 1/sqrt(hd)
  (global $CL i32 (i32.const 636))      ;; layer and position the helpers work on
  (global $CT i32 (i32.const 640))
  (global $HEAP i32 (i32.const 644))
  (global $MHASH i32 (i32.const 648))   ;; i64, the tokenizer the model was made with
  (global $E i32 (i32.const 656))       ;; the embedding matrix
  (global $MV i32 (i32.const 688))      ;; the matrix-vector product in flight
  (global $MVX i32 (i32.const 692))
  (global $MVY i32 (i32.const 696))
  (global $ASTR i32 (i32.const 700))    ;; attention score row stride, floats

  ;; the tokenizer
  (global $NMERGES i32 (i32.const 768))
  (global $MERGES i32 (i32.const 772))
  (global $RKEYS i32 (i32.const 776))   ;; pair -> merge rank, open addressing
  (global $RVALS i32 (i32.const 780))
  (global $TOFF i32 (i32.const 784))    ;; token i is tblob[toff[i] .. toff[i+1])
  (global $TBLOB i32 (i32.const 788))
  (global $WORK i32 (i32.const 792))
  (global $THASH i32 (i32.const 800))   ;; i64

  (global $TOPV i32 (i32.const 1024))   ;; the sampler's 64 best
  (global $TOPI i32 (i32.const 1280))

  ;; a matrix: 0 weights, 4 scales, 8 rows, 12 cols, 16 quant type (0 f32, 1 int8, 2 int4)

  (data $names "<|bos|>\00<|user|>\00<|assistant|>\00<|system|>\00<|end|>\00<|reserved|>\00")

  ;; bump allocator, 64 byte aligned, zeroed (nothing is ever freed)
  (func $alloc (export "alloc") (param $n i32) (result i32)
    (local $p i32) (local $end i32) (local $pages i32)
    (if (i32.eqz (i32.load (global.get $HEAP)))
      (then (i32.store (global.get $HEAP) (i32.const 4096))))
    (local.set $p (i32.and (i32.add (i32.load (global.get $HEAP)) (i32.const 63)) (i32.const -64)))
    (local.set $end (i32.add (local.get $p) (local.get $n)))
    (local.set $pages (i32.shr_u (i32.add (local.get $end) (i32.const 65535)) (i32.const 16)))
    (if (i32.gt_u (local.get $pages) (memory.size))
      (then
        (if (i32.eq (memory.grow (i32.sub (local.get $pages) (memory.size))) (i32.const -1))
          (then (unreachable)))))
    (i32.store (global.get $HEAP) (local.get $end))
    (local.get $p))

  ;; ---- threads

  (func $work
    (local $i i32) (local $e i32) (local $n i32) (local $c i32) (local $fn i32)
    (local.set $n (i32.load (global.get $N)))
    (local.set $c (i32.load (global.get $CHUNK)))
    (local.set $fn (i32.load (global.get $FN)))
    (block $out
      (loop $l
        (local.set $i (i32.atomic.rmw.add (global.get $NEXT) (local.get $c)))
        (br_if $out (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $e (i32.add (local.get $i) (local.get $c)))
        (if (i32.gt_u (local.get $e) (local.get $n)) (then (local.set $e (local.get $n))))
        (call_indirect (type $job) (local.get $i) (local.get $e) (local.get $fn))
        (br $l))))

  ;; runs job fn over items [0, n), chunk at a time, here and on the helpers
  (func $par (param $fn i32) (param $n i32) (param $chunk i32)
    (local $l i32) (local $spin i32)
    (if (i32.or (i32.eqz (i32.load (global.get $NHELP)))
                (i32.le_u (local.get $n) (local.get $chunk)))
      (then
        (call_indirect (type $job) (i32.const 0) (local.get $n) (local.get $fn))
        (return)))
    (i32.store (global.get $FN) (local.get $fn))
    (i32.store (global.get $N) (local.get $n))
    (i32.store (global.get $CHUNK) (local.get $chunk))
    (i32.atomic.store (global.get $NEXT) (i32.const 0))
    (i32.atomic.store (global.get $LEFT) (i32.load (global.get $NHELP)))
    (drop (i32.atomic.rmw.add (global.get $GEN) (i32.const 1)))
    (drop (memory.atomic.notify (global.get $GEN) (i32.const -1)))
    (call $work)
    ;; spin a while, the helpers are usually about done, then sleep
    (block $done
      (loop $w
        (local.set $l (i32.atomic.load (global.get $LEFT)))
        (br_if $done (i32.eqz (local.get $l)))
        (local.set $spin (i32.add (local.get $spin) (i32.const 1)))
        (if (i32.gt_u (local.get $spin) (i32.const 100000))
          (then (drop (memory.atomic.wait32 (global.get $LEFT) (local.get $l) (i64.const -1)))))
        (br $w))))

  ;; a helper worker calls this and never comes back. it reads GEN before it
  ;; counts itself ready, so it can't miss a job (jobs only start once the driver
  ;; has set NHELP from READY). its slot is where it came in, not the page's id,
  ;; so the NHELP helpers that take part are always ones that have started
  (func (export "helper") (param $id i32)
    (local $seen i32) (local $g i32) (local $spin i32) (local $slot i32)
    (local.set $seen (i32.atomic.load (global.get $GEN)))
    (local.set $slot (i32.atomic.rmw.add (global.get $READY) (i32.const 1)))
    (loop $forever
      (local.set $g (i32.atomic.load (global.get $GEN)))
      (if (i32.eq (local.get $g) (local.get $seen))
        (then
          (local.set $spin (i32.add (local.get $spin) (i32.const 1)))
          (if (i32.gt_u (local.get $spin) (i32.const 100000))
            (then (drop (memory.atomic.wait32 (global.get $GEN) (local.get $seen) (i64.const -1)))))
          (br $forever)))
      (local.set $seen (local.get $g))
      (if (i32.lt_u (local.get $slot) (i32.load (global.get $NHELP)))
        (then
          (local.set $spin (i32.const 0))
          (call $work)
          (if (i32.eq (i32.atomic.rmw.sub (global.get $LEFT) (i32.const 1)) (i32.const 1))
            (then (drop (memory.atomic.notify (global.get $LEFT) (i32.const 1))))))
        (else (local.set $spin (i32.const 100000))))   ;; not needed, straight back to sleep
      (br $forever)))

  ;; n = threads in all, this one included. only between jobs. returns what it got
  (func (export "set_threads") (param $n i32) (result i32)
    (local $h i32)
    (local.set $h (i32.sub (local.get $n) (i32.const 1)))
    (if (i32.lt_s (local.get $h) (i32.const 0)) (then (local.set $h (i32.const 0))))
    (if (i32.gt_u (local.get $h) (i32.atomic.load (global.get $READY)))
      (then (local.set $h (i32.atomic.load (global.get $READY)))))
    (i32.store (global.get $NHELP) (local.get $h))
    (i32.add (local.get $h) (i32.const 1)))

  (func (export "helpers_ready") (result i32)
    (i32.atomic.load (global.get $READY)))

  ;; ---- math. wasm has no exp/log/sin/cos instructions

  ;; e^x = 2^k e^r, taylor for e^r on |r| < 0.35
  (func $exp64 (param $x f64) (result f64)
    (local $k f64) (local $r f64) (local $p f64)
    (local.set $k (f64.nearest (f64.mul (local.get $x) (f64.const 1.4426950408889634))))
    (local.set $r (f64.sub (f64.sub (local.get $x) (f64.mul (local.get $k) (f64.const 6.93147180369123816490e-01)))
                           (f64.mul (local.get $k) (f64.const 1.90821492927058770002e-10))))
    (local.set $p (f64.const 1.6059043836821613e-10))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 2.08767569878681e-09)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 2.505210838544172e-08)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 2.755731922398589e-07)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 2.7557319223985893e-06)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 2.48015873015873e-05)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 1.984126984126984e-04)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 1.388888888888889e-03)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 8.333333333333333e-03)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 4.1666666666666664e-02)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 1.6666666666666666e-01)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 0.5)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 1)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $r)) (f64.const 1)))
    (f64.mul (local.get $p)
      (f64.reinterpret_i64 (i64.shl (i64.add (i64.trunc_f64_s (local.get $k)) (i64.const 1023)) (i64.const 52)))))

  ;; x > 0. x = 2^e m with m in [0.7, 1.4], log m = 2 atanh((m-1)/(m+1))
  (func $log64 (param $x f64) (result f64)
    (local $b i64) (local $e f64) (local $m f64) (local $s f64) (local $z f64) (local $p f64)
    (local.set $b (i64.reinterpret_f64 (local.get $x)))
    (local.set $e (f64.convert_i64_s (i64.sub (i64.shr_u (local.get $b) (i64.const 52)) (i64.const 1023))))
    (local.set $m (f64.reinterpret_i64 (i64.or (i64.and (local.get $b) (i64.const 0x000fffffffffffff))
                                               (i64.const 0x3ff0000000000000))))
    (if (f64.gt (local.get $m) (f64.const 1.4142135623730951))
      (then
        (local.set $m (f64.mul (local.get $m) (f64.const 0.5)))
        (local.set $e (f64.add (local.get $e) (f64.const 1)))))
    (local.set $s (f64.div (f64.sub (local.get $m) (f64.const 1)) (f64.add (local.get $m) (f64.const 1))))
    (local.set $z (f64.mul (local.get $s) (local.get $s)))
    (local.set $p (f64.const 0.047619047619047616))   ;; 1/21
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $z)) (f64.const 0.05263157894736842)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $z)) (f64.const 0.058823529411764705)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $z)) (f64.const 0.06666666666666667)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $z)) (f64.const 0.07692307692307693)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $z)) (f64.const 0.09090909090909091)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $z)) (f64.const 0.1111111111111111)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $z)) (f64.const 0.14285714285714285)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $z)) (f64.const 0.2)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $z)) (f64.const 0.3333333333333333)))
    (local.set $p (f64.add (f64.mul (local.get $p) (local.get $z)) (f64.const 1)))
    (f64.add (f64.mul (local.get $e) (f64.const 0.6931471805599453))
             (f64.mul (f64.mul (local.get $s) (f64.const 2)) (local.get $p))))

  ;; sin and cos of x >= 0. reduce by pi/2 in three parts (exact for the angles
  ;; rope uses), taylor on |r| < pi/4, then pick by quadrant
  (func $sincos (param $x f64) (result f64 f64)
    (local $k f64) (local $r f64) (local $z f64) (local $s f64) (local $c f64) (local $q i32)
    (local.set $k (f64.nearest (f64.mul (local.get $x) (f64.const 0.6366197723675814))))
    (local.set $r (f64.sub (f64.sub (f64.sub (local.get $x)
      (f64.mul (local.get $k) (f64.const 1.57079632673412561417e+00)))
      (f64.mul (local.get $k) (f64.const 6.07710050630396597660e-11)))
      (f64.mul (local.get $k) (f64.const 2.02226624879595063154e-21))))
    (local.set $z (f64.mul (local.get $r) (local.get $r)))
    (local.set $s (f64.const 2.8114572543455206e-15))
    (local.set $s (f64.sub (f64.mul (local.get $s) (local.get $z)) (f64.const 7.647163731819816e-13)))
    (local.set $s (f64.add (f64.mul (local.get $s) (local.get $z)) (f64.const 1.6059043836821613e-10)))
    (local.set $s (f64.sub (f64.mul (local.get $s) (local.get $z)) (f64.const 2.505210838544172e-08)))
    (local.set $s (f64.add (f64.mul (local.get $s) (local.get $z)) (f64.const 2.7557319223985893e-06)))
    (local.set $s (f64.sub (f64.mul (local.get $s) (local.get $z)) (f64.const 1.984126984126984e-04)))
    (local.set $s (f64.add (f64.mul (local.get $s) (local.get $z)) (f64.const 8.333333333333333e-03)))
    (local.set $s (f64.sub (f64.mul (local.get $s) (local.get $z)) (f64.const 1.6666666666666666e-01)))
    (local.set $s (f64.mul (f64.add (f64.mul (local.get $s) (local.get $z)) (f64.const 1)) (local.get $r)))
    (local.set $c (f64.const -1.5619206968586225e-16))
    (local.set $c (f64.add (f64.mul (local.get $c) (local.get $z)) (f64.const 4.779477332387385e-14)))
    (local.set $c (f64.sub (f64.mul (local.get $c) (local.get $z)) (f64.const 1.1470745597729725e-11)))
    (local.set $c (f64.add (f64.mul (local.get $c) (local.get $z)) (f64.const 2.08767569878681e-09)))
    (local.set $c (f64.sub (f64.mul (local.get $c) (local.get $z)) (f64.const 2.755731922398589e-07)))
    (local.set $c (f64.add (f64.mul (local.get $c) (local.get $z)) (f64.const 2.48015873015873e-05)))
    (local.set $c (f64.sub (f64.mul (local.get $c) (local.get $z)) (f64.const 1.388888888888889e-03)))
    (local.set $c (f64.add (f64.mul (local.get $c) (local.get $z)) (f64.const 4.1666666666666664e-02)))
    (local.set $c (f64.sub (f64.mul (local.get $c) (local.get $z)) (f64.const 0.5)))
    (local.set $c (f64.add (f64.mul (local.get $c) (local.get $z)) (f64.const 1)))
    (local.set $q (i32.and (i32.trunc_f64_s (local.get $k)) (i32.const 3)))
    (if (i32.eq (local.get $q) (i32.const 1))
      (then (return (local.get $c) (f64.neg (local.get $s)))))
    (if (i32.eq (local.get $q) (i32.const 2))
      (then (return (f64.neg (local.get $s)) (f64.neg (local.get $c)))))
    (if (i32.eq (local.get $q) (i32.const 3))
      (then (return (f64.neg (local.get $c)) (local.get $s))))
    (local.get $s) (local.get $c))

  ;; for the tests
  (func (export "t_exp") (param f64) (result f64) (call $exp64 (local.get 0)))
  (func (export "t_log") (param f64) (result f64) (call $log64 (local.get 0)))
  (func (export "t_sin") (param f64) (result f64) (call $sincos (local.get 0)) (drop))
  (func (export "t_cos") (param f64) (result f64) (local $c f64)
    (call $sincos (local.get 0)) (local.set $c) (drop) (local.get $c))

  ;; e^x for 4 floats, the same cephes polynomial as exp8 in chat\kernels.asm
  (func $exp4 (param $x v128) (result v128)
    (local $n v128) (local $r v128) (local $p v128)
    (local.set $x (f32x4.min (local.get $x) (f32x4.splat (f32.const 88.3762626647949))))
    (local.set $x (f32x4.max (local.get $x) (f32x4.splat (f32.const -88.3762626647949))))
    (local.set $n (f32x4.nearest (f32x4.mul (local.get $x) (f32x4.splat (f32.const 1.44269504088896341)))))
    (local.set $r (f32x4.sub (local.get $x) (f32x4.mul (local.get $n) (f32x4.splat (f32.const 0.693359375)))))
    (local.set $r (f32x4.add (local.get $r) (f32x4.mul (local.get $n) (f32x4.splat (f32.const 2.12194440e-4)))))
    (local.set $p (f32x4.splat (f32.const 1.9875691500E-4)))
    (local.set $p (f32x4.add (f32x4.mul (local.get $p) (local.get $r)) (f32x4.splat (f32.const 1.3981999507E-3))))
    (local.set $p (f32x4.add (f32x4.mul (local.get $p) (local.get $r)) (f32x4.splat (f32.const 8.3334519073E-3))))
    (local.set $p (f32x4.add (f32x4.mul (local.get $p) (local.get $r)) (f32x4.splat (f32.const 4.1665795894E-2))))
    (local.set $p (f32x4.add (f32x4.mul (local.get $p) (local.get $r)) (f32x4.splat (f32.const 1.6666665459E-1))))
    (local.set $p (f32x4.add (f32x4.mul (local.get $p) (local.get $r)) (f32x4.splat (f32.const 5.0000001201E-1))))
    (local.set $p (f32x4.add (f32x4.add (local.get $r) (f32x4.splat (f32.const 1)))
                             (f32x4.mul (local.get $p) (f32x4.mul (local.get $r) (local.get $r)))))
    (f32x4.mul (local.get $p)
      (i32x4.shl (i32x4.add (i32x4.trunc_sat_f32x4_s (local.get $n)) (i32x4.splat (i32.const 127))) (i32.const 23))))

  (func $hsum (param $v v128) (result f32)
    (f32.add (f32.add (f32x4.extract_lane 0 (local.get $v)) (f32x4.extract_lane 1 (local.get $v)))
             (f32.add (f32x4.extract_lane 2 (local.get $v)) (f32x4.extract_lane 3 (local.get $v)))))

  (func $hmax (param $v v128) (result f32)
    (f32.max (f32.max (f32x4.extract_lane 0 (local.get $v)) (f32x4.extract_lane 1 (local.get $v)))
             (f32.max (f32x4.extract_lane 2 (local.get $v)) (f32x4.extract_lane 3 (local.get $v)))))

  ;; ---- the tokenizer (tokenizer\tok.asm, tokenizer\pretok.asm)

  ;; p = tokenizer.bin in memory. 1 if it's one
  (func (export "tok_load") (param $p i32) (param $len i32) (result i32)
    (local $nm i32) (local $i i32) (local $key i32) (local $h i32) (local $keys i32) (local $vals i32)
    (local $toff i32) (local $off i32) (local $m i32) (local $a i32) (local $b i32) (local $blob i32)
    (local $names i32) (local $nq i32) (local $n i32)
    (if (i64.ne (i64.load (local.get $p)) (i64.const 0x31525A4B4F544E4D))   ;; MNTOKZR1
      (then (return (i32.const 0))))
    (if (i32.ne (i32.load offset=8 (local.get $p)) (i32.const 32768)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load offset=16 (local.get $p)) (i32.const 32752)) (then (return (i32.const 0))))
    (local.set $nm (i32.load offset=12 (local.get $p)))
    (i32.store (global.get $NMERGES) (local.get $nm))
    (i64.store (global.get $THASH) (i64.load offset=24 (local.get $p)))
    (i32.store (global.get $MERGES) (i32.add (local.get $p) (i32.const 32)))

    ;; ranks, 2^17 slots. the key is the merge as stored, a | b << 16, which is
    ;; also what a 4 byte load of two neighbouring u16 tokens gives
    (local.set $keys (call $alloc (i32.const 524288)))
    (memory.fill (local.get $keys) (i32.const 0xff) (i32.const 524288))
    (local.set $vals (call $alloc (i32.const 524288)))
    (i32.store (global.get $RKEYS) (local.get $keys))
    (i32.store (global.get $RVALS) (local.get $vals))
    (local.set $i (i32.const 0))
    (block $rd (loop $rk
      (br_if $rd (i32.ge_u (local.get $i) (local.get $nm)))
      (local.set $key (i32.load offset=32 (i32.add (local.get $p) (i32.shl (local.get $i) (i32.const 2)))))
      (local.set $h (i32.shr_u (i32.mul (local.get $key) (i32.const 0x9e3779b1)) (i32.const 15)))
      (block $free (loop $probe
        (br_if $free (i32.eq (i32.load (i32.add (local.get $keys) (i32.shl (local.get $h) (i32.const 2)))) (i32.const -1)))
        (local.set $h (i32.and (i32.add (local.get $h) (i32.const 1)) (i32.const 131071)))
        (br $probe)))
      (i32.store (i32.add (local.get $keys) (i32.shl (local.get $h) (i32.const 2))) (local.get $key))
      (i32.store (i32.add (local.get $vals) (i32.shl (local.get $h) (i32.const 2))) (local.get $i))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $rk)))

    ;; every token's bytes. offsets first (a merge is its two halves, both older)
    (local.set $toff (call $alloc (i32.const 131076)))
    (i32.store (global.get $TOFF) (local.get $toff))
    (local.set $i (i32.const 0))
    (loop $byte
      (i32.store (i32.add (local.get $toff) (i32.shl (local.get $i) (i32.const 2))) (local.get $i))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $byte (i32.lt_u (local.get $i) (i32.const 256))))
    (local.set $off (i32.const 256))
    (local.set $m (i32.const 0))
    (block $md (loop $mg
      (br_if $md (i32.ge_u (local.get $m) (local.get $nm)))
      (i32.store (i32.add (local.get $toff) (i32.shl (i32.add (local.get $m) (i32.const 256)) (i32.const 2))) (local.get $off))
      (local.set $a (i32.load offset=32 (i32.add (local.get $p) (i32.shl (local.get $m) (i32.const 2)))))
      (local.set $b (i32.shr_u (local.get $a) (i32.const 16)))
      (local.set $a (i32.and (local.get $a) (i32.const 0xffff)))
      (local.set $off (i32.add (local.get $off) (i32.add (call $tlen (local.get $a)) (call $tlen (local.get $b)))))
      (local.set $m (i32.add (local.get $m) (i32.const 1)))
      (br $mg)))
    ;; ids past the last merge are empty, then the specials' names
    (local.set $i (i32.add (local.get $nm) (i32.const 256)))
    (block $ud (loop $un
      (br_if $ud (i32.ge_u (local.get $i) (i32.const 32752)))
      (i32.store (i32.add (local.get $toff) (i32.shl (local.get $i) (i32.const 2))) (local.get $off))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $un)))
    (local.set $names (call $alloc (i32.const 64)))
    (memory.init $names (local.get $names) (i32.const 0) (i32.const 63))
    (local.set $nq (local.get $names))
    (block $sd (loop $sp
      (br_if $sd (i32.ge_u (local.get $i) (i32.const 32768)))
      (i32.store (i32.add (local.get $toff) (i32.shl (local.get $i) (i32.const 2))) (local.get $off))
      (local.set $n (call $zlen (local.get $nq)))
      (local.set $off (i32.add (local.get $off) (local.get $n)))
      (if (i32.lt_u (local.get $i) (i32.const 32757))   ;; five names, then <|reserved|> for the rest
        (then (local.set $nq (i32.add (local.get $nq) (i32.add (local.get $n) (i32.const 1))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sp)))
    (i32.store (i32.add (local.get $toff) (i32.const 131072)) (local.get $off))

    ;; then the bytes themselves, in id order
    (local.set $blob (call $alloc (local.get $off)))
    (i32.store (global.get $TBLOB) (local.get $blob))
    (local.set $i (i32.const 0))
    (loop $b8
      (i32.store8 (i32.add (local.get $blob) (local.get $i)) (local.get $i))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $b8 (i32.lt_u (local.get $i) (i32.const 256))))
    (local.set $m (i32.const 0))
    (block $cd (loop $cp
      (br_if $cd (i32.ge_u (local.get $m) (local.get $nm)))
      (local.set $a (i32.load offset=32 (i32.add (local.get $p) (i32.shl (local.get $m) (i32.const 2)))))
      (local.set $b (i32.shr_u (local.get $a) (i32.const 16)))
      (local.set $a (i32.and (local.get $a) (i32.const 0xffff)))
      (local.set $off (call $tptr (i32.add (local.get $m) (i32.const 256))))
      (memory.copy (local.get $off) (call $tptr (local.get $a)) (call $tlen (local.get $a)))
      (memory.copy (i32.add (local.get $off) (call $tlen (local.get $a))) (call $tptr (local.get $b)) (call $tlen (local.get $b)))
      (local.set $m (i32.add (local.get $m) (i32.const 1)))
      (br $cp)))
    (local.set $i (i32.const 32752))
    (local.set $nq (local.get $names))
    (loop $sn
      (local.set $n (call $zlen (local.get $nq)))
      (memory.copy (call $tptr (local.get $i)) (local.get $nq) (local.get $n))
      (if (i32.lt_u (local.get $i) (i32.const 32757))
        (then (local.set $nq (i32.add (local.get $nq) (i32.add (local.get $n) (i32.const 1))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $sn (i32.lt_u (local.get $i) (i32.const 32768))))

    (i32.store (global.get $WORK) (call $alloc (i32.const 131072)))
    (i32.const 1))

  (func $zlen (param $p i32) (result i32)
    (local $n i32)
    (block $d (loop $l
      (br_if $d (i32.eqz (i32.load8_u (i32.add (local.get $p) (local.get $n)))))
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (br $l)))
    (local.get $n))

  (func $tptr (export "tok_bytes") (param $t i32) (result i32)
    (i32.add (i32.load (global.get $TBLOB))
      (i32.load (i32.add (i32.load (global.get $TOFF)) (i32.shl (i32.and (local.get $t) (i32.const 0x7fff)) (i32.const 2))))))

  (func $tlen (export "tok_len") (param $t i32) (result i32)
    (local $o i32)
    (local.set $o (i32.add (i32.load (global.get $TOFF)) (i32.shl (i32.and (local.get $t) (i32.const 0x7fff)) (i32.const 2))))
    (i32.sub (i32.load offset=4 (local.get $o)) (i32.load (local.get $o))))

  (func (export "tok_hash") (result i64) (i64.load (global.get $THASH)))

  ;; pair key -> merge rank, -1 if there's no such merge
  (func $rank (param $key i32) (result i32)
    (local $h i32) (local $k i32)
    (local.set $h (i32.shr_u (i32.mul (local.get $key) (i32.const 0x9e3779b1)) (i32.const 15)))
    (loop $p
      (local.set $k (i32.load (i32.add (i32.load (global.get $RKEYS)) (i32.shl (local.get $h) (i32.const 2)))))
      (if (i32.eq (local.get $k) (local.get $key))
        (then (return (i32.load (i32.add (i32.load (global.get $RVALS)) (i32.shl (local.get $h) (i32.const 2)))))))
      (if (i32.eq (local.get $k) (i32.const -1)) (then (return (i32.const -1))))
      (local.set $h (i32.and (i32.add (local.get $h) (i32.const 1)) (i32.const 131071)))
      (br $p))
    (unreachable))

  ;; the character at p: class | length << 4. classes: 0 letter, 1 digit,
  ;; 2 space/tab, 3 \r \n, 4 other, 5 '. non-ascii is a letter, except the
  ;; blocks that are mostly punctuation (U+0080-00BF, U+2000-2FFF, U+3000-303F, emoji)
  (func $cls (param $p i32) (param $end i32) (result i32)
    (local $c i32) (local $n i32) (local $k i32)
    (local.set $c (i32.load8_u (local.get $p)))
    (if (i32.lt_u (local.get $c) (i32.const 0x80))
      (then
        (if (i32.lt_u (i32.sub (i32.or (local.get $c) (i32.const 0x20)) (i32.const 97)) (i32.const 26))
          (then (return (i32.const 0x10))))
        (if (i32.lt_u (i32.sub (local.get $c) (i32.const 48)) (i32.const 10))
          (then (return (i32.const 0x11))))
        (if (i32.or (i32.eq (local.get $c) (i32.const 32))
                    (i32.lt_u (i32.sub (local.get $c) (i32.const 9)) (i32.const 4)))   ;; 9 10 11 12
          (then
            (if (i32.eq (local.get $c) (i32.const 10)) (then (return (i32.const 0x13))))
            (return (i32.const 0x12))))
        (if (i32.eq (local.get $c) (i32.const 13)) (then (return (i32.const 0x13))))
        (if (i32.eq (local.get $c) (i32.const 39)) (then (return (i32.const 0x15))))
        (return (i32.const 0x14))))
    (if (i32.lt_u (local.get $c) (i32.const 0xc0)) (then (return (i32.const 0x10))))  ;; stray continuation
    (local.set $k (i32.const 0))
    (if (i32.lt_u (local.get $c) (i32.const 0xe0))
      (then
        (local.set $n (i32.const 2))
        (if (i32.eq (local.get $c) (i32.const 0xc2)) (then (local.set $k (i32.const 4)))))
      (else
        (if (i32.lt_u (local.get $c) (i32.const 0xf0))
          (then
            (local.set $n (i32.const 3))
            (if (i32.eq (local.get $c) (i32.const 0xe2)) (then (local.set $k (i32.const 4))))
            (if (i32.and (i32.eq (local.get $c) (i32.const 0xe3))
                         (i32.lt_u (i32.add (local.get $p) (i32.const 1)) (local.get $end)))
              (then
                (if (i32.eq (i32.load8_u offset=1 (local.get $p)) (i32.const 0x80))
                  (then (local.set $k (i32.const 4)))))))
          (else
            (local.set $n (i32.const 4))
            (if (i32.and (i32.eq (local.get $c) (i32.const 0xf0))
                         (i32.lt_u (i32.add (local.get $p) (i32.const 1)) (local.get $end)))
              (then
                (if (i32.eq (i32.load8_u offset=1 (local.get $p)) (i32.const 0x9f))
                  (then (local.set $k (i32.const 4))))))))))
    ;; cut off by the end of the text
    (if (i32.gt_u (i32.add (local.get $p) (local.get $n)) (local.get $end))
      (then (local.set $n (i32.sub (local.get $end) (local.get $p)))))
    (i32.or (local.get $k) (i32.shl (local.get $n) (i32.const 4))))

  ;; a run of letters from p, where the first one is n bytes
  (func $letters (param $p i32) (param $end i32) (param $n i32) (result i32)
    (local $x i32)
    (loop $l
      (local.set $p (i32.add (local.get $p) (local.get $n)))
      (if (i32.ge_u (local.get $p) (local.get $end)) (then (return (local.get $p))))
      (local.set $x (call $cls (local.get $p) (local.get $end)))
      (if (i32.and (local.get $x) (i32.const 15)) (then (return (local.get $p))))
      (local.set $n (i32.shr_u (local.get $x) (i32.const 4)))
      (br $l))
    (unreachable))

  ;; a run of punctuation, plus the newlines straight after it
  (func $prun (param $p i32) (param $end i32) (result i32)
    (local $x i32) (local $c i32)
    (block $nl (loop $l
      (br_if $nl (i32.ge_u (local.get $p) (local.get $end)))
      (local.set $x (call $cls (local.get $p) (local.get $end)))
      (local.set $c (i32.and (local.get $x) (i32.const 15)))
      (br_if $nl (i32.and (i32.ne (local.get $c) (i32.const 4)) (i32.ne (local.get $c) (i32.const 5))))
      (local.set $p (i32.add (local.get $p) (i32.shr_u (local.get $x) (i32.const 4))))
      (br $l)))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $p) (local.get $end)))
      (local.set $c (i32.load8_u (local.get $p)))
      (br_if $d (i32.and (i32.ne (local.get $c) (i32.const 10)) (i32.ne (local.get $c) (i32.const 13))))
      (local.set $p (i32.add (local.get $p) (i32.const 1)))
      (br $l)))
    (local.get $p))

  ;; a whitespace run. with newlines in it: up to the last newline. otherwise all
  ;; but the last char, which goes with the word after (unless it's the end)
  (func $space (param $s i32) (param $end i32) (result i32)
    (local $p i32) (local $nl i32) (local $c i32)
    (local.set $p (local.get $s))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $p) (local.get $end)))
      (local.set $c (i32.load8_u (local.get $p)))
      (if (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 13)))
        (then
          (local.set $p (i32.add (local.get $p) (i32.const 1)))
          (local.set $nl (local.get $p))
          (br $l)))
      (br_if $d (i32.and (i32.ne (local.get $c) (i32.const 32))
                         (i32.ge_u (i32.sub (local.get $c) (i32.const 9)) (i32.const 4))))
      (local.set $p (i32.add (local.get $p) (i32.const 1)))
      (br $l)))
    (if (local.get $nl) (then (return (local.get $nl))))
    (if (i32.ge_u (local.get $p) (local.get $end)) (then (return (local.get $p))))
    (if (i32.gt_u (i32.sub (local.get $p) (i32.const 1)) (local.get $s))
      (then (return (i32.sub (local.get $p) (i32.const 1)))))
    (local.get $p))

  ;; the gpt-4 split pattern by hand (see pretok.asm). s = chunk start, returns its end
  (func $pretok (param $s i32) (param $end i32) (result i32)
    (local $x i32) (local $c i32) (local $n i32) (local $p i32) (local $d i32) (local $e i32)
    (local.set $x (call $cls (local.get $s) (local.get $end)))
    (local.set $c (i32.and (local.get $x) (i32.const 15)))
    (local.set $n (i32.shr_u (local.get $x) (i32.const 4)))
    (if (i32.eqz (local.get $c)) (then (return (call $letters (local.get $s) (local.get $end) (local.get $n)))))
    (if (i32.eq (local.get $c) (i32.const 1))
      (then
        ;; digits, one or two
        (local.set $p (i32.add (local.get $s) (local.get $n)))
        (if (i32.ge_u (local.get $p) (local.get $end)) (then (return (local.get $p))))
        (local.set $x (call $cls (local.get $p) (local.get $end)))
        (if (i32.ne (i32.and (local.get $x) (i32.const 15)) (i32.const 1)) (then (return (local.get $p))))
        (return (i32.add (local.get $p) (i32.shr_u (local.get $x) (i32.const 4))))))
    (if (i32.eq (local.get $c) (i32.const 3)) (then (return (call $space (local.get $s) (local.get $end)))))
    (if (i32.eq (local.get $c) (i32.const 2))
      (then
        ;; space or tab: in front of letters it joins them, a plain space also
        ;; leads punctuation
        (if (i32.ge_u (i32.add (local.get $s) (i32.const 1)) (local.get $end))
          (then (return (call $space (local.get $s) (local.get $end)))))
        (local.set $x (call $cls (i32.add (local.get $s) (i32.const 1)) (local.get $end)))
        (local.set $c (i32.and (local.get $x) (i32.const 15)))
        (if (i32.eqz (local.get $c))
          (then (return (call $letters (i32.add (local.get $s) (i32.const 1)) (local.get $end)
                                       (i32.shr_u (local.get $x) (i32.const 4))))))
        (if (i32.and (i32.eq (i32.load8_u (local.get $s)) (i32.const 32))
                     (i32.or (i32.eq (local.get $c) (i32.const 4)) (i32.eq (local.get $c) (i32.const 5))))
          (then (return (call $prun (i32.add (local.get $s) (i32.const 1)) (local.get $end)))))
        (return (call $space (local.get $s) (local.get $end)))))
    (if (i32.eq (local.get $c) (i32.const 5))
      (then
        ;; contractions: 's 't 'd 'm 'll 've 're, any case
        (if (i32.lt_u (i32.add (local.get $s) (i32.const 1)) (local.get $end))
          (then
            (local.set $d (i32.or (i32.load8_u offset=1 (local.get $s)) (i32.const 0x20)))
            (if (i32.or (i32.or (i32.eq (local.get $d) (i32.const 115)) (i32.eq (local.get $d) (i32.const 116)))
                        (i32.or (i32.eq (local.get $d) (i32.const 100)) (i32.eq (local.get $d) (i32.const 109))))
              (then (return (i32.add (local.get $s) (i32.const 2)))))
            (if (i32.lt_u (i32.add (local.get $s) (i32.const 2)) (local.get $end))
              (then
                (local.set $e (i32.or (i32.load8_u offset=2 (local.get $s)) (i32.const 0x20)))
                (if (i32.and (i32.eq (local.get $d) (i32.const 108)) (i32.eq (local.get $e) (i32.const 108)))
                  (then (return (i32.add (local.get $s) (i32.const 3)))))
                (if (i32.and (i32.or (i32.eq (local.get $d) (i32.const 118)) (i32.eq (local.get $d) (i32.const 114)))
                             (i32.eq (local.get $e) (i32.const 101)))
                  (then (return (i32.add (local.get $s) (i32.const 3)))))))))))
    ;; punctuation. one right before letters sticks to them, like "(word"
    (local.set $p (i32.add (local.get $s) (local.get $n)))
    (if (i32.ge_u (local.get $p) (local.get $end)) (then (return (local.get $p))))
    (local.set $x (call $cls (local.get $p) (local.get $end)))
    (if (i32.eqz (i32.and (local.get $x) (i32.const 15)))
      (then (return (call $letters (local.get $p) (local.get $end) (i32.shr_u (local.get $x) (i32.const 4))))))
    (call $prun (local.get $p) (local.get $end)))

  ;; bpe on one chunk (up to 65536 bytes): keep applying the lowest ranked merge
  ;; found in it, left to right. returns tokens written to out
  (func $chunk (param $src i32) (param $n i32) (param $out i32) (result i32)
    (local $w i32) (local $i i32) (local $best i32) (local $r i32) (local $m i32)
    (local $a i32) (local $b i32) (local $t i32) (local $rd i32) (local $wr i32)
    (if (i32.eq (local.get $n) (i32.const 1))
      (then
        (i32.store16 (local.get $out) (i32.load8_u (local.get $src)))
        (return (i32.const 1))))
    (local.set $w (i32.load (global.get $WORK)))
    (loop $ld
      (i32.store16 (i32.add (local.get $w) (i32.shl (local.get $i) (i32.const 1)))
                   (i32.load8_u (i32.add (local.get $src) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $ld (i32.lt_u (local.get $i) (local.get $n))))
    (block $fin (loop $round
      (local.set $best (i32.const -1))
      (local.set $i (i32.const 0))
      (block $sd (loop $scan
        (br_if $sd (i32.ge_u (i32.add (local.get $i) (i32.const 1)) (local.get $n)))
        (local.set $r (call $rank (i32.load (i32.add (local.get $w) (i32.shl (local.get $i) (i32.const 1))))))
        (if (i32.lt_u (local.get $r) (local.get $best)) (then (local.set $best (local.get $r))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan)))
      (br_if $fin (i32.eq (local.get $best) (i32.const -1)))
      (local.set $m (i32.load (i32.add (i32.load (global.get $MERGES)) (i32.shl (local.get $best) (i32.const 2)))))
      (local.set $a (i32.and (local.get $m) (i32.const 0xffff)))
      (local.set $b (i32.shr_u (local.get $m) (i32.const 16)))
      (local.set $rd (i32.const 0))
      (local.set $wr (i32.const 0))
      (block $md (loop $mg
        (br_if $md (i32.ge_u (local.get $rd) (local.get $n)))
        (local.set $t (i32.load16_u (i32.add (local.get $w) (i32.shl (local.get $rd) (i32.const 1)))))
        (if (i32.and (i32.and (i32.lt_u (i32.add (local.get $rd) (i32.const 1)) (local.get $n))
                              (i32.eq (local.get $t) (local.get $a)))
                     (i32.eq (i32.load16_u offset=2 (i32.add (local.get $w) (i32.shl (local.get $rd) (i32.const 1))))
                             (local.get $b)))
          (then
            (local.set $t (i32.add (local.get $best) (i32.const 256)))
            (local.set $rd (i32.add (local.get $rd) (i32.const 2))))
          (else (local.set $rd (i32.add (local.get $rd) (i32.const 1)))))
        (i32.store16 (i32.add (local.get $w) (i32.shl (local.get $wr) (i32.const 1))) (local.get $t))
        (local.set $wr (i32.add (local.get $wr) (i32.const 1)))
        (br $mg)))
      (local.set $n (local.get $wr))
      (br_if $round (i32.gt_u (local.get $n) (i32.const 1)))))
    (memory.copy (local.get $out) (local.get $w) (i32.shl (local.get $n) (i32.const 1)))
    (local.get $n))

  ;; text -> tokens (u16) at out. returns how many
  (func (export "tok_encode") (param $p i32) (param $len i32) (param $out i32) (result i32)
    (local $end i32) (local $ce i32) (local $n i32) (local $o i32)
    (local.set $end (i32.add (local.get $p) (local.get $len)))
    (local.set $o (local.get $out))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $p) (local.get $end)))
      (local.set $ce (call $pretok (local.get $p) (local.get $end)))
      (block $pd (loop $piece   ;; giant chunks go in pieces, like tok.asm
        (br_if $pd (i32.ge_u (local.get $p) (local.get $ce)))
        (local.set $n (i32.sub (local.get $ce) (local.get $p)))
        (if (i32.gt_u (local.get $n) (i32.const 65536)) (then (local.set $n (i32.const 65536))))
        (local.set $o (i32.add (local.get $o)
          (i32.shl (call $chunk (local.get $p) (local.get $n) (local.get $o)) (i32.const 1))))
        (local.set $p (i32.add (local.get $p) (local.get $n)))
        (br $piece)))
      (br $l)))
    (i32.shr_u (i32.sub (local.get $o) (local.get $out)) (i32.const 1)))

  ;; ---- the model

  (func $a64 (param $n i32) (result i32)
    (i32.and (i32.add (local.get $n) (i32.const 63)) (i32.const -64)))

  ;; bytes a matrix takes in the file (chat\quant.asm mf_size)
  (func $mfsize (param $r i32) (param $c i32) (param $qt i32) (result i32)
    (local $n i32)
    (local.set $n (i32.mul (local.get $r) (local.get $c)))
    (if (i32.eqz (local.get $qt)) (then (return (call $a64 (i32.shl (local.get $n) (i32.const 2))))))
    (if (i32.eq (local.get $qt) (i32.const 1))
      (then (return (call $a64 (i32.add (call $a64 (local.get $n)) (i32.shl (local.get $r) (i32.const 2)))))))
    (call $a64 (i32.add (call $a64 (i32.shr_u (local.get $n) (i32.const 1)))
                        (i32.shl (i32.mul (i32.shr_u (local.get $c) (i32.const 5)) (local.get $r)) (i32.const 2)))))

  ;; fills matrix mx that starts at p, returns where the next one starts
  (func $mxset (param $mx i32) (param $p i32) (param $r i32) (param $c i32) (param $qt i32) (result i32)
    (local $n i32)
    (i32.store (local.get $mx) (local.get $p))
    (i32.store offset=8 (local.get $mx) (local.get $r))
    (i32.store offset=12 (local.get $mx) (local.get $c))
    (i32.store offset=16 (local.get $mx) (local.get $qt))
    (local.set $n (i32.mul (local.get $r) (local.get $c)))
    (if (i32.eq (local.get $qt) (i32.const 2)) (then (local.set $n (i32.shr_u (local.get $n) (i32.const 1)))))
    (i32.store offset=4 (local.get $mx) (i32.add (local.get $p) (call $a64 (local.get $n))))
    (i32.add (local.get $p) (call $mfsize (local.get $r) (local.get $c) (local.get $qt))))

  (func $buf (param $floats i32) (result i32)
    (call $alloc (i32.shl (local.get $floats) (i32.const 2))))

  ;; p = a model file in memory (64 byte aligned). 1 = ready, 0 = not a model
  ;; file, 2 = made with a different tokenizer
  (func (export "eng_load") (param $p i32) (param $len i32) (result i32)
    (local $q i32) (local $l i32) (local $m i32) (local $t i32) (local $i i32) (local $hd i32)
    (local $lb f64) (local $f f64) (local $s f64) (local $c f64) (local $tab i32) (local $mc i32)
    (if (i64.ne (i64.load (local.get $p)) (i64.const 0x314C45444F4D4E4D))   ;; MNMODEL1
      (then (return (i32.const 0))))
    (i32.store (global.get $L) (i32.load offset=8 (local.get $p)))
    (i32.store (global.get $D) (i32.load offset=16 (local.get $p)))
    (i32.store (global.get $H) (i32.load offset=24 (local.get $p)))
    (i32.store (global.get $KVH) (i32.load offset=32 (local.get $p)))
    (i32.store (global.get $HD) (i32.load offset=40 (local.get $p)))
    (i32.store (global.get $F) (i32.load offset=48 (local.get $p)))
    (i32.store (global.get $V) (i32.load offset=56 (local.get $p)))
    (i32.store (global.get $T) (i32.load offset=64 (local.get $p)))
    (i32.store (global.get $QT) (i32.load offset=80 (local.get $p)))
    (i64.store (global.get $MHASH) (i64.load offset=88 (local.get $p)))
    (if (i32.and (i64.ne (i64.load (global.get $MHASH)) (i64.const 0))   ;; (test models have none)
                 (i64.ne (i64.load (global.get $MHASH)) (i64.load (global.get $THASH))))
      (then (return (i32.const 2))))
    (local.set $hd (i32.load (global.get $HD)))
    (i32.store (global.get $QD) (i32.mul (i32.load (global.get $H)) (local.get $hd)))
    (i32.store (global.get $KVD) (i32.mul (i32.load (global.get $KVH)) (local.get $hd)))
    (i32.store (global.get $QKV) (i32.add (i32.load (global.get $QD)) (i32.shl (i32.load (global.get $KVD)) (i32.const 1))))
    (f32.store (global.get $SCALE) (f32.demote_f64 (f64.div (f64.const 1) (f64.sqrt (f64.convert_i32_u (local.get $hd))))))

    ;; the tensors, in file order
    (local.set $q (call $mxset (global.get $E) (i32.add (local.get $p) (i32.const 4096))
      (i32.load (global.get $V)) (i32.load (global.get $D)) (i32.load (global.get $QT))))
    (local.set $m (call $alloc (i32.shl (i32.load (global.get $L)) (i32.const 7))))
    (i32.store (global.get $LAYERS) (local.get $m))
    (block $ld (loop $layer
      (br_if $ld (i32.ge_u (local.get $l) (i32.load (global.get $L))))
      (local.set $q (call $mxset (local.get $m) (local.get $q)
        (i32.load (global.get $QKV)) (i32.load (global.get $D)) (i32.load (global.get $QT))))
      (local.set $q (call $mxset (i32.add (local.get $m) (i32.const 32)) (local.get $q)
        (i32.load (global.get $D)) (i32.load (global.get $QD)) (i32.load (global.get $QT))))
      (local.set $q (call $mxset (i32.add (local.get $m) (i32.const 64)) (local.get $q)
        (i32.shl (i32.load (global.get $F)) (i32.const 1)) (i32.load (global.get $D)) (i32.load (global.get $QT))))
      (local.set $q (call $mxset (i32.add (local.get $m) (i32.const 96)) (local.get $q)
        (i32.load (global.get $D)) (i32.load (global.get $F)) (i32.load (global.get $QT))))
      (local.set $m (i32.add (local.get $m) (i32.const 128)))
      (local.set $l (i32.add (local.get $l) (i32.const 1)))
      (br $layer)))
    (i32.store (global.get $NORMS) (local.get $q))

    ;; kv cache and working buffers
    (local.set $t (i32.mul (i32.mul (i32.load (global.get $L)) (i32.load (global.get $T))) (i32.load (global.get $KVD))))
    (i32.store (global.get $KC) (call $buf (local.get $t)))
    (i32.store (global.get $VC) (call $buf (local.get $t)))
    (i32.store (global.get $ROPE) (call $buf (i32.mul (i32.load (global.get $T)) (local.get $hd))))
    (i32.store (global.get $X) (call $buf (i32.load (global.get $D))))
    (i32.store (global.get $XN) (call $buf (i32.load (global.get $D))))
    (i32.store (global.get $QKVB) (call $buf (i32.load (global.get $QKV))))
    (i32.store (global.get $Y) (call $buf (i32.load (global.get $QD))))
    (i32.store (global.get $HB) (call $buf (i32.shl (i32.load (global.get $F)) (i32.const 1))))
    (i32.store (global.get $G) (call $buf (i32.load (global.get $F))))
    (i32.store (global.get $LOGITS) (call $buf (i32.load (global.get $V))))
    (i32.store (global.get $PROBS) (call $buf (i32.load (global.get $V))))
    (i32.store (global.get $TMP) (call $buf (i32.load (global.get $D))))
    ;; a padded row per head: exp4 writes up to 3 floats past the last score
    (i32.store (global.get $ASTR) (i32.add (i32.load (global.get $T)) (i32.const 8)))
    (i32.store (global.get $ATT) (call $buf (i32.mul (i32.load (global.get $H)) (i32.load (global.get $ASTR)))))
    (local.set $mc (i32.load (global.get $D)))
    (if (i32.gt_u (i32.load (global.get $QD)) (local.get $mc)) (then (local.set $mc (i32.load (global.get $QD)))))
    (if (i32.gt_u (i32.load (global.get $F)) (local.get $mc)) (then (local.set $mc (i32.load (global.get $F)))))
    (i32.store (global.get $XQ) (call $alloc (i32.shl (local.get $mc) (i32.const 1))))
    (i32.store (global.get $XS) (call $buf (i32.shr_u (local.get $mc) (i32.const 5))))

    ;; rope table [t][i] = (cos, sin) of t base^(-2i/hd), in f64 then f32, like the gpu
    (local.set $lb (call $log64 (f64.load offset=72 (local.get $p))))
    (local.set $tab (i32.load (global.get $ROPE)))
    (local.set $t (i32.const 0))
    (block $rd (loop $rt
      (br_if $rd (i32.ge_u (local.get $t) (i32.load (global.get $T))))
      (local.set $i (i32.const 0))
      (block $id (loop $ri
        (br_if $id (i32.ge_u (i32.shl (local.get $i) (i32.const 1)) (local.get $hd)))
        (local.set $f (call $exp64 (f64.neg (f64.mul (local.get $lb)
          (f64.div (f64.convert_i32_u (i32.shl (local.get $i) (i32.const 1))) (f64.convert_i32_u (local.get $hd)))))))
        (call $sincos (f64.mul (local.get $f) (f64.convert_i32_u (local.get $t))))
        (local.set $c)
        (local.set $s)
        (f32.store (local.get $tab) (f32.demote_f64 (local.get $c)))
        (f32.store offset=4 (local.get $tab) (f32.demote_f64 (local.get $s)))
        (local.set $tab (i32.add (local.get $tab) (i32.const 8)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $ri)))
      (local.set $t (i32.add (local.get $t) (i32.const 1)))
      (br $rt)))
    (i32.store (global.get $POS) (i32.const 0))
    (i32.const 1))

  (func (export "eng_reset") (i32.store (global.get $POS) (i32.const 0)))

  ;; engine fields for the page: 0 L, 1 D, 2 H, 3 KVH, 4 HD, 5 F, 6 V, 7 T, 11 quant type, 12 pos
  (func (export "eng_get") (param $i i32) (result i32)
    (i32.load (i32.add (i32.const 512) (i32.shl (local.get $i) (i32.const 2)))))

  ;; dst = src * rstd * w, rstd = 1/sqrt(mean(src^2) + 1e-5). n a multiple of 4
  (func $rmsnorm (param $src i32) (param $w i32) (param $dst i32) (param $n i32)
    (local $i i32) (local $acc v128) (local $v v128) (local $r v128)
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $v (v128.load (i32.add (local.get $src) (i32.shl (local.get $i) (i32.const 2)))))
      (local.set $acc (f32x4.add (local.get $acc) (f32x4.mul (local.get $v) (local.get $v))))
      (local.set $i (i32.add (local.get $i) (i32.const 4)))
      (br $l)))
    (local.set $r (f32x4.splat (f32.div (f32.const 1)
      (f32.sqrt (f32.add (f32.div (call $hsum (local.get $acc)) (f32.convert_i32_u (local.get $n)))
                         (f32.const 1e-5))))))
    (local.set $i (i32.const 0))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
      (v128.store (i32.add (local.get $dst) (i32.shl (local.get $i) (i32.const 2)))
        (f32x4.mul (f32x4.mul (local.get $r) (v128.load (i32.add (local.get $src) (i32.shl (local.get $i) (i32.const 2)))))
                   (v128.load (i32.add (local.get $w) (i32.shl (local.get $i) (i32.const 2))))))
      (local.set $i (i32.add (local.get $i) (i32.const 4)))
      (br $l))))

  ;; dst += src
  (func $addv (param $dst i32) (param $src i32) (param $n i32)
    (local $i i32) (local $a i32)
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $a (i32.add (local.get $dst) (i32.shl (local.get $i) (i32.const 2))))
      (v128.store (local.get $a) (f32x4.add (v128.load (local.get $a))
        (v128.load (i32.add (local.get $src) (i32.shl (local.get $i) (i32.const 2))))))
      (local.set $i (i32.add (local.get $i) (i32.const 4)))
      (br $l))))

  ;; the token's embedding row -> x, as f32
  (func $embed (param $tok i32)
    (local $d i32) (local $x i32) (local $q i32) (local $i i32) (local $s f32) (local $sp i32) (local $b i32) (local $j i32)
    (local.set $d (i32.load (global.get $D)))
    (local.set $x (i32.load (global.get $X)))
    (local.set $q (i32.load (global.get $E)))
    (if (i32.eqz (i32.load (global.get $QT)))
      (then
        (memory.copy (local.get $x) (i32.add (local.get $q) (i32.shl (i32.mul (local.get $tok) (local.get $d)) (i32.const 2)))
                     (i32.shl (local.get $d) (i32.const 2)))
        (return)))
    (if (i32.eq (i32.load (global.get $QT)) (i32.const 1))
      (then
        (local.set $q (i32.add (local.get $q) (i32.mul (local.get $tok) (local.get $d))))
        (local.set $s (f32.load (i32.add (i32.load offset=4 (global.get $E)) (i32.shl (local.get $tok) (i32.const 2)))))
        (loop $b8
          (f32.store (i32.add (local.get $x) (i32.shl (local.get $i) (i32.const 2)))
            (f32.mul (f32.convert_i32_s (i32.load8_s (i32.add (local.get $q) (local.get $i)))) (local.get $s)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if $b8 (i32.lt_u (local.get $i) (local.get $d))))
        (return)))
    ;; int4: low nibbles are 0-15 of a group, high ones 16-31, both stored + 8
    (local.set $q (i32.add (local.get $q) (i32.shr_u (i32.mul (local.get $tok) (local.get $d)) (i32.const 1))))
    (local.set $sp (i32.add (i32.load offset=4 (global.get $E)) (i32.shr_u (i32.mul (local.get $tok) (local.get $d)) (i32.const 3))))
    (loop $g
      (local.set $s (f32.load (local.get $sp)))
      (local.set $j (i32.const 0))
      (loop $n
        (local.set $b (i32.load8_u (i32.add (local.get $q) (local.get $j))))
        (f32.store (i32.add (local.get $x) (i32.shl (i32.add (local.get $i) (local.get $j)) (i32.const 2)))
          (f32.mul (f32.convert_i32_s (i32.sub (i32.and (local.get $b) (i32.const 15)) (i32.const 8))) (local.get $s)))
        (f32.store offset=64 (i32.add (local.get $x) (i32.shl (i32.add (local.get $i) (local.get $j)) (i32.const 2)))
          (f32.mul (f32.convert_i32_s (i32.sub (i32.shr_u (local.get $b) (i32.const 4)) (i32.const 8))) (local.get $s)))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br_if $n (i32.lt_u (local.get $j) (i32.const 16))))
      (local.set $q (i32.add (local.get $q) (i32.const 16)))
      (local.set $sp (i32.add (local.get $sp) (i32.const 4)))
      (local.set $i (i32.add (local.get $i) (i32.const 32)))
      (br_if $g (i32.lt_u (local.get $i) (local.get $d)))))

  ;; rotary embedding on the q and k heads, position CT. pairs (2i, 2i+1)
  (func $rope
    (local $q i32) (local $n i32) (local $tab i32) (local $hd i32) (local $f i32) (local $k i32)
    (local $c f32) (local $s f32) (local $x0 f32) (local $x1 f32)
    (local.set $q (i32.load (global.get $QKVB)))
    (local.set $hd (i32.load (global.get $HD)))
    (local.set $n (i32.mul (i32.add (i32.load (global.get $H)) (i32.load (global.get $KVH))) (local.get $hd)))
    (local.set $tab (i32.add (i32.load (global.get $ROPE))
      (i32.shl (i32.mul (i32.load (global.get $CT)) (local.get $hd)) (i32.const 2))))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $f) (local.get $n)))
      ;; (cos, sin) of this pair: the float index within the head, times 4 bytes
      (local.set $k (i32.add (local.get $tab) (i32.shl (i32.rem_u (local.get $f) (local.get $hd)) (i32.const 2))))
      (local.set $c (f32.load (local.get $k)))
      (local.set $s (f32.load offset=4 (local.get $k)))
      (local.set $k (i32.add (local.get $q) (i32.shl (local.get $f) (i32.const 2))))
      (local.set $x0 (f32.load (local.get $k)))
      (local.set $x1 (f32.load offset=4 (local.get $k)))
      (f32.store (local.get $k) (f32.sub (f32.mul (local.get $x0) (local.get $c)) (f32.mul (local.get $x1) (local.get $s))))
      (f32.store offset=4 (local.get $k) (f32.add (f32.mul (local.get $x0) (local.get $s)) (f32.mul (local.get $x1) (local.get $c))))
      (local.set $f (i32.add (local.get $f) (i32.const 2)))
      (br $l))))

  ;; x (f32, n) -> XQ: int8 values kept as int16, per group of 32 scale = max|x| / 127
  (func $qx (param $x i32) (param $n i32)
    (local $q i32) (local $s i32) (local $g i32) (local $m v128) (local $inv v128) (local $mx f32)
    (local $a v128) (local $b v128)
    (local.set $q (i32.load (global.get $XQ)))
    (local.set $s (i32.load (global.get $XS)))
    (local.set $g (i32.shr_u (local.get $n) (i32.const 5)))
    (loop $grp
      (local.set $m (f32x4.max (f32x4.max (f32x4.abs (v128.load (local.get $x))) (f32x4.abs (v128.load offset=16 (local.get $x))))
                               (f32x4.max (f32x4.abs (v128.load offset=32 (local.get $x))) (f32x4.abs (v128.load offset=48 (local.get $x))))))
      (local.set $m (f32x4.max (local.get $m)
        (f32x4.max (f32x4.max (f32x4.abs (v128.load offset=64 (local.get $x))) (f32x4.abs (v128.load offset=80 (local.get $x))))
                   (f32x4.max (f32x4.abs (v128.load offset=96 (local.get $x))) (f32x4.abs (v128.load offset=112 (local.get $x)))))))
      (local.set $mx (call $hmax (local.get $m)))
      (f32.store (local.get $s) (f32.div (local.get $mx) (f32.const 127)))
      (local.set $inv (f32x4.splat
        (select (f32.div (f32.const 127) (local.get $mx)) (f32.const 0) (f32.gt (local.get $mx) (f32.const 0)))))
      ;; round to nearest, like cvtps2dq
      (v128.store (local.get $q) (i16x8.narrow_i32x4_s
        (i32x4.trunc_sat_f32x4_s (f32x4.nearest (f32x4.mul (v128.load (local.get $x)) (local.get $inv))))
        (i32x4.trunc_sat_f32x4_s (f32x4.nearest (f32x4.mul (v128.load offset=16 (local.get $x)) (local.get $inv))))))
      (v128.store offset=16 (local.get $q) (i16x8.narrow_i32x4_s
        (i32x4.trunc_sat_f32x4_s (f32x4.nearest (f32x4.mul (v128.load offset=32 (local.get $x)) (local.get $inv))))
        (i32x4.trunc_sat_f32x4_s (f32x4.nearest (f32x4.mul (v128.load offset=48 (local.get $x)) (local.get $inv))))))
      (v128.store offset=32 (local.get $q) (i16x8.narrow_i32x4_s
        (i32x4.trunc_sat_f32x4_s (f32x4.nearest (f32x4.mul (v128.load offset=64 (local.get $x)) (local.get $inv))))
        (i32x4.trunc_sat_f32x4_s (f32x4.nearest (f32x4.mul (v128.load offset=80 (local.get $x)) (local.get $inv))))))
      (v128.store offset=48 (local.get $q) (i16x8.narrow_i32x4_s
        (i32x4.trunc_sat_f32x4_s (f32x4.nearest (f32x4.mul (v128.load offset=96 (local.get $x)) (local.get $inv))))
        (i32x4.trunc_sat_f32x4_s (f32x4.nearest (f32x4.mul (v128.load offset=112 (local.get $x)) (local.get $inv))))))
      (local.set $x (i32.add (local.get $x) (i32.const 128)))
      (local.set $q (i32.add (local.get $q) (i32.const 64)))
      (local.set $s (i32.add (local.get $s) (i32.const 4)))
      (br_if $grp (local.tee $g (i32.sub (local.get $g) (i32.const 1))))))

  ;; y = W x for matrix mx, rows split over the threads
  (func $mv (param $mx i32) (param $x i32) (param $y i32)
    (local $r i32) (local $chunk i32)
    (i32.store (global.get $MV) (local.get $mx))
    (i32.store (global.get $MVX) (local.get $x))
    (i32.store (global.get $MVY) (local.get $y))
    (if (i32.load offset=16 (local.get $mx))
      (then (call $qx (local.get $x) (i32.load offset=12 (local.get $mx)))))
    ;; about 8 chunks per thread, at least 4 rows each
    (local.set $r (i32.load offset=8 (local.get $mx)))
    (local.set $chunk (i32.div_u (local.get $r)
      (i32.shl (i32.add (i32.load (global.get $NHELP)) (i32.const 1)) (i32.const 3))))
    (if (i32.lt_u (local.get $chunk) (i32.const 4)) (then (local.set $chunk (i32.const 4))))
    (call $par (i32.load offset=16 (local.get $mx)) (local.get $r) (local.get $chunk)))

  ;; f32 rows [r0, r1)
  (func $mvf32 (param $r0 i32) (param $r1 i32)
    (local $mx i32) (local $c i32) (local $w i32) (local $x i32) (local $k i32)
    (local $a0 v128) (local $a1 v128) (local $a2 v128) (local $a3 v128)
    (local.set $mx (i32.load (global.get $MV)))
    (local.set $c (i32.load offset=12 (local.get $mx)))
    (block $d (loop $row
      (br_if $d (i32.ge_u (local.get $r0) (local.get $r1)))
      (local.set $w (i32.add (i32.load (local.get $mx)) (i32.shl (i32.mul (local.get $r0) (local.get $c)) (i32.const 2))))
      (local.set $x (i32.load (global.get $MVX)))
      (local.set $a0 (v128.const i32x4 0 0 0 0))
      (local.set $a1 (v128.const i32x4 0 0 0 0))
      (local.set $a2 (v128.const i32x4 0 0 0 0))
      (local.set $a3 (v128.const i32x4 0 0 0 0))
      (local.set $k (i32.shr_u (local.get $c) (i32.const 4)))
      (loop $l
        (local.set $a0 (f32x4.add (local.get $a0) (f32x4.mul (v128.load (local.get $w)) (v128.load (local.get $x)))))
        (local.set $a1 (f32x4.add (local.get $a1) (f32x4.mul (v128.load offset=16 (local.get $w)) (v128.load offset=16 (local.get $x)))))
        (local.set $a2 (f32x4.add (local.get $a2) (f32x4.mul (v128.load offset=32 (local.get $w)) (v128.load offset=32 (local.get $x)))))
        (local.set $a3 (f32x4.add (local.get $a3) (f32x4.mul (v128.load offset=48 (local.get $w)) (v128.load offset=48 (local.get $x)))))
        (local.set $w (i32.add (local.get $w) (i32.const 64)))
        (local.set $x (i32.add (local.get $x) (i32.const 64)))
        (br_if $l (local.tee $k (i32.sub (local.get $k) (i32.const 1)))))
      (f32.store (i32.add (i32.load (global.get $MVY)) (i32.shl (local.get $r0) (i32.const 2)))
        (call $hsum (f32x4.add (f32x4.add (local.get $a0) (local.get $a1)) (f32x4.add (local.get $a2) (local.get $a3)))))
      (local.set $r0 (i32.add (local.get $r0) (i32.const 1)))
      (br $row))))

  ;; int8 rows, a scale per row: y = scale[row] * sum_g xs[g] (w_g . xq_g).
  ;; the dot products widen the weights to int16 and use pmaddwd's cousin
  (func $mvq8 (param $r0 i32) (param $r1 i32)
    (local $mx i32) (local $c i32) (local $w i32) (local $x i32) (local $xs i32) (local $g i32)
    (local $acc v128) (local $a v128) (local $d v128)
    (local.set $mx (i32.load (global.get $MV)))
    (local.set $c (i32.load offset=12 (local.get $mx)))
    (block $done (loop $row
      (br_if $done (i32.ge_u (local.get $r0) (local.get $r1)))
      (local.set $w (i32.add (i32.load (local.get $mx)) (i32.mul (local.get $r0) (local.get $c))))
      (local.set $x (i32.load (global.get $XQ)))
      (local.set $xs (i32.load (global.get $XS)))
      (local.set $acc (v128.const i32x4 0 0 0 0))
      (local.set $g (i32.shr_u (local.get $c) (i32.const 5)))
      (loop $grp
        (local.set $a (v128.load (local.get $w)))
        (local.set $d (i32x4.add
          (i32x4.dot_i16x8_s (i16x8.extend_low_i8x16_s (local.get $a)) (v128.load (local.get $x)))
          (i32x4.dot_i16x8_s (i16x8.extend_high_i8x16_s (local.get $a)) (v128.load offset=16 (local.get $x)))))
        (local.set $a (v128.load offset=16 (local.get $w)))
        (local.set $d (i32x4.add (local.get $d) (i32x4.add
          (i32x4.dot_i16x8_s (i16x8.extend_low_i8x16_s (local.get $a)) (v128.load offset=32 (local.get $x)))
          (i32x4.dot_i16x8_s (i16x8.extend_high_i8x16_s (local.get $a)) (v128.load offset=48 (local.get $x))))))
        (local.set $acc (f32x4.add (local.get $acc)
          (f32x4.mul (f32x4.convert_i32x4_s (local.get $d)) (v128.load32_splat (local.get $xs)))))
        (local.set $w (i32.add (local.get $w) (i32.const 32)))
        (local.set $x (i32.add (local.get $x) (i32.const 64)))
        (local.set $xs (i32.add (local.get $xs) (i32.const 4)))
        (br_if $grp (local.tee $g (i32.sub (local.get $g) (i32.const 1)))))
      (f32.store (i32.add (i32.load (global.get $MVY)) (i32.shl (local.get $r0) (i32.const 2)))
        (f32.mul (call $hsum (local.get $acc))
                 (f32.load (i32.add (i32.load offset=4 (local.get $mx)) (i32.shl (local.get $r0) (i32.const 2))))))
      (local.set $r0 (i32.add (local.get $r0) (i32.const 1)))
      (br $row))))

  ;; int4 rows, a scale per group: y = sum_g xs[g] ws[g] (w_g . xq_g). 16 bytes
  ;; unpack to 32 weights: low nibbles are 0-15, high ones 16-31, minus 8
  (func $mvq4 (param $r0 i32) (param $r1 i32)
    (local $mx i32) (local $c i32) (local $w i32) (local $x i32) (local $xs i32) (local $ws i32) (local $g i32)
    (local $acc v128) (local $b v128) (local $lo v128) (local $hi v128) (local $d v128)
    (local.set $mx (i32.load (global.get $MV)))
    (local.set $c (i32.load offset=12 (local.get $mx)))
    (block $done (loop $row
      (br_if $done (i32.ge_u (local.get $r0) (local.get $r1)))
      (local.set $w (i32.add (i32.load (local.get $mx)) (i32.shr_u (i32.mul (local.get $r0) (local.get $c)) (i32.const 1))))
      (local.set $ws (i32.add (i32.load offset=4 (local.get $mx)) (i32.shr_u (i32.mul (local.get $r0) (local.get $c)) (i32.const 3))))
      (local.set $x (i32.load (global.get $XQ)))
      (local.set $xs (i32.load (global.get $XS)))
      (local.set $acc (v128.const i32x4 0 0 0 0))
      (local.set $g (i32.shr_u (local.get $c) (i32.const 5)))
      (loop $grp
        (local.set $b (v128.load (local.get $w)))
        (local.set $lo (i8x16.sub (v128.and (local.get $b) (i8x16.splat (i32.const 15))) (i8x16.splat (i32.const 8))))
        (local.set $hi (i8x16.sub (i8x16.shr_u (local.get $b) (i32.const 4)) (i8x16.splat (i32.const 8))))
        (local.set $d (i32x4.add (i32x4.add
          (i32x4.dot_i16x8_s (i16x8.extend_low_i8x16_s (local.get $lo)) (v128.load (local.get $x)))
          (i32x4.dot_i16x8_s (i16x8.extend_high_i8x16_s (local.get $lo)) (v128.load offset=16 (local.get $x))))
          (i32x4.add
          (i32x4.dot_i16x8_s (i16x8.extend_low_i8x16_s (local.get $hi)) (v128.load offset=32 (local.get $x)))
          (i32x4.dot_i16x8_s (i16x8.extend_high_i8x16_s (local.get $hi)) (v128.load offset=48 (local.get $x))))))
        (local.set $acc (f32x4.add (local.get $acc) (f32x4.mul (f32x4.convert_i32x4_s (local.get $d))
          (f32x4.splat (f32.mul (f32.load (local.get $xs)) (f32.load (local.get $ws)))))))
        (local.set $w (i32.add (local.get $w) (i32.const 16)))
        (local.set $x (i32.add (local.get $x) (i32.const 64)))
        (local.set $xs (i32.add (local.get $xs) (i32.const 4)))
        (local.set $ws (i32.add (local.get $ws) (i32.const 4)))
        (br_if $grp (local.tee $g (i32.sub (local.get $g) (i32.const 1)))))
      (f32.store (i32.add (i32.load (global.get $MVY)) (i32.shl (local.get $r0) (i32.const 2)))
        (call $hsum (local.get $acc)))
      (local.set $r0 (i32.add (local.get $r0) (i32.const 1)))
      (br $row))))

  ;; attention for heads [h0, h1) at layer CL, position CT
  (func $att (param $h0 i32) (param $h1 i32)
    (local $t i32) (local $hd i32) (local $kvs i32) (local $grp i32) (local $kb i32) (local $vb i32)
    (local $q i32) (local $s i32) (local $y i32) (local $j i32) (local $i i32) (local $kp i32)
    (local $acc v128) (local $m f32) (local $v f32) (local $sum f32) (local $mx v128) (local $p v128) (local $a i32)
    (local.set $t (i32.load (global.get $CT)))
    (local.set $hd (i32.load (global.get $HD)))
    (local.set $kvs (i32.shl (i32.load (global.get $KVD)) (i32.const 2)))   ;; cache row stride, bytes
    (local.set $grp (i32.div_u (i32.load (global.get $H)) (i32.load (global.get $KVH))))
    (block $done (loop $head
      (br_if $done (i32.ge_u (local.get $h0) (local.get $h1)))
      ;; its kv head's rows, this layer, position 0
      (local.set $kb (i32.shl (i32.add
        (i32.mul (i32.mul (i32.load (global.get $CL)) (i32.load (global.get $T))) (i32.load (global.get $KVD)))
        (i32.mul (i32.div_u (local.get $h0) (local.get $grp)) (local.get $hd))) (i32.const 2)))
      (local.set $vb (i32.add (i32.load (global.get $VC)) (local.get $kb)))
      (local.set $kb (i32.add (i32.load (global.get $KC)) (local.get $kb)))
      (local.set $q (i32.add (i32.load (global.get $QKVB)) (i32.shl (i32.mul (local.get $h0) (local.get $hd)) (i32.const 2))))
      (local.set $s (i32.add (i32.load (global.get $ATT)) (i32.shl (i32.mul (local.get $h0) (i32.load (global.get $ASTR))) (i32.const 2))))
      (local.set $y (i32.add (i32.load (global.get $Y)) (i32.shl (i32.mul (local.get $h0) (local.get $hd)) (i32.const 2))))

      ;; scores s_j = q . k_j * scale, and their max
      (local.set $m (f32.const -inf))
      (local.set $kp (local.get $kb))
      (local.set $j (i32.const 0))
      (block $sd (loop $sc
        (br_if $sd (i32.gt_u (local.get $j) (local.get $t)))
        (local.set $acc (v128.const i32x4 0 0 0 0))
        (local.set $i (i32.const 0))
        (loop $dot
          (local.set $acc (f32x4.add (local.get $acc)
            (f32x4.mul (v128.load (i32.add (local.get $q) (local.get $i))) (v128.load (i32.add (local.get $kp) (local.get $i))))))
          (local.set $i (i32.add (local.get $i) (i32.const 16)))
          (br_if $dot (i32.lt_u (local.get $i) (i32.shl (local.get $hd) (i32.const 2)))))
        (local.set $v (f32.mul (call $hsum (local.get $acc)) (f32.load (global.get $SCALE))))
        (f32.store (i32.add (local.get $s) (i32.shl (local.get $j) (i32.const 2))) (local.get $v))
        (local.set $m (f32.max (local.get $m) (local.get $v)))
        (local.set $kp (i32.add (local.get $kp) (local.get $kvs)))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $sc)))

      ;; p_j = exp(s_j - max), 4 at a time (the row has room past t)
      (local.set $mx (f32x4.splat (local.get $m)))
      (local.set $j (i32.const 0))
      (block $ed (loop $ex
        (br_if $ed (i32.gt_u (local.get $j) (local.get $t)))
        (local.set $a (i32.add (local.get $s) (i32.shl (local.get $j) (i32.const 2))))
        (v128.store (local.get $a) (call $exp4 (f32x4.sub (v128.load (local.get $a)) (local.get $mx))))
        (local.set $j (i32.add (local.get $j) (i32.const 4)))
        (br $ex)))
      (local.set $sum (f32.const 0))   ;; in order
      (local.set $j (i32.const 0))
      (loop $sm
        (local.set $sum (f32.add (local.get $sum) (f32.load (i32.add (local.get $s) (i32.shl (local.get $j) (i32.const 2))))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br_if $sm (i32.le_u (local.get $j) (local.get $t))))

      ;; y = sum_j p_j v_j / sum
      (memory.fill (local.get $y) (i32.const 0) (i32.shl (local.get $hd) (i32.const 2)))
      (local.set $kp (local.get $vb))
      (local.set $j (i32.const 0))
      (loop $vs
        (local.set $p (v128.load32_splat (i32.add (local.get $s) (i32.shl (local.get $j) (i32.const 2)))))
        (local.set $i (i32.const 0))
        (loop $col
          (local.set $a (i32.add (local.get $y) (local.get $i)))
          (v128.store (local.get $a) (f32x4.add (v128.load (local.get $a))
            (f32x4.mul (local.get $p) (v128.load (i32.add (local.get $kp) (local.get $i))))))
          (local.set $i (i32.add (local.get $i) (i32.const 16)))
          (br_if $col (i32.lt_u (local.get $i) (i32.shl (local.get $hd) (i32.const 2)))))
        (local.set $kp (i32.add (local.get $kp) (local.get $kvs)))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br_if $vs (i32.le_u (local.get $j) (local.get $t))))
      (local.set $p (f32x4.splat (f32.div (f32.const 1) (local.get $sum))))
      (local.set $i (i32.const 0))
      (loop $sc2
        (local.set $a (i32.add (local.get $y) (local.get $i)))
        (v128.store (local.get $a) (f32x4.mul (v128.load (local.get $a)) (local.get $p)))
        (local.set $i (i32.add (local.get $i) (i32.const 16)))
        (br_if $sc2 (i32.lt_u (local.get $i) (i32.shl (local.get $hd) (i32.const 2)))))
      (local.set $h0 (i32.add (local.get $h0) (i32.const 1)))
      (br $head))))

  ;; g = silu(a) * b, a = hb[0..F), b = hb[F..2F)
  (func $swiglu
    (local $a i32) (local $b i32) (local $g i32) (local $i i32) (local $n i32) (local $v v128)
    (local.set $a (i32.load (global.get $HB)))
    (local.set $n (i32.shl (i32.load (global.get $F)) (i32.const 2)))
    (local.set $b (i32.add (local.get $a) (local.get $n)))
    (local.set $g (i32.load (global.get $G)))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $v (v128.load (i32.add (local.get $a) (local.get $i))))
      (v128.store (i32.add (local.get $g) (local.get $i))
        (f32x4.mul (f32x4.mul (local.get $v)
          (f32x4.div (f32x4.splat (f32.const 1)) (f32x4.add (f32x4.splat (f32.const 1)) (call $exp4 (f32x4.neg (local.get $v))))))
          (v128.load (i32.add (local.get $b) (local.get $i)))))
      (local.set $i (i32.add (local.get $i) (i32.const 16)))
      (br $l))))

  ;; runs the token through the model at the next position and adds it to the
  ;; kv cache. want = 1 to compute the logits
  (func (export "eng_step") (param $tok i32) (param $want i32)
    (local $l i32) (local $lp i32) (local $nw i32) (local $d i32) (local $kv i32) (local $off i32)
    (if (i32.ge_u (i32.load (global.get $POS)) (i32.load (global.get $T))) (then (unreachable)))   ;; cache full
    (call $embed (local.get $tok))
    (i32.store (global.get $CT) (i32.load (global.get $POS)))
    (local.set $d (i32.load (global.get $D)))
    (local.set $kv (i32.load (global.get $KVD)))
    (local.set $lp (i32.load (global.get $LAYERS)))
    (block $done (loop $layer
      (br_if $done (i32.ge_u (local.get $l) (i32.load (global.get $L))))
      (i32.store (global.get $CL) (local.get $l))
      (local.set $nw (i32.add (i32.load (global.get $NORMS)) (i32.shl (i32.mul (local.get $l) (local.get $d)) (i32.const 3))))
      (call $rmsnorm (i32.load (global.get $X)) (local.get $nw) (i32.load (global.get $XN)) (local.get $d))
      (call $mv (local.get $lp) (i32.load (global.get $XN)) (i32.load (global.get $QKVB)))
      (call $rope)
      ;; k and v into the cache at this position (v follows k in the qkv row)
      (local.set $off (i32.shl (i32.mul (i32.add (i32.mul (local.get $l) (i32.load (global.get $T))) (i32.load (global.get $CT)))
                                        (local.get $kv)) (i32.const 2)))
      (memory.copy (i32.add (i32.load (global.get $KC)) (local.get $off))
                   (i32.add (i32.load (global.get $QKVB)) (i32.shl (i32.load (global.get $QD)) (i32.const 2)))
                   (i32.shl (local.get $kv) (i32.const 2)))
      (memory.copy (i32.add (i32.load (global.get $VC)) (local.get $off))
                   (i32.add (i32.load (global.get $QKVB)) (i32.shl (i32.add (i32.load (global.get $QD)) (local.get $kv)) (i32.const 2)))
                   (i32.shl (local.get $kv) (i32.const 2)))
      (call $par (i32.const 3) (i32.load (global.get $H)) (i32.const 1))
      (call $mv (i32.add (local.get $lp) (i32.const 32)) (i32.load (global.get $Y)) (i32.load (global.get $TMP)))
      (call $addv (i32.load (global.get $X)) (i32.load (global.get $TMP)) (local.get $d))
      (call $rmsnorm (i32.load (global.get $X)) (i32.add (local.get $nw) (i32.shl (local.get $d) (i32.const 2)))
                     (i32.load (global.get $XN)) (local.get $d))
      (call $mv (i32.add (local.get $lp) (i32.const 64)) (i32.load (global.get $XN)) (i32.load (global.get $HB)))
      (call $swiglu)
      (call $mv (i32.add (local.get $lp) (i32.const 96)) (i32.load (global.get $G)) (i32.load (global.get $TMP)))
      (call $addv (i32.load (global.get $X)) (i32.load (global.get $TMP)) (local.get $d))
      (local.set $lp (i32.add (local.get $lp) (i32.const 128)))
      (local.set $l (i32.add (local.get $l) (i32.const 1)))
      (br $layer)))
    (i32.store (global.get $POS) (i32.add (i32.load (global.get $POS)) (i32.const 1)))
    (if (local.get $want)
      (then
        (call $rmsnorm (i32.load (global.get $X))
          (i32.add (i32.load (global.get $NORMS)) (i32.shl (i32.mul (i32.load (global.get $L)) (local.get $d)) (i32.const 3)))
          (i32.load (global.get $XN)) (local.get $d))
        (call $mv (global.get $E) (i32.load (global.get $XN)) (i32.load (global.get $LOGITS))))))

  (func $lmax (result f32)
    (local $l i32) (local $i i32) (local $m v128)
    (local.set $l (i32.load (global.get $LOGITS)))
    (local.set $m (f32x4.splat (f32.const -inf)))
    (loop $x
      (local.set $m (f32x4.max (local.get $m) (v128.load (i32.add (local.get $l) (i32.shl (local.get $i) (i32.const 2))))))
      (local.set $i (i32.add (local.get $i) (i32.const 4)))
      (br_if $x (i32.lt_u (local.get $i) (i32.load (global.get $V)))))
    (call $hmax (local.get $m)))

  ;; -log p(target) under the current logits
  (func (export "eng_nll") (param $tgt i32) (result f64)
    (local $l i32) (local $i i32) (local $m f32) (local $mx v128) (local $acc v128)
    (local.set $l (i32.load (global.get $LOGITS)))
    (local.set $m (call $lmax))
    (local.set $mx (f32x4.splat (local.get $m)))
    (loop $x
      (local.set $acc (f32x4.add (local.get $acc)
        (call $exp4 (f32x4.sub (v128.load (i32.add (local.get $l) (i32.shl (local.get $i) (i32.const 2)))) (local.get $mx)))))
      (local.set $i (i32.add (local.get $i) (i32.const 4)))
      (br_if $x (i32.lt_u (local.get $i) (i32.load (global.get $V)))))
    (f64.sub (f64.add (call $log64 (f64.promote_f32 (call $hsum (local.get $acc)))) (f64.promote_f32 (local.get $m)))
             (f64.promote_f32 (f32.load (i32.add (local.get $l) (i32.shl (local.get $tgt) (i32.const 2)))))))

  ;; the next token from the logits: temperature (0 = the most likely one), then
  ;; top-p among the 64 likeliest. u = a uniform random number in [0, 1)
  (func (export "samp_pick") (param $temp f64) (param $topp f64) (param $u f64) (result i32)
    (local $l i32) (local $pr i32) (local $v i32) (local $i i32) (local $k i32) (local $kept i32)
    (local $m f32) (local $x f32) (local $mx v128) (local $inv v128) (local $acc v128) (local $e v128)
    (local $run f64) (local $thr f64) (local $a i32)
    (local.set $l (i32.load (global.get $LOGITS)))
    (local.set $v (i32.load (global.get $V)))
    (local.set $m (call $lmax))
    (if (f64.le (local.get $temp) (f64.const 0))
      (then
        (loop $am
          (if (f32.eq (f32.load (i32.add (local.get $l) (i32.shl (local.get $i) (i32.const 2)))) (local.get $m))
            (then (return (local.get $i))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if $am (i32.lt_u (local.get $i) (local.get $v))))
        (return (i32.const 0))))   ;; only if the logits are nan

    ;; p = exp((l - max) / temp), all of them
    (local.set $pr (i32.load (global.get $PROBS)))
    (local.set $mx (f32x4.splat (local.get $m)))
    (local.set $inv (f32x4.splat (f32.div (f32.const 1) (f32.demote_f64 (local.get $temp)))))
    (loop $p
      (local.set $a (i32.shl (local.get $i) (i32.const 2)))
      (local.set $e (call $exp4 (f32x4.mul (f32x4.sub (v128.load (i32.add (local.get $l) (local.get $a))) (local.get $mx)) (local.get $inv))))
      (v128.store (i32.add (local.get $pr) (local.get $a)) (local.get $e))
      (local.set $acc (f32x4.add (local.get $acc) (local.get $e)))
      (local.set $i (i32.add (local.get $i) (i32.const 4)))
      (br_if $p (i32.lt_u (local.get $i) (local.get $v))))

    ;; the 64 largest, descending (insertion; most never get past the last one)
    (local.set $i (i32.const 0))
    (loop $top
      (local.set $x (f32.load (i32.add (local.get $pr) (i32.shl (local.get $i) (i32.const 2)))))
      (block $skip
        (if (i32.eq (local.get $kept) (i32.const 64))
          (then
            (br_if $skip (f32.le (local.get $x) (f32.load offset=252 (global.get $TOPV))))
            (local.set $kept (i32.const 63))))
        (local.set $k (local.get $kept))
        (block $put (loop $sh
          (br_if $put (i32.eqz (local.get $k)))
          (local.set $a (i32.shl (local.get $k) (i32.const 2)))
          (br_if $put (f32.le (local.get $x) (f32.load offset=1020 (local.get $a))))   ;; TOPV + 4(k-1)
          (f32.store offset=1024 (local.get $a) (f32.load offset=1020 (local.get $a)))
          (i32.store offset=1280 (local.get $a) (i32.load offset=1276 (local.get $a)))
          (local.set $k (i32.sub (local.get $k) (i32.const 1)))
          (br $sh)))
        (f32.store offset=1024 (i32.shl (local.get $k) (i32.const 2)) (local.get $x))
        (i32.store offset=1280 (i32.shl (local.get $k) (i32.const 2)) (local.get $i))
        (local.set $kept (i32.add (local.get $kept) (i32.const 1))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $top (i32.lt_u (local.get $i) (local.get $v))))

    ;; the smallest top set whose probability reaches top_p
    (local.set $thr (f64.mul (f64.promote_f32 (call $hsum (local.get $acc))) (local.get $topp)))
    (local.set $k (i32.const 0))
    (block $cd (loop $c
      (local.set $run (f64.add (local.get $run) (f64.promote_f32 (f32.load offset=1024 (i32.shl (local.get $k) (i32.const 2))))))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br_if $cd (i32.ge_u (local.get $k) (local.get $kept)))
      (br_if $c (f64.lt (local.get $run) (local.get $thr)))))
    ;; and draw from it
    (local.set $u (f64.mul (local.get $u) (local.get $run)))
    (local.set $i (i32.const 0))
    (block $got (loop $w
      (br_if $got (i32.ge_u (i32.add (local.get $i) (i32.const 1)) (local.get $k)))   ;; the last takes what rounding left
      (local.set $u (f64.sub (local.get $u) (f64.promote_f32 (f32.load offset=1024 (i32.shl (local.get $i) (i32.const 2))))))
      (br_if $got (f64.lt (local.get $u) (f64.const 0)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $w)))
    (i32.load offset=1280 (i32.shl (local.get $i) (i32.const 2))))
)
