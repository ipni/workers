#!/usr/bin/env bash
# Create the permanent identities of a box's content cluster node: its
# ipfs-cluster peer and its kubo node, plus the cluster-wide swarm secret if it
# does not exist yet.
#
#   ./scripts/new-content-cluster-identity.sh <box>
#
# Writes:
#   host_vars/<box>/vault.yml         vault_content_cluster_privkey, vault_content_kubo_privkey
#   group_vars/ipfs_nodes/vault.yml   vault_content_cluster_secret (once, for all boxes)
#   host_vars/<box>/content.yml       content_cluster_peer_id, content_kubo_peer_id (public)
#
# The PeerIDs are fixed because the other boxes name them: all three cluster
# peers are CRDT trusted peers, and each kubo peers with the other two.
#
# Safe to re-run: it only adds what is missing and never replaces an existing
# key, so an interrupted run is finished by running it again. content.yml is
# always derived from the vaulted keys. Keys are never printed and only exist
# unencrypted in a private temp dir, which is shredded on exit.
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

PUBLIC="host_vars/$BOX/content.yml"
VAULT="host_vars/$BOX/vault.yml"
GROUP_VAULT="group_vars/ipfs_nodes/vault.yml"

if [[ ! -e "$VAULT" || ! -e "$GROUP_VAULT" ]]; then
  echo "error: $VAULT and $GROUP_VAULT must exist (see Secrets in README.md)" >&2
  exit 1
fi

umask 077
WORK=$(mktemp -d)
cleanup() { find "$WORK" -type f -exec shred -u {} \; 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# ansible-vault refuses to run when it inherits a non-blocking stderr, so give
# it a plain file and show that only if the command fails.
vault() {
  if ! ansible-vault "$@" </dev/null >/dev/null 2>"$WORK/vault.err"; then
    echo "error: ansible-vault $1 failed:" >&2
    cat "$WORK/vault.err" >&2
    exit 1
  fi
}

# Decrypt both vaults before changing anything, so a vault that cannot be
# read stops the run before any key is written.
vault decrypt --output "$WORK/box.yml" "$VAULT"
vault decrypt --output "$WORK/group.yml" "$GROUP_VAULT"

# vault_value <file> <var>: print a variable from a decrypted vault (empty if absent).
vault_value() {
  python3 -c 'import sys, yaml; print((yaml.safe_load(open(sys.argv[1])) or {}).get(sys.argv[2], ""), end="")' "$1" "$2"
}

# add_key <var> <description>: generate a libp2p key into the box vault unless present.
# ipfs-cluster's identity private_key uses the same encoding as kubo's
# Identity.PrivKey, so libp2p_identity.py generates and checks both.
box_changed=false
add_key() {
  local var=$1 description=$2
  if [[ -n "$(vault_value "$WORK/box.yml" "$var")" ]]; then
    echo "$var: already in $VAULT, kept"
    return
  fi
  python3 scripts/libp2p_identity.py generate > "$WORK/identity.json"
  python3 - "$WORK/identity.json" "$WORK/box.yml" "$var" "$description" <<'PYEOF'
import json, sys
identity, vault, var, description = sys.argv[1:]
key = json.load(open(identity))["PrivKey"]
with open(vault, "a") as f:
    f.write(f"# {var} - {description}. The other boxes name its PeerID\n"
            "#   (content.yml), so it must not change.\n"
            f'{var}: "{key}"\n')
PYEOF
  shred -u "$WORK/identity.json"
  box_changed=true
  echo "$var: created"
}

add_key vault_content_cluster_privkey "ipfs-cluster identity of this box's content cluster peer"
add_key vault_content_kubo_privkey "kubo Identity.PrivKey of this box's content node"

if [[ -z "$(vault_value "$WORK/group.yml" vault_content_cluster_secret)" ]]; then
  secret=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
  {
    printf '# vault_content_cluster_secret - ipfs-cluster swarm secret (32 bytes, hex),\n'
    printf '#   shared by every content cluster peer. Peers with another secret\n'
    printf '#   cannot connect at all.\n'
    printf 'vault_content_cluster_secret: "%s"\n' "$secret"
  } >> "$WORK/group.yml"
  vault encrypt --output "$GROUP_VAULT" "$WORK/group.yml"
  echo "vault_content_cluster_secret: created in $GROUP_VAULT"
fi

if $box_changed; then
  vault encrypt --output "$VAULT" "$WORK/box.yml"
fi

# Derive the public PeerIDs from what the vault now holds, as the role's
# preflight does, and refuse to overwrite a content.yml that disagrees.
peer_id_of() {
  vault_value "$WORK/box.yml" "$1" | python3 scripts/libp2p_identity.py derive
}
CLUSTER_ID=$(peer_id_of vault_content_cluster_privkey)
KUBO_ID=$(peer_id_of vault_content_kubo_privkey)
if [[ -z "$CLUSTER_ID" || -z "$KUBO_ID" ]]; then
  echo "error: could not derive PeerIDs from $VAULT" >&2
  exit 1
fi

cat > "$WORK/content.yml" <<EOF
---
# Permanent identities of this box's content cluster node. Public. The other
# boxes name them (cluster trusted peers, kubo peering), so they must not
# change. Private keys: vault_content_cluster_privkey and
# vault_content_kubo_privkey in vault.yml next to this file.
content_cluster_peer_id: $CLUSTER_ID
content_kubo_peer_id: $KUBO_ID
EOF

if [[ -e "$PUBLIC" ]]; then
  for pair in "content_cluster_peer_id $CLUSTER_ID" "content_kubo_peer_id $KUBO_ID"; do
    set -- $pair
    existing=$(python3 -c 'import sys, yaml; print((yaml.safe_load(open(sys.argv[1])) or {}).get(sys.argv[2], ""))' "$PUBLIC" "$1")
    if [[ -n "$existing" && "$existing" != "$2" ]]; then
      echo "error: $PUBLIC has $1 $existing, but the vaulted key derives $2; refusing to overwrite" >&2
      exit 1
    fi
  done
fi
cp "$WORK/content.yml" "$PUBLIC"
chmod 644 "$PUBLIC"

cat <<EOF

$BOX content cluster identities:
  ipfs-cluster peer  $CLUSTER_ID
  kubo node          $KUBO_ID
Next: ansible-playbook content.yml on ALL boxes. The other boxes' trusted
peers, peer addresses, kubo peering and 9096 firewall rules name this box.
Store the updated vault files in the operators' secret store.
EOF
