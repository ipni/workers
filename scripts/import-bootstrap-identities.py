#!/usr/bin/env python3
"""Move the bootstrappers onto the legacy bootstrap.libp2p.io identities.

  ./scripts/import-bootstrap-identities.py <keys-file> [--dry-run]

The keys file holds four kubo `"Identity": { "PeerID": ..., "PrivKey": ... },`
fragments (not valid JSON as a whole). Anything after them is ignored: the file
ends with a fifth key whose stated public key does not match it, and it is not
deployed. Keys are matched to instances by the PeerID they DERIVE, never by
position, and each must also match the PeerID its fragment states.

Writes, only after every key has derived its expected PeerID:
  host_vars/<box>/vault.yml       vault_bootstrap_privkey (replaced) and, on boxes
                                  with a second instance, vault_bootstrap_b_privkey
                                  and vault_bootstrap_b_api_token
  host_vars/<box>/bootstrap.yml   bootstrap_peer_id, bootstrap_legacy_name and
                                  bootstrap_extra_instances

Before any write, each box's current ENCRYPTED vault.yml and bootstrap.yml are
copied to ~/ipni-vault-backup/<UTC timestamp>/<box>/. The old vaulted keys exist
nowhere else, so that copy is the only way back.

Output is limited to PeerIDs, key types and detected formats: no private key,
decrypted vault or keys-file line is ever printed. Plaintext only exists in a
0700 temp dir that is shredded on exit.
"""
import argparse
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import libp2p_identity as L  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

# PeerID -> (box, instance, legacy bootstrap.libp2p.io name)
PLACEMENT = {
    "QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt": ("sing-1", "bootstrap", "sg1"),
    "QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb": ("lith-1", "bootstrap", "am6"),
    "QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa": ("chic-1", "bootstrap", "ny5"),
    "QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN": ("chic-1", "bootstrap-b", "sv15"),
}
BOXES = ["sing-1", "lith-1", "chic-1"]
KEY_TYPES = {L.RSA: "RSA", L.ED25519: "Ed25519"}


class Abort(Exception):
    pass


def parse_keys(path):
    """[(PrivKey base64, source, PeerID the fragment states)] for the four fragments."""
    text = open(path).read()
    fragments = re.findall(r'"Identity"\s*:\s*\{\s*"PeerID"\s*:\s*"([^"]+)"\s*,\s*"PrivKey"\s*:\s*"([^"]+)"', text)
    if len(fragments) != 4:
        raise Abort(f"expected 4 Identity fragments, found {len(fragments)}")
    return [(privkey, f"fragment {n}", claimed) for n, (claimed, privkey) in enumerate(fragments, 1)]


def verify(keys):
    """{PeerID: PrivKey}; every key must derive a placed PeerID matching its claim."""
    found, problems = {}, []
    for privkey, source, claimed in keys:
        try:
            derived = L.peer_id_from_privkey(privkey)
            kind = KEY_TYPES[L.key_type_of(privkey)]
        except (ValueError, IndexError) as e:
            problems.append(f"{source}: malformed key ({e})")
            continue
        where = PLACEMENT.get(derived)
        label = f"{where[0]} {where[1]} ({where[2]})" if where else "NOT PLACED"
        print(f"  {source}: {kind} -> {derived}  {label}")
        if claimed and claimed != derived:
            problems.append(f"{source}: derives {derived} but the file gives {claimed}")
        if not where:
            problems.append(f"{source}: {derived} is not an expected PeerID")
        if derived in found:
            problems.append(f"{source}: {derived} appears twice")
        found[derived] = privkey
    missing = [pid for pid in PLACEMENT if pid not in found]
    for pid in missing:
        problems.append(f"no key derives {pid} ({' '.join(PLACEMENT[pid])})")
    if problems:
        raise Abort("key check failed:\n  " + "\n  ".join(problems))
    return found


class Vault:
    def __init__(self, work):
        self.work = work

    def run(self, *args, capture=False):
        err = os.path.join(self.work, "vault.err")
        with open(err, "w") as ferr:
            r = subprocess.run(["ansible-vault", *args], cwd=ROOT, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE if capture else subprocess.DEVNULL, stderr=ferr)
        if r.returncode:
            raise Abort(f"ansible-vault {args[0]} failed:\n{open(err).read()}")
        return r.stdout


def set_var(text, name, value, comment):
    """Replace a one-line `name: "..."` in vault YAML, or append it with a comment."""
    line = f'{name}: "{value}"'
    pattern = re.compile(rf"^{re.escape(name)}:.*$", re.M)
    if len(pattern.findall(text)) > 1:
        raise Abort(f"{name} appears more than once in a vault")
    if pattern.search(text):
        return pattern.sub(lambda _: line, text)
    return text.rstrip("\n") + "\n" + comment + line + "\n"


