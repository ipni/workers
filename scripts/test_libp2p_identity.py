#!/usr/bin/env python3
"""Tests for libp2p_identity.py: python3 -m unittest scripts/test_libp2p_identity.py

The real proof for RSA is that the legacy bootstrap.libp2p.io keys derive their
published PeerIDs (scripts/import-bootstrap-identities.py checks that); these
tests pin the derivation against an independent construction and guard the
Ed25519 output that the existing PeerIDs depend on.
"""
import base64
import hashlib
import io
import os
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import libp2p_identity as L  # noqa: E402

from cryptography.hazmat.primitives.asymmetric import rsa  # noqa: E402
from cryptography.hazmat.primitives.serialization import (  # noqa: E402
    Encoding, NoEncryption, PrivateFormat, PublicFormat)

# A fixed Ed25519 key (seed 0x00..0x1f) and the PeerID the pre-RSA code derived
# for it, so a refactor cannot silently change existing Ed25519 PeerIDs.
FIXED_SEED = bytes(range(32))
FIXED_PEER_ID = "12D3KooWA4Xop1JaT3MHxwYMkCepYsv4iPVopMXwCz5iHYdBfeSB"


def _ed25519_privkey(seed):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    pub = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(
        Encoding.Raw, PublicFormat.Raw)
    return base64.b64encode(bytes([0x08, 0x01, 0x12, 0x40]) + seed + pub).decode()


def _rsa_privkey(bits):
    key = rsa.generate_private_key(public_exponent=65537, key_size=bits)
    der = key.private_bytes(Encoding.DER, PrivateFormat.TraditionalOpenSSL, NoEncryption())
    proto = b"\x08\x00\x12" + L._encode_varint(len(der)) + der
    return key, base64.b64encode(proto).decode()


def _run(argv, stdin):
    out, err = io.StringIO(), io.StringIO()
    with mock.patch("sys.stdin", io.StringIO(stdin)), redirect_stdout(out), redirect_stderr(err):
        code = L.main(["libp2p_identity.py"] + argv)
    return code, out.getvalue()


class Ed25519(unittest.TestCase):
    def test_round_trip(self):
        identity = L.generate()
        self.assertTrue(identity["PeerID"].startswith("12D3KooW"))
        self.assertEqual(L.peer_id_from_privkey(identity["PrivKey"]), identity["PeerID"])

    def test_existing_output_unchanged(self):
        self.assertEqual(L.peer_id_from_privkey(_ed25519_privkey(FIXED_SEED)), FIXED_PEER_ID)

    def test_tampered_public_key_rejected(self):
        raw = bytearray(base64.b64decode(_ed25519_privkey(FIXED_SEED)))
        raw[-1] ^= 1
        with self.assertRaises(ValueError):
            L.peer_id_from_privkey(base64.b64encode(bytes(raw)).decode())


class RSA(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key, cls.privkey = _rsa_privkey(2048)

    def test_peer_id_matches_independent_construction(self):
        spki = self.key.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
        self.assertGreater(len(spki), 127)   # needs a two-byte varint length
        pub_proto = b"\x08\x00\x12" + bytes([len(spki) & 0x7F | 0x80, len(spki) >> 7]) + spki
        expected = L._b58(b"\x12\x20" + hashlib.sha256(pub_proto).digest())
        derived = L.peer_id_from_privkey(self.privkey)
        self.assertTrue(derived.startswith("Qm"))
        self.assertEqual(derived, expected)

    def test_short_key_rejected(self):
        _, weak = _rsa_privkey(1024)
        with self.assertRaisesRegex(ValueError, "1024 bits"):
            L.peer_id_from_privkey(weak)

    def test_garbage_key_data_rejected(self):
        with self.assertRaises(ValueError):
            L.peer_id_from_privkey(base64.b64encode(b"\x08\x00\x12\x03abc").decode())

    def test_unknown_key_type_rejected(self):
        with self.assertRaisesRegex(ValueError, "key type 2"):
            L.peer_id_from_privkey(base64.b64encode(b"\x08\x02\x12\x01\x00").decode())


class CLI(unittest.TestCase):
    def test_exit_codes(self):
        _, rsa_key = _rsa_privkey(2048)
        rsa_id = L.peer_id_from_privkey(rsa_key)
        ed_key = _ed25519_privkey(FIXED_SEED)
        self.assertEqual(_run(["check", FIXED_PEER_ID], ed_key)[0], 0)
        self.assertEqual(_run(["check", rsa_id], rsa_key)[0], 0)
        self.assertEqual(_run(["check", FIXED_PEER_ID], rsa_key)[0], 1)
        self.assertEqual(_run(["check", FIXED_PEER_ID], "not base64!")[0], 2)
        _, weak = _rsa_privkey(1024)
        self.assertEqual(_run(["check", FIXED_PEER_ID], weak)[0], 2)
        self.assertEqual(_run(["derive"], rsa_key), (0, rsa_id + "\n"))
        self.assertEqual(_run(["derive"], "AAAA")[0], 2)
        self.assertEqual(_run(["bogus"], "")[0], 64)


if __name__ == "__main__":
    unittest.main()
