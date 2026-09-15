// Usage: node browser.mjs <multiaddr>
// Runs client.mjs inside headless Chrome: esbuild bundles it for the browser
// (picking up libp2p's browser builds and connection gater), a page served from
// http://127.0.0.1 (a secure context) dials the target, and the result is
// printed. Uses the Chrome at $CHROME, default /usr/bin/google-chrome.
import http from 'node:http'
import * as esbuild from 'esbuild'
import puppeteer from 'puppeteer-core'

const target = process.argv[2]
if (target == null) {
  console.error('usage: node browser.mjs <multiaddr>')
  process.exit(2)
}

const bundle = await esbuild.build({
  stdin: {
    contents: "import { dialWss } from './client.mjs'; window.dialWss = dialWss",
    resolveDir: import.meta.dirname
  },
  bundle: true,
  format: 'esm',
  platform: 'browser',
  write: false,
  logLevel: 'error'
})

const server = http.createServer((req, res) => {
  if (req.url === '/client.js') {
    res.writeHead(200, { 'content-type': 'text/javascript' })
    res.end(bundle.outputFiles[0].contents)
  } else {
    res.writeHead(200, { 'content-type': 'text/html' })
    res.end('<!doctype html><script type="module" src="/client.js"></script>')
  }
})
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME ?? '/usr/bin/google-chrome',
  headless: true
})
try {
  const page = await browser.newPage()
  page.on('console', msg => console.error('[page]', msg.text()))
  await page.goto(`http://127.0.0.1:${server.address().port}/`)
  await page.waitForFunction(() => typeof window.dialWss === 'function')
  const result = await page.evaluate(async (ma) => {
    try {
      return { ok: true, userAgent: navigator.userAgent, ...(await window.dialWss(ma)) }
    } catch (err) {
      return { ok: false, error: `${err?.name}: ${err?.message}`, errors: err?.errors?.map(e => e.message) }
    }
  }, target)
  console.log(JSON.stringify(result, null, 2))
  process.exitCode = result.ok ? 0 : 1
} finally {
  await browser.close()
  server.close()
}
