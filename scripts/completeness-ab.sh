#!/usr/bin/env bash
# Measure how many providers a build returns per fixture, so the completeness
# cost of the DHT tail budget and the FindPeer grace can be put beside the
# throughput they buy.
#
# ONE ARM PER INVOCATION. This never flips a flag and never interleaves: it
# measures whatever build is currently deployed and tags the rows with --arm.
# Interleaving would let drift in the DHT or in cid.contact land inside the
# comparison instead of beside it.
#
# WHY IT QUERIES ONE INSTANCE DIRECTLY. The default --host is
# http://127.0.0.1:8190, a single someguy instance, not the public hostname.
# Through Cloudflare, Envoy round-robins across the four instances, so the
# address-book counters sampled around a query would belong to whichever
# instance happened to serve it. Querying one instance makes the cache
# accounting below exact and removes Cloudflare from a measurement that is not
# about the network path.
#
# REPEATS ARE NOT INDEPENDENT, AND NOT FOR THE REASON YOU MIGHT EXPECT.
# someguy has no CID-keyed provider cache: every /routing/v1/providers request
# is a fresh DHT walk (verified in server_cached_router.go - the only caches are
# the cachedAddrBook, the negative TTL and the FindPeer singleflight, all keyed
# on PEER ID, never on the CID). So a second query for a fixture is not served
# from a stored answer.
#
# Repeats are still correlated, through the address book: the first query
# dispatches FindPeer for providers that arrive without multiaddrs, and those
# addresses are cached, so later queries for the same fixture resolve the same
# providers without a walk. That changes latency a lot and can change the count.
#
# This script therefore does NOT silently average the two populations. It
# samples someguy_cached_router_peer_addr_lookups around every query and records
# the hit/miss/negative deltas per row, and the summary reports the median count
# over all repeats AND, separately, repeat 1 (coldest address book) against
# repeats 2..N. If those two disagree, the disagreement is the result.
#
# Usage:
#   ./scripts/completeness-ab.sh --arm armB --out results.tsv
#   ./scripts/completeness-ab.sh --arm armA --fixtures scripts/completeness-cids.txt
#
# Exit 0 on success, 2 on bad arguments.
set -euo pipefail

host="http://127.0.0.1:8190"
fixtures="scripts/completeness-cids.txt"
repeats=5
out=""
arm=""
metrics_url=""
delay=1

usage() {
  cat <<'EOF'
Usage: ./scripts/completeness-ab.sh --arm LABEL [options]

Options:
  --arm LABEL        required, tags every row (e.g. armA, armB, armB-bracket)
  --host URL         base URL of ONE someguy instance
                     (default: http://127.0.0.1:8190)
  --fixtures FILE    provider fixtures, "providers <cid> # comment" lines
                     (default: scripts/completeness-cids.txt)
  --repeats N        queries per fixture (default: 5)
  --out FILE         write TSV rows here (default: stdout only)
  --metrics-url URL  someguy Prometheus endpoint for cache accounting
                     (default: <host>/debug/metrics/prometheus)
  --delay SECONDS    pause between queries (default: 1). This is a completeness
                     test, not a capacity test: the rate must stay far below
                     anything that queues, or the tail behaviour being measured
                     reappears as a measurement artefact.
  --help             this text
EOF
}

need_value() {
  if [[ $# -lt 2 || -z ${2:-} || ${2:0:2} == "--" ]]; then
    echo "error: $1 needs a value" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arm) need_value "$@"; arm=$2; shift 2 ;;
    --host) need_value "$@"; host=$2; shift 2 ;;
    --fixtures) need_value "$@"; fixtures=$2; shift 2 ;;
    --repeats) need_value "$@"; repeats=$2; shift 2 ;;
    --out) need_value "$@"; out=$2; shift 2 ;;
    --metrics-url) need_value "$@"; metrics_url=$2; shift 2 ;;
    --delay) need_value "$@"; delay=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z $arm ]]; then
  echo "error: --arm is required" >&2
  usage >&2
  exit 2
fi
if [[ ! -r $fixtures ]]; then
  echo "error: cannot read fixtures file $fixtures" >&2
  exit 2
