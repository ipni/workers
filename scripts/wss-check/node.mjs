// Usage: node node.mjs <multiaddr>
//   node node.mjs /dnsaddr/bootstrap.ipni.io/p2p/12D3KooW...
// Dials with Node's WebSocket (TLS verified against Node's CA store) and the
// browser connection gater. See "Browser clients (WSS)" in the top-level README.
import { dialWss } from './client.mjs'

const target = process.argv[2]
if (target == null) {
  console.error('usage: node node.mjs <multiaddr>')
  process.exit(2)
}

try {
  console.log(JSON.stringify(await dialWss(target, { browserGater: true }), null, 2))
} catch (err) {
  console.error('dial failed:', err?.name, err?.message, err?.errors?.map(e => e.message) ?? '')
  process.exitCode = 1
}
