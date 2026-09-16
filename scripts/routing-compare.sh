#!/usr/bin/env bash
# Compare our Delegated Routing V1 endpoints (the candidates) with a baseline,
# by default the public delegated-ipfs.dev, over the fixtures in
# scripts/routing-compare-cids.txt. DHT lookups are nondeterministic, so this
# reports medians and latency percentiles instead of asserting equality.
#
# Exit 0 when every candidate is within tolerance, 1 when a candidate is
# consistently low on any fixture or its error rate exceeds the baseline's by
# more than 5 percentage points, 2 if the baseline could not be reached (or the
# arguments are invalid).
#
# Usage: ./scripts/routing-compare.sh [--baseline HOST] [--candidate HOST]...
#          [--fixtures FILE] [--runs N] [--timeout SECONDS] [--tolerance F]
#          [--out FILE]
# See --help. Results for content with no providers are expected to be 0.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: ./scripts/routing-compare.sh [options]

Queries /routing/v1/providers, /peers and /ipns for every fixture on the
baseline and each candidate, --runs times, and prints a per-fixture table and a
latency/error summary.

Options:
  --baseline HOST     reference endpoint (default: delegated-ipfs.dev)
  --candidate HOST    endpoint under test; repeatable
                      (default: route-sing-1.ipni.io, route-lith-1.ipni.io,
                      route-chic-1.ipni.io)
  --fixtures FILE     fixture list, `type id # comment` per line
                      (default: scripts/routing-compare-cids.txt)
  --runs N            requests per fixture per endpoint (default: 3)
  --timeout SECONDS   per-request timeout (default: 30)
  --tolerance F       a run counts as low when the candidate returns fewer than
                      (1 - F) x the baseline's results (default: 0.25)
  --out FILE          also write the full results as JSON
  -h, --help          show this help

A fixture is `low` for a candidate only when it is low in every run where both
endpoints answered. Exit 0: all candidates within tolerance. Exit 1: a
candidate is low on any fixture, or its error rate exceeds the baseline's by
more than 5 percentage points. Exit 2: baseline unreachable or bad arguments.
EOF
}

baseline=delegated-ipfs.dev
candidates=()
fixtures=scripts/routing-compare-cids.txt
runs=3
timeout=30
tolerance=0.25
out=

need_value() {
  if [[ $# -lt 2 || -z $2 ]]; then
    echo "error: $1 needs a value (see --help)" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --baseline)  need_value "$@"; baseline=$2; shift 2 ;;
    --candidate) need_value "$@"; candidates+=("$2"); shift 2 ;;
    --fixtures)  need_value "$@"; fixtures=$2; shift 2 ;;
    --runs)      need_value "$@"; runs=$2; shift 2 ;;
    --timeout)   need_value "$@"; timeout=$2; shift 2 ;;
    --tolerance) need_value "$@"; tolerance=$2; shift 2 ;;
    --out)       need_value "$@"; out=$2; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "error: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  candidates=(route-sing-1.ipni.io route-lith-1.ipni.io route-chic-1.ipni.io)
