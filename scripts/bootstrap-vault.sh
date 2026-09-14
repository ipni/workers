#!/usr/bin/env bash
# Move credentials out of plaintext servers.txt and into per-host ansible-vault
# files. Idempotent: re-running regenerates the vault files from servers.txt.
#
# Usage: ./scripts/bootstrap-vault.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SRC=servers.txt
VAULT_PASS=.vault_pass

[[ -f "$SRC" ]] || { echo "error: $SRC not found" >&2; exit 1; }

# 1. Vault password — generated once, never committed (.gitignore covers it).
if [[ ! -f "$VAULT_PASS" ]]; then
  head -c 32 /dev/urandom | base64 > "$VAULT_PASS"
  chmod 600 "$VAULT_PASS"
  echo "generated $VAULT_PASS (back this up: without it the vaults are unreadable)"
fi

# 2. One encrypted vault file per inventory host. servers.txt is keyed by
#    location, but inventory hosts are named per box (chic-1, ...), and a site
#    may hold more than one box - so rows are matched to hosts by IP.
IP_TO_HOST=$(ansible-inventory --list 2>/dev/null </dev/null | python3 -c '
import json, sys
inv = json.load(sys.stdin)
for host, v in inv["_meta"]["hostvars"].items():
    print(v["ansible_host"], host)
')

while IFS='|' read -r location ip root console; do
  # skip header and blank lines
  [[ "$location" == "location" || -z "${location// }" ]] && continue

  host=$(awk -v ip="$ip" '$1 == ip {print $2}' <<<"$IP_TO_HOST")
  if [[ -z "$host" ]]; then
    echo "error: no inventory host has ansible_host=$ip ($location); add it to inventory/hosts.yml first" >&2
    exit 1
  fi

  mkdir -p "host_vars/${host}"
  target="host_vars/${host}/vault.yml"

  cat > "${target}.tmp" <<EOF
---
# Encrypted with ansible-vault. Decrypt: ansible-vault view ${target}
# vault_root_password  - initial provider-set root password, used ONLY for the
#                        bootstrap connection. Rotate after hardening.
# vault_console_password - provider KVM/web console login. This is the
#                        out-of-band recovery path; Ansible never uses it.
vault_root_password: "${root}"
vault_console_password: "${console}"
EOF

  # Password file comes from ansible.cfg's vault_password_file; passing it
  # again here would register two vault-ids and error out.
  ansible-vault encrypt --output "$target" "${target}.tmp"
  rm -f "${target}.tmp"
  echo "wrote $target"
done < "$SRC"

echo
echo "Done. servers.txt is gitignored but still plaintext on disk."
echo "Once you have verified key-based SSH works, delete it:  shred -u $SRC"
