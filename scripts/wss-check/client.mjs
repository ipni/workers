// A minimal browser-style libp2p client: WebSockets only, no listeners.
// Shared by node.mjs (run by Node) and browser.mjs (bundled into a page).
import { createLibp2p } from 'libp2p'
import { webSockets } from '@libp2p/websockets'
import { noise } from '@chainsafe/libp2p-noise'
import { yamux } from '@chainsafe/libp2p-yamux'
import { identify } from '@libp2p/identify'
import { multiaddr } from '@multiformats/multiaddr'
import { WebSockets } from '@multiformats/multiaddr-matcher'
import { isPrivate } from '@libp2p/utils'
import { dns } from '@multiformats/dns'
import { dnsJsonOverHttps } from '@multiformats/dns/resolvers'

// Dial `target`, wait for identify, and return what the server reported.
// Throws if the dial fails. In a browser bundle libp2p already applies its
// browser connection gater; `browserGater` reproduces it under Node (no plain
// /ws, no private addresses).
export async function dialWss (target, { browserGater = false, timeoutMs = 20_000 } = {}) {
  const node = await createLibp2p({
    addresses: { listen: [] },
    transports: [webSockets()],
    connectionEncrypters: [noise()],
    streamMuxers: [yamux()],
    services: { identify: identify() },
    // The DoH resolvers js-libp2p uses in browsers, for /dnsaddr. /dns4 names
    // are resolved by the WebSocket implementation itself.
    dns: dns({
      resolvers: {
        '.': [dnsJsonOverHttps('https://cloudflare-dns.com/dns-query'), dnsJsonOverHttps('https://dns.google/resolve')]
      }
    }),
    ...(browserGater ? { connectionGater: { denyDialMultiaddr: (ma) => WebSockets.matches(ma) || isPrivate(ma) } } : {})
  })

  // identify runs by itself on every new connection; calling it again errors.
  const identified = new Promise(resolve => node.addEventListener('peer:identify', evt => resolve(evt.detail), { once: true }))
  try {
    const conn = await node.dial(multiaddr(target), { signal: AbortSignal.timeout(timeoutMs) })
    const id = await identified
    return {
      remoteAddr: conn.remoteAddr.toString(),
      peer: conn.remotePeer.toString(),
      encryption: conn.encryption,
      muxer: conn.multiplexer,
      agentVersion: id.agentVersion,
      listenAddrs: id.listenAddrs.map(String),
      protocols: id.protocols
    }
  } finally {
    await node.stop()
  }
}
