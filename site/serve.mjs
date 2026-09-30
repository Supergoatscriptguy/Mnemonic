// local server for the chat page: site\web at /, models\ at /models/, with the
// headers that shared memory needs (vercel.json does the same when deployed).
//   node site\serve.mjs      then open http://localhost:8080
import { createServer } from 'node:http'
import { createReadStream, statSync } from 'node:fs'
import { join, extname, normalize } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('..', import.meta.url))
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.wasm': 'application/wasm' }

createServer((req, res) => {
  const url = decodeURIComponent(new URL(req.url, 'http://x').pathname)
  const rel = normalize(url === '/' ? '/index.html' : url)
  const file = rel.startsWith('\\models\\') ? join(root, rel) : join(root, 'site', 'web', rel)
  let size
  try { size = statSync(file).size } catch { res.writeHead(404).end('not found'); return }
  res.writeHead(200, {
    'Content-Type': types[extname(file)] || 'application/octet-stream',
    'Content-Length': size,
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Embedder-Policy': 'require-corp',
    'Cache-Control': 'no-store'
  })
  createReadStream(file).pipe(res)
}).listen(8080, () => console.log('  http://localhost:8080'))
