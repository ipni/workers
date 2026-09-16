#!/usr/bin/env bash
# Show what a box's content cluster peer holds beside roles/content/vars/pinset.yml:
# pending entries first, then entries with a CID the cluster does not hold, then
# pinned entries with their per-peer status and DNSLink drift, then the raw
# `ipfs-cluster-ctl pin ls` and `status`. Read-only: it pins nothing.
#
# Usage:  ./scripts/content-pinset.sh <box> [local-port]
#         ./scripts/content-pinset.sh chic-1
#
# Opens an SSH tunnel to the box's k3s API server (as scripts/kubectl-tunnel.sh
# does) and closes it on exit. The pinset is the same on every box, so any box
# shows the whole cluster; per-peer status covers all peers.
set -euo pipefail

cd "$(dirname "$0")/.."

HOST="${1:-}"
# Not 6443, so it can run while a kubectl-tunnel.sh tunnel is up.
PORT="${2:-16443}"

if [[ -z "$HOST" ]]; then
  # Glob loop rather than `ls | xargs`: the shell already has the names, and
  # parsing ls output breaks on anything unusual in them (shellcheck SC2011).
  boxes=()
  for kubeconfig in kubeconfigs/*.yaml; do
    [[ -e "$kubeconfig" ]] || continue
    kubeconfig=${kubeconfig##*/}
    boxes+=("${kubeconfig%.yaml}")
  done
  echo "usage: $0 <box> [local-port]" >&2
  echo "boxes: ${boxes[*]}" >&2
  exit 1
fi

KUBECONFIG_SRC="kubeconfigs/${HOST}.yaml"
[[ -f "$KUBECONFIG_SRC" ]] || { echo "error: no kubeconfig for '$HOST'" >&2; exit 1; }

PINSET="roles/content/vars/pinset.yml"
[[ -f "$PINSET" ]] || echo "warning: $PINSET does not exist; showing the cluster's pins only" >&2

if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
  echo "Local port ${PORT} is already in use. Pick another port:  $0 ${HOST} <local-port>" >&2
  exit 1
fi

