#!/usr/bin/env bash
# Unloaded, cache-free latency of our Delegated Routing V1 endpoints (the
# candidates) against a baseline, by default the public delegated-ipfs.dev.
#
# Every fixture is issued exactly once per endpoint. A repeat measurement needs
# a different fixture, not a different URL: a unique query parameter busts
# Cloudflare's URL-keyed cache but not anything keyed on the CID behind it.
# Requests go one at a time, alternating which endpoint sees each fixture
# first, so neither side is ever loaded and drift hits both equally.
#
# Three modes:
#   generate  build per-box fixture files from a cid.contact CloudFront log
#             chunk that has never been replayed (the lists are not committed;
#             each run records the list it used in its --out JSON)
#   measure   the default: calibrate what a cache hit looks like, then measure
#   report    merge several --out files into markdown tables and check that the
#             runs shared no fixture and never overlapped at the baseline
#
# Exit 0: a valid run. 1: the run completed but is invalid (too many suspected
# cache hits, or the baseline answered nothing). 2: bad arguments, a duplicate
# or reused fixture, or the baseline is unreachable.
#
# Usage: ./scripts/routing-latency-vs-baseline.sh [--candidate HOST]...
#          [--baseline HOST] --fixtures FILE [--samples N] [--out FILE]
#        ./scripts/routing-latency-vs-baseline.sh --generate LOG --split BOXES
#          [--exclude FILE]... [--samples N] [--unprovided N] --out-dir DIR
#        ./scripts/routing-latency-vs-baseline.sh --report OUT.json...
# See --help.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/routing-latency-vs-baseline.sh [options]

Measure (default): issues each fixture exactly once to the baseline and once to
each candidate, one request at a time, and reports p50/p95, error rate and
median result count per endpoint per class (found, notfound, unprovided,
peers, ipns). Run it ON a box so the client's own path is not the variable.

  --candidate HOST    endpoint under test; repeatable (default: none; required)
  --baseline HOST     reference endpoint (default: delegated-ipfs.dev)
  --fixtures FILE     fixture file written by --generate (required)
  --samples N         use at most N fixtures per class (default: all)
  --out FILE          write the full results, the fixture list and the box's
                      configuration as JSON
  --ledger FILE       every (endpoint, fixture) issued is appended here, and a
                      run refuses to start if any planned pair is already in it
                      (default: ~/.cache/ipni-routing-latency/issued.tsv)
  --timeout SECONDS   per-request timeout (default: 30)
  --gap SECONDS       pause between requests (default: 0.2)
  --max-suspects N    more suspected cache hits than this makes the run
                      invalid (default: 5)
  --box-config MODE   auto: record image, instances, flags and address-book
                      size from the local k3s when present; off: skip
                      (default: auto)

Generate: --generate LOG builds one fixture file per --split name from a
cid.contact CloudFront log chunk (plain or .gz), deduplicated, with every id
seen in any --exclude file removed, plus fresh unprovided CIDs (CIDv1, raw,
sha2-256 over a unique string). Names are disjoint across the split, so the
baseline never sees a fixture twice even when every box queries it.

  --generate LOG      the log chunk (must never have been replayed)
  --exclude FILE      anything that lists ids already queried (replay
                      fixtures, earlier log chunks, per-request outputs);
                      repeatable, .gz accepted; every alphanumeric run of 32
                      or more characters counts as an id
  --split A,B,...     one fixture file per name, e.g. sing-1,lith-1,chic-1
  --samples N         fixtures per class per file for found, notfound and
                      peers (default: 100); ipns takes what the chunk has
  --unprovided N      generated unprovided CIDs per file (default: 40)
  --seed S            (default: random, recorded in every file)
  --out-dir DIR       where to write <name>.fixtures

Report: --report OUT.json... prints markdown tables per class and per box, and
checks that no fixture appears in two runs and that no two runs' baseline
requests overlapped in time.

  -h, --help          show this help

A cache hit is not assumed away. Before measuring, a fresh fixture of each
class is queried twice on every endpoint; if a cache header says the second
was a hit, or it is at least 3x faster than the first and within 3x of the
endpoint's /version round trip (a bare network trip through Cloudflare), that
establishes what a hit looks like there. A measured sample is suspect when a
cache header says it was served from cache, or when its latency is at or below
1.5x the calibrated hit latency. An endpoint and class with no confirmed hit of
its own uses the fastest hit confirmed anywhere in the run instead (usually the
baseline's CDN edge): nothing cold answers faster than a cache hit. Suspects
are excluded from the statistics and counted in every report.
EOF
}

mode=measure
baseline=delegated-ipfs.dev
candidates=()
fixtures=
samples=
out=
ledger="${HOME:-/tmp}/.cache/ipni-routing-latency/issued.tsv"
timeout=30
gap=0.2
max_suspects=5
box_config=auto
log=
excludes=()
split=
unprovided=40
seed=
out_dir=
reports=()

