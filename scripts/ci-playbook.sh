#!/usr/bin/env bash
# Run a playbook from CI (the site-* and platform-* jobs of
# .github/workflows/ci.yml).
#
#   scripts/ci-playbook.sh site|platform check [limit]   dry run: --check --diff
#   scripts/ci-playbook.sh site|platform apply [limit]   the real run
#
# SSH as the admin user comes from ANSIBLE_SSH_PRIVATE_KEY, whose public half is
# keys/github-actions.pub. The vault files are gitignored, so CI has none: each
# playbook's vault variables come from repository secrets instead, in the
# environment. Copies of every secret are in 1Password (IPFS account, Compass
# vault).
#
#   site.yml      none. Its one vault variable, vault_root_password, is only
#                 for a box that has never been hardened, and CI refuses those
#                 (site_require_hardened): building a box stays an operator's
#                 job. Nor does it fetch kubeconfigs (k3s_write_local_kubeconfig).
#   platform.yml  ARGOCD_AGE_KEY       -> vault_argocd_age_key
#                 CLOUDFLARE_DNS_TOKEN -> vault_cloudflare_dns_token
#                 ARGOCD_REPO_SSH_KEY  -> vault_argocd_repo_ssh_key (optional:
#                                         only while ipni/infra is private)
set -euo pipefail

playbook=${1:?usage: $0 site|platform check|apply [limit]}
mode=${2:?usage: $0 site|platform check|apply [limit]}
limit=${3:-}
[[ $playbook == site || $playbook == platform ]] || { echo "playbook must be site or platform" >&2; exit 2; }
[[ $mode == check || $mode == apply ]] || { echo "mode must be check or apply" >&2; exit 2; }
: "${ANSIBLE_SSH_PRIVATE_KEY:?not set}"
if [[ $playbook == platform ]]; then
  : "${ARGOCD_AGE_KEY:?not set}" "${CLOUDFLARE_DNS_TOKEN:?not set}"
fi

cd "$(dirname "$0")/.."
umask 077

# Connect only to the boxes whose host keys are pinned in the repo.
mkdir -p "$HOME/.ssh"
printf '%s\n' "$ANSIBLE_SSH_PRIVATE_KEY" > "$HOME/.ssh/id_ed25519"
grep -v '^#' inventory/known_hosts > "$HOME/.ssh/known_hosts"

# ansible.cfg names .vault_pass; nothing CI reads is vault-encrypted.
echo ci > .vault_pass

# The secrets as extra vars, from a file rather than the command line, so they
# never appear in a process list or the log.
secrets=$(mktemp)
trap 'rm -f "$secrets"' EXIT
python3 - "$playbook" "$secrets" <<'PY'
import json, os, sys
playbook, path = sys.argv[1], sys.argv[2]
values = {}
if playbook == "site":
    values["site_require_hardened"] = True
    values["k3s_write_local_kubeconfig"] = False
elif playbook == "platform":
    values["vault_argocd_age_key"] = os.environ["ARGOCD_AGE_KEY"]
    values["vault_cloudflare_dns_token"] = os.environ["CLOUDFLARE_DNS_TOKEN"]
    if os.environ.get("ARGOCD_REPO_SSH_KEY"):
        values["vault_argocd_repo_ssh_key"] = os.environ["ARGOCD_REPO_SSH_KEY"]
with open(path, "w") as f:
    json.dump(values, f)  # JSON is YAML, which -e @file reads
PY

args=("$playbook.yml" -e "@$secrets")
[[ $mode == check ]] && args+=(--check --diff)
[[ -n $limit ]] && args+=(--limit "$limit")

if [[ -z ${GITHUB_STEP_SUMMARY:-} ]]; then
  ansible-playbook "${args[@]}"
  exit
fi

# In CI, both modes also write what they change to the run's summary page:
# each box, task, loop item and diff. On a merge, the dry run's summary is what
# the approver reads before approving the apply; the apply's says what it did.
log=$(mktemp)
trap 'rm -f "$secrets" "$log"' EXIT
set +e
ansible-playbook "${args[@]}" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
python3 scripts/ci-summary.py "$playbook" "$mode" "$log" "$status" >> "$GITHUB_STEP_SUMMARY"

# Whether the dry run would change anything (any `changed=` above 0 in the
# PLAY RECAP). On a merge, the apply jobs are skipped when it would not.
if [[ $mode == check && -n ${GITHUB_OUTPUT:-} ]]; then
  if sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -qE '^[^ ]+ +: ok=[0-9]+ +changed=[1-9]'; then
    echo "changes=true" >> "$GITHUB_OUTPUT"
  else
    echo "changes=false" >> "$GITHUB_OUTPUT"
  fi
fi
exit "$status"
