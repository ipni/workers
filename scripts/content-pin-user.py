#!/usr/bin/env python3
"""Manage users of the content cluster's remote pinning API (pin.ipni.io).

  ./scripts/content-pin-user.py list
  ./scripts/content-pin-user.py add <user>      generate a password into the vault
  ./scripts/content-pin-user.py remove <user>   revoke: their tokens stop working
  ./scripts/content-pin-user.py token <user> [--box <box>]

Users live in vault_content_pin_users in group_vars/ipfs_nodes/vault.yml, as
{name: password}. add and remove only edit the vault: run content.yml for the
boxes to pick the change up (one box at a time, each restarting its content
node once). token asks a box's live API for the user's bearer token, so the
user must already be deployed; the token is what the user is given:

  ipfs pin remote service add ipni https://pin.ipni.io:9443 <token>
  ipfs pin remote add --service=ipni --name=<name> <cid>

A token is signed with the user's password and does not expire. It stops
working when the user is removed (or re-added with a new password).

Passwords are never printed. Before every write the encrypted vault is copied to
~/ipni-vault-backup/<UTC timestamp>/group/; plaintext only exists in a 0700
temp dir that is shredded on exit.
"""
import argparse
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

import yaml

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
VAULT = "group_vars/ipfs_nodes/vault.yml"
VAR = "vault_content_pin_users"
NAME_RE = r"[A-Za-z0-9_.-]+"


class Abort(Exception):
    pass


def ansible_vault(work, *args, capture=False):
    err = os.path.join(work, "vault.err")
    with open(err, "w") as ferr:
        r = subprocess.run(["ansible-vault", *args], cwd=ROOT, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE if capture else subprocess.DEVNULL, stderr=ferr)
    if r.returncode:
        raise Abort(f"ansible-vault {args[0]} failed:\n{open(err).read()}")
    return r.stdout


def read_users(work):
    return (yaml.safe_load(ansible_vault(work, "view", VAULT, capture=True)) or {}).get(VAR) or {}


def write_users(work, users):
    """Replace the VAR block in the vault, keeping every other line as it is."""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = os.path.expanduser(f"~/ipni-vault-backup/{stamp}/group")
    os.makedirs(backup, mode=0o700)
    shutil.copy2(os.path.join(ROOT, VAULT), os.path.join(backup, "vault.yml"))

    plain = os.path.join(work, "vault.yml")
    ansible_vault(work, "decrypt", "--output", plain, VAULT)
    text = open(plain).read()
    before = yaml.safe_load(text) or {}
    # Drop any existing block: the key line and its indented entries.
    text = re.sub(rf"^{VAR}:.*\n(?:[ \t]+.*\n)*", "", text, flags=re.M)
    block = (f"# {VAR} - users of the remote pinning API (pin.ipni.io), name: password.\n"
             "#   Managed by scripts/content-pin-user.py.\n" if f"# {VAR}" not in text else "")
    block += f"{VAR}:\n" + "".join(f'  {name}: "{pw}"\n' for name, pw in sorted(users.items())) if users else f"{VAR}: {{}}\n"
    text = text.rstrip("\n") + "\n" + block
    after = yaml.safe_load(text)
    if any(after.get(k) != v for k, v in before.items() if k != VAR) or (after.get(VAR) or {}) != users:
        raise Abort("editing the vault would change other variables; nothing written")
    open(plain, "w").write(text)
    enc = os.path.join(work, "vault.enc")
    ansible_vault(work, "encrypt", "--output", enc, plain)
    shutil.copyfile(enc, os.path.join(ROOT, VAULT))
    if read_users(work) != users:
        shutil.copy2(os.path.join(backup, "vault.yml"), os.path.join(ROOT, VAULT))
        raise Abort(f"round trip failed; restored {VAULT} from {backup}")
    return backup


def box_ip(box):
    hosts = yaml.safe_load(open(os.path.join(ROOT, "inventory/hosts.yml")))["all"]["children"]["ipfs_nodes"]["hosts"]
    if box not in hosts:
        raise Abort(f"{box} is not in inventory/hosts.yml")
    return hosts[box]["ansible_host"]


def defaults():
    return yaml.safe_load(open(os.path.join(ROOT, "roles/content/defaults/main.yml")))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["list", "add", "remove", "token"])
    ap.add_argument("user", nargs="?")
    ap.add_argument("--box", default="sing-1", help="box whose API issues the token (default sing-1)")
    args = ap.parse_args()
    if args.action != "list" and not (args.user and re.fullmatch(NAME_RE, args.user)):
        raise Abort(f"a user name ({NAME_RE}) is required")

    old_umask = os.umask(0o077)
    work = tempfile.mkdtemp()
    try:
        users = read_users(work)
        if args.action == "list":
            print("\n".join(sorted(users)) or "(no users)")
        elif args.action == "add":
            if args.user in users:
                raise Abort(f"{args.user} already exists; remove it first to issue a new password")
            users[args.user] = secrets.token_urlsafe(32)
            backup = write_users(work, users)
            print(f"added {args.user} (previous vault in {backup}).\n"
                  "Next: ansible-playbook content.yml, then "
                  f"./scripts/content-pin-user.py token {args.user}")
        elif args.action == "remove":
            if args.user not in users:
                raise Abort(f"no such user: {args.user}")
            del users[args.user]
            if not users:
                print("note: no users left; content.yml refuses to deploy the pinning API without one",
                      file=sys.stderr)
            backup = write_users(work, users)
            print(f"removed {args.user} (previous vault in {backup}). "
                  "Their tokens stop working once content.yml has run on every box.")
        else:
            if args.user not in users:
                raise Abort(f"no such user: {args.user}")
            d = defaults()
            host, port = d["content_pin_hostname"], d["content_pin_port"]
            r = subprocess.run(
                ["curl", "-sS", "--fail-with-body", "--max-time", "30", "-X", "POST", "-K", "-",
                 "--resolve", f"{host}:{port}:{box_ip(args.box)}", f"https://{host}:{port}/token"],
                input=f'user = "{args.user}:{users[args.user]}"', capture_output=True, text=True)
            if r.returncode:
                raise Abort(f"{args.box} refused the token request: {(r.stdout + r.stderr).strip()[:300]}")
            print(json.loads(r.stdout)["token"])
    finally:
        for name in os.listdir(work):
            subprocess.run(["shred", "-u", os.path.join(work, name)], check=False)
        shutil.rmtree(work, ignore_errors=True)
        os.umask(old_umask)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Abort as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
