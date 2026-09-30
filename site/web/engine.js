// the engine's workers. the page starts one driver and a few helpers, all on one
// shared memory. helpers just sit inside engine.wasm taking chunks of work
const BOS = 32752, USER = 32753, ASSIST = 32754, END = 32756, SPECIAL0 = 32752

let e, mem, stop, io, T

onmessage = async ({ data: m }) => {
  try {
    if (m.type === 'helper') new WebAssembly.Instance(m.module, { env: { mem: m.mem } }).exports.helper(m.id)
    else if (m.type === 'load') await load(m)
    else if (m.type === 'chat') chat(m)
    else if (m.type === 'threads') postMessage({ type: 'threads', threads: e.set_threads(m.threads) })
    else if (m.type === 'chat-reset') e.eng_reset()
  } catch (err) {
    postMessage({ type: 'error', msg: String(err && err.message || err) })
  }
}

function put(bytes) {
  const p = e.alloc(bytes.length)
  new Uint8Array(mem.buffer, p, bytes.length).set(bytes)
  return p
}

async function load(m) {
  mem = m.mem
  stop = new Int32Array(m.stop)
  e = new WebAssembly.Instance(m.module, { env: { mem } }).exports
  const tok = new Uint8Array(await (await fetch(m.tokenizer)).arrayBuffer())
  if (e.tok_load(put(tok), tok.length) !== 1) throw new Error("tokenizer.bin isn't a tokenizer")
  const p = e.alloc(m.model.bytes)
  await download(m.model, p)
  const r = e.eng_load(p, m.model.bytes)
  if (r !== 1) throw new Error(r === 2 ? 'the model was made with a different tokenizer' : "that isn't a model file")
  T = e.eng_get(7)
  io = e.alloc(1 << 18)
  // the helpers count themselves in; don't wait forever on one that never started
  const ready = new Int32Array(mem.buffer, 320, 1)
  for (let i = 0; i < 100 && Atomics.load(ready, 0) < m.helpers; i++) await new Promise(r => setTimeout(r, 20))
  postMessage({
    type: 'ready', threads: e.set_threads(m.threads),
    info: { layers: e.eng_get(0), d: e.eng_get(1), heads: e.eng_get(2), kvheads: e.eng_get(3), ffn: e.eng_get(5), vocab: e.eng_get(6), ctx: T, quant: e.eng_get(11) }
  })
}

// streams the model into wasm memory. the first visit keeps a copy in the cache
async function download(model, p) {
  let cache = null, res = null, cached = false
  try { cache = await caches.open('mnemonic-models') } catch {}
  if (cache) {
    res = await cache.match(model.url)
    if (res && +res.headers.get('content-length') !== model.bytes) { await cache.delete(model.url); res = null }
    cached = !!res
  }
  if (!res) {
    res = await fetch(model.url)
    if (!res.ok) throw new Error(`couldn't download the model (${res.status})`)
    if (cache) cache.put(model.url, res.clone()).catch(() => {})   // (a full disk just means no cache)
  }
  const view = new Uint8Array(mem.buffer, p, model.bytes)
  const reader = res.body.getReader()
  let got = 0, last = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    if (got + value.length > model.bytes) throw new Error('the model file is bigger than models.json says')
    view.set(value, got)
    got += value.length
    const now = performance.now()
    if (now - last > 100) { postMessage({ type: 'progress', got, total: model.bytes, cached }); last = now }
  }
  if (got !== model.bytes) throw new Error('the download stopped early')
  postMessage({ type: 'progress', got, total: model.bytes, cached })
}

function encode(text) {
  const b = new TextEncoder().encode(text).slice(0, 1 << 16)
  new Uint8Array(mem.buffer, io, b.length).set(b)
  const n = e.tok_encode(io, b.length, io + (1 << 16))
  return Array.from(new Uint16Array(mem.buffer, io + (1 << 16), n))
}

function chat({ text, s }) {
  let toks = encode(text)
  if (toks.length > T / 2) toks = toks.slice(0, T / 2)   // a huge paste gets cut
  const turn = [USER, ...toks, END, ASSIST]
  let note = ''
  const pos = () => e.eng_get(12)
  // single turn, or out of room: a fresh conversation with just this turn
  if (!s.multi || pos() === 0 || pos() + turn.length + s.max > T) {
    if (s.multi && pos() > 0) note = 'the conversation got too long for the model, so it started over'
    e.eng_reset()
    e.eng_step(BOS, 0)
  }
  turn.forEach((t, i) => e.eng_step(t, i === turn.length - 1 ? 1 : 0))

  Atomics.store(stop, 0, 0)
  const dec = new TextDecoder()
  const t0 = performance.now()
  let n = 0, stopped = false
  for (;;) {
    const t = e.samp_pick(s.temp, s.topp, Math.random())
    if (t >= SPECIAL0) break                    // <|end|>, or any other special
    const piece = dec.decode(new Uint8Array(mem.buffer, e.tok_bytes(t), e.tok_len(t)).slice(), { stream: true })
    if (piece) postMessage({ type: 'tok', text: piece })
    n++
    if (Atomics.load(stop, 0)) { stopped = true; break }
    if (n >= s.max || pos() + 1 >= T) break
    e.eng_step(t, 1)
  }
  const rest = dec.decode()
  if (rest) postMessage({ type: 'tok', text: rest })
  if (pos() < T) e.eng_step(END, 0)            // the turn ends with <|end|> in the cache either way
  postMessage({ type: 'done', n, secs: (performance.now() - t0) / 1000, stopped, note, used: pos(), ctx: T })
}