fi
if [[ ! $runs =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --runs must be a positive integer" >&2; exit 2
fi
if [[ ! $timeout =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --timeout must be a positive integer" >&2; exit 2
fi
if [[ ! $tolerance =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
  echo "error: --tolerance must be between 0 and 1" >&2; exit 2
fi
if [[ ! -r $fixtures ]]; then
  echo "error: cannot read fixtures file $fixtures" >&2; exit 2
fi
command -v curl >/dev/null || { echo "error: curl is required" >&2; exit 2; }

python3 - "$baseline" "$fixtures" "$runs" "$timeout" "$tolerance" "$out" "${candidates[@]}" <<'EOF'
import concurrent.futures, datetime, json, math, statistics, subprocess, sys, uuid

baseline, fixtures_path, runs, timeout, tolerance, out_path = sys.argv[1:7]
runs, timeout, tolerance = int(runs), int(timeout), float(tolerance)
candidates = list(dict.fromkeys(sys.argv[7:]))  # de-duplicate, keep order
endpoints = [baseline] + [c for c in candidates if c != baseline]
candidates = endpoints[1:]

# Why these Accept headers: providers and peers are asked for as one JSON
# document (the default is NDJSON streaming). IPNS has no JSON form; both
# delegated-ipfs.dev and someguy answer application/json with 406, so records
# are requested as application/vnd.ipfs.ipns-record.
ACCEPT = {
    "providers": "application/json",
    "peers": "application/json",
    "ipns": "application/vnd.ipfs.ipns-record",
}
# A missing record comes back as `200 text/plain` with this body (seen on both
# someguy and delegated-ipfs.dev), or as 404. Both mean "no result", not error.
NOT_FOUND = b"routing: not found"
ERROR_RATE_MARGIN = 0.05
USER_AGENT = "ipni-workers-routing-compare/1 (+https://github.com/ipni/workers)"


def load_fixtures(path):
    fixtures = []
    for lineno, line in enumerate(open(path), 1):
        body, _, comment = line.partition("#")
        fields = body.split()
        if not fields:
            continue
        if len(fields) != 2 or fields[0] not in ACCEPT:
            die(f"{path}:{lineno}: expected `providers|peers|ipns <id> # comment`")
        fixtures.append({"type": fields[0], "id": fields[1], "comment": comment.strip()})
    if not fixtures:
        die(f"{path} has no fixtures")
    return fixtures


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(2)


def curl(url, accept):
    """One request. Returns (curl exit code, HTTP status, seconds, content type,
    cf-cache-status, body, curl error message)."""
    cmd = [
        "curl", "-sS", "--max-time", str(timeout),
        "--connect-timeout", str(min(10, timeout)),
        "-A", USER_AGENT, "-H", f"Accept: {accept}",
        "-D", "-", "-o", "-", "-w", "%{stderr}%{json}", url,
    ]
    p = subprocess.run(cmd, capture_output=True, timeout=timeout + 15)
    # With -sS, an error message may precede the JSON on stderr.
    err = p.stderr.decode(errors="replace")
    info = {}
    start = err.rfind("{")
    while start != -1:
        try:
            info = json.loads(err[start:])
            break
        except json.JSONDecodeError:
            start = err.rfind("{", 0, start)
    # -D - puts the (single, no redirects followed) header block before the body.
    head, _, body = p.stdout.partition(b"\r\n\r\n")
    cache = None
    for line in head.decode(errors="replace").splitlines():
        name, _, value = line.partition(":")
        if name.strip().lower() == "cf-cache-status":
            cache = value.strip()
    return (p.returncode, info.get("http_code", 0), info.get("time_total", 0.0),
            (info.get("content_type") or "").split(";")[0].strip(), cache,
            body, (info.get("errormsg") or err[:start].strip() or None))


def query(host, fixture, run):
    kind, ident = fixture["type"], fixture["id"]
    # A unique query parameter per request defeats CDN caching. delegated-ipfs.dev
    # serves `max-age=300` responses from Cloudflare's cache, so without it
    # repeat runs would time a cache HIT against our uncached origin.
    url = f"https://{host}/routing/v1/{kind}/{ident}?routing-compare={uuid.uuid4().hex}"
    rec = {"run": run, "status": None, "duration_ms": None, "count": None,
           "cache": None, "error": None}
    try:
        code, status, secs, ctype, rec["cache"], body, errmsg = curl(url, ACCEPT[kind])
    except subprocess.TimeoutExpired:
        rec["error"] = "curl did not exit"
        return rec
    rec["status"] = status or None
    rec["duration_ms"] = round(secs * 1000, 1)
    if code != 0:
        rec["error"] = f"curl exit {code}: {errmsg}"
        return rec
    if status == 404 or (status == 200 and ctype == "text/plain" and NOT_FOUND in body):
        rec["count"] = 0
    elif status != 200:
        rec["error"] = f"HTTP {status}: {body[:120].decode(errors='replace').strip()}"
    elif kind == "ipns":
        if ctype == "application/vnd.ipfs.ipns-record" and body:
            rec["count"] = 1
        else:
            rec["error"] = f"unexpected IPNS response ({ctype or 'no content type'})"
    else:
        key = "Providers" if kind == "providers" else "Peers"
        try:
            rec["count"] = len(json.loads(body).get(key) or [])
        except (ValueError, AttributeError):
            rec["error"] = f"unparseable JSON ({ctype or 'no content type'})"
    return rec


def ok(r):
    return r["error"] is None


def med(values):
    return statistics.median(values) if values else None


def percentile(values, p):
    """Nearest-rank percentile."""
    if not values:
        return None
    values = sorted(values)
    return values[max(0, math.ceil(p / 100 * len(values)) - 1)]


def verdict(base_reqs, cand_reqs):
    base = {r["run"]: r["count"] for r in base_reqs if ok(r)}
    pairs = [(base[r["run"]], r["count"]) for r in cand_reqs if ok(r) and r["run"] in base]
    if not pairs:
        return "error"
    if all(c < b * (1 - tolerance) for b, c in pairs):
        return "low"
    return "match"


def baseline_reachable():
    for _ in range(2):
        try:
            code = curl(f"https://{baseline}/version", "*/*")[0]
        except subprocess.TimeoutExpired:
            continue
        if code == 0:  # any HTTP answer at all proves the host is reachable
            return True
    return False


def write_out(doc):
    if out_path:
        with open(out_path, "w") as f:
            json.dump(doc, f, indent=2)
            f.write("\n")
        print(f"\nwrote {out_path}")


if not candidates:
    die("need at least one candidate different from the baseline")
fixtures = load_fixtures(fixtures_path)
doc = {
    "schema_version": 1,
    "started_at": now(),
    "finished_at": None,
    "exit_code": None,
    "config": {
        "baseline": baseline, "candidates": candidates, "fixtures": fixtures_path,
        "runs": runs, "timeout_s": timeout, "tolerance": tolerance,
        "error_rate_margin": ERROR_RATE_MARGIN,
    },
    "fixtures": [],
    "summary": {},
}

if not baseline_reachable():
    print(f"error: baseline {baseline} is unreachable; nothing to compare against", file=sys.stderr)
    doc.update(finished_at=now(), exit_code=2)
    write_out(doc)
    sys.exit(2)

results = [{**f, "endpoints": {h: {"requests": []} for h in endpoints}, "verdicts": {}} for f in fixtures]
total = runs * len(fixtures)
print(f"baseline {baseline}; candidates {', '.join(candidates)}; "
      f"{len(fixtures)} fixtures x {runs} runs", file=sys.stderr)

# Run by run, fixture by fixture; each fixture hits every endpoint at the same
# moment, so all endpoints see the same DHT conditions.
with concurrent.futures.ThreadPoolExecutor(max_workers=len(endpoints)) as pool:
    done = 0
    for run in range(1, runs + 1):
        for res in results:
            futures = {h: pool.submit(query, h, res, run) for h in endpoints}
            for h, fut in futures.items():
                res["endpoints"][h]["requests"].append(fut.result())
            done += 1
            print(f"\r  {done}/{total}", end="", file=sys.stderr, flush=True)
print(file=sys.stderr)

for res in results:
    for h in endpoints:
        e = res["endpoints"][h]
        good = [r for r in e["requests"] if ok(r)]
        e["median_count"] = med([r["count"] for r in good])
        e["median_ms"] = med([r["duration_ms"] for r in good])
        e["errors"] = len(e["requests"]) - len(good)
    for c in candidates:
        res["verdicts"][c] = verdict(res["endpoints"][baseline]["requests"],
                                     res["endpoints"][c]["requests"])
doc["fixtures"] = results

for h in endpoints:
    reqs = [r for res in results for r in res["endpoints"][h]["requests"]]
    good_ms = [r["duration_ms"] for r in reqs if ok(r)]
    errors = sum(not ok(r) for r in reqs)
    doc["summary"][h] = {
        "role": "baseline" if h == baseline else "candidate",
        "requests": len(reqs),
        "errors": errors,
        "error_rate": errors / len(reqs),
        "p50_ms": percentile(good_ms, 50),
        "p95_ms": percentile(good_ms, 95),
        "low_fixtures": None if h == baseline else sum(res["verdicts"][h] == "low" for res in results),
    }

# --- per-fixture table ------------------------------------------------------
def short(host):
    return host[:-len(".ipni.io")] if host.endswith(".ipni.io") else host


def num(v, suffix=""):
    if v is None:
        return "-"
    return (f"{v:.0f}" if v == int(v) else f"{v:.1f}") + suffix


def ms(v):
    return "-" if v is None else f"{v:.0f}ms"


def cell(e):
    if e["median_count"] is None:
        return "err"
    mark = "*" if e["errors"] else ""
    return f"{num(e['median_count'])}/{ms(e['median_ms'])}{mark}"


idw = 16
cols = [max(len(short(h)), 13) for h in endpoints]
vw = [max(len(short(c)), 7) for c in candidates]
print("\nPer fixture: median result count/median latency, then each candidate's verdict")
counts_w = sum(cols) + len(cols) - 1
verdicts_w = sum(vw) + len(vw) - 1
print(f"{'':<9} {'':<{idw}} {'count/latency':^{counts_w}}  {'verdict vs baseline':^{verdicts_w}}")
header = f"{'type':<9} {'id':<{idw}} " + " ".join(f"{short(h):>{w}}" for h, w in zip(endpoints, cols))
header += "  " + " ".join(f"{short(c):>{w}}" for c, w in zip(candidates, vw))
print(header)
print("-" * len(header))
for res in results:
    ident = res["id"] if len(res["id"]) <= idw else res["id"][:7] + ".." + res["id"][-7:]
    row = f"{res['type']:<9} {ident:<{idw}} "
    row += " ".join(f"{cell(res['endpoints'][h]):>{w}}" for h, w in zip(endpoints, cols))
    row += "  " + " ".join(f"{res['verdicts'][c]:>{w}}" for c, w in zip(candidates, vw))
    print(row)
print("* some runs failed; median over the runs that answered. "
      "Provider and peer counts are capped at 100 by the JSON API.")

# --- summary ----------------------------------------------------------------
print("\nSummary (latency over successful requests)")
hw = max(len(h) for h in endpoints)
print(f"{'endpoint':<{hw}}  {'role':<9} {'p50':>9} {'p95':>9} {'errors':>12} {'low':>4}")
for h in endpoints:
    s = doc["summary"][h]
    errs = f"{s['errors']}/{s['requests']} {s['error_rate']:.0%}"
    low = "-" if s["low_fixtures"] is None else str(s["low_fixtures"])
    print(f"{h:<{hw}}  {s['role']:<9} {ms(s['p50_ms']):>9} {ms(s['p95_ms']):>9} {errs:>12} {low:>4}")
print("Reminder: a low or zero count for content with no providers is expected, not a fault.")

base_summary = doc["summary"][baseline]
if base_summary["errors"] == base_summary["requests"]:
    print(f"\nFAIL: every baseline request failed; {baseline} is unusable as a reference", file=sys.stderr)
    status = 2
else:
    failing = []
    for c in candidates:
        s = doc["summary"][c]
        if s["low_fixtures"]:
            failing.append(f"{c}: low on {s['low_fixtures']} fixture(s)")
        if s["error_rate"] > base_summary["error_rate"] + ERROR_RATE_MARGIN:
            failing.append(f"{c}: error rate {s['error_rate']:.0%} vs baseline {base_summary['error_rate']:.0%}")
    status = 1 if failing else 0
    print()
    print("\n".join(f"FAIL {f}" for f in failing) if failing else "OK: every candidate is within tolerance of the baseline")

doc.update(finished_at=now(), exit_code=status)
write_out(doc)
sys.exit(status)
EOF