need_value() {
  if [[ $# -lt 2 || -z $2 ]]; then
    echo "error: $1 needs a value (see --help)" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --candidate)    need_value "$@"; candidates+=("$2"); shift 2 ;;
    --baseline)     need_value "$@"; baseline=$2; shift 2 ;;
    --fixtures)     need_value "$@"; fixtures=$2; shift 2 ;;
    --samples)      need_value "$@"; samples=$2; shift 2 ;;
    --out)          need_value "$@"; out=$2; shift 2 ;;
    --ledger)       need_value "$@"; ledger=$2; shift 2 ;;
    --timeout)      need_value "$@"; timeout=$2; shift 2 ;;
    --gap)          need_value "$@"; gap=$2; shift 2 ;;
    --max-suspects) need_value "$@"; max_suspects=$2; shift 2 ;;
    --box-config)   need_value "$@"; box_config=$2; shift 2 ;;
    --generate)     need_value "$@"; mode=generate; log=$2; shift 2 ;;
    --exclude)      need_value "$@"; excludes+=("$2"); shift 2 ;;
    --split)        need_value "$@"; split=$2; shift 2 ;;
    --unprovided)   need_value "$@"; unprovided=$2; shift 2 ;;
    --seed)         need_value "$@"; seed=$2; shift 2 ;;
    --out-dir)      need_value "$@"; out_dir=$2; shift 2 ;;
    --report)       mode=report; shift
                    while [[ $# -gt 0 && $1 != --* ]]; do reports+=("$1"); shift; done ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "error: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

posint() { [[ $2 =~ ^[1-9][0-9]*$ ]] || { echo "error: $1 must be a positive integer" >&2; exit 2; }; }
command -v python3 >/dev/null || { echo "error: python3 is required" >&2; exit 2; }

case $mode in
  generate)
    [[ -r $log ]] || { echo "error: cannot read log chunk $log" >&2; exit 2; }
    [[ -n $split ]] || { echo "error: --generate needs --split" >&2; exit 2; }
    [[ -n $out_dir ]] || { echo "error: --generate needs --out-dir" >&2; exit 2; }
    posint --samples "${samples:-100}"
    posint --unprovided "$unprovided"
    for f in "${excludes[@]}"; do
      [[ -r $f ]] || { echo "error: cannot read exclude file $f" >&2; exit 2; }
    done
    ;;
  report)
    [[ ${#reports[@]} -gt 0 ]] || { echo "error: --report needs at least one JSON file" >&2; exit 2; }
    ;;
  measure)
    [[ ${#candidates[@]} -gt 0 ]] || { echo "error: at least one --candidate is required" >&2; exit 2; }
    [[ -r $fixtures ]] || { echo "error: cannot read fixtures file ${fixtures:-(none given)}" >&2; exit 2; }
    [[ -z $samples ]] || posint --samples "$samples"
    posint --timeout "$timeout"
    [[ $max_suspects =~ ^[0-9]+$ ]] || { echo "error: --max-suspects must be a non-negative integer" >&2; exit 2; }
    [[ $gap =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "error: --gap must be a number of seconds" >&2; exit 2; }
    [[ $box_config == auto || $box_config == off ]] || { echo "error: --box-config is auto or off" >&2; exit 2; }
    command -v curl >/dev/null || { echo "error: curl is required" >&2; exit 2; }
    ;;
esac

export RLB_MODE=$mode RLB_BASELINE=$baseline RLB_FIXTURES=$fixtures \
  RLB_SAMPLES=${samples:-} RLB_OUT=$out RLB_LEDGER=$ledger RLB_TIMEOUT=$timeout \
  RLB_GAP=$gap RLB_MAX_SUSPECTS=$max_suspects RLB_BOX_CONFIG=$box_config \
  RLB_LOG=$log RLB_SPLIT=$split RLB_UNPROVIDED=$unprovided RLB_SEED=$seed \
  RLB_OUT_DIR=$out_dir
# Lists go through the argument vector, separated by a lone `--`.
exec python3 - "${candidates[@]}" -- "${excludes[@]}" -- "${reports[@]}" <<'EOF'
import base64, datetime, gzip, hashlib, json, math, os, random, re, statistics
import subprocess, sys, time, uuid

env = os.environ
argv = sys.argv[1:]
first = argv.index("--")
second = argv.index("--", first + 1)
CANDIDATES = list(dict.fromkeys(argv[:first]))
EXCLUDES = argv[first + 1:second]
REPORTS = argv[second + 1:]

# Classes, in report order, and the API path each one queries.
CLASSES = {"found": "providers", "notfound": "providers", "unprovided": "providers",
           "peers": "peers", "ipns": "ipns"}
# Providers and peers are asked for as one JSON document (the default is NDJSON
# streaming). IPNS has no JSON form; both delegated-ipfs.dev and someguy answer
# application/json with 406, so records come as application/vnd.ipfs.ipns-record.
ACCEPT = {"providers": "application/json", "peers": "application/json",
          "ipns": "application/vnd.ipfs.ipns-record"}
# A missing record is `200 text/plain` with this body, or a 404: no result, not
# an error.
NOT_FOUND = b"routing: not found"
# Cache statuses that mean the answer came out of a cache, not the origin.
CACHED = {"HIT", "STALE", "UPDATING", "REVALIDATED"}
CONFIRM_RATIO = 3.0     # second answer at least 3x faster than the first,
FLOOR_FACTOR = 3.0      # and within 3x of the endpoint's /version round trip
CEILING_FACTOR = 1.5    # suspect at or below 1.5x the calibrated hit latency
USER_AGENT = "ipni-workers-routing-latency/1 (+https://github.com/ipni/workers)"
ANYCAST = ("delegated-ipfs.dev is anycast: each box is compared with whichever "
           "Cloudflare PoP and origin served it, which is what a user in that "
           "region gets, not a like-for-like origin comparison. Where caching "
           "lives differs too (their edge caches repeats; ours is DYNAMIC at the "
           "edge), which is a real difference, but every number here is a cold "
           "lookup on both sides.")
# Anything in an exclude file that could be an id: every alphanumeric run of 32
# or more. Over-matching only excludes more; matching by prefix missed IPNS
# names that are not k51 (k2k4r8... is an RSA key), so shape is not trusted.
ID_RE = re.compile(r"[A-Za-z0-9]{32,}")


def die(msg, code=2):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def open_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", errors="replace")
    return open(path, errors="replace")


def percentile(values, p):
    """Nearest-rank percentile."""
    if not values:
        return None
    values = sorted(values)
    return values[max(0, math.ceil(p / 100 * len(values)) - 1)]


# --- fixture ids generated offline ------------------------------------------
def raw_cid(text):
    """CIDv1, raw codec, sha2-256 of text, base32: content nobody provides."""
    digest = hashlib.sha256(text.encode()).digest()
    data = bytes([0x01, 0x55, 0x12, 0x20]) + digest
    return "b" + base64.b32encode(data).decode().lower().rstrip("=")


def ipns_name(text):
    """An IPNS name (CIDv1 libp2p-key, base36) for an ed25519 key derived from
    text: a name nobody has published."""
    key = hashlib.sha256(text.encode()).digest()
    pub = bytes([0x08, 0x01, 0x12, 0x20]) + key         # protobuf PublicKey
    data = bytes([0x01, 0x72, 0x00, len(pub)]) + pub    # CIDv1, identity mh
    n, digits = int.from_bytes(data, "big"), ""
    while n:
        n, r = divmod(n, 36)
        digits = "0123456789abcdefghijklmnopqrstuvwxyz"[r] + digits
    return "k" + digits


# --- fixture files ----------------------------------------------------------
def load_fixtures(path):
    """Returns (meta, fixtures, raw lines). A fixture line is `class id`; the
    first `#@ {json}` line is the generator's metadata. Any id twice is fatal."""
    meta, fixtures, seen = {}, [], {}
    raw = open(path).read()
    for lineno, line in enumerate(raw.splitlines(), 1):
        if line.startswith("#@ ") and not meta:
            meta = json.loads(line[3:])
            continue
        body = line.partition("#")[0].split()
        if not body:
            continue
        if len(body) != 2:
            die(f"{path}:{lineno}: expected `class id`")
        cls, ident = body
        role = "measure"
        if cls.startswith("calibrate-"):
            role, cls = "calibrate", cls[len("calibrate-"):]
        if cls not in CLASSES:
            die(f"{path}:{lineno}: unknown class {cls!r}")
        if ident in seen:
            die(f"{path}:{lineno}: {ident} duplicates line {seen[ident]}; "
                "every fixture is single-use, refusing to run")
        seen[ident] = lineno
        fixtures.append({"class": cls, "id": ident, "role": role})
    if not any(f["role"] == "measure" for f in fixtures):
        die(f"{path} has no fixtures to measure")
    return meta, fixtures, raw


# --- generate ---------------------------------------------------------------
def generate():
    log_path, names = env["RLB_LOG"], [n for n in env["RLB_SPLIT"].split(",") if n]
    per_class, n_unprovided = int(env["RLB_SAMPLES"] or 100), int(env["RLB_UNPROVIDED"])
    seed = env["RLB_SEED"] or uuid.uuid4().hex
    if len(set(names)) != len(names):
        die("--split names must be distinct")

    excluded, exclude_meta = set(), []
    for path in EXCLUDES:
        ids = set()
        with open_text(path) as f:
            for line in f:
                ids.update(ID_RE.findall(line))
        excluded |= ids
        exclude_meta.append({"path": os.path.basename(path), "sha256": sha256_file(path),
                             "ids": len(ids)})

    requests, statuses = {}, {}
    found, notfound, unknown, peers, ipns = set(), set(), set(), set(), set()
    fields, first_ts, last_ts = None, None, None
    with open_text(log_path) as f:
        for line in f:
            if line.startswith("#Fields:"):
                fields = line.split(":", 1)[1].split()
                continue
            if line.startswith("#") or not fields:
                continue
            row = dict(zip(fields, line.rstrip("\n").split("\t")))
            parts = row.get("cs-uri-stem", "").split("/")
            if len(parts) < 5 or parts[1:3] != ["routing", "v1"] or not parts[4]:
                continue
            kind, ident, status = parts[3], parts[4], row.get("sc-status", "")
            if kind not in ACCEPT or not re.fullmatch(r"[A-Za-z0-9]+", ident):
                continue
            stamp = f"{row.get('date', '')} {row.get('time', '')}"
            first_ts = min(first_ts or stamp, stamp)
            last_ts = max(last_ts or stamp, stamp)
            requests[kind] = requests.get(kind, 0) + 1
            key = f"{kind} {status}"
            statuses[key] = statuses.get(key, 0) + 1
            if kind == "providers":
                (found if status == "200" else notfound if status == "404" else unknown).add(ident)
            elif kind == "peers":
                peers.add(ident)
            else:
                ipns.add(ident)
    if fields is None:
        die(f"{log_path} is not a CloudFront log (no #Fields line)")
    notfound -= found           # found at least once wins
    unknown -= found | notfound  # only ever 000 (client gave up): unclassifiable
    total = sum(requests.values())
    if not total:
        die(f"{log_path} has no /routing/v1 requests")
    prov = requests.get("providers", 0)
    proportions = {
        "requests": total,
        "by_request": {
            "found": statuses.get("providers 200", 0) / total,
            "notfound": statuses.get("providers 404", 0) / total,
            "providers_unanswered": (prov - statuses.get("providers 200", 0)
                                     - statuses.get("providers 404", 0)) / total,
            "peers": requests.get("peers", 0) / total,
            "ipns": requests.get("ipns", 0) / total,
        },
        "providers_found_share": statuses.get("providers 200", 0) / prov if prov else None,
        "distinct": {"found": len(found), "notfound": len(notfound),
                     "unanswered_only": len(unknown), "peers": len(peers), "ipns": len(ipns)},
    }

    rng = random.Random(seed)
    pools, dropped = {}, {}
    for cls, ids in (("found", found), ("notfound", notfound), ("peers", peers), ("ipns", ipns)):
        keep = sorted(ids - excluded)
        dropped[cls] = len(ids) - len(keep)
        rng.shuffle(keep)
        pools[cls] = keep

    # Calibration takes one real fixture per class per file up front; ipns
    # calibrates on a generated name, the chunk has too few real ones to spare.
    k = len(names)
    plan = {n: [] for n in names}
    for cls in ("found", "notfound", "peers"):
        need = k * (per_class + 1)
        if len(pools[cls]) < need:
            print(f"warning: only {len(pools[cls])} usable {cls} ids for {need} wanted; "
                  "files get fewer", file=sys.stderr)
        pool = pools[cls]
        for i, n in enumerate(names):
            share = pool[i::k][:per_class + 1]
            if share:
                plan[n].append((f"calibrate-{cls}", share[0], "from the chunk"))
                plan[n] += [(cls, x, "from the chunk") for x in share[1:]]
    for i, n in enumerate(names):
        plan[n] += [("ipns", x, "from the chunk") for x in pools["ipns"][i::k]]
        tag = f"ipni-workers/routing-latency-vs-baseline/{seed}/{n}"
        plan[n].append(("calibrate-unprovided", raw_cid(f"{tag}/calibrate"),
                        f'raw CID of sha256("{tag}/calibrate")'))
        plan[n].append(("calibrate-ipns", ipns_name(f"{tag}/calibrate-ipns"),
                        f'ed25519 key sha256("{tag}/calibrate-ipns")'))
        plan[n] += [("unprovided", raw_cid(f"{tag}/{j}"), f'raw CID of sha256("{tag}/{j}")')
                    for j in range(n_unprovided)]

    every = [x for n in names for _, x, _ in plan[n]]
    assert len(every) == len(set(every)), "generator produced a duplicate"

    os.makedirs(env["RLB_OUT_DIR"], exist_ok=True)
    chunk = os.path.basename(log_path)
    for n in names:
        meta = {"generator": "routing-latency-vs-baseline.sh --generate", "generated_at": now(),
                "seed": seed, "split": names, "file": n,
                "chunk": {"name": chunk, "sha256": sha256_file(log_path),
                          "first": first_ts, "last": last_ts},
                "excludes": exclude_meta, "excluded_from_chunk": dropped,
                "proportions": proportions}
        path = os.path.join(env["RLB_OUT_DIR"], f"{n}.fixtures")
        with open(path, "w") as f:
            f.write("#@ " + json.dumps(meta, sort_keys=True) + "\n")
            f.write(f"# Fixtures for routing-latency-vs-baseline.sh, file {n} of "
                    f"{','.join(names)}.\n# Every id is single-use: issue it once per "
                    "endpoint, never again.\n")
            for cls, x, note in plan[n]:
                f.write(f"{cls} {x}  # {note}\n")
        counts = {}
        for cls, _, _ in plan[n]:
            counts[cls] = counts.get(cls, 0) + 1
        print(f"{path}: " + ", ".join(f"{c} {v}" for c, v in counts.items()))
    print(f"chunk {chunk}: {total} routing requests {first_ts} to {last_ts}; "
          f"removed as already seen: {dropped}")


# --- measure ----------------------------------------------------------------
def curl(url, accept, timeout):
    """One request. Returns a dict of what curl saw."""
    cmd = ["curl", "-sS", "--max-time", str(timeout), "--connect-timeout", str(min(10, timeout)),
           "-A", USER_AGENT, "-H", f"Accept: {accept}",
           "-D", "-", "-o", "-", "-w", "%{stderr}%{json}", url]
    t0 = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout + 15)
    except subprocess.TimeoutExpired:
        return {"code": -1, "start": t0, "end": time.time(), "error": "curl did not exit"}
    t1 = time.time()
    err = p.stderr.decode(errors="replace")
    info, start = {}, err.rfind("{")
    while start != -1:
        try:
            info = json.loads(err[start:])
            break
        except json.JSONDecodeError:
            start = err.rfind("{", 0, start)
    head, _, body = p.stdout.partition(b"\r\n\r\n")
    headers = {}
    for line in head.decode(errors="replace").splitlines()[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return {"code": p.returncode, "start": t0, "end": t1,
            "status": info.get("http_code", 0), "secs": info.get("time_total", 0.0),
            "ctype": (info.get("content_type") or "").split(";")[0].strip(),
            "headers": headers, "body": body,
            "error": info.get("errormsg") or (err[:start].strip() if start > 0 else None)}


def query(host, cls, ident, timeout, unique=True):
    kind = CLASSES[cls]
    # The parameter keeps Cloudflare's URL-keyed cache out of it on both sides;
    # single-use fixtures keep everything keyed on the id out of it.
    tag = uuid.uuid4().hex if unique else "calibrate-repeat"
    url = f"https://{host}/routing/v1/{kind}/{ident}?routing-latency={tag}"
    r = curl(url, ACCEPT[kind], timeout)
    h = r.get("headers", {})
    ray = h.get("cf-ray", "")
    rec = {"endpoint": host, "class": cls, "id": ident, "param": tag,
           "start": round(r["start"], 3), "end": round(r["end"], 3),
           "status": r.get("status") or None,
           "ms": round(r["secs"] * 1000, 1) if r.get("secs") else None,
           "count": None, "error": None,
           "cache": h.get("cf-cache-status"), "age": h.get("age"),
           "pop": ray.rsplit("-", 1)[1] if "-" in ray else None,
           "origin": h.get("x-ipfs-pop")}
    if r["code"] != 0:
        rec["error"] = f"curl exit {r['code']}: {r.get('error')}"
        return rec
    status, ctype, body = r["status"], r["ctype"], r["body"]
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


def run(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout if p.returncode == 0 else None


def box_state(ports):
    """Address-book size and /version per local instance."""
    state = {}
    for port in ports:
        metrics = run(["curl", "-s", "--max-time", "5",
                       f"http://127.0.0.1:{port}/debug/metrics/prometheus"]) or ""
        size = None
        for line in metrics.splitlines():
            if line.startswith("someguy_cached_addr_book_peer_state_size"):
                size = float(line.split()[-1])
        version = run(["curl", "-s", "--max-time", "5", f"http://127.0.0.1:{port}/version"])
        state[str(port)] = {"addr_book_peer_state_size": size,
                            "version": version.strip() if version else None}
    return state


# Set per instance by the manifests, so they say nothing about the build.
PER_INSTANCE = {"SOMEGUY_LISTEN_ADDRESS", "SOMEGUY_LIBP2P_LISTEN_ADDRS", "SOMEGUY_DATADIR"}


def box_config():
    """The box this runs on, from its k3s: image, instance count, every
    explicitly set variable (someguy's defaults apply to anything not set)."""
    if env["RLB_BOX_CONFIG"] == "off":
        return {"recorded": False, "reason": "--box-config off"}
    kubectl = ["sudo", "-n", "k3s", "kubectl", "-n", "someguy"]
    deploys = run(kubectl + ["get", "deploy", "-o", "json"])
    if deploys is None:
        return {"recorded": False, "reason": "no local k3s (not run on a box?)"}
    cfg = {"recorded": True, "hostname": os.uname().nodename, "instances": [], "flags": {}}
    cms = {}
    for d in json.loads(deploys)["items"]:
        c = d["spec"]["template"]["spec"]["containers"][0]
        flags = {}
        for ref in c.get("envFrom", []):
            name = (ref.get("configMapRef") or {}).get("name")
            if name and name not in cms:
                raw = run(kubectl + ["get", "configmap", name, "-o", "json"])
                cms[name] = json.loads(raw).get("data", {}) if raw else {}
            flags.update(cms.get(name, {}))
        for e in c.get("env", []):
            flags[e["name"]] = e.get("value", "(valueFrom)")
        port = flags.get("SOMEGUY_LISTEN_ADDRESS", "").rpartition(":")[2]
        cfg["instances"].append({
            "name": d["metadata"]["name"], "image": c["image"],
            "ready": d.get("status", {}).get("readyReplicas", 0), "port": port,
            "flags": {k: v for k, v in sorted(flags.items()) if k not in PER_INSTANCE}})
    ready = [i for i in cfg["instances"] if i["ready"]]
    cfg["instance_count"] = len(ready)
    cfg["images"] = sorted({i["image"] for i in cfg["instances"]})
    # Flags common to every instance, then whatever differs per instance.
    common = None
    for i in cfg["instances"]:
        items = set(i["flags"].items())
        common = items if common is None else common & items
    cfg["flags"] = dict(sorted(common or []))
    cfg["flags_per_instance"] = {i["name"]: {k: v for k, v in i["flags"].items()
                                             if (k, v) not in (common or set())}
                                 for i in cfg["instances"]}
    cfg["ports"] = [i["port"] for i in ready if i["port"].isdigit()]
    return cfg


def ledger_load(path):
    issued = set()
    if os.path.exists(path):
        for line in open(path):
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 2:
                issued.add((fields[0], fields[1]))
    return issued


def measure():
    baseline, timeout, gap = env["RLB_BASELINE"], int(env["RLB_TIMEOUT"]), float(env["RLB_GAP"])
    candidates = [c for c in CANDIDATES if c != baseline]
    if not candidates:
        die("need at least one candidate different from the baseline")
    endpoints = [baseline] + candidates
    meta, fixtures, raw = load_fixtures(env["RLB_FIXTURES"])
    cap = int(env["RLB_SAMPLES"]) if env["RLB_SAMPLES"] else None

    calib = [f for f in fixtures if f["role"] == "calibrate"]
    measured, taken = [], {}
    for f in fixtures:
        if f["role"] == "measure" and (cap is None or taken.get(f["class"], 0) < cap):
            taken[f["class"]] = taken.get(f["class"], 0) + 1
            measured.append(f)
    # Interleave the classes so drift over the run spreads across all of them.
    order_seed = uuid.uuid4().hex
    random.Random(order_seed).shuffle(measured)

    ledger_path = env["RLB_LEDGER"]
    issued = ledger_load(ledger_path)
    planned = {(h, f["id"]) for f in calib + measured for h in endpoints}
    reused = planned & issued
    if reused:
        die(f"{len(reused)} (endpoint, fixture) pairs were already issued according to "
            f"{ledger_path}, e.g. {sorted(reused)[0]}; generate fresh fixtures")
    os.makedirs(os.path.dirname(ledger_path) or ".", exist_ok=True)
    ledger = open(ledger_path, "a")
    sent = set()
    requests = []   # every request in the order it was sent, calibration included

    def send(host, f, unique=True, allow_repeat=False):
        key = (host, f["id"])
        if key in sent and not allow_repeat:
            die(f"refusing to issue {f['id']} to {host} a second time")
        sent.add(key)
        ledger.write(f"{host}\t{f['id']}\t{now()}\n")
        ledger.flush()
        rec = query(host, f["class"], f["id"], timeout, unique)
        requests.append(rec)
        time.sleep(gap)
        return rec

    doc = {"schema_version": 1, "tool": "routing-latency-vs-baseline.sh",
           "host": os.uname().nodename, "started_at": now(), "finished_at": None, "exit_code": None, "valid": None,
           "caveat": ANYCAST,
           "config": {"baseline": baseline, "candidates": candidates,
                      "fixtures_file": os.path.basename(env["RLB_FIXTURES"]),
                      "fixtures_sha256": hashlib.sha256(raw.encode()).hexdigest(),
                      "samples_cap": cap, "timeout_s": timeout, "gap_s": gap,
                      "order_seed": order_seed, "max_suspects": int(env["RLB_MAX_SUSPECTS"]),
                      "confirm_ratio": CONFIRM_RATIO, "floor_factor": FLOOR_FACTOR, "ceiling_factor": CEILING_FACTOR,
                      "concurrency": 1},
           "fixtures_meta": meta, "fixtures_list": raw,
           "box": None, "box_state_before": None, "box_state_after": None,
           "network_floor_ms": {}, "calibration": {}, "ceilings_ms": {}, "requests": [], "summary": {},
           "pops": {}, "order_effect": {}, "checks": {}}

    def write_out():
        if env["RLB_OUT"]:
            doc["requests"] = requests
            with open(env["RLB_OUT"], "w") as out:
                json.dump(doc, out, indent=1)
                out.write("\n")

    box = box_config()
    doc["box"] = box
    ports = box.get("ports") or []
    doc["box_state_before"] = box_state(ports) if ports else None

    version = run(["curl", "-sS", "--max-time", "15", "-o", "/dev/null", "-w", "%{http_code}",
                   "-A", USER_AGENT, f"https://{baseline}/version"])
    if not version or version.strip() == "000":
        doc.update(finished_at=now(), exit_code=2)
        write_out()
        die(f"baseline {baseline} is unreachable; nothing to compare against")

    # The network floor per endpoint: a /version round trip, median of three.
    for h in endpoints:
        trips = [curl(f"https://{h}/version", "*/*", 15) for _ in range(3)]
        doc["network_floor_ms"][h] = percentile(
            [t["secs"] * 1000 for t in trips if t["code"] == 0 and t.get("secs")], 50)

    print(f"baseline {baseline}; candidates {', '.join(candidates)}; "
          f"{len(measured)} fixtures x {len(endpoints)} endpoints, one request at a time",
          file=sys.stderr)

    # --- calibration: what does a cache hit look like here? ------------------
    # Each calibration fixture goes to every endpoint twice in a row. On the
    # baseline the second is the same URL, so its edge cache can answer it; on
    # candidates the URL differs, so only a cache keyed on the id can.
    for f in calib:
        for h in endpoints:
            same_url = h == baseline
            a = send(h, f, unique=not same_url)
            b = send(h, f, unique=not same_url, allow_repeat=True)
            ok = a["ms"] is not None and b["ms"] is not None and not a["error"] and not b["error"]
            ratio = (a["ms"] / b["ms"]) if ok and b["ms"] else None
            header_hit = (b.get("cache") or "").upper() in CACHED
            floor_ms = doc["network_floor_ms"].get(h)
            near_floor = floor_ms is not None and ok and b["ms"] <= FLOOR_FACTOR * floor_ms
            confirmed = bool(ok and (header_hit or ((ratio or 0) >= CONFIRM_RATIO and near_floor)))
            doc["calibration"].setdefault(h, {})[f["class"]] = {
                "id": f["id"], "first_ms": a["ms"], "second_ms": b["ms"],
                "ratio": round(ratio, 2) if ratio else None,
                "first_cache": a.get("cache"), "second_cache": b.get("cache"),
                "confirmed": confirmed}
    # Ceilings. A confirmed endpoint/class uses its own hit latency; everything
    # else uses the fastest confirmed hit anywhere as a floor (nothing cold
    # answers faster than a cache hit), and has no latency rule if there is none.
    confirmed_hits = [c["second_ms"] for cal in doc["calibration"].values()
                      for c in cal.values() if c["confirmed"]]
    floor = round(min(confirmed_hits) * CEILING_FACTOR, 1) if confirmed_hits else None
    for h in endpoints:
        for cls in CLASSES:
            c = doc["calibration"].get(h, {}).get(cls)
            if c and c["confirmed"]:
                doc["ceilings_ms"].setdefault(h, {})[cls] = {
                    "ms": round(c["second_ms"] * CEILING_FACTOR, 1), "source": "own calibration"}
            else:
                doc["ceilings_ms"].setdefault(h, {})[cls] = {
                    "ms": floor, "source": "floor: fastest confirmed hit anywhere" if floor
                    else "none: no hit was confirmed anywhere"}

    # --- measurement ------------------------------------------------------------
    for i, f in enumerate(measured):
        # Rotate who goes first. Both sides share upstreams (cid.contact), so
        # the second to ask can find them warm; rotating splits that evenly.
        k = i % len(endpoints)
        for pos, h in enumerate(endpoints[k:] + endpoints[:k]):
            rec = send(h, f)
            rec["position"] = pos
            rec["measured"] = True
            ceiling = doc["ceilings_ms"][h][f["class"]]["ms"]
            reasons = []
            if (rec.get("cache") or "").upper() in CACHED:
                reasons.append(f"cf-cache-status {rec['cache']}")
            if rec["ms"] is not None and ceiling is not None and rec["ms"] <= ceiling:
                reasons.append(f"{rec['ms']}ms <= hit ceiling {ceiling}ms")
            rec["suspect"] = "; ".join(reasons) or None
        print(f"\r  {i + 1}/{len(measured)}", end="", file=sys.stderr, flush=True)
    print(file=sys.stderr)
    ledger.close()
    doc["box_state_after"] = box_state(ports) if ports else None

    # --- checks -----------------------------------------------------------------
    spans = sorted((r["start"], r["end"]) for r in requests)
    overlaps = sum(1 for a, b in zip(spans, spans[1:]) if b[0] < a[1])
    per_endpoint = {}
    for r in requests:
        if r.get("measured"):
            per_endpoint.setdefault((r["endpoint"], r["id"]), 0)
            per_endpoint[(r["endpoint"], r["id"])] += 1
    measured_ids = [f["id"] for f in measured]
    calib_ids = {f["id"] for f in calib}
    doc["checks"] = {
        "overlapping_requests": overlaps,
        "max_issues_per_endpoint_per_fixture": max(per_endpoint.values()),
        "fixture_ids_distinct": len(measured_ids) == len(set(measured_ids)),
        "calibration_ids_disjoint_from_measured": not (calib_ids & set(measured_ids)),
        "unprovided_distinct": len({f["id"] for f in measured if f["class"] == "unprovided"})
                               == sum(f["class"] == "unprovided" for f in measured),
    }
    assert overlaps == 0, "two requests overlapped"

    # --- summary ----------------------------------------------------------------
    meas = [r for r in requests if r.get("measured")]
    for h in endpoints:
        doc["summary"][h] = {}
        for cls in CLASSES:
            rs = [r for r in meas if r["endpoint"] == h and r["class"] == cls]
            if not rs:
                continue
            clean = [r for r in rs if not r["suspect"]]
            good = [r for r in clean if not r["error"]]
            counts = [r["count"] for r in good]
            doc["summary"][h][cls] = {
                "n": len(rs), "suspects": len(rs) - len(clean),
                "errors": len(clean) - len(good),
                "error_rate": (len(clean) - len(good)) / len(clean) if clean else None,
                "p50_ms": percentile([r["ms"] for r in good], 50),
                "p95_ms": percentile([r["ms"] for r in good], 95),
                "median_count": statistics.median(counts) if counts else None,
                "nonempty_share": sum(c > 0 for c in counts) / len(counts) if counts else None,
            }
        pops = {}
        for r in (r for r in requests if r["endpoint"] == h):
            key = f"{r['pop'] or '?'}" + (f" -> {r['origin']}" if r["origin"] else "")
            pops[key] = pops.get(key, 0) + 1
        doc["pops"][h] = dict(sorted(pops.items(), key=lambda kv: -kv[1]))
        doc["order_effect"][h] = {
            str(p): percentile([r["ms"] for r in meas if r["endpoint"] == h and r["position"] == p
                                and not r["error"] and not r["suspect"]], 50)
            for p in range(len(endpoints))}

    suspects = sum(1 for r in meas if r["suspect"])
    baseline_good = sum(1 for r in meas if r["endpoint"] == baseline and not r["error"])
    doc["suspects_total"] = suspects
    doc["valid"] = suspects <= int(env["RLB_MAX_SUSPECTS"]) and baseline_good > 0
    status = 0 if doc["valid"] else 1
    print_run(doc)
    doc.update(finished_at=now(), exit_code=status)
    write_out()
    if env["RLB_OUT"]:
        print(f"\nwrote {env['RLB_OUT']}")
    sys.exit(status)


# --- output -----------------------------------------------------------------
def ms(v):
    return "-" if v is None else f"{v:.0f}ms"


def pct(v):
    return "-" if v is None else f"{v:.0%}"


def num(v):
    return "-" if v is None else (f"{v:.0f}" if v == int(v) else f"{v:.1f}")


def short(host):
    return host[:-len(".ipni.io")] if host.endswith(".ipni.io") else host


def print_run(doc):
    base = doc["config"]["baseline"]
    endpoints = [base] + doc["config"]["candidates"]
    box = doc["box"]
    print(f"\nRun from {doc['host']}", end="")
    if box.get("recorded"):
        sizes = [s["addr_book_peer_state_size"] for s in (doc["box_state_before"] or {}).values()]
        print(f": {box['instance_count']} instances, image {', '.join(box['images'])}, "
              f"address book {', '.join(num(s) for s in sizes)}")
    else:
        print(f" ({box.get('reason')})")
    print("\nCalibration (same fixture twice in a row)")
    for h, cal in doc["calibration"].items():
        for cls, c in cal.items():
            print(f"  {short(h):<20} {cls:<11} {ms(c['first_ms']):>8} then {ms(c['second_ms']):>8}"
                  f"  x{c['ratio'] or '-':<6} cache {c['first_cache'] or '-'}/{c['second_cache'] or '-'}"
                  f"  {'HIT CONFIRMED' if c['confirmed'] else 'no dramatic hit'}")
    print("\nPer class (suspects excluded; latency over successful requests)")
    print(f"{'class':<11} {'endpoint':<20} {'n':>4} {'p50':>8} {'p95':>8} {'errors':>7} "
          f"{'med.results':>11} {'non-empty':>9} {'suspect':>7}")
    for cls in CLASSES:
        for h in endpoints:
            s = doc["summary"].get(h, {}).get(cls)
            if s:
                print(f"{cls:<11} {short(h):<20} {s['n']:>4} {ms(s['p50_ms']):>8} {ms(s['p95_ms']):>8} "
                      f"{pct(s['error_rate']):>7} {num(s['median_count']):>11} "
                      f"{pct(s['nonempty_share']):>9} {s['suspects']:>7}")
    print("\nPoPs reached (cf-ray suffix -> x-ipfs-pop origin, requests)")
    for h, pops in doc["pops"].items():
        print(f"  {short(h):<20} " + ", ".join(f"{k} x{v}" for k, v in pops.items()))
    print("\nOrder effect, p50 by position (0 = asked first)")
    for h, eff in doc["order_effect"].items():
        print(f"  {short(h):<20} " + ", ".join(f"{p}: {ms(v)}" for p, v in eff.items()))
    props = (doc["fixtures_meta"].get("proportions") or {}).get("by_request")
    if props:
        print("\nClass mix of the sampled log chunk, by request: " +
              ", ".join(f"{k} {v:.1%}" for k, v in props.items()))
    print(f"\n{doc['caveat']}")
    print(f"\nSuspected cache hits: {doc['suspects_total']} "
          f"(limit {doc['config']['max_suspects']}); concurrent requests: "
          f"{doc['checks']['overlapping_requests']}; "
          f"{'VALID' if doc['valid'] else 'INVALID'} run")


def report():
    docs = []
    for path in REPORTS:
        with open(path) as f:
            docs.append((path, json.load(f)))
    # Cross-run checks: disjoint fixtures, and never two runs at the baseline at once.
    owner, clash = {}, []
    for path, d in docs:
        for r in d["requests"]:
            prev = owner.setdefault(r["id"], path)
            if prev != path:
                clash.append(r["id"])
    spans = sorted((r["start"], r["end"], path) for path, d in docs for r in d["requests"]
                   if r["endpoint"] == d["config"]["baseline"])
    overlap = sum(1 for a, b in zip(spans, spans[1:]) if b[0] < a[1])
    print(f"Runs: {len(docs)}; fixtures shared between runs: {len(set(clash))}; "
          f"overlapping baseline requests across runs: {overlap}\n")
    print("| Box | Image | Instances | Non-default flags | Address book (per instance) | Suspects | Valid |")
    print("|-----|-------|-----------|-------------------|------------------------------|----------|-------|")
    for path, d in docs:
        b = d["box"]
        sizes = ", ".join(num(s["addr_book_peer_state_size"])
                          for s in (d["box_state_before"] or {}).values()) or "-"
        flags = ", ".join(f"`{k}={v}`" for k, v in (b.get("flags") or {}).items())
        extra = {k: v for per in (b.get("flags_per_instance") or {}).values() for k, v in per.items()}
        if extra:
            flags += "; per instance: " + ", ".join(f"`{k}={v}`" for k, v in extra.items())
        print(f"| {d['host']} | {', '.join(b.get('images', [])) or '-'} | "
              f"{b.get('instance_count', '-')} | {flags or '-'} | {sizes} | "
              f"{d['suspects_total']} | {'yes' if d['valid'] else 'NO'} |")
    for cls in CLASSES:
        print(f"\n**{cls}**\n")
        print("| Run from | Endpoint | n | p50 | p95 | Errors | Median results | Non-empty |")
        print("|----------|----------|---|-----|-----|--------|----------------|-----------|")
        for path, d in docs:
            for h in [d["config"]["baseline"]] + d["config"]["candidates"]:
                s = d["summary"].get(h, {}).get(cls)
                if s:
                    print(f"| {d['host']} | {h} | {s['n']} | {ms(s['p50_ms'])} | "
                          f"{ms(s['p95_ms'])} | {pct(s['error_rate'])} | {num(s['median_count'])} | "
                          f"{pct(s['nonempty_share'])} |")
    print("\nPoPs:")
    for path, d in docs:
        for h, pops in d["pops"].items():
            print(f"- {d['host']} -> {h}: " +
                  ", ".join(f"{k} x{v}" for k, v in pops.items()))
    sys.exit(1 if clash or overlap else 0)


{"generate": generate, "measure": measure, "report": report}[env["RLB_MODE"]]()
EOF
