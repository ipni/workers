#!/usr/bin/env bash
# Open-loop load test for a routing endpoint, meant to run ON the box so the
# client is not limited by a remote link.
#
# Unlike scripts/routing-load.sh (closed loop: N requests in flight, throughput
# = concurrency / latency, so a slow link caps the result), this drives a fixed
# ARRIVAL RATE. Requests are scheduled at a steady rate whether or not earlier
# ones have finished, so queueing shows up as growing latency instead of
# silently lowering throughput.
#
# It also samples what the box itself is doing around every stage: needle's
# CPU, its address-book cache hit/miss counters, in-flight and rejected
# lookups, open FDs, and NIC bytes. That is what separates "needle is at its
# limit" from "the client or the network is".
#
# WORKLOAD. --workload cold generates random CIDs that nobody provides, so
# every request is a real, uncached lookup (the expensive case: needle has no
# provider-response cache, only a cached address book). --workload fixtures
# replays scripts/routing-compare-cids.txt, which is mostly popular CIDs that
# cid.contact answers quickly. --cold-fraction mixes the two.
#
# Cold lookups reach the public Amino DHT and cid.contact. Rate and duration
# are the only things keeping that polite: keep both modest.
#
# Exit 0 when every stage met its target rate within thresholds, 1 when a stage
# degraded (the climb stops there), 2 on bad arguments.
#
# Usage: ./scripts/routing-rate-test.sh --url-base URL [--rates 25,50,100,200]
#          [--stage-seconds N] [--workload cold|fixtures] [--cold-fraction F]
#          [--fixtures FILE] [--metrics-url URL] [--timeout S]
#          [--max-error-rate F] [--json FILE] [--per-request FILE]
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/routing-rate-test.sh --url-base URL [options]

Options:
  --url-base URL        required, e.g. http://127.0.0.1:8190 (needle direct)
                        or https://route-chic-1.ipni.io (through Cloudflare)
  --rates LIST          comma-separated target rates in requests/sec
                        (default: 25,50,100,200)
  --stage-seconds N     how long to hold each rate (default: 45)
  --workload KIND       cold | fixtures (default: cold)
  --cold-fraction F     fraction of requests using fresh random CIDs; implied
                        1.0 for --workload cold, 0.0 for fixtures
  --fixtures FILE       fixture list for the non-cold share
                        (default: scripts/routing-compare-cids.txt)
  --metrics-url URL     needle Prometheus endpoint to sample around each stage
                        (default: http://127.0.0.1:8190/debug/metrics/prometheus)
  --timeout S           per-request timeout (default: 30)
  --max-error-rate F    stop climbing above this error rate (default: 0.05)
  --workers N           client worker threads per stage (default: rate x 4,
                        capped at 2048). Must exceed rate x latency or the
                        client, not the endpoint, caps the achieved rate.
  --json FILE           write full results as JSON
  --per-request FILE    append one TSV line per completed request:
                        op, id, status, bytes, service_ms, timed_out.
                        status and bytes are empty when the request raised;
                        timed_out is 1 when it raised the client --timeout.
                        Appends, so a header is written only for a new file.
  -h, --help            show this help

A stage stops the climb when its error rate exceeds --max-error-rate, any 429
is returned, or the achieved rate falls below 90% of target (which means the
client, the network or the box could not keep up; the queue-delay column says
which).
EOF
}

url_base=
rates=25,50,100,200
stage_seconds=45
workload=cold
cold_fraction=
fixtures=scripts/routing-compare-cids.txt
metrics_url=http://127.0.0.1:8190/debug/metrics/prometheus
timeout=30
max_error_rate=0.05
workers=
json_out=
per_request_out=

