// checks the webassembly engine against the x86 one (bin\chat).
//   node site\test.mjs [model=models\mnemonic-q8.mnm] [rows=1] [threads=all] [docs=2000]
// the wasm runs exactly as on the page: one driver, helpers in worker threads,
// one shared memory
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { Worker, isMainThread, workerData } from 'node:worker_threads'
import { availableParallelism } from 'node:os'
import { fileURLToPath } from 'node:url'

if (!isMainThread) {
  const { module, mem, id } = workerData
  new WebAssembly.Instance(module, { env: { mem } }).exports.helper(id)
}

const arg = (k, d) => (process.argv.find(a => a.startsWith(k + '=')) || '').slice(k.length + 1) || d
const root = fileURLToPath(new URL('..', import.meta.url))
const path = p => root + p
let bad = 0
const check = (ok, what) => { console.log((ok ? '  ok    ' : '  FAIL  ') + what); if (!ok) bad++ }

const module = new WebAssembly.Module(readFileSync(path('site/engine.wasm')))
const mem = new WebAssembly.Memory({ initial: 64, maximum: 65536, shared: true })
const e = new WebAssembly.Instance(module, { env: { mem } }).exports
const put = bytes => { const p = e.alloc(bytes.length); new Uint8Array(mem.buffer, p, bytes.length).set(bytes); return p }

// math: wasm has no transcendental instructions, these are ours
{
  let worst = 0
  const rel = (a, b) => Math.abs(a - b) / Math.max(Math.abs(b), 1e-300)
  for (let x = -30; x <= 5; x += 0.01) worst = Math.max(worst, rel(e.t_exp(x), Math.exp(x)))
  for (let x = 1e-6; x < 1e6; x *= 1.01) worst = Math.max(worst, rel(e.t_log(x), Math.log(x)))
  let wsc = 0
  for (let x = 0; x < 2100; x += 0.37) wsc = Math.max(wsc, Math.abs(e.t_sin(x) - Math.sin(x)), Math.abs(e.t_cos(x) - Math.cos(x)))
  check(worst < 1e-14, `exp and log vs Math, worst relative error ${worst.toExponential(2)}`)
  check(wsc < 1e-12, `sin and cos on [0, 2100) vs Math, worst error ${wsc.toExponential(2)}`)
}

// tokenizer: the validation docs must encode to exactly what bin\tokenize wrote
const tokfile = readFileSync(path('datasets/tokenizer.bin'))
check(e.tok_load(put(tokfile), tokfile.length) === 1, 'tokenizer loads')
const io = e.alloc(16 << 20)           // text in (up to 8 MB), tokens out after it
const encode = s => {
  const b = typeof s === 'string' ? new TextEncoder().encode(s) : s
  new Uint8Array(mem.buffer, io, b.length).set(b)
  const n = e.tok_encode(io, b.length, io + (8 << 20))
  return new Uint16Array(mem.buffer.slice(io + (8 << 20), io + (8 << 20) + 2 * n))
}
const bytes = t => new Uint8Array(mem.buffer, e.tok_bytes(t), e.tok_len(t))
{
  const docs = readFileSync(path('datasets/fineweb/shard_01822.docs'))
  const toks = readFileSync(path('datasets/fineweb/shard_01822.tok'))
  const dv = new DataView(docs.buffer, docs.byteOffset)
  const tv = new Uint16Array(toks.buffer, toks.byteOffset + 64, (toks.length - 64) >> 1)
  const ndocs = Number(dv.getBigUint64(8, true)), offs = Number(dv.getBigUint64(32, true)), text = Number(dv.getBigUint64(56, true))
  const want = Math.min(ndocs, +arg('docs', 2000))
  let pos = 0, n = 0, bytesIn = 0, first = -1
  const t0 = performance.now()
  for (let i = 0; i < want && first < 0; i++) {
    const a = text + Number(dv.getBigUint64(offs + 8 * i, true)), b = text + Number(dv.getBigUint64(offs + 8 * i + 8, true))
    const got = encode(docs.subarray(a, b))
    if (tv[pos] !== 32752) first = i
    pos++
    for (let k = 0; k < got.length; k++) if (got[k] !== tv[pos + k]) { first = i; break }
    pos += got.length; n += got.length; bytesIn += b - a
  }
  const secs = (performance.now() - t0) / 1000
  check(first < 0, `${want} validation docs (${(bytesIn / 1e6).toFixed(1)} MB) encode to the same ${n} tokens as bin\\tokenize` +
    (first >= 0 ? `, first mismatch in doc ${first}` : `, ${(bytesIn / 1e6 / secs).toFixed(1)} MB/s`))
  let round = true
  for (const s of ["Hello, world! It's 2026... ", "  spaces\n\n\ttabs\r\n", "naïve café — “quotes” 😀 日本語。", "x=123456; y'll we've I'M"]) {
    const t = encode(s), back = new Uint8Array(t.reduce((n, k) => n + e.tok_len(k), 0))
    let o = 0
    for (const k of t) { back.set(bytes(k), o); o += e.tok_len(k) }
    round &&= new TextDecoder().decode(back) === s
  }
  check(round, 'decode(encode(s)) == s on unicode, digits, contractions, whitespace')
  check(new TextDecoder().decode(bytes(32756)) === '<|end|>' && new TextDecoder().decode(bytes(32760)) === '<|reserved|>', 'special token names')
}

