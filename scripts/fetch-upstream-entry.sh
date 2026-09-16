#!/usr/bin/env bash
# Fetch one upstream-recovered CID into the content cluster and pin it.
#
# The three entries recovered from the upstream collab cluster
# (roles/content/vars/pinset.yml, source: upstream-cluster) are not
# re-resolvable: the recorded CID is the only record of the site, and the
# blocks exist only where that cluster still holds them. This connects our kubo
# node straight to the upstream peers so bitswap can serve the DAG without any
# DHT or IPNI lookup having to succeed first, then pins through ipfs-cluster.
#
# Reachability and completion are separate questions, with separate timeouts:
#   --probe-timeout  a peer that has not begun serving the DAG in this long is
#                    not serving it; waiting longer tells you nothing. On a
#                    timeout with no root block locally, the CID is reported
#                    unreachable so the caller can try the next candidate.
#   --fetch-timeout  once the root block is in, finishing a multi-thousand-block
#                    walk from one or two dormant peers is slow but worth
#                    waiting for. A DAG still walking at this point is reported
#                    partial, with the number of blocks reached.
#
# UPSTREAM PEERS (valid only until IPFS Shipyard shuts down on 2026-09-30; read
# from the follower's own `peers ls` on 2026-09-16, when only two of the four
# collab peers were left):
#   /ip4/15.235.54.25/tcp/4001/p2p/12D3KooWQHS83N7ykf2pJMBSjsDMtyv5MrEukHdoiCJke2e6GjFf   (collab-cluster-bhs8)
#   /ip4/141.94.161.49/tcp/4001/p2p/12D3KooWRNijznEQoXrxBeNLb2TqbSFm8gG8jKtfEsbC1C9nPqce  (collab-cluster-rbx8)
# To re-derive them after the state in scripts/recover-upstream-pinset.sh
# --state is gone: run that script's follower again and ask it
#   ipfs-cluster-ctl --host /unix/<config>/ipfs-websites/api-socket peers ls
# The "> IPFS:" line of each peer carries its kubo PeerID and addresses.
#
# Pins are added from ONE peer: replication is -1/-1, so the cluster replicates
# to the others itself.
#
# Exit 0 fetched and pinned, 3 unreachable (try the next candidate CID),
# 4 partial (fetch timed out with blocks still missing), 2 on a cluster or
# tooling error, 64 on bad usage.
#
# Usage: ./scripts/fetch-upstream-entry.sh --cid <cid> --name <domain>
#          [--connect <multiaddr>]... [--probe-timeout 120] [--fetch-timeout 900]
#          [--box <box>] [--no-pin]
#        ./scripts/fetch-upstream-entry.sh --candidates [<domain>]
set -euo pipefail
cd "$(dirname "$0")/.."

CID=
NAME=
BOX=chic-1
PROBE_TIMEOUT=120
FETCH_TIMEOUT=900
NO_PIN=false
CANDIDATES=false
PINSET=roles/content/vars/pinset.yml
CONNECT=(
  /ip4/15.235.54.25/tcp/4001/p2p/12D3KooWQHS83N7ykf2pJMBSjsDMtyv5MrEukHdoiCJke2e6GjFf
  /ip4/141.94.161.49/tcp/4001/p2p/12D3KooWRNijznEQoXrxBeNLb2TqbSFm8gG8jKtfEsbC1C9nPqce
)
CONNECT_GIVEN=false

usage() {
  cat <<EOF
Usage: $0 --cid <cid> --name <domain> [options]

Fetch one upstream-recovered CID into the content cluster and pin it, by
connecting directly to the upstream collab cluster's IPFS peers.

Options:
  --cid CID             the CID to fetch (required)
  --name DOMAIN         pin name, the domain it belongs to (required)
  --connect MULTIADDR   peer to connect before fetching; repeatable. Defaults
                        to the two upstream peers named in this script's header
  --probe-timeout SECS  reachability window (default: $PROBE_TIMEOUT). No root block
                        within it means unreachable: exit 3, try the next CID
  --fetch-timeout SECS  window for the whole DAG once reachable (default: $FETCH_TIMEOUT).
                        Still walking at the end means partial: exit 4
  --box BOX             box whose cluster peer to use (default: $BOX); the pin
                        replicates to the others by itself
  --no-pin              fetch and report, but do not pin
  --candidates [DOMAIN] print the candidate CIDs $PINSET holds for the
                        upstream-cluster entries (newest snapshot first, then
                        upstream_other_cids) and exit, fetching nothing
  -h, --help            show this help

Exit: 0 fetched and pinned, 3 unreachable, 4 partial, 2 error, 64 bad usage.
EOF
}

while (($#)); do
  case "$1" in
    --cid) CID=${2:?--cid needs a value}; shift 2 ;;
    --name) NAME=${2:?--name needs a value}; shift 2 ;;
    --connect)
      $CONNECT_GIVEN || CONNECT=()
      CONNECT_GIVEN=true
      CONNECT+=("${2:?--connect needs a value}"); shift 2 ;;
    --probe-timeout) PROBE_TIMEOUT=${2:?--probe-timeout needs a value}; shift 2 ;;
    --fetch-timeout) FETCH_TIMEOUT=${2:?--fetch-timeout needs a value}; shift 2 ;;
    --box) BOX=${2:?--box needs a value}; shift 2 ;;
    --no-pin) NO_PIN=true; shift ;;
    --candidates)
      CANDIDATES=true
      [[ ${2:-} && ${2:-} != -* ]] && { NAME=$2; shift; }
      shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

