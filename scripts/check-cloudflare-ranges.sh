#!/usr/bin/env bash
# Compare the pinned Cloudflare edge ranges (the only sources allowed to reach
# the origins on :443) with what Cloudflare currently publishes.
#
# Exit 0 when they match, 1 on drift, 2 if Cloudflare could not be reached.
# A range Cloudflare added but we have not pinned shows up in production as
# intermittent 522s from those edges only, so run this periodically (cron/CI).
#
# Usage: ./scripts/check-cloudflare-ranges.sh
# Fix drift: edit route_origin_cloudflare_ranges, then
#            ansible-playbook routing.yml --tags origin
set -euo pipefail
cd "$(dirname "$0")/.."

DEFAULTS=roles/route_origin/defaults/main.yml

if ! api=$(curl -sf --max-time 30 https://api.cloudflare.com/client/v4/ips); then
  echo "error: could not fetch https://api.cloudflare.com/client/v4/ips" >&2
  exit 2
fi

python3 - "$DEFAULTS" "$api" <<'EOF'
import json, sys, yaml

pinned = set(yaml.safe_load(open(sys.argv[1]))["route_origin_cloudflare_ranges"])
result = json.loads(sys.argv[2])["result"]
live = set(result["ipv4_cidrs"]) | set(result["ipv6_cidrs"])

added, removed = sorted(live - pinned), sorted(pinned - live)
print(f"pinned: {len(pinned)}  published: {len(live)}  (Cloudflare etag {result.get('etag')})")
if not added and not removed:
    print("OK: pinned list matches Cloudflare")
    sys.exit(0)
for r in added:
    print(f"  + published by Cloudflare, not pinned: {r}")
for r in removed:
    print(f"  - pinned, no longer published:        {r}")
sys.exit(1)
EOF
