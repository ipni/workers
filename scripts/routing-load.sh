#!/usr/bin/env bash
# Climbing (step) load test for our Delegated Routing V1 endpoints: hold a fixed
# concurrency for a stage, measure, then climb to the next stage, until the
# endpoint degrades or the stages run out. It answers "where does it start to
# hurt", which scripts/routing-compare.sh (correctness/latency vs a baseline)
# deliberately does not.
#
# Endpoints are tested ONE AT A TIME so a stage's numbers belong to one box.
#
# Load reaches real third parties: every lookup someguy cannot serve from its
# cache becomes queries to the Amino DHT and cid.contact. By default the same
# fixtures repeat, so someguy's cache absorbs most of them and this mainly
# measures our own path (Cloudflare -> Envoy -> someguy). --cache-bust forces
# every request to miss that cache; keep concurrency and duration low with it.
#
# Exit 0 when every endpoint completed all stages within thresholds, 1 when any
# endpoint degraded (its climb was stopped), 2 on bad arguments.
#
# Usage: ./scripts/routing-load.sh [--endpoint HOST]... [--stages 1,2,4,8,16,32]
#          [--stage-seconds N] [--fixtures FILE] [--timeout SECONDS]
#          [--max-error-rate F] [--cache-bust] [--out FILE]
# See --help.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: ./scripts/routing-load.sh [options]

Runs a climbing load test against each endpoint in turn and prints, per stage,
the achieved request rate, latency percentiles and error rate.

Options:
  --endpoint HOST       endpoint under test; repeatable
                        (default: route-sing-1.ipni.io, route-lith-1.ipni.io,
                        route-chic-1.ipni.io)
  --stages LIST         comma-separated concurrency steps (default: 1,2,4,8,16,32)
  --stage-seconds N     how long to hold each stage (default: 20)
  --fixtures FILE       fixture list, `type id # comment` per line
                        (default: scripts/routing-compare-cids.txt)
  --timeout SECONDS     per-request timeout (default: 30)
  --max-error-rate F    stop climbing an endpoint above this rate (default: 0.05)
  --cache-bust          unique query string per request, so someguy answers
                        every request from the DHT/cid.contact instead of cache
  --out FILE            also write the full results as JSON
  -h, --help            show this help

A stage is the last one for an endpoint when its error rate exceeds
--max-error-rate, it returns any 429, or every request fails. The endpoint's
"knee" is reported as the highest stage that stayed within thresholds.
EOF
}

endpoints=()
stages=1,2,4,8,16,32
stage_seconds=20
fixtures=scripts/routing-compare-cids.txt
timeout=30
max_error_rate=0.05
cache_bust=0
out=

need_value() {
  if [[ $# -lt 2 || -z $2 ]]; then
    echo "error: $1 needs a value (see --help)" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --endpoint)       need_value "$@"; endpoints+=("$2"); shift 2 ;;
    --stages)         need_value "$@"; stages=$2; shift 2 ;;
    --stage-seconds)  need_value "$@"; stage_seconds=$2; shift 2 ;;
    --fixtures)       need_value "$@"; fixtures=$2; shift 2 ;;
    --timeout)        need_value "$@"; timeout=$2; shift 2 ;;
    --max-error-rate) need_value "$@"; max_error_rate=$2; shift 2 ;;
    --cache-bust)     cache_bust=1; shift ;;
    --out)            need_value "$@"; out=$2; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "error: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

