#!/usr/bin/env python3
"""Prove Secrets are encrypted at rest by reading the kine table directly.

A `k3s secrets-encrypt status` line is not proof. Every Secret's CURRENT row
must be encrypted in both value and old_value. Plaintext left in OLDER
revisions is reported, not failed: those rows go away with kine compaction
(newest 1000 revisions kept) plus the VACUUM k3s runs at startup.

Exit codes are distinct so the caller can tell the three cases apart:
    0  every current row is ciphertext (and there is at least one Secret)
    1  at least one current row still holds plaintext - re-annotate and retry
    2  the datastore holds no Secrets at all, as on a fresh cluster
"""

import sqlite3
import sys

DB = "file:/var/lib/rancher/k3s/server/db/state.db?mode=ro"
OK, PLAINTEXT, NO_SECRETS = 0, 1, 2


def encrypted(blob):
    return blob is None or len(blob) == 0 or bytes(blob).startswith(b"k8s:enc:")


def main():
    db = sqlite3.connect(DB, uri=True)
    current = db.execute("""
        SELECT k.name, k.value, k.old_value FROM kine k
        JOIN (SELECT name, MAX(id) AS id FROM kine
              WHERE name LIKE '/registry/secrets/%' GROUP BY name) latest
          ON k.id = latest.id
        WHERE k.deleted = 0""").fetchall()
    bad = [n for n, v, o in current if not (encrypted(v) and encrypted(o))]
    history = db.execute("""
        SELECT value, old_value FROM kine
        WHERE name LIKE '/registry/secrets/%'""").fetchall()
    old_plain = sum(1 for v, o in history if not (encrypted(v) and encrypted(o)))

    print(f"{len(current)} secrets; current rows with plaintext: {len(bad)}; "
          f"older revisions still holding plaintext: {old_plain}")
    for name in bad:
        print("PLAINTEXT", name)

    if bad:
        return PLAINTEXT
    return OK if current else NO_SECRETS


if __name__ == "__main__":
    sys.exit(main())