// the model
const model = arg('model', 'models\\mnemonic-q8.mnm')
{
  const f = readFileSync(path(model))
  const r = e.eng_load(put(f), f.length)
  check(r === 1, `${model} loads (${(f.length / 1048576).toFixed(0)} MB, ${e.eng_get(0)} layers, d ${e.eng_get(1)}, ctx ${e.eng_get(7)})`)
  if (r !== 1) process.exit(1)
}

// a stuck job blocks this thread inside the wasm for good, where no timer can run,
// so a watchdog thread fails the test instead of letting test.bat hang
new Worker(`
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 600000)
  require('node:fs').writeSync(1, '  FAIL  stuck for 10 minutes, a job never finished\\n')
  process.kill(process.pid)
`, { eval: true }).unref()

// helpers. their ids start at 1, as if the page's helper 0 never started: the engine
// has to count only the helpers that are really there
const want = +arg('threads', availableParallelism())
const workers = []
for (let i = 0; i < want - 1; i++) workers.push(new Worker(new URL(import.meta.url), { workerData: { module, mem, id: i + 1 } }))
const ready = new Int32Array(mem.buffer, 320, 1)
while (Atomics.load(ready, 0) < want - 1) await new Promise(r => setTimeout(r, 5))
const threads = e.set_threads(want)

// loss on the first rows of the chat val file, next to bin\chat's on the same rows
{
  const rows = +arg('rows', 1)
  const vf = readFileSync(path('datasets/chat/val.tok'))
  const tv = new Uint16Array(vf.buffer, vf.byteOffset + 64, (vf.length - 64) >> 1)
  const T = e.eng_get(7)
  let sum = 0, cnt = 0
  const t0 = performance.now()
  for (let r = 0; r < rows; r++) {
    e.eng_reset()
    for (let t = 0; t < T; t++) {
      e.eng_step(tv[r * T + t] & 0x7fff, 1)
      const tgt = tv[r * T + t + 1]
      if (tgt & 0x8000) { sum += e.eng_nll(tgt & 0x7fff); cnt++ }
    }
  }
  const secs = (performance.now() - t0) / 1000
  const out = execFileSync(path('bin/chat.exe'), [`model=${model}`, 'eval=datasets\\chat\\val.tok', `rows=${rows}`], { cwd: root }).toString()
  const m = out.match(/loss ([\d.]+) over (\d+) targets, ([\d.]+) tok\/s/)
  const loss = sum / cnt
  check(m && +m[2] === cnt && Math.abs(loss - +m[1]) < 5e-4,
    `loss ${loss.toFixed(5)} over ${cnt} targets, bin\\chat says ${m ? m[1] : '?'} (${rows} row${rows > 1 ? 's' : ''})`)
  console.log(`        wasm ${(rows * T / secs).toFixed(1)} tok/s on ${threads} threads, bin\\chat ${m ? m[3] : '?'} tok/s`)
}

// greedy reply, same as bin\chat temp=0
{
  const q = 'Hi! Who are you?'
  e.eng_reset()
  const prompt = [32752, 32753, ...encode(q), 32756, 32754]
  prompt.forEach((t, i) => e.eng_step(t, i === prompt.length - 1 ? 1 : 0))
  const parts = []
  for (let i = 0; i < 60; i++) {
    const t = e.samp_pick(0, 0.9, 0.5)
    if (t >= 32752) break
    parts.push(...bytes(t))
    e.eng_step(t, 1)
  }
  const reply = new TextDecoder().decode(new Uint8Array(parts))
  const out = execFileSync(path('bin/chat.exe'), [`model=${model}`, 'temp=0', 'max=60'], { cwd: root, input: q + '\n' }).toString()
  const m = out.match(/\x1b\[0m {2}(.*?)\r\n\x1b\[90m/s)
  check(m && m[1] === reply, `greedy "${q}" -> "${reply}"` + (m && m[1] !== reply ? `, bin\\chat: "${m[1]}"` : ''))
}

console.log(bad ? '  SOME CHECKS FAILED' : '  all passed')
process.exit(bad ? 1 : 0)