need_value() {
  if [[ $# -lt 2 || -z $2 ]]; then
    echo "error: $1 needs a value (see --help)" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --url-base)       need_value "$@"; url_base=$2; shift 2 ;;
    --rates)          need_value "$@"; rates=$2; shift 2 ;;
    --stage-seconds)  need_value "$@"; stage_seconds=$2; shift 2 ;;
    --workload)       need_value "$@"; workload=$2; shift 2 ;;
    --cold-fraction)  need_value "$@"; cold_fraction=$2; shift 2 ;;
    --fixtures)       need_value "$@"; fixtures=$2; shift 2 ;;
    --metrics-url)    need_value "$@"; metrics_url=$2; shift 2 ;;
    --timeout)        need_value "$@"; timeout=$2; shift 2 ;;
    --max-error-rate) need_value "$@"; max_error_rate=$2; shift 2 ;;
    --workers)        need_value "$@"; workers=$2; shift 2 ;;
    --json)           need_value "$@"; json_out=$2; shift 2 ;;
    --per-request)    need_value "$@"; per_request_out=$2; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "error: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

[[ -n $url_base ]] || { echo "error: --url-base is required (see --help)" >&2; exit 2; }
case $workload in
  cold)     cold_fraction=${cold_fraction:-1.0} ;;
  fixtures) cold_fraction=${cold_fraction:-0.0} ;;
  *) echo "error: --workload must be cold or fixtures" >&2; exit 2 ;;
esac
if [[ ! $rates =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]]; then
  echo "error: --rates must be comma-separated positive integers" >&2; exit 2