def public_yaml(box, primary, extra):
    pid, legacy = primary
    out = [
        "---",
        "# libp2p identity of this box's bootstrapper: the legacy",
        f"# {legacy}.bootstrap.libp2p.io identity. Public: it appears in every /dnsaddr",
        "# record and client bootstrap list, so it must never change. The private key",
        "# is vault_bootstrap_privkey in vault.yml next to this file.",
        f"bootstrap_peer_id: {pid}",
        f"bootstrap_legacy_name: {legacy}",
    ]
    if extra:
        out += [
            "",
            "# Further kubo instances on this box, each with its own legacy identity.",
            "# Ports come from bootstrap_instance_table (group_vars/ipfs_nodes); the",
            "# key is vault_<name with - as _>_privkey in vault.yml.",
            "bootstrap_extra_instances:",
        ]
        for name, pid, legacy in extra:
            out.append(f"  - {{name: {name}, peer_id: {pid}, legacy_name: {legacy}}}")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("keys_file")
    ap.add_argument("--dry-run", action="store_true", help="verify the keys, write nothing")
    args = ap.parse_args()
    os.chdir(ROOT)
    keys_file = os.path.abspath(args.keys_file)

    if subprocess.run(["git", "check-ignore", "-q", keys_file]).returncode != 0:
        raise Abort(f"{args.keys_file} is not ignored by git; refusing to read private keys from it")

    print("keys:")
    found = verify(parse_keys(keys_file))
    print(f"all {len(found)} keys derive their expected PeerIDs")

    plan = {box: {"primary": None, "extra": []} for box in BOXES}
    for pid, (box, instance, legacy) in PLACEMENT.items():
        if instance == "bootstrap":
            plan[box]["primary"] = (pid, legacy)
        else:
            plan[box]["extra"].append((instance, pid, legacy))
    for box in BOXES:
        extra = ", ".join(f"{i} {p}" for i, p, _ in plan[box]["extra"])
        print(f"  {box}: bootstrap {plan[box]['primary'][0]}" + (f"; {extra}" if extra else ""))
    if args.dry_run:
        print("dry run: nothing written")
        return 0

    for box in BOXES:
        for f in ("vault.yml", "bootstrap.yml"):
            if not os.path.isfile(os.path.join("host_vars", box, f)):
                raise Abort(f"host_vars/{box}/{f} is missing")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = os.path.expanduser(os.path.join("~/ipni-vault-backup", stamp))
    old_umask = os.umask(0o077)
    try:
        for box in BOXES:
            os.makedirs(os.path.join(backup, box), mode=0o700)
            for f in ("vault.yml", "bootstrap.yml"):
                shutil.copy2(os.path.join("host_vars", box, f), os.path.join(backup, box, f))
        os.chmod(os.path.dirname(backup), 0o700)
        os.chmod(backup, 0o700)
    except OSError as e:
        raise Abort(f"backup to {backup} failed, nothing written: {e}")
    print(f"backed up the encrypted vaults and bootstrap.yml to {backup}")

    work = tempfile.mkdtemp()
    try:
        vault = Vault(work)
        staged = {}
        for box in BOXES:
            plain = os.path.join(work, f"{box}.yml")
            vault.run("decrypt", "--output", plain, os.path.join("host_vars", box, "vault.yml"))
            text = open(plain).read()
            before = yaml.safe_load(text) or {}
            pid, _ = plan[box]["primary"]
            text = set_var(text, "vault_bootstrap_privkey", found[pid], "")
            expect = {"vault_bootstrap_privkey": pid}
            for instance, ipid, legacy in plan[box]["extra"]:
                var = "vault_" + instance.replace("-", "_")
                text = set_var(text, f"{var}_privkey", found[ipid],
                               f"# {var}_privkey - kubo Identity.PrivKey of {instance}, the legacy\n"
                               f"#   {legacy}.bootstrap.libp2p.io identity ({ipid}).\n")
                if not before.get(f"{var}_api_token"):
                    text = set_var(text, f"{var}_api_token", secrets.token_urlsafe(32),
                                   f"# {var}_api_token - bearer token for {instance}'s kubo RPC API.\n")
                expect[f"{var}_privkey"] = ipid
            after = yaml.safe_load(text)
            untouched = {k for k in before if k not in expect}
            if any(after.get(k) != before[k] for k in untouched):
                raise Abort(f"{box}: editing the vault changed variables it should not have")
            for var, want in expect.items():
                if L.peer_id_from_privkey(after[var]) != want:
                    raise Abort(f"{box}: staged {var} does not derive {want}")
            open(plain, "w").write(text)
            enc = os.path.join(work, f"{box}.vault.yml")
            vault.run("encrypt", "--output", enc, plain)
            staged[box] = (enc, expect)

        # Everything is staged and encrypted: swap it all in, then prove it.
        for box in BOXES:
            enc, _ = staged[box]
            shutil.copyfile(enc, os.path.join("host_vars", box, "vault.yml"))
            with open(os.path.join("host_vars", box, "bootstrap.yml"), "w") as f:
                f.write(public_yaml(box, plan[box]["primary"], plan[box]["extra"]))
        for box in BOXES:
            _, expect = staged[box]
            loaded = yaml.safe_load(vault.run("view", os.path.join("host_vars", box, "vault.yml"), capture=True))
            for var, want in expect.items():
                if L.peer_id_from_privkey(loaded[var]) != want:
                    raise Abort(f"{box}: round trip: {var} does not derive {want}")
            if "vault_bootstrap_api_token" not in loaded:
                raise Abort(f"{box}: round trip: vault_bootstrap_api_token is gone")
            print(f"  {box}: vault round trip ok ({', '.join(f'{v} -> {p}' for v, p in expect.items())})")
    except BaseException:
        if "staged" in locals() and staged:
            for box in BOXES:
                for f in ("vault.yml", "bootstrap.yml"):
                    shutil.copy2(os.path.join(backup, box, f), os.path.join("host_vars", box, f))
            print(f"failed: restored every box from {backup}", file=sys.stderr)
        raise
    finally:
        for name in os.listdir(work):
            subprocess.run(["shred", "-u", os.path.join(work, name)], check=False)
        shutil.rmtree(work, ignore_errors=True)
        os.umask(old_umask)

    print(f"done. Store the new vaults and {backup} in the operators' secret store.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Abort as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