WORK=$(mktemp -d)
SOCK="${WORK}/ssh.sock"
IP="" ADMIN=""
cleanup() {
  if [[ -S "$SOCK" ]]; then ssh -S "$SOCK" -O exit "${ADMIN}@${IP}" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ansible-inventory refuses to run when it inherits a non-blocking stderr
# (common when this script's output is piped), so give it a plain file.
if ! HOSTVARS=$(ansible-inventory --host "$HOST" 2>"${WORK}/inventory.err" </dev/null); then
  echo "error: inventory lookup for '$HOST' failed:" >&2
  cat "${WORK}/inventory.err" >&2
  exit 1
fi
read -r IP ADMIN < <(python3 -c '
import json, sys
v = json.loads(sys.argv[1])
print(v["ansible_host"], v.get("admin_user", "ipni"))
' "$HOSTVARS")

# Working kubeconfig pointed at the local end of the tunnel, private to this run.
sed "s|127.0.0.1:6443|127.0.0.1:${PORT}|" "$KUBECONFIG_SRC" > "${WORK}/kubeconfig"
chmod 600 "${WORK}/kubeconfig"

echo "Opening tunnel to ${HOST} (${IP}) on local port ${PORT}..." >&2
# A control socket, so exactly this tunnel is closed on exit.
ssh -f -N -M -S "$SOCK" -o ExitOnForwardFailure=yes -L "${PORT}:127.0.0.1:6443" "${ADMIN}@${IP}"

k() { kubectl --kubeconfig "${WORK}/kubeconfig" --namespace=content exec deploy/content "$@"; }
ctl() { k -c cluster -- ipfs-cluster-ctl --host /ip4/127.0.0.1/tcp/9094 "$@"; }

ctl pin ls > "${WORK}/pinls.txt"
ctl status > "${WORK}/status.txt"

# Names of dnslink entries (the default source) and every CID in view, from the
# pinset and the cluster.
python3 - "$PINSET" "${WORK}" <<'PY'
import os, sys, yaml
path, work = sys.argv[1], sys.argv[2]
p = (yaml.safe_load(open(path)) if os.path.exists(path) else None) or {}
names, cids = [], []
for e in p.get("pinset") or []:
    if isinstance(e, dict) and e.get("name"):
        if (e.get("source") or "dnslink") == "dnslink":
            names.append(str(e["name"]))
        if e.get("cid"):
            cids.append(str(e["cid"]).strip())
for line in open(os.path.join(work, "pinls.txt")):
    if line.strip():
        cids.append(line.split(" | ")[0].strip())
open(os.path.join(work, "dnslink-names"), "w").write("\n".join(names))
open(os.path.join(work, "cids"), "w").write("\n".join(dict.fromkeys(cids)))
PY

# One exec each: "<name>\t<resolved path or error>", then the resolved CIDs
# and every other CID in CIDv1 base32 ("invalid" for a non-CID), one per line.
# shellcheck disable=SC2046
k -c kubo -- sh -c '
  for n; do
    r=$(ipfs --api=/ip4/127.0.0.1/tcp/5021 --timeout=30s resolve -r "/ipns/$n" 2>&1) || r="error: $r"
    printf "%s\t%s\n" "$n" "$(echo "$r" | tr "\n" " ")"
  done' sh $(cat "${WORK}/dnslink-names") > "${WORK}/dnslink.tsv"
sed -n 's|^[^\t]*\t/ipfs/\([^/ ]*\) *$|\1|p' "${WORK}/dnslink.tsv" >> "${WORK}/cids"
# shellcheck disable=SC2046
k -c kubo -- sh -c '
  for c; do
    ipfs --api=/ip4/127.0.0.1/tcp/5021 cid format -v 1 -b base32 "$c" 2>/dev/null || echo invalid
  done' sh $(cat "${WORK}/cids") > "${WORK}/cids-v1"

python3 - "$HOST" "$PINSET" "${WORK}" <<'PY'
import os, re, sys, yaml
host, path, work = sys.argv[1:4]
rd = lambda f: open(os.path.join(work, f)).read()

p = (yaml.safe_load(open(path)) if os.path.exists(path) else None) or {}
defaults = yaml.safe_load(open("roles/content/defaults/main.yml")) or {}
exclude = set(defaults.get("content_pin_exclude") or [])
v1 = dict(zip(rd("cids").split("\n"), rd("cids-v1").split("\n")))
norm = lambda c: v1.get(c, c)

pins = {}   # v1 CID -> (cid as listed, name)
for line in rd("pinls.txt").splitlines():
    if line.strip():
        f = [x.strip() for x in line.split(" | ")]
        pins[norm(f[0])] = (f[0], f[1] if len(f) > 1 else "")

status, cur = {}, None   # v1 CID -> {peer: state}
for line in rd("status.txt").splitlines():
    if not line.strip():
        continue
    if not line[0].isspace():
        cur = norm(line.split(" | ")[0].rstrip(":").strip())
        status[cur] = {}
    elif cur and (m := re.match(r"\s+>\s+(\S+)\s+:\s+([A-Z_]+)", line)):
        status[cur][m.group(1)] = m.group(2)

dnslink = {}
for line in rd("dnslink.tsv").splitlines():
    n, _, r = line.partition("\t")
    dnslink[n] = r.strip()

def state(key):
    s = status.get(key, {})
    ok = sum(1 for v in s.values() if v == "PINNED")
    other = sorted(f"{k}={v}" for k, v in s.items() if v != "PINNED")
    return f"PINNED {ok}/{len(s)}" + (f" ({', '.join(other)})" if other else "")

def nm(e):
    return str(e.get("name") or "") if isinstance(e, dict) else str(e)

entries = [e for e in (p.get("pinset") or []) if isinstance(e, dict) and e.get("name")]
with_cid = [e for e in entries if e.get("cid") and nm(e) not in exclude]
pinnable = {nm(e) for e in with_cid}
pending = [(nm(e), "in pinset without a cid") for e in entries if not e.get("cid") and nm(e) not in exclude]
pending += [(nm(e), "recover_from_upstream") for e in (p.get("recover_from_upstream") or [])
            if nm(e) and nm(e) not in pinnable and nm(e) not in exclude]
unclassified = [nm(e) or str(e.get("cid")) for e in (p.get("found_upstream_unclassified") or [])]

used, missing, pinned = set(), [], []
for e in with_cid:
    name, cid, src = nm(e), str(e["cid"]).strip(), e.get("source") or "dnslink"
    key = norm(cid)
    used.add(key)
    note = ""
    if src == "dnslink":
        r = dnslink.get(name, "")
        if r.startswith("/ipfs/") and "/" not in r[6:]:
            rkey = norm(r[6:])
            if rkey != key:
                used.add(rkey)
                note = f"DRIFT: DNSLink now {r[6:]} ({state(rkey) if rkey in pins else 'NOT pinned'})"
        else:
            note = f"DNSLink: {r or 'not resolved'}"
    (pinned if key in pins else missing).append((name, src, cid, state(key) if key in pins else "", note))

print(f"\ncontent pinset on {host}: {path} (resolved_on {p.get('resolved_on', '?')}), "
      f"cluster holds {len(pins)} pins\n")
print(f"PENDING ({len(pending)}): no CID yet. Once pinset.yml has one: ansible-playbook content.yml")
for n, why in pending:
    print(f"  {n:<26} {why}")
print(f"\nNOT PINNED ({len(missing)}): has a CID the cluster does not hold "
      "(size gate, unretrievable, or content.yml not re-run since)")
for n, src, cid, _, note in missing:
    print(f"  {n:<26} {src:<16} {cid}" + (f"\n  {'':<26} {note}" if note else ""))
if unclassified:
    print(f"\nUNCLASSIFIED ({len(unclassified)}): found upstream, not pinned until moved into pinset")
    for n in unclassified[:10]:
        print(f"  {n}")
    if len(unclassified) > 10:
        print(f"  ... and {len(unclassified) - 10} more in {path}")
if exclude & {nm(e) for e in entries}:
    print(f"\nEXCLUDED (content_pin_exclude): {', '.join(sorted(exclude & {nm(e) for e in entries}))}")
print(f"\nPINNED ({len(pinned)})")
for n, src, cid, st, note in pinned:
    print(f"  {n:<26} {src:<16} {cid}  {st}" + (f"\n  {'':<26} {note}" if note else ""))
extra = [(c, name) for key, (c, name) in pins.items() if key not in used]
if extra:
    print(f"\nCLUSTER PINS NOT IN PINSET.YML ({len(extra)}): e.g. earlier DNSLink snapshots")
    for c, name in extra:
        print(f"  {name:<26} {c}  {state(norm(c))}")
print("\n--- ipfs-cluster-ctl pin ls")
print(rd("pinls.txt").rstrip())
print("\n--- ipfs-cluster-ctl status")
print(rd("status.txt").rstrip())
PY
