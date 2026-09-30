// the chat page. the model runs in workers (engine.js): one drives, the rest help
const $ = s => document.querySelector(s)
const log = $('#log'), input = $('#input'), send = $('#send'), status = $('#status'), bar = $('#bar')
const cores = navigator.hardwareConcurrency || 4
// serve.mjs has the models too, unless ?remote says to try the real download
const local = ['localhost', '127.0.0.1'].includes(location.hostname) && !location.search.includes('remote')

const defaults = { model: '', temp: 0.7, topp: 0.9, max: 400, multi: false, threads: Math.max(1, Math.min(16, Math.floor(cores * 3 / 4))) }
let s = { ...defaults }
try { Object.assign(s, JSON.parse(localStorage.getItem('mnemonic') || '{}')) } catch {}
const save = () => { try { localStorage.setItem('mnemonic', JSON.stringify(s)) } catch {} }

let models = [], model, driver, stopFlag, ready = false, busy = false, queued = null, bot = null, threads = 0

// ---- starting the engine

async function start() {
  if (!crossOriginIsolated || typeof SharedArrayBuffer === 'undefined')
    return fail("This browser can't run Mnemonic here: it needs shared memory for its threads. Try a recent Chrome, Edge, Firefox or Safari.")
  models = await (await fetch('models.json')).json()
  model = models.find(m => m.id === s.model) || models[0]
  fillSettings()
  let module
  try { module = await WebAssembly.compileStreaming(fetch('engine.wasm')) }
  catch { return fail("This browser can't run Mnemonic: it needs WebAssembly SIMD (Chrome 91+, Firefox 89+, Safari 16.4+).") }

  // the model, its kv cache and buffers all live in one shared memory
  const pages = Math.min(65536, Math.ceil((model.bytes * 1.3 + (256 << 20)) / 65536))
  let mem
  try { mem = new WebAssembly.Memory({ initial: 256, maximum: pages, shared: true }) }
  catch { return fail("Couldn't get enough memory for the model. Closing other tabs might help.") }
  stopFlag = new Int32Array(new SharedArrayBuffer(4))

  const helpers = cores - 1
  for (let i = 0; i < helpers; i++) new Worker('engine.js').postMessage({ type: 'helper', module, mem, id: i })
  driver = new Worker('engine.js')
  driver.onmessage = ({ data }) => on[data.type](data)
  driver.postMessage({
    type: 'load', module, mem, stop: stopFlag.buffer, tokenizer: 'tokenizer.bin', helpers, threads: s.threads,
    model: { url: local ? `/models/${model.file}` : model.url, bytes: model.bytes }
  })
  input.placeholder = 'Loading Mnemonic…'
}

const mb = n => (n / 1048576).toFixed(0)

const on = {
  progress({ got, total, cached }) {
    bar.style.width = (100 * got / total) + '%'
    input.placeholder = cached ? 'Loading Mnemonic…' : `Downloading Mnemonic… ${mb(got)} of ${mb(total)} MB (first visit only)`
  },
  ready({ threads: n, info }) {
    ready = true
    threads = n
    bar.style.width = '0'
    input.placeholder = 'Message Mnemonic'
    model.info = info
    showStatus()
    updateSend()
    if (queued) { bot.meta.textContent = ''; run(queued); queued = null }
  },
  tok({ text }) {
    bot.raw += text
    bot.el.innerHTML = md(bot.raw)
    follow()
  },
  done({ n, secs, stopped, note }) {
    const rate = n > 1 ? `${n} tokens · ${(n / secs).toFixed(1)} tok/s` : `${n} token${n === 1 ? '' : 's'}`
    bot.box.classList.remove('busy')
    bot.meta.textContent = rate + (stopped ? ' · stopped' : '')
    if (note) addNote(note, bot.box)
    bot = null
    setBusy(false)
    driver.postMessage({ type: 'threads', threads: s.threads })   // in case it changed mid-reply
  },
  threads({ threads: n }) { threads = n; showStatus() },
  error({ msg }) {
    if (bot) { bot.box.classList.remove('busy'); bot = null }
    setBusy(false)
    fail('Something went wrong: ' + msg)
  }
}

function fail(msg) {
  status.textContent = msg
  status.className = 'error'
  input.placeholder = "Mnemonic couldn't start"
  bar.style.width = '0'
}

function showStatus() {
  const q = ['f32', 'int8', 'int4'][model.info.quant]
  status.className = ''
  status.textContent = `${model.name} · ${q} · ${threads} thread${threads > 1 ? 's' : ''} · runs on your device`
}

// ---- the conversation

function add(cls) {
  $('#intro')?.remove()
  const box = document.createElement('div')
  box.className = 'msg ' + cls
  const el = document.createElement('div')
  el.className = 'text'
  box.append(el)
  log.append(box)
  return { box, el }
}

function addNote(text, after) {
  const p = document.createElement('p')
  p.className = 'note'
  p.textContent = text
  after ? after.before(p) : log.append(p)
}

function follow() {
  if (log.scrollHeight - log.scrollTop - log.clientHeight < 120) log.scrollTop = log.scrollHeight
}