if [[ ${#endpoints[@]} -eq 0 ]]; then
  endpoints=(route-sing-1.ipni.io route-lith-1.ipni.io route-chic-1.ipni.io)
fi
if [[ ! $stages =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]]; then
  echo "error: --stages must be comma-separated positive integers" >&2; exit 2
fi
if [[ ! $stage_seconds =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --stage-seconds must be a positive integer" >&2; exit 2
fi
if [[ ! $timeout =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --timeout must be a positive integer" >&2; exit 2
fi
if [[ ! $max_error_rate =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
  echo "error: --max-error-rate must be between 0 and 1" >&2; exit 2
fi
if [[ ! -r $fixtures ]]; then
  echo "error: cannot read fixtures file $fixtures" >&2; exit 2
fi

python3 - "$stages" "$stage_seconds" "$fixtures" "$timeout" "$max_error_rate" \
         "$cache_bust" "$out" "${endpoints[@]}" <<'EOF'
import datetime, http.client, json, math, ssl, statistics, sys, threading, time, uuid

(stages_arg, stage_seconds, fixtures_path, timeout,
 max_error_rate, cache_bust, out_path) = sys.argv[1:8]
endpoints = list(dict.fromkeys(sys.argv[8:]))
stages = [int(s) for s in stages_arg.split(",")]
stage_seconds, timeout = int(stage_seconds), int(timeout)
max_error_rate, cache_bust = float(max_error_rate), bool(int(cache_bust))

ACCEPT = {
    "providers": "application/json",
    "peers": "application/json",
    "ipns": "application/vnd.ipfs.ipns-record",
}
USER_AGENT = "ipni-workers-routing-load/1 (+https://github.com/ipni/workers)"
# 404 and the `routing: not found` 200 both mean "no result", not a failure.
OK_STATUS = {200, 404}


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(2)


def load_fixtures(path):
    out = []
    for lineno, line in enumerate(open(path), 1):
        body, _, _ = line.partition("#")
        fields = body.split()
        if not fields:
            continue
        if len(fields) != 2 or fields[0] not in ACCEPT:
            die(f"{path}:{lineno}: expected `providers|peers|ipns <id> # comment`")
        out.append((fields[0], fields[1]))
    if not out:
        die(f"{path} has no fixtures")
    return out


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def percentile(values, p):
    if not values:
        return None
    values = sorted(values)
    return values[max(0, math.ceil(p / 100 * len(values)) - 1)]


def ms(v):
    return "-" if v is None else f"{v:.0f}ms"


class Worker(threading.Thread):
    """Sends requests back to back until the deadline, reusing one TLS
    connection (as a real client behind keep-alive would)."""

    def __init__(self, host, fixtures, offset, deadline, ctx):
        super().__init__(daemon=True)
        self.host, self.fixtures, self.offset = host, fixtures, offset
        self.deadline, self.ctx = deadline, ctx
        self.samples, self.statuses, self.errors, self.cache = [], {}, {}, {}
        self.conn = None

    def connect(self):
        if self.conn is not None:
            self.conn.close()
        self.conn = http.client.HTTPSConnection(self.host, timeout=timeout, context=self.ctx)

    def run(self):
        i = self.offset
        while time.monotonic() < self.deadline:
            kind, ident = self.fixtures[i % len(self.fixtures)]
            i += 1
            path = f"/routing/v1/{kind}/{ident}"
            if cache_bust:
                path += f"?routing-load={uuid.uuid4().hex}"
            started = time.monotonic()
            try:
                if self.conn is None:
                    self.connect()
                self.conn.request("GET", path, headers={
                    "Accept": ACCEPT[kind], "User-Agent": USER_AGENT, "Host": self.host,
                })
                resp = self.conn.getresponse()
                resp.read()  # drain, so the connection can be reused
                elapsed = (time.monotonic() - started) * 1000
                self.statuses[resp.status] = self.statuses.get(resp.status, 0) + 1
                cache = resp.getheader("cf-cache-status") or "none"
                self.cache[cache] = self.cache.get(cache, 0) + 1
                if resp.status in OK_STATUS:
                    self.samples.append(elapsed)
                else:
                    self.errors[f"HTTP {resp.status}"] = self.errors.get(f"HTTP {resp.status}", 0) + 1
                if resp.will_close:
                    self.connect()
            except Exception as exc:  # timeout, reset, TLS error
                name = type(exc).__name__
                self.errors[name] = self.errors.get(name, 0) + 1
                try:
                    self.connect()
                except Exception:
                    self.conn = None
                    time.sleep(0.2)


def run_stage(host, fixtures, concurrency, ctx):
    deadline = time.monotonic() + stage_seconds
    started = time.monotonic()
    workers = [Worker(host, fixtures, n, deadline, ctx) for n in range(concurrency)]
    for w in workers:
        w.start()
    for w in workers:
        w.join(timeout + stage_seconds + 30)
    wall = time.monotonic() - started

    samples, statuses, errors, cache = [], {}, {}, {}
    for w in workers:
        samples += w.samples
        for src, dst in ((w.statuses, statuses), (w.errors, errors), (w.cache, cache)):
            for k, v in src.items():
                dst[k] = dst.get(k, 0) + v
    total = sum(statuses.values()) + sum(v for k, v in errors.items() if not k.startswith("HTTP "))
    failed = sum(errors.values())
    return {
        "concurrency": concurrency, "seconds": round(wall, 1), "requests": total,
        "errors": failed, "error_rate": (failed / total) if total else 1.0,
        "rps": round(total / wall, 1) if wall else 0.0,
        "p50_ms": percentile(samples, 50), "p95_ms": percentile(samples, 95),
        "p99_ms": percentile(samples, 99), "max_ms": max(samples) if samples else None,
        "statuses": statuses, "error_kinds": errors, "cache": cache,
    }


fixtures = load_fixtures(fixtures_path)
ctx = ssl.create_default_context()
doc = {
    "schema_version": 1, "started_at": now(), "finished_at": None, "exit_code": None,
    "config": {
        "endpoints": endpoints, "stages": stages, "stage_seconds": stage_seconds,
        "fixtures": fixtures_path, "timeout_s": timeout,
        "max_error_rate": max_error_rate, "cache_bust": cache_bust,
    },
    "endpoints": {},
}

print(f"endpoints: {', '.join(endpoints)}", file=sys.stderr)
print(f"stages: {stages} x {stage_seconds}s, {len(fixtures)} fixtures, "
      f"cache-bust {'on' if cache_bust else 'off'}", file=sys.stderr)

degraded = []
for host in endpoints:
    print(f"\n{host}", file=sys.stderr)
    results, knee, stopped = [], None, None
    for concurrency in stages:
        print(f"  c={concurrency} ...", end="", file=sys.stderr, flush=True)
        stage = run_stage(host, fixtures, concurrency, ctx)
        results.append(stage)
        print(f"\r  c={concurrency:<4} {stage['rps']:>7.1f} rps  p50 {ms(stage['p50_ms']):>7}"
              f"  p95 {ms(stage['p95_ms']):>7}  err {stage['error_rate']:.1%}",
              file=sys.stderr)
        throttled = stage["statuses"].get(429, 0)
        if stage["error_rate"] > max_error_rate or throttled:
            stopped = ("429 rate limited" if throttled
                       else f"error rate {stage['error_rate']:.1%}")
            break
        knee = concurrency
    doc["endpoints"][host] = {"stages": results, "knee": knee, "stopped": stopped}
    if stopped:
        degraded.append(f"{host}: stopped at c={results[-1]['concurrency']} ({stopped})")

# --- per-endpoint tables ----------------------------------------------------
for host in endpoints:
    e = doc["endpoints"][host]
    print(f"\n{host}")
    print(f"{'conc':>5} {'reqs':>7} {'rps':>8} {'p50':>9} {'p95':>9} {'p99':>9} "
          f"{'max':>9} {'errors':>12}")
    for s in e["stages"]:
        errs = f"{s['errors']}/{s['requests']} {s['error_rate']:.0%}"
        print(f"{s['concurrency']:>5} {s['requests']:>7} {s['rps']:>8.1f} "
              f"{ms(s['p50_ms']):>9} {ms(s['p95_ms']):>9} {ms(s['p99_ms']):>9} "
              f"{ms(s['max_ms']):>9} {errs:>12}")
    cache = {}
    for s in e["stages"]:
        for k, v in s["cache"].items():
            cache[k] = cache.get(k, 0) + v
    print(f"  highest clean stage: c={e['knee']}" + (f"; stopped: {e['stopped']}" if e["stopped"] else ""))
    print(f"  cf-cache-status: {', '.join(f'{k} {v}' for k, v in sorted(cache.items()))}")

status = 1 if degraded else 0
print()
print("\n".join(f"DEGRADED {d}" for d in degraded) if degraded
      else "OK: every endpoint completed all stages within thresholds")
print("Note: latency includes the trip to Cloudflare's edge and back, so it "
      "reflects distance to the box as well as the box's own work.")

doc.update(finished_at=now(), exit_code=status)
if out_path:
    with open(out_path, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    print(f"\nwrote {out_path}")
sys.exit(status)
EOF
