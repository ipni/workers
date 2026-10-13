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

if [[ $mode == apply || -z ${GITHUB_STEP_SUMMARY:-} ]]; then
  ansible-playbook "${args[@]}"
  exit
fi

# A dry run in CI also writes what it would change to the run's summary page:
# on a merge, that is what the approver reads before approving the apply.
log=$(mktemp)
trap 'rm -f "$secrets" "$log"' EXIT
set +e
ansible-playbook "${args[@]}" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
python3 - "$playbook" "$log" "$status" >> "$GITHUB_STEP_SUMMARY" <<'PY'
import collections, re, sys
playbook, log, status = sys.argv[1], sys.argv[2], int(sys.argv[3])
ansi = re.compile(r"\x1b\[[0-9;]*m")
lines = [ansi.sub("", l.rstrip("\n")) for l in open(log, errors="replace")]
task, changes, failures, recap, in_recap = "", collections.OrderedDict(), [], [], False
for line in lines:
    if m := re.match(r"TASK \[(.*)\]", line):
        task = m.group(1)
    elif m := re.match(r"changed: \[([^\]]+)\]", line):
        changes.setdefault((m.group(1).split(" -> ")[0], task), 0)
        changes[(m.group(1).split(" -> ")[0], task)] += 1
    elif m := re.match(r"fatal: \[([^\]]+)\]", line):
        failures.append(f"{m.group(1)}: {task}")
    elif line.startswith("PLAY RECAP"):
        in_recap = True
    elif in_recap:
        if not line.strip():
            in_recap = False
        else:
            recap.append(line)
print(f"### {playbook}.yml dry run (`--check --diff`)\n")
if failures:
    print("**Failed:** " + "; ".join(failures) + "\n")
if changes:
    print("Would change (approve only if this is what you expect):\n")
    print("| Box | Task | Changes |\n|---|---|---|")
    for (host, name), n in changes.items():
        print(f"| {host} | {name} | {n} |")
elif status == 0:
    print("Nothing would change on the boxes.")
print("\n<details><summary>PLAY RECAP</summary>\n\n```\n" + "\n".join(recap) + "\n```\n</details>\n")
print("Full output, including the diffs: this job's log.")
PY
exit "$status"
