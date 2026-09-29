#!/usr/bin/env python3
"""Generate and verify libp2p identities in kubo's config format.

The bootstrappers' PeerIDs are permanent (published in DNS, hardcoded by
clients), so a vaulted key that does not match its published PeerID must be
caught before a deploy, not after the node starts. No kubo binary is needed.

  check <expected-peer-id>   private key (kubo Identity.PrivKey, base64) on stdin
                             exit 0 match, 1 mismatch, 2 malformed key
  derive                     private key on stdin; prints its PeerID
                             exit 0, or 2 malformed key
  generate                   prints {"PeerID": ..., "PrivKey": ...} as JSON

generate always makes Ed25519. check and derive also accept RSA (>= 2048 bits),
the key type of the legacy bootstrap.libp2p.io identities.

Formats (libp2p peer-id spec and kubo):
  PrivKey  = base64(protobuf{ 1: KeyType, 2: data })
               Ed25519(1): data = seed[32] || pubkey[32]
               RSA(0):     data = PKCS#1 RSAPrivateKey DER
  PubProto = protobuf{ 1: KeyType, 2: pubkey }
               Ed25519: pubkey[32];  RSA: PKIX SubjectPublicKeyInfo DER
  PeerID   = base58btc( multihash(PubProto) ): identity multihash when PubProto
             is at most 42 bytes (Ed25519, "12D3..."), else sha2-256 (RSA, "Qm...")
"""
import base64
import hashlib
import json
import sys

from cryptography.exceptions import UnsupportedAlgorithm
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPrivateKey
from cryptography.hazmat.primitives.serialization import (
    Encoding, NoEncryption, PrivateFormat, PublicFormat, load_der_private_key)

RSA = 0
ED25519 = 1
RSA_MIN_BITS = 2048
MAX_INLINE_KEY_LENGTH = 42   # longer public key protobufs are sha2-256 hashed
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


def _encode_varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


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


def peer_id_from_pubproto(pub_proto):
    """PeerID of a serialized libp2p PublicKey protobuf."""
    if len(pub_proto) <= MAX_INLINE_KEY_LENGTH:
        multihash = b"\x00" + _encode_varint(len(pub_proto)) + pub_proto   # identity
    else:
        multihash = b"\x12\x20" + hashlib.sha256(pub_proto).digest()       # sha2-256
    return _b58(multihash)


def _pub_proto(key_type, pub):
    return bytes([0x08, key_type, 0x12]) + _encode_varint(len(pub)) + pub


def _ed25519_pub(data):
    if data is None or len(data) != 64:
        raise ValueError("Ed25519 key data must be 64 bytes (seed || public key)")
    seed, embedded_pub = data[:32], data[32:]
    # Derive the public key from the seed rather than trusting the embedded copy.
    derived_pub = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(
        Encoding.Raw, PublicFormat.Raw)
    if derived_pub != embedded_pub:
        raise ValueError("embedded public key does not match the private seed")
    return derived_pub


def _rsa_pub(data):
    if not data:
        raise ValueError("RSA key data is empty")
    try:
        key = load_der_private_key(data, password=None)
    except (ValueError, TypeError, UnsupportedAlgorithm) as e:
        raise ValueError(f"RSA key data is not a PKCS#1 private key: {e}") from None
    if not isinstance(key, RSAPrivateKey):
        raise ValueError("RSA key data holds a non-RSA key")
    if key.key_size < RSA_MIN_BITS:
        raise ValueError(f"RSA key is {key.key_size} bits, below the {RSA_MIN_BITS}-bit minimum")
    return key.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)


def key_type_of(privkey_b64):
    return _parse_key_proto(base64.b64decode(privkey_b64, validate=True))[0]


def peer_id_from_privkey(privkey_b64):
    key_type, data = _parse_key_proto(base64.b64decode(privkey_b64, validate=True))
    if key_type == ED25519:
        pub = _ed25519_pub(data)
    elif key_type == RSA:
        pub = _rsa_pub(data)
    else:
        raise ValueError(f"key type {key_type} is not Ed25519 or RSA")
    return peer_id_from_pubproto(_pub_proto(key_type, pub))


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
    if len(argv) == 2 and argv[1] == "derive":
        try:
            print(peer_id_from_privkey(sys.stdin.read().strip()))
        except (ValueError, IndexError) as e:
            print(f"malformed key: {e}", file=sys.stderr)
            return 2
        return 0
    if len(argv) == 2 and argv[1] == "generate":
        print(json.dumps(generate()))
        return 0
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
