#!/usr/bin/env python3
"""Generate and verify libp2p Ed25519 identities in kubo's config format.

The bootstrappers' PeerIDs are permanent (published in DNS, hardcoded by
clients), so a vaulted key that does not match its published PeerID must be
caught before a deploy, not after the node starts. No kubo binary is needed.

  check <expected-peer-id>   private key (kubo Identity.PrivKey, base64) on stdin
                             exit 0 match, 1 mismatch, 2 malformed key
  generate                   prints {"PeerID": ..., "PrivKey": ...} as JSON

Formats (libp2p peer-id spec and kubo):
  PrivKey  = base64(protobuf{ 1: KeyType=Ed25519(1), 2: seed[32] || pubkey[32] })
  PeerID   = base58btc( identity-multihash( protobuf{ 1: Ed25519, 2: pubkey[32] } ) )
"""
import base64
import json
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat, PublicFormat

ED25519 = 1
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def _varint(buf, i):
    shift = value = 0
    while True:
        b = buf[i]
        i += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, i
        shift += 7


def _parse_key_proto(raw):
    """Return (key_type, data) from a libp2p crypto.pb PrivateKey/PublicKey."""
    fields, i = {}, 0
    while i < len(raw):
        tag, i = _varint(raw, i)
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            fields[field], i = _varint(raw, i)
        elif wire == 2:
            n, i = _varint(raw, i)
            fields[field], i = raw[i:i + n], i + n
        else:
            raise ValueError(f"unexpected protobuf wire type {wire}")
    return fields.get(1), fields.get(2)


def _b58(data):
    n = int.from_bytes(data, "big")
    out = ""
    while n:
        n, r = divmod(n, 58)
        out = B58[r] + out
    return "1" * (len(data) - len(data.lstrip(b"\0"))) + out


def peer_id_from_privkey(privkey_b64):
    key_type, data = _parse_key_proto(base64.b64decode(privkey_b64, validate=True))
    if key_type != ED25519:
        raise ValueError(f"key type {key_type} is not Ed25519")
    if data is None or len(data) != 64:
        raise ValueError("Ed25519 key data must be 64 bytes (seed || public key)")
    seed, embedded_pub = data[:32], data[32:]
    # Derive the public key from the seed rather than trusting the embedded copy.
    derived_pub = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(
        Encoding.Raw, PublicFormat.Raw)
    if derived_pub != embedded_pub:
        raise ValueError("embedded public key does not match the private seed")
    pub_proto = bytes([0x08, ED25519, 0x12, 0x20]) + derived_pub
    return _b58(bytes([0x00, len(pub_proto)]) + pub_proto)   # identity multihash


def generate():
    key = Ed25519PrivateKey.generate()
    seed = key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    pub = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    privkey_b64 = base64.b64encode(bytes([0x08, ED25519, 0x12, 0x40]) + seed + pub).decode()
    return {"PeerID": peer_id_from_privkey(privkey_b64), "PrivKey": privkey_b64}


def main(argv):
    if len(argv) == 3 and argv[1] == "check":
        try:
            derived = peer_id_from_privkey(sys.stdin.read().strip())
        except (ValueError, IndexError) as e:
            print(f"malformed key: {e}")
            return 2
        if derived != argv[2]:
            print(f"mismatch: key derives {derived}, expected {argv[2]}")
            return 1
        print(f"ok {derived}")
        return 0
    if len(argv) == 2 and argv[1] == "generate":
        print(json.dumps(generate()))
        return 0
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
