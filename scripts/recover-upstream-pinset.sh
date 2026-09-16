#!/usr/bin/env bash
# Capture the IPFS Websites pinset from the upstream collab cluster
# (https://collab.ipfscluster.io/, operated by IPFS Shipyard until 2026-09-30)
# and fold it into roles/content/vars/pinset.yml.
#
# The upstream cluster publishes no CID list: the only way to read it is to
# follow it. This joins as a follower in Docker, waits for the CRDT pinset to
# stop growing, saves the raw listing, and removes everything it started.
#
# NO CONTENT IS FETCHED. A follower always tries to pin what it follows, so it
# is pointed at a throwaway kubo with an empty repo running --offline: every pin
# fails fast with "block was not found locally (offline)" and is only recorded
# as an error, while the pinset itself still syncs over ipfs-cluster's own
# libp2p host. kubo is online only beforehand, for the few seconds it takes to
# fetch the follower's config (a single small file published through DNSLink).
# Nothing here talks to this project's own cluster.
#
# Then, without touching any CID resolved from DNSLink, it:
#   - moves each `recover_from_upstream` domain found upstream into `pinset`
#     (source: upstream-cluster, recovered_on), leaving absent ones in place;
#   - records upstream CIDs that differ from a DNSLink entry as drift
#     (upstream_cid, upstream_seen_on);
#   - lists every other upstream pin under `found_upstream_unclassified`.
# The YAML is rebuilt from parsed data, so re-running never duplicates entries.
#
# Exit 0 when every requested domain was found upstream, 1 when some are absent
# (named in the report), 2 if the listing could not be captured, 64 on bad usage.
#
# Replaying the upstream history takes hours, so keep the follower's data with
# --state DIR: a re-run then resumes instead of syncing from nothing again.
#
# Usage: ./scripts/recover-upstream-pinset.sh [--timeout SECONDS] [--interval SECONDS]
#          [--state DIR] [--out FILE] [--pinset FILE] [--from-listing FILE]...
# Requires docker and python3 with PyYAML. See --help.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=ipfs-websites
CONFIG_NAME=ipfs-websites.collab.ipfscluster.io
TODAY=$(date -u +%F)
TIMEOUT=900
INTERVAL=30
PINSET=roles/content/vars/pinset.yml
OUT=
STATE=
FROM_LISTING=()

usage() {
  cat <<EOF
Usage: $0 [options]

Follow the upstream IPFS Websites collab cluster without fetching content,
save its pinset listing, and update $PINSET from it.

Options:
  --timeout SECONDS     give up if the listing has not stabilised (default: $TIMEOUT)
  --interval SECONDS    time between listing polls (default: $INTERVAL); the
                        listing is stable once its size is unchanged for two
                        consecutive polls and the follower logged no CRDT pin
                        events, or unchanged for 10 polls whatever the log says
                        (the upstream history keeps churning long after the
                        pinset itself settles). Replaying that history can take
                        far longer than the default timeout; on a timeout the
                        listing so far is kept as <out>.partial
  --state DIR           keep the follower and kubo data here and resume from it
                        on the next run (default: a temp dir, deleted at exit).
                        Syncing the upstream history takes hours; resuming
                        continues where the last run stopped
  --out FILE            raw listing file
                        (default: roles/content/vars/upstream-pinset-<date>.txt)
  --pinset FILE         pinset YAML to update (default: $PINSET)
  --from-listing FILE   skip the follower and update the YAML from a listing
                        captured earlier. Repeatable: the first file is the
                        authoritative pinset, later ones are older evidence,
                        used only for a domain the first does not hold (a pin
                        that upstream has since removed). Such entries are
                        marked with upstream_listing.
  -h, --help            show this help

Exit: 0 all requested domains found, 1 some absent upstream,
      2 listing not captured, 64 bad usage.
EOF
}

