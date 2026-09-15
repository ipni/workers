#!/usr/bin/env bash
# Create the permanent bootstrapper identity for a box.
#
#   ./scripts/new-bootstrap-identity.sh <box>
#
# Writes:
#   host_vars/<box>/bootstrap.yml   bootstrap_peer_id (public)
#   host_vars/<box>/vault.yml       vault_bootstrap_privkey (added; file created if absent)
#
# Refuses to touch a box that already has an identity: a PeerID is published in
# DNS and hardcoded by clients, so replacing it breaks every bootstrap address.
# The key is never printed and only exists unencrypted in a private temp dir,
# which is shredded on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

BOX="${1:-}"
if [[ -z "$BOX" ]]; then
  echo "usage: $0 <box>" >&2
  exit 64
fi

if ! ansible-inventory --host "$BOX" </dev/null >/dev/null 2>&1; then
  echo "error: '$BOX' is not in inventory/hosts.yml; add it first" >&2
  exit 1
fi

PUBLIC="host_vars/$BOX/bootstrap.yml"
VAULT="host_vars/$BOX/vault.yml"

if [[ -e "$PUBLIC" ]]; then
  echo "error: $PUBLIC already exists - $BOX already has a bootstrap identity; refusing to replace it" >&2
  exit 1
fi

umask 077
WORK=$(mktemp -d)
cleanup() { find "$WORK" -type f -exec shred -u {} \; 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# ansible-vault refuses to run when it inherits a non-blocking stderr (common
# when this script's output is captured or piped), so give it a plain file and
# show that only if the command fails.
vault() {
  if ! ansible-vault "$@" </dev/null >/dev/null 2>"$WORK/vault.err"; then
    echo "error: ansible-vault $1 failed:" >&2
    cat "$WORK/vault.err" >&2
    exit 1
  fi
}

if [[ -e "$VAULT" ]]; then
  vault decrypt --output "$WORK/vault.yml" "$VAULT"
  if grep -q '^vault_bootstrap_privkey:' "$WORK/vault.yml"; then
    echo "error: $VAULT already contains vault_bootstrap_privkey; refusing to replace it" >&2
    exit 1
  fi
else
  mkdir -p "host_vars/$BOX"
  printf -- '---\n' > "$WORK/vault.yml"
fi

python3 scripts/libp2p_identity.py generate > "$WORK/identity.json"
PEER_ID=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["PeerID"])' "$WORK/identity.json")

python3 - "$WORK/identity.json" "$WORK/vault.yml" <<'PYEOF'
import json, sys
identity, vault = sys.argv[1:]
key = json.load(open(identity))["PrivKey"]
with open(vault, "a") as f:
    f.write(
        "# vault_bootstrap_privkey - kubo Identity.PrivKey of this box's bootstrapper\n"
        "#   (bootstrap_peer_id in bootstrap.yml). Losing or changing it changes\n"
        "#   the PeerID and breaks every published bootstrap address.\n"
        f'vault_bootstrap_privkey: "{key}"\n'
    )
PYEOF

# Verify the key derives the PeerID BEFORE anything is written to the repo.
python3 -c 'import json, sys; sys.stdout.write(json.load(open(sys.argv[1]))["PrivKey"])' "$WORK/identity.json" \
  | python3 scripts/libp2p_identity.py check "$PEER_ID" >/dev/null

vault encrypt --output "$VAULT" "$WORK/vault.yml"
cat > "$PUBLIC" <<EOF
---
# Permanent libp2p identity of this box's bootstrapper. Public: it appears in
# every /dnsaddr record and client bootstrap list, so it must never change.
# The private key is vault_bootstrap_privkey in vault.yml next to this file.
bootstrap_peer_id: $PEER_ID
EOF
chmod 644 "$PUBLIC"

# Final round trip through the vault, as the role's preflight will do it.
ansible-vault view "$VAULT" </dev/null 2>"$WORK/vault.err" \
  | python3 -c 'import sys, yaml; sys.stdout.write(yaml.safe_load(sys.stdin)["vault_bootstrap_privkey"])' \
  | python3 scripts/libp2p_identity.py check "$PEER_ID"

cat <<EOF

Created bootstrap identity for $BOX: $PEER_ID
Next:
  1. ./scripts/bootstrap-dns.py > dns.txt   and import the new records in Cloudflare
  2. ansible-playbook bootstrap.yml
Back up .vault_pass: without it this identity is unrecoverable.
EOF