fi
if [[ ! $stage_seconds =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --stage-seconds must be a positive integer" >&2; exit 2
fi
if [[ ! $timeout =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --timeout must be a positive integer" >&2; exit 2
fi
for f in "$cold_fraction" "$max_error_rate"; do
  if [[ ! $f =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
    echo "error: fractions must be between 0 and 1 (got $f)" >&2; exit 2
  fi
done
if [[ $cold_fraction != "1.0" && ! -r $fixtures ]]; then
  echo "error: cannot read fixtures file $fixtures" >&2; exit 2
fi

if [[ -n $workers && ! $workers =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --workers must be a positive integer" >&2; exit 2
fi

python3 - "$url_base" "$rates" "$stage_seconds" "$cold_fraction" "$fixtures" \
         "$metrics_url" "$timeout" "$max_error_rate" "$json_out" "${workers:-0}" \
         "$per_request_out" <<'PYEOF'
import datetime, hashlib, http.client, json, math, os, queue, resource, socket, ssl, sys, threading, time
import urllib.parse, urllib.request

(url_base, rates_arg, stage_seconds, cold_fraction, fixtures_path,
 metrics_url, timeout, max_error_rate, json_out, workers_arg,
 per_request_out) = sys.argv[1:12]
rates = [int(r) for r in rates_arg.split(",")]
stage_seconds, timeout = int(stage_seconds), int(timeout)
cold_fraction, max_error_rate = float(cold_fraction), float(max_error_rate)
workers_arg = int(workers_arg)


def pool_size(rate):
    return workers_arg if workers_arg else min(2048, max(64, rate * 4))

ACCEPT = {
    "providers": "application/json",
    "peers": "application/json",
    "ipns": "application/vnd.ipfs.ipns-record",
}
USER_AGENT = "ipni-workers-routing-rate-test/1 (+https://github.com/ipni/workers)"
OK_STATUS = {200, 404}
B32 = "abcdefghijklmnopqrstuvwxyz234567"


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(2)


def b32(raw):
    bits = "".join(f"{byte:08b}" for byte in raw)
    bits += "0" * ((-len(bits)) % 5)
    return "".join(B32[int(bits[i:i + 5], 2)] for i in range(0, len(bits), 5))


def cold_cid():
    """A CIDv1 raw/sha2-256 over random bytes: valid, and nobody provides it,
    so needle must do the full lookup."""
    return "b" + b32(bytes([0x01, 0x55, 0x12, 0x20]) + hashlib.sha256(os.urandom(32)).digest())


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


# --- what the box is doing --------------------------------------------------
METRICS = (
    "needle_cached_router_peer_addr_lookups",
    "needle_cached_router_find_peer_lookups_rejected",
    "needle_cached_router_find_peer_lookups_in_flight",
    "process_cpu_seconds_total",
    "process_open_fds",
    "go_goroutines",
)


def scrape():
    """needle's own counters. Returns {} if the endpoint is not reachable."""
    out = {}
    try:
        with urllib.request.urlopen(metrics_url, timeout=10) as resp:
            for line in resp.read().decode(errors="replace").splitlines():
                if line.startswith("#") or not line.startswith(METRICS):
                    continue
                name, _, value = line.rpartition(" ")
                try:
                    out[name.strip()] = float(value)
                except ValueError:
                    pass
    except Exception as exc:
        out["_error"] = str(exc)
    return out


def net_bytes():
    rx = tx = 0
    try:
        for line in open("/proc/net/dev").read().splitlines()[2:]:
            iface, _, rest = line.partition(":")
            if iface.strip() in ("lo",) or "veth" in iface or iface.strip().startswith(("cni", "flannel")):
                continue
            f = rest.split()
            rx += int(f[0])
            tx += int(f[8])
    except Exception:
        pass
    return rx, tx


def client_cpu():
    r = resource.getrusage(resource.RUSAGE_SELF)
    c = resource.getrusage(resource.RUSAGE_CHILDREN)
    return r.ru_utime + r.ru_stime + c.ru_utime + c.ru_stime


def delta(before, after, key):
    if key in before and key in after:
        return after[key] - before[key]
    return None


def sum_by(metrics, prefix, **labels):
    total = 0.0
    want = [f'{k}="{v}"' for k, v in labels.items()]
    for name, value in metrics.items():
        if not name.startswith(prefix):
            continue
        if all(w in name for w in want):
            total += value
    return total


# --- the load itself --------------------------------------------------------
parsed = urllib.parse.urlparse(url_base)
if parsed.scheme not in ("http", "https") or not parsed.hostname:
    die(f"--url-base must be http(s)://host[:port], got {url_base}")
HOST, PORT, TLS = parsed.hostname, parsed.port, parsed.scheme == "https"
CTX = ssl.create_default_context() if TLS else None
fixtures = load_fixtures(fixtures_path) if cold_fraction < 1.0 else []
if cold_fraction < 1.0 and not fixtures:
    die(f"{fixtures_path} has no fixtures")


def connect():
    if TLS:
        return http.client.HTTPSConnection(HOST, PORT, timeout=timeout, context=CTX)
    return http.client.HTTPConnection(HOST, PORT, timeout=timeout)


def write_per_request(records):
    """Append one TSV line per completed request. Opened per stage in append
    mode so a run that is killed mid-climb still keeps the stages it finished,
    and so several stages accumulate in one file."""
    if not per_request_out:
        return
    new = not os.path.exists(per_request_out) or os.path.getsize(per_request_out) == 0
    with open(per_request_out, "a") as fh:
        if new:
            fh.write("op\tid\tstatus\tbytes\tservice_ms\ttimed_out\n")
        for r in records:
            status = "" if r.get("status") is None else r["status"]
            nbytes = "" if r.get("bytes") is None else r["bytes"]
            fh.write("%s\t%s\t%s\t%s\t%.3f\t%d\n" % (
                r.get("op", ""), r.get("id", ""), status, nbytes,
                r.get("service_ms", 0.0), 1 if r.get("timed_out") else 0))


class Worker(threading.Thread):
    def __init__(self, jobs, results):
        super().__init__(daemon=True)
        self.jobs, self.results, self.conn = jobs, results, None

    def run(self):
        while True:
            job = self.jobs.get()
            if job is None:
                if self.conn:
                    self.conn.close()
                return
            scheduled, kind, ident = job
            started = time.monotonic()
            rec = {"queue_ms": (started - scheduled) * 1000, "op": kind, "id": ident}
            try:
                if self.conn is None:
                    self.conn = connect()
                self.conn.request("GET", f"/routing/v1/{kind}/{ident}",
                                  headers={"Accept": ACCEPT[kind], "User-Agent": USER_AGENT,
                                           "Host": HOST})
                resp = self.conn.getresponse()
                body = resp.read()
                rec.update(status=resp.status, bytes=len(body), end=time.monotonic(),
                           service_ms=(time.monotonic() - started) * 1000)
                if resp.will_close:
                    self.conn.close()
                    self.conn = None
            except Exception as exc:
                # A socket timeout is the client's own --timeout firing, which is
                # a different thing from the endpoint answering slowly, so record
                # it separately rather than lumping it in with the other errors.
                rec.update(status=None, error=type(exc).__name__, end=time.monotonic(),
                           service_ms=(time.monotonic() - started) * 1000,
                           timed_out=isinstance(exc, (TimeoutError, socket.timeout)))
                try:
                    self.conn.close()
                except Exception:
                    pass
                self.conn = None
            self.results.append(rec)


def next_request(i):
    if cold_fraction >= 1.0 or (cold_fraction > 0 and (i % 100) < cold_fraction * 100):
        return "providers", cold_cid()
    return fixtures[i % len(fixtures)]


def run_stage(rate):
    results = []
    jobs = queue.Queue()
    # The pool must cover rate x latency, or the CLIENT becomes the limit and
    # the achieved rate just reports pool_size / latency. Sized for a 4s
    # response by default: at 200/s that is 800 workers, so a 2.8s endpoint
    # still gets its full offered load. --workers overrides.
    workers = [Worker(jobs, results) for _ in range(pool_size(rate))]
    for w in workers:
        w.start()

    m_before, (rx0, tx0), cpu0 = scrape(), net_bytes(), client_cpu()
    start = time.monotonic()
    total = rate * stage_seconds
    for i in range(total):
        target = start + i / rate
        sleep = target - time.monotonic()
        if sleep > 0:
            time.sleep(sleep)
        jobs.put((target, *next_request(i)))
    dispatch_done = time.monotonic()
    for _ in workers:
        jobs.put(None)
    for w in workers:
        w.join(timeout + 60)
    wall = time.monotonic() - start
    m_after, (rx1, tx1), cpu1 = scrape(), net_bytes(), client_cpu()

    window_end = start + stage_seconds
    in_window = sum(1 for r in results if r.get("end", 0) <= window_end)
    good = [r for r in results if r.get("status") in OK_STATUS]
    failed = [r for r in results if r.get("status") not in OK_STATUS]
    service = [r["service_ms"] for r in good]
    queued = [r["queue_ms"] for r in results]
    write_per_request(results)

    statuses, errors = {}, {}
    for r in results:
        if r.get("error"):
            errors[r["error"]] = errors.get(r["error"], 0) + 1
        else:
            statuses[r["status"]] = statuses.get(r["status"], 0) + 1

    hits = sum_by(m_after, "needle_cached_router_peer_addr_lookups", cache="hit") - \
        sum_by(m_before, "needle_cached_router_peer_addr_lookups", cache="hit")
    misses = sum_by(m_after, "needle_cached_router_peer_addr_lookups", cache="miss") - \
        sum_by(m_before, "needle_cached_router_peer_addr_lookups", cache="miss")
    return {
        "target_rate": rate, "workers": pool_size(rate), "seconds": round(wall, 1),
        "requests": len(results), "errors": len(failed),
        "error_rate": len(failed) / len(results) if results else 1.0,
        # Completions inside the stage window. total/wall would also count the
        # drain after dispatch stops, which makes a slow tail look like lost
        # throughput even when every request succeeded.
        "achieved_rps": round(in_window / stage_seconds, 1),
        "completed_all_rps": round(len(results) / wall, 1) if wall else 0.0,
        "drain_s": round(wall - stage_seconds, 1),
        "dispatch_overrun_s": round(dispatch_done - start - stage_seconds, 1),
        "p50_ms": percentile(service, 50), "p95_ms": percentile(service, 95),
        "p99_ms": percentile(service, 99), "max_ms": max(service) if service else None,
        "queue_p50_ms": percentile(queued, 50), "queue_p95_ms": percentile(queued, 95),
        "bytes_total": sum(r.get("bytes", 0) for r in good),
        "statuses": statuses, "error_kinds": errors,
        "needle_cpu_s": delta(m_before, m_after, "process_cpu_seconds_total"),
        "needle_open_fds": m_after.get("process_open_fds"),
        "needle_goroutines": m_after.get("go_goroutines"),
        "needle_lookups_rejected": delta(
            m_before, m_after, "needle_cached_router_find_peer_lookups_rejected"),
        "needle_lookups_in_flight": m_after.get(
            "needle_cached_router_find_peer_lookups_in_flight"),
        "addr_cache_hits": hits, "addr_cache_misses": misses,
        "addr_cache_hit_rate": hits / (hits + misses) if (hits + misses) else None,
        "client_cpu_s": round(cpu1 - cpu0, 1),
        "net_rx_mbps": round((rx1 - rx0) * 8 / 1e6 / wall, 1) if wall else 0,
        "net_tx_mbps": round((tx1 - tx0) * 8 / 1e6 / wall, 1) if wall else 0,
    }


doc = {
    "schema_version": 1, "started_at": now(), "finished_at": None, "exit_code": None,
    "host": os.uname().nodename,
    "config": {
        "url_base": url_base, "rates": rates, "stage_seconds": stage_seconds,
        "cold_fraction": cold_fraction, "fixtures": fixtures_path,
        "timeout_s": timeout, "max_error_rate": max_error_rate,
    },
    "stages": [],
}

print(f"{doc['host']}: {url_base}, cold_fraction {cold_fraction}, "
      f"rates {rates} x {stage_seconds}s", file=sys.stderr)

stopped = None
for rate in rates:
    stage = run_stage(rate)
    doc["stages"].append(stage)
    print(f"  {rate:>5}/s -> {stage['achieved_rps']:>7.1f}/s  p50 {ms(stage['p50_ms']):>8}"
          f"  p95 {ms(stage['p95_ms']):>8}  drain {stage['drain_s']}s"
          f"  err {stage['error_rate']:.1%}  needle_cpu {stage['needle_cpu_s']}s",
          file=sys.stderr)
    throttled = stage["statuses"].get(429, 0)
    if throttled:
        stopped = f"429 at {rate}/s"
    elif stage["error_rate"] > max_error_rate:
        stopped = f"error rate {stage['error_rate']:.1%} at {rate}/s"
    elif stage["achieved_rps"] < rate * 0.9:
        stopped = (f"achieved {stage['achieved_rps']:.0f}/s of {rate}/s "
                   f"(queue p95 {ms(stage['queue_p95_ms'])})")
    if stopped:
        break

print(f"\n{doc['host']}  {url_base}  cold_fraction={cold_fraction}")
head = (f"{'target':>7} {'actual':>8} {'p50':>8} {'p95':>8} {'p99':>8} {'qp95':>8} "
        f"{'err':>7} {'sg_cpu':>7} {'hit%':>6} {'MB/s':>6}")
print(head)
print("-" * len(head))
for s in doc["stages"]:
    hit = "-" if s["addr_cache_hit_rate"] is None else f"{s['addr_cache_hit_rate']:.0%}"
    cpu = "-" if s["needle_cpu_s"] is None else f"{s['needle_cpu_s']:.1f}s"
    mbs = s["bytes_total"] / 1e6 / s["seconds"] if s["seconds"] else 0
    print(f"{s['target_rate']:>7} {s['achieved_rps']:>8.1f} {ms(s['p50_ms']):>8} "
          f"{ms(s['p95_ms']):>8} {ms(s['p99_ms']):>8} {ms(s['queue_p95_ms']):>8} "
          f"{s['error_rate']:>6.1%} {cpu:>7} {hit:>6} {mbs:>6.1f}")
last = doc["stages"][-1]
print(f"client cpu {last['client_cpu_s']}s/stage, nic rx {last['net_rx_mbps']}Mb/s "
      f"tx {last['net_tx_mbps']}Mb/s, needle fds {last['needle_open_fds']}, "
      f"goroutines {last['needle_goroutines']}, lookups rejected {last['needle_lookups_rejected']}")
print("STOPPED: " + stopped if stopped else "OK: every stage met its target rate")

doc.update(finished_at=now(), exit_code=1 if stopped else 0, stopped=stopped)
if json_out:
    with open(json_out, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    print(f"wrote {json_out}")
sys.exit(1 if stopped else 0)
PYEOF