while (($#)); do
  case "$1" in
    --timeout) TIMEOUT=${2:?--timeout needs a value}; shift 2 ;;
    --interval) INTERVAL=${2:?--interval needs a value}; shift 2 ;;
    --out) OUT=${2:?--out needs a value}; shift 2 ;;
    --state) STATE=${2:?--state needs a value}; shift 2 ;;
    --pinset) PINSET=${2:?--pinset needs a value}; shift 2 ;;
    --from-listing) FROM_LISTING+=("${2:?--from-listing needs a value}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

for n in "$TIMEOUT" "$INTERVAL"; do
  if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: --timeout and --interval take a positive number of seconds" >&2
    exit 64
  fi
done
if [[ ! -f "$PINSET" ]]; then
  echo "error: $PINSET not found" >&2
  exit 64
fi

capture_listing() {
  local out=$1
  if ! command -v docker >/dev/null; then
    echo "error: docker is required" >&2
    exit 2
  fi

  # The same kubo and ipfs-cluster images the content cluster runs, by digest.
  local images kubo_image cluster_image
  images=$(python3 - <<'PY'
import yaml
k = yaml.safe_load(open("k8s/content/kustomization.yaml"))
imgs = {i["name"]: f'{i["newName"]}@{i["digest"]}' for i in k["images"]}
print(imgs["kubo"], imgs["ipfs-cluster"])
PY
)
  read -r kubo_image cluster_image <<<"$images"

  local work kubo follow user resume=false
  kubo="recover-pinset-kubo-$$"
  follow="recover-pinset-follow-$$"
  user="$(id -u):$(id -g)"
  if [[ -n "$STATE" ]]; then
    mkdir -p "$STATE"
    work=$(cd "$STATE" && pwd)
    [[ -d "$work/follow/$CLUSTER" ]] && resume=true
    # shellcheck disable=SC2064  # expand now: these names are fixed for this run
    trap "docker rm -f '$follow' '$kubo' >/dev/null 2>&1 || true" EXIT
  else
    work=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "docker rm -f '$follow' '$kubo' >/dev/null 2>&1 || true; rm -rf '$work'" EXIT
  fi

  wait_for_kubo() {
    for _ in $(seq 60); do
      docker exec "$kubo" ipfs id >/dev/null 2>&1 && return 0
      sleep 1
    done
    echo "error: throwaway kubo did not start" >&2
    docker logs "$kubo" 2>&1 | tail -20 >&2
    exit 2
  }

  echo "starting throwaway kubo (empty repo, online) to fetch the follower config"
  docker run -d --name "$kubo" --user "$user" -v "$work:/work" \
    -e IPFS_PATH=/work/kubo -e HOME=/tmp --entrypoint sh "$kubo_image" \
    -c '[ -f "$IPFS_PATH/config" ] || ipfs init --empty-repo >/dev/null; exec ipfs daemon' >/dev/null
  wait_for_kubo
  # Cached in the kubo repo, so a resumed run can serve it to the follower offline.
  if ! docker exec "$kubo" sh -c \
      "p=\$(ipfs resolve -r /ipns/$CONFIG_NAME) && timeout 180 ipfs cat \"\$p\" >/dev/null"; then
    echo "error: could not fetch the follower config for $CONFIG_NAME" >&2
    exit 2
  fi

  echo "restarting kubo offline: pins from the follower will fail instead of fetching"
  docker rm -f "$kubo" >/dev/null
  docker run -d --name "$kubo" --user "$user" -v "$work:/work" \
    -e IPFS_PATH=/work/kubo -e HOME=/tmp --entrypoint ipfs "$kubo_image" \
    daemon --offline >/dev/null
  wait_for_kubo

  # IPFS_GATEWAY needs the scheme: the follower builds <gateway>/ipns/<name>.
  local follow_env=(-e HOME=/tmp -e IPFS_GATEWAY=http://127.0.0.1:8080)
  local run_args=("$CLUSTER" run)
  if $resume; then
    echo "resuming the follower from $work (already initialised)"
  else
    echo "starting ipfs-cluster-follow $CLUSTER run --init $CONFIG_NAME"
    run_args+=(--init "$CONFIG_NAME")
  fi
  docker run -d --name "$follow" --network "container:$kubo" --user "$user" \
    -v "$work:/work" "${follow_env[@]}" --entrypoint ipfs-cluster-follow "$cluster_image" \
    --config /work/follow "${run_args[@]}" >/dev/null

  # Size alone is not enough: the CRDT replays years of history (additions and
  # removals) in bursts, and the count can hold still between them. So also
  # require that the follower logged no pin events in the interval - but accept
  # a size that has not moved for STABLE_POLLS polls even if the log is still
  # busy, because the history churn (rebuilt badbits lists, CI deploys) can
  # outlast the pinset settling.
  local start prev=-1 stable=0 count activity since delta bar filled elapsed
  local STABLE_POLLS=10
  start=$(date +%s)
  since=$start
  while :; do
    sleep "$INTERVAL"
    if [[ "$(docker inspect -f '{{.State.Running}}' "$follow" 2>/dev/null)" != true ]]; then
      echo "error: the follower exited" >&2
      docker logs "$follow" 2>&1 | grep -v '^\s*$' | tail -20 >&2
      exit 2
    fi
    count=$(docker exec "$follow" ipfs-cluster-follow --config /work/follow "$CLUSTER" list 2>/dev/null | grep -c . || true)
    activity=$(docker logs --since "$since" "$follow" 2>&1 | grep -cE 'pin (added|removed)' || true)
    since=$(($(date +%s) - 1))

    # Progress meter. There is no total to count towards - the upstream pinset
    # size is unknown until it stops growing - so the bar tracks elapsed time
    # against the timeout, and the counters show what the follower is doing.
    elapsed=$(($(date +%s) - start))
    delta=$((prev < 0 ? 0 : count - prev))
    filled=$((elapsed * 24 / TIMEOUT))
    ((filled > 24)) && filled=24
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $((24 - filled)) '')
    printf '\r[%s] %5ss/%ss  %4d pins (%+d)  %4d crdt events  settled %d/%d ' \
      "$bar" "$elapsed" "$TIMEOUT" "$count" "$delta" "$activity" "$stable" "$STABLE_POLLS"
    # A terminal gets one line rewritten in place; a log file gets one line per
    # poll, so progress is still visible in `tail -f`.
    [[ -t 1 ]] || echo
    if ((count > 0 && count == prev)); then
      stable=$((stable + 1))
    else
      stable=0
    fi
    prev=$count
    if ((stable >= 2 && activity == 0)) || ((stable >= STABLE_POLLS)); then
      break
    fi
    if (($(date +%s) - start >= TIMEOUT)); then
      docker exec "$follow" ipfs-cluster-follow --config /work/follow "$CLUSTER" list >"$out.partial" 2>/dev/null || true
      [[ -t 1 ]] && echo
      echo "error: listing did not stabilise within ${TIMEOUT}s (last count $count);" \
        "the listing so far is in $out.partial - re-run with a longer --timeout" >&2
      exit 2
    fi
  done

  [[ -t 1 ]] && echo
  echo "listing stable at $count entries; stopping the follower"
  docker stop -t 60 "$follow" >/dev/null
  # Listed from the stopped peer's state on disk: plain "<cid> <name>" lines,
  # without the running peer's per-pin status and error text. It still loads
  # its config through the (offline) kubo gateway, hence the shared network.
  docker run --rm --network "container:$kubo" --user "$user" -v "$work:/work" \
    "${follow_env[@]}" --entrypoint ipfs-cluster-follow "$cluster_image" \
    --config /work/follow "$CLUSTER" list >"$out"
  if [[ ! -s "$out" ]]; then
    echo "error: the stopped follower listed nothing" >&2
    exit 2
  fi
  echo "wrote $(grep -c . "$out") entries to $out"
}

if ((${#FROM_LISTING[@]})); then
  # The recovery date is the capture date, taken from the file name if it has one.
  if [[ "$(basename "${FROM_LISTING[0]}")" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    TODAY=${BASH_REMATCH[1]}
  fi
else
  FROM_LISTING=("${OUT:-roles/content/vars/upstream-pinset-$TODAY.txt}")
  capture_listing "${FROM_LISTING[0]}"
fi

python3 - "$PINSET" "$TODAY" "${FROM_LISTING[@]}" <<'PY'
import re, sys, textwrap
import yaml

pinset_path, today = sys.argv[1:3]
listing_paths = sys.argv[3:]
listing_path = listing_paths[0]
CID = re.compile(r"^(Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{50,})$")

# --- parse the listing ------------------------------------------------------
# A stopped follower prints "<cid> <name>"; a running one "<status> <cid> <name>
# (<error>)". Accept both: the name is everything after the CID, minus a
# trailing "(IPFS error ...)".
def parse(path):
    out = []
    for line in open(path):
        words = line.split()
        idx = next((i for i, w in enumerate(words) if CID.match(w)), None)
        if idx is None:
            continue
        name = " ".join(words[idx + 1:])
        name = re.sub(r"\s*\((IPFS error|error).*\)\s*$", "", name).strip()
        out.append((name, words[idx]))
    if not out:
        sys.exit(f"error: no <cid> <name> entries parsed from {path}")
    return out

upstream = parse(listing_path)     # (name, cid), the authoritative pinset
# Older captures: a CRDT replay passes through pins that upstream later removed,
# so a listing taken mid-sync can hold the last CID a dead site ever had.
older = {path: parse(path) for path in listing_paths[1:]}

def index(pairs):
    idx = {}
    for name, cid in pairs:
        idx.setdefault(name, [])
        if cid not in idx[name]:
            idx[name].append(cid)
    return idx

by_name = index(upstream)
# One index over every capture, so the newest snapshot of a domain is used even
# when it only survives in an older one. listing_of says where a name came from.
combined, listing_of = dict(by_name), {n: None for n in by_name}
for path, pairs in older.items():
    for name, cids in index(pairs).items():
        if name in combined:
            for c in cids:
                if c not in combined[name]:
                    combined[name].append(c)
        else:
            combined[name] = list(cids)
            listing_of[name] = path

# Upstream no longer pins under the bare domain as pin-websites.sh did: names
# now carry a snapshot suffix, e.g. "libp2p.io__2024-08-07_220424",
# "research.protocol.ai build 3412". Treat "<domain>", "<domain>__...",
# "<domain> ..." and "<domain>-..." as snapshots of that domain, newest first,
# so the newest CID is the one recovered and the rest are kept as history.
SEP = re.compile(r"^(__|[ -])")
def natural(s):
    # (0, n) sorts numerically, (1, text) lexically; the tag keeps a number and
    # a string from ever being compared to each other.
    return [(0, int(t), "") if t.isdigit() else (1, 0, t) for t in re.split(r"(\d+)", s)]

def snapshots(domain, source=None):
    """[(name, cid)] for this domain, newest first; exact-name pins last."""
    found = []
    for name, cids in (source if source is not None else combined).items():
        if name == domain:
            found += [((0, []), name, c) for c in cids]
        elif name.startswith(domain) and SEP.match(name[len(domain):]):
            found += [((1, natural(name[len(domain):])), name, c) for c in cids]
    found.sort(key=lambda x: x[0], reverse=True)
    return [(name, cid) for _, name, cid in found]

# --- read the current YAML --------------------------------------------------
text = open(pinset_path).read()
data = yaml.safe_load(text)
lines = text.splitlines()

# Comment lines directly above each top-level key, kept verbatim, and the
# header (everything above the first key).
key_line = {}
for i, l in enumerate(lines):
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", l)
    if m:
        key_line[m.group(1)] = i
first_key = min(key_line.values())
# Lines this script writes itself start with "#:" and are regenerated, so they
# are dropped when reading the comments back (no duplicates on re-runs).
def comments_above(key):
    i = key_line.get(key)
    if i is None:
        return []
    block = []
    j = i - 1
    while j >= 0 and (lines[j].startswith("#") or not lines[j].strip()) and j >= first_key:
        if not lines[j].startswith("#:"):
            block.insert(0, lines[j])
        j -= 1
    while block and not block[0].strip():
        block.pop(0)
    return block

header = lines[:first_key]
while header and not header[-1].strip():
    header.pop()
BEGIN, END = "# --- BEGIN upstream recovery (scripts/recover-upstream-pinset.sh) ---", "# --- END upstream recovery ---"
if BEGIN in header:
    header = header[:header.index(BEGIN)] + header[header.index(END) + 1:]
    while header and not header[-1].strip():
        header.pop()

# Inline comments on recover_from_upstream items become notes.
recover_notes = {}
if "recover_from_upstream" in key_line:
    for l in lines[key_line["recover_from_upstream"] + 1:]:
        m = re.match(r"^\s+-\s+([^\s#]+)\s*(?:#\s*(.*))?$", l)
        if m:
            recover_notes[m.group(1)] = (m.group(2) or "").strip()
        elif l.strip() and not l.startswith((" ", "#")):
            break

pinset = data.get("pinset") or []
recover = [str(d) for d in (data.get("recover_from_upstream") or [])]
retired = [str(d) for d in (data.get("retired") or [])]
previous_unclassified = {(e["name"], e["cid"]): e for e in (data.get("found_upstream_unclassified") or [])}
names = {e["name"] for e in pinset}

report = {"recovered": [], "history": [], "already": [], "absent": [], "drift": [], "match": [], "multi": []}

# --- DNSLink entries: add source, record drift ------------------------------
claimed = set()      # upstream names accounted for by a pinset entry
for e in pinset:
    e.setdefault("source", "dnslink")
    found = snapshots(e["name"])
    claimed.update(n for n, _ in found)
    if e["source"] != "dnslink" or not found:
        continue
    if all(c == e["cid"] for _, c in found):
        report["match"].append(e["name"])
        for k in ("upstream_cid", "upstream_name", "upstream_seen_on", "upstream_older_snapshots"):
            e.pop(k, None)
        continue
    # Newest upstream CID that differs from what DNSLink returned. DNSLink stays
    # authoritative; this records what upstream held for the same site.
    name, cid = next((n, c) for n, c in found if c != e["cid"])
    e["upstream_cid"] = cid
    e["upstream_name"] = name
    e["upstream_seen_on"] = today
    if len(found) > 1:
        e["upstream_older_snapshots"] = len(found) - 1
    report["drift"].append((e["name"], e["cid"], cid, name, len(found)))

# --- requested domains --------------------------------------------------------
still_missing = []
for domain in recover:
    found = snapshots(domain)
    if not found:
        still_missing.append(domain)
        report["absent"].append(domain)
        continue
    claimed.update(n for n, _ in found)
    note = recover_notes.get(domain, "")
    name, cid = found[0]
    # A name only an older capture holds is a pin upstream has since removed:
    # the CRDT replay passed through it on the way to the current pinset.
    from_listing = listing_of.get(name)
    others = [c for n, c in found[1:] if c != cid]
    entry = {
        "name": domain,
        "cid": cid,
        "description": f"{domain} website, recovered from the upstream collab cluster pinset"
                       f" as \"{name}\", its newest snapshot there"
                       f" (no DNSLink record since at least 2026-09-15{'; ' + note if note else ''})",
        "source": "upstream-cluster",
        "recovered_on": today,
        "upstream_name": name,
    }
    if from_listing is not None:
        entry["upstream_listing"] = from_listing.split("/")[-1]
        entry["description"] += (". NOT in the final upstream pinset: upstream had"
                                 " already removed this pin, and it was seen only while"
                                 " the CRDT replayed its history, so this is the last"
                                 " recorded CID for the site")
        report["history"].append((domain, cid, from_listing))
    else:
        report["recovered"].append((domain, cid))
    if others:
        entry["upstream_other_cids"] = others
        report["multi"].append((domain, found))
    if domain in names:
        report["already"].append(domain)
    else:
        pinset.append(entry)
        names.add(domain)

# --- everything else upstream -------------------------------------------------
cid_owner = {e["cid"]: e["name"] for e in pinset}
unclassified = []
seen = set()
for name, cid in upstream:
    if name in names or name in claimed or (name, cid) in seen:
        continue
    seen.add((name, cid))
    item = {"name": name, "cid": cid, "first_seen_on": previous_unclassified.get((name, cid), {}).get("first_seen_on", today)}
    hints = []
    if cid in cid_owner:
        hints.append(f"same CID as pinset entry {cid_owner[cid]}")
    if name in retired:
        hints.append("listed under retired")
    # Upstream stopped naming pins after the domain (CI build names now), so a
    # requested domain can appear inside another name. Flagged for a human,
    # never assigned: the name is not the domain and may be a different site.
    near = [d for d in still_missing if d in name]
    if near:
        hints.append("possible match for requested domain(s) " + ", ".join(near) + " - NOT assigned, needs a human")
    if hints:
        item["note"] = "; ".join(hints)
    unclassified.append(item)
unclassified.sort(key=lambda x: (x["name"], x["cid"]))

# --- write --------------------------------------------------------------------
def scalar(v):
    if isinstance(v, int) and not isinstance(v, bool):
        return str(v)
    s = str(v)
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
        return f'"{s}"'   # unquoted, YAML would load a date object
    if re.fullmatch(r"[A-Za-z0-9._/-]+", s) and not re.fullmatch(r"(true|false|yes|no|null|~|[0-9.]+)", s, re.I):
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def entry_lines(e, order):
    out = []
    keys = [k for k in order if k in e] + [k for k in e if k not in order]
    for n, k in enumerate(keys):
        lead = "  - " if n == 0 else "    "
        v = e[k]
        if isinstance(v, list):
            out.append(f"{lead}{k}:")
            out += [f"      - {scalar(x)}" for x in v]
        elif k in ("description", "note") and len(str(v)) > 60:
            out.append(f"{lead}{k}: >-")
            out += ["      " + w for w in textwrap.wrap(str(v), 72)]
        else:
            out.append(f"{lead}{k}: {scalar(v)}")
    return out

ORDER = ["name", "cid", "description", "source", "recovered_on", "upstream_name",
         "upstream_cid", "upstream_other_cids", "upstream_older_snapshots",
         "upstream_listing", "upstream_seen_on"]
out = header + [
    "",
    BEGIN,
    f"# UPSTREAM RECOVERY, {today}. The IPFS Websites pinset was read from the",
    "# upstream collab cluster by following it (ipfs-cluster-follow ipfs-websites,",
    "# config ipfs-websites.collab.ipfscluster.io, https://collab.ipfscluster.io/).",
    "# That cluster was operated by IPFS Shipyard and no longer exists after",
    "# 2026-09-30; the raw listing captured from it is committed next to this file",
    f"# (upstream-pinset-{today}.txt, plus any earlier capture named in",
    "# upstream_listing) and cannot be regenerated.",
    "#",
    "# Upstream had stopped naming pins after the bare domain, as the 2019",
    "# pin-websites.sh did: names now carry a snapshot suffix, e.g.",
    "# \"libp2p.io__2024-08-07_220424\" or \"research.protocol.ai build 3412\". The",
    "# newest snapshot per domain is the one recorded; upstream_name says which it",
    "# was, upstream_other_cids keeps the older ones.",
    "#",
    "# `source` on every pinset entry:",
    "#   dnslink           re-resolvable at pin time; `cid` is the 2026-09-15 snapshot.",
    "#                     upstream_cid, when present, is a DIFFERENT CID upstream held",
    "#                     for the same site (drift), named in upstream_name: DNSLink",
    "#                     stays authoritative, the upstream snapshot may be worth keeping.",
    "#   upstream-cluster  NOT re-resolvable: no DNSLink record exists, and the",
    "#                     recorded `cid` is the only remaining copy of the pointer.",
    END,
    "",
]
out.append(f'resolved_on: "{data.get("resolved_on", "")}"')
out += ["", *comments_above("pinset"), "pinset:"]
for n, e in enumerate(pinset):
    if n:
        out.append("")
    out += entry_lines(e, ORDER)

out += [""] + comments_above("recover_from_upstream")
if still_missing:
    out.append(f"#: Checked against the upstream pinset on {today}: NOT FOUND upstream, so no")
    out.append("#: CID could be recovered for these.")
    out.append("recover_from_upstream:")
    for d in still_missing:
        note = recover_notes.get(d, "")
        out.append(f"  - {d}" + (f"          # {note}" if note else ""))
else:
    out.append(f"#: All recovered from upstream on {today}: see pinset entries with")
    out.append("#: source: upstream-cluster.")
    out.append("recover_from_upstream: []")

out += [""] + comments_above("retired") + ["retired:"] + [f"  - {d}" for d in retired]

out += [
    "",
    "#: Pins present in the upstream pinset under a name that is in neither `pinset`",
    "#: nor `recover_from_upstream`. Recorded so nothing is lost by omission; scope",
    "#: is NOT decided here. Out of scope for loading until a human triages them.",
]
if unclassified:
    out.append("found_upstream_unclassified:")
    for n, e in enumerate(unclassified):
        out += entry_lines(e, ["name", "cid", "first_seen_on", "note"])
else:
    out.append("found_upstream_unclassified: []")
open(pinset_path, "w").write("\n".join(out) + "\n")
yaml.safe_load(open(pinset_path))   # must still parse

# --- report ---------------------------------------------------------------------
print(f"\nupstream listing: {len(upstream)} entries, {len(by_name)} names ({listing_path})")
for d, c in report["recovered"]:
    print(f"  recovered   {d:28} {c}")
for d in report["already"]:
    print(f"  kept        {d:28} (recovered on an earlier run)")
for d, c, path in report["history"]:
    print(f"  from history {d:27} {c}")
    print(f"  {'':40} only in {path}: upstream had already removed it")
for d in report["absent"]:
    print(f"  ABSENT      {d:28} not in the upstream pinset")
for e in unclassified:
    if "possible match" in e.get("note", ""):
        print(f"  NEAR MATCH  {e['name'][:44]:44} {e['note'].split(' - ')[0]}")
for d, found in report["multi"]:
    print(f"  snapshots   {d:28} {len(found)} upstream snapshots; newest recorded, {len(found) - 1} older kept as upstream_other_cids")
for d in report["match"]:
    print(f"  match       {d:28} upstream CID equals DNSLink")
for d, c, up, upname, n in report["drift"]:
    print(f"  DRIFT       {d:28} dnslink {c}")
    print(f"  {'':40} upstream {up} as \"{upname}\" ({n} snapshot(s))")
print(f"  unclassified: {len(unclassified)} upstream entries in found_upstream_unclassified")
sys.exit(1 if report["absent"] else 0)
PY