# Candidate CIDs, newest snapshot first: what `cid` records, then each older
# snapshot in upstream_other_cids. Printed before anything is fetched so the
# list can be checked against the pinset by eye.
if $CANDIDATES; then
  python3 - "$PINSET" "${NAME:-}" <<'PY'
import sys, yaml
path, only = sys.argv[1], sys.argv[2]
data = yaml.safe_load(open(path)) or {}
for e in data.get("pinset") or []:
    if e.get("source") != "upstream-cluster" or (only and e.get("name") != only):
        continue
    others = e.get("upstream_other_cids") or []
    print(f'{e["name"]}  ({1 + len(others)} candidate(s), newest first)')
    print(f'  {e["cid"]}   {e.get("upstream_name", "")}'
          f'{"  [from " + e["upstream_listing"] + "]" if e.get("upstream_listing") else ""}')
    for cid in others:
        print(f'  {cid}   older snapshot')
PY
  exit 0
fi

if [[ -z "$CID" || -z "$NAME" ]]; then
  echo "error: --cid and --name are required" >&2
  usage >&2
  exit 64
fi
for n in "$PROBE_TIMEOUT" "$FETCH_TIMEOUT"; do
  if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: timeouts take a positive number of seconds" >&2
    exit 64
  fi
done

ADMIN=$(ansible-inventory --host "$BOX" </dev/null 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("admin_user","ipni"))') || {
  echo "error: '$BOX' is not in the inventory" >&2
  exit 64
}

# One remote script does the whole thing: ansible buffers output until a task
# finishes, so the timing has to happen on the box, not here.
remote=$(cat <<REMOTE
set -u
K="k3s kubectl -n content exec deploy/content -c kubo -- ipfs --api=/ip4/127.0.0.1/tcp/5021"
C="k3s kubectl -n content exec deploy/content -c cluster -- ipfs-cluster-ctl --host /ip4/127.0.0.1/tcp/9094"

for addr in ${CONNECT[*]}; do
  \$K --timeout=60s swarm connect "\$addr" 2>&1 | sed 's/^/connect: /' || true
done

# Reachability: the whole DAG may well arrive inside the probe window - these
# sites are tens of MB - in which case there is nothing left to fetch.
echo "probe: dag stat within ${PROBE_TIMEOUT}s"
if \$K --timeout=${PROBE_TIMEOUT}s dag stat --progress=false "$CID" 2>&1; then
  echo "RESULT=fetched"
else
  # Did anything arrive? A root block held locally means a peer IS serving the
  # DAG and the walk simply needs longer; nothing means unreachable.
  if \$K --timeout=30s --offline block stat "$CID" >/dev/null 2>&1; then
    echo "probe: root block present, continuing for up to ${FETCH_TIMEOUT}s"
    if \$K --timeout=${FETCH_TIMEOUT}s dag stat --progress=false "$CID" 2>&1; then
      echo "RESULT=fetched"
    else
      echo "BLOCKS_LOCAL=\$(\$K --timeout=120s --offline refs -r -u "$CID" 2>/dev/null | wc -l)"
      echo "RESULT=partial"
    fi
  else
    echo "RESULT=unreachable"
  fi
fi
REMOTE
)

echo "== $NAME  $CID"
out=$(ansible "$BOX" -u "$ADMIN" -b -m shell -a "$remote" </dev/null 2>&1) || true
echo "$out" | sed -n '/CHANGED\|FAILED\|UNREACHABLE/,$p' | tail -n +2

result=$(sed -n 's/^RESULT=//p' <<<"$out" | tail -1)
case "$result" in
  fetched) ;;
  unreachable)
    echo "UNREACHABLE: no peer served $CID within ${PROBE_TIMEOUT}s"
    exit 3 ;;
  partial)
    echo "PARTIAL: $CID still incomplete after ${FETCH_TIMEOUT}s ($(sed -n 's/^BLOCKS_LOCAL=//p' <<<"$out" | tail -1) blocks held locally)"
    exit 4 ;;
  *)
    echo "ERROR: the fetch did not report a result; see the output above" >&2
    exit 2 ;;
esac

if $NO_PIN; then
  echo "fetched (not pinned: --no-pin)"
  exit 0
fi

echo "pinning as $NAME"
pin=$(ansible "$BOX" -u "$ADMIN" -b -m shell -a \
  "k3s kubectl -n content exec deploy/content -c cluster -- ipfs-cluster-ctl --host /ip4/127.0.0.1/tcp/9094 pin add --name '$NAME' --wait --wait-timeout 300s '$CID'" \
  </dev/null 2>&1) || true
echo "$pin" | sed -n '/CHANGED\|FAILED\|UNREACHABLE/,$p' | tail -n +2
if ! grep -q "PINNED" <<<"$pin"; then
  echo "ERROR: $CID did not reach PINNED; see the output above" >&2
  exit 2
fi
echo "PINNED: $NAME $CID"