fi
if ! [[ $repeats =~ ^[0-9]+$ ]] || [[ $repeats -lt 1 ]]; then
  echo "error: --repeats must be a positive integer" >&2
  exit 2
fi
metrics_url=${metrics_url:-$host/debug/metrics/prometheus}

# Address-book counters, summed over origins, as "hit miss negative".
read_counters() {
  curl -sf --max-time 10 "$metrics_url" 2>/dev/null | awk '
    /^someguy_cached_router_peer_addr_lookups\{.*cache="hit"/      {h += $2}
    /^someguy_cached_router_peer_addr_lookups\{.*cache="miss"/     {m += $2}
    /^someguy_cached_router_peer_addr_lookups\{.*cache="negative"/ {n += $2}
    END {printf "%d %d %d\n", h+0, m+0, n+0}'
}

addr_book_size() {
  curl -sf --max-time 10 "$metrics_url" 2>/dev/null |
    awk '/^someguy_cached_addr_book_peer_state_size/ {print int($2); found = 1}
         END {if (!found) print 0}'
}

# Providers returned for a CID. Counts objects in the Providers array rather
# than grepping, so a schema someguy does not know is still counted once.
count_providers() {
  local cid=$1
  curl -sf --max-time 60 -H 'Accept: application/json' \
    "$host/routing/v1/providers/$cid" 2>/dev/null |
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(-1); sys.exit(0)
p = d.get("Providers")
print(len(p) if isinstance(p, list) else 0)
' 2>/dev/null || echo -1
}

started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ab_start=$(addr_book_size)

rows=$(mktemp)
trap 'rm -f "$rows"' EXIT
printf 'arm\tfixture\trepeat\tproviders\tlatency_ms\thit_delta\tmiss_delta\tneg_delta\n' > "$rows"

while read -r kind cid _rest; do
  [[ $kind == "providers" ]] || continue
  [[ $cid =~ ^[A-Za-z0-9]+$ ]] || continue
  for ((r = 1; r <= repeats; r++)); do
    read -r h0 m0 n0 <<<"$(read_counters)"
    t0=$(date +%s.%N)
    n=$(count_providers "$cid")
    t1=$(date +%s.%N)
    read -r h1 m1 n1 <<<"$(read_counters)"
    ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.0f", (b - a) * 1000}')
    printf '%s\t%s\t%d\t%s\t%s\t%d\t%d\t%d\n' \
      "$arm" "$cid" "$r" "$n" "$ms" \
      $((h1 - h0)) $((m1 - m0)) $((n1 - n0)) >> "$rows"
    sleep "$delay"
  done
done < "$fixtures"

ab_end=$(addr_book_size)
finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [[ -n $out ]]; then
  cp "$rows" "$out"
fi

# Summary: median over all repeats, and repeat 1 against repeats 2..N, so a
# cold address book is never averaged into a warm one without saying so.
python3 - "$rows" "$arm" "$ab_start" "$ab_end" "$started" "$finished" <<'PY'
import collections, statistics, sys

path, arm, ab_start, ab_end, started, finished = sys.argv[1:7]
first, rest, allr = collections.defaultdict(list), collections.defaultdict(list), collections.defaultdict(list)
order = []
with open(path) as fh:
    next(fh)
    for line in fh:
        f = line.rstrip("\n").split("\t")
        cid, rep, cnt = f[1], int(f[2]), int(f[3])
        if cid not in order:
            order.append(cid)
        allr[cid].append(cnt)
        (first if rep == 1 else rest)[cid].append(cnt)

def med(xs):
    return "-" if not xs else f"{statistics.median(xs):g}"

print(f"\narm={arm}  {started} -> {finished}")
print(f"address book: {ab_start} at start, {ab_end} at end")
print(f"\n{'fixture':<56} {'median':>7} {'r1':>5} {'r2+':>6}  raw")
print("-" * 96)
for cid in order:
    short = cid if len(cid) <= 54 else cid[:26] + ".." + cid[-26:]
    print(f"{short:<56} {med(allr[cid]):>7} {med(first[cid]):>5} {med(rest[cid]):>6}  {allr[cid]}")
PY