function ask(text) {
  add('user').el.textContent = text
  const { box, el } = add('bot busy')
  const meta = document.createElement('div')
  meta.className = 'meta'
  box.append(meta)
  bot = { box, el, meta, raw: '' }
  log.scrollTop = log.scrollHeight
  setBusy(true)
  if (ready) run(text)
  else { queued = text; meta.textContent = 'waiting for the model to load' }
}

const run = text => driver.postMessage({ type: 'chat', text, s: { temp: s.temp, topp: s.topp, max: s.max, multi: s.multi } })

function setBusy(b) {
  busy = b
  document.body.classList.toggle('busy', b)
  updateSend()
}

function updateSend() {
  send.disabled = !busy && !input.value.trim()
  send.setAttribute('aria-label', busy ? 'Stop' : 'Send')
}

$('#form').addEventListener('submit', ev => {
  ev.preventDefault()
  if (busy) {
    if (ready) Atomics.store(stopFlag, 0, 1)
    else { queued = null; bot.box.remove(); bot = null; setBusy(false) }   // not started yet, just drop it
    return
  }
  const text = input.value.trim()
  if (!text) return
  input.value = ''
  grow()
  ask(text)
})
input.addEventListener('keydown', ev => {
  if (ev.key === 'Enter' && !ev.shiftKey && !ev.isComposing) { ev.preventDefault(); $('#form').requestSubmit() }
})
const grow = () => { input.style.height = 'auto'; input.style.height = input.scrollHeight + 'px'; updateSend() }
input.addEventListener('input', grow)
document.querySelectorAll('.chips button').forEach(b => b.addEventListener('click', () => { if (!busy) ask(b.textContent) }))

$('#new').addEventListener('click', () => {
  if (busy) return
  log.replaceChildren()
  if (ready) driver.postMessage({ type: 'chat-reset' })
  input.focus()
})

// ---- a little markdown: paragraphs, lists, headings, code, bold, italics

function md(src) {
  const esc = t => t.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])
  const inline = t => esc(t)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*\w])\*(?!\s)(.+?)\*(?!\w)/g, '$1<em>$2</em>')
  const out = []
  let para = [], list = null
  const endPara = () => { if (para.length) out.push('<p>' + para.map(inline).join('<br>') + '</p>'); para = [] }
  const endList = () => { if (list) out.push(`</${list}>`); list = null }
  const lines = src.split('\n')
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i]
    let m
    if (l.trimStart().startsWith('```')) {
      endPara(); endList()
      const code = []
      while (++i < lines.length && !lines[i].trimStart().startsWith('```')) code.push(lines[i])
      out.push('<pre><code>' + esc(code.join('\n')) + '</code></pre>')
    } else if ((m = l.match(/^#{1,6}\s+(.*)/))) {
      endPara(); endList()
      out.push(`<h4>${inline(m[1])}</h4>`)
    } else if ((m = l.match(/^\s*(?:[-*•]|(\d+)[.)])\s+(.*)/))) {
      endPara()
      const kind = m[1] ? 'ol' : 'ul'
      if (list !== kind) { endList(); out.push(kind === 'ol' ? `<ol start="${m[1]}">` : '<ul>'); list = kind }
      out.push(`<li>${inline(m[2])}</li>`)
    } else if (!l.trim()) {
      endPara()
    } else {
      endList()
      para.push(l)
    }
  }
  endPara(); endList()
  return out.join('')
}

// ---- settings

const dlg = $('#settings')
const sliders = { temp: v => (+v).toFixed(2), topp: v => (+v).toFixed(2), max: v => `${v} tokens`, threads: v => `${v} of ${cores}` }

function fillSettings() {
  const sel = $('#s-model')
  sel.replaceChildren(...models.map(m => new Option(`${m.name} (${mb(m.bytes)} MB)`, m.id)))
  sel.value = model.id
  $('#s-model-about').textContent = model.about
  $('#s-threads').max = cores
  for (const k in sliders) { $('#s-' + k).value = s[k]; $('#o-' + k).textContent = sliders[k](s[k]) }
  $('#s-multi').checked = s.multi
}

for (const k in sliders) {
  $('#s-' + k).addEventListener('input', ev => {
    s[k] = +ev.target.value
    $('#o-' + k).textContent = sliders[k](s[k])
    save()
    if (k === 'threads' && ready && !busy) driver.postMessage({ type: 'threads', threads: s.threads })
  })
}
$('#s-multi').addEventListener('change', ev => { s.multi = ev.target.checked; save() })
$('#s-model').addEventListener('change', ev => {
  s.model = ev.target.value
  save()
  location.reload()   // a different model means a fresh engine
})
$('#s-reset').addEventListener('click', () => {
  const keep = s.model
  s = { ...defaults, model: keep }
  save()
  fillSettings()
  if (ready && !busy) driver.postMessage({ type: 'threads', threads: s.threads })
})
$('#gear').addEventListener('click', () => dlg.showModal())
dlg.addEventListener('close', () => { if (ready && !busy) driver.postMessage({ type: 'threads', threads: s.threads }) })

updateSend()
start().catch(err => fail(String(err.message || err)))
