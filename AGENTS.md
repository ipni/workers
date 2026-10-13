# Working on this repo against the live boxes

Three independent single-node k3s clusters. There is no failover between them:
each box is a whole site behind its own hostname, so anything you do to all
three at once is a full outage of that service.

| Box    | Site      | IP              |
|--------|-----------|-----------------|
| sing-1 | singapore | 5.199.165.77    |
| lith-1 | lithuania | 46.166.169.131  |
| chic-1 | chicago   | 84.32.48.211    |

## Getting in

SSH is key-only as the hardened admin user `ipni`; root login is disabled and
the provider KVM console is the out-of-band fallback. The keys that may sign in
are the files in `keys/`, listed in `admin_pubkey_file` (takgn, nymd, byo, the
break-glass key and CI's own key); the hardening role removes any other.

### Break-glass access

For when no operator key works (lost laptop, someone away, a bad hardening
run). The private key exists only in 1Password: IPFS account, Compass vault,
item "IPNI boxes: break-glass SSH key (ipni user)", ID
`4ghgjny7l4rawld4spedu7mxz4`. The reference below uses the ID: the title's `:`
is not allowed in a 1Password reference, and the ID survives a rename. Use it
without writing it to disk, through a throwaway agent:

```bash
eval "$(ssh-agent -s)"
op read --account team-ipfs.1password.com \
  "op://Compass/4ghgjny7l4rawld4spedu7mxz4/private key?ssh-format=openssh" | ssh-add -
ssh -o IdentitiesOnly=yes -o IdentityFile=keys/break-glass.pub ipni@46.166.169.131
ssh-agent -k
```

Then fix whatever locked people out, through the repo, not by hand. If the key
has been used outside a real emergency or may have leaked, replace it: a new
SSH Key item in Compass, its public half in `keys/break-glass.pub`, and a
hardening run. Last resort if SSH itself is down: the provider's KVM console,
with `vault_console_password`.

The playbooks set `remote_user: "{{ admin_user }}"` themselves, so
`ansible-playbook` needs no user flag. **Ad-hoc `ansible` commands do not**, and
default to your local username, which fails with `Permission denied
(publickey)`. Pass `-u ipni`:

```bash
ansible ipfs_nodes -u ipni -m ping                       # all three
ansible sing-1 -u ipni -m shell -a 'uptime'              # one box
ssh ipni@5.199.165.77                                    # plain ssh
```

`ansible.cfg` sets `vault_password_file = .vault_pass`, which is gitignored, so
every ansible invocation fails without it. It already exists on this
controller; in CI it is `echo ci > .vault_pass`.

## kubectl

The k3s API server (6443) is deliberately closed to the internet — ufw denies
it and there is no flag to open it. The one exception is Argo CD on lith-1
(`argocd_hub`), which `platform.yml` lets reach the other boxes' 6443 from
lith-1's address only. Two ways in for people:

```bash
# 1. straight through ssh, no setup
ansible sing-1 -u ipni -m shell -a 'sudo k3s kubectl get pods -n needle -o wide'
ssh ipni@5.199.165.77 'sudo k3s kubectl -n needle logs deploy/needle --tail=50'

# 2. an ssh tunnel plus the fetched kubeconfig, for real kubectl
./scripts/kubectl-tunnel.sh sing-1        # prints the KUBECONFIG line to use
pkill -f "^ssh -f -N .*-L 6443:127.0.0.1:6443"   # stop it
```

`kubeconfigs/` holds cluster-admin credentials and is gitignored.

## needle

Four instances per box, `hostNetwork`, all on loopback. Defined in
`roles/needle/defaults/main.yml` as `needle_running_instances`:

| Instance  | HTTP API         | libp2p |
|-----------|------------------|--------|
| needle   | 127.0.0.1:8190   | 4004   |
| needle-b | 127.0.0.1:8191   | 4005   |
| needle-c | 127.0.0.1:8192   | 4006   |
| needle-d | 127.0.0.1:8193   | 4007   |

Loopback-only, so metrics have to be curled **on the box**:

```bash
ansible sing-1 -u ipni -m shell -a \
  'curl -s http://127.0.0.1:8190/debug/metrics/prometheus | grep ^needle_dht'
```

Each instance has an `<instance>-data` PVC mounted at `/data/needle`, holding
the autoconf cache and the `*.ndjson` snapshots. It is backed by k3s
`local-path`, pointed at the NVMe by `default-local-storage-path`
(`roles/k3s/tasks/main.yml`), so on the box the data is under
`/data/local-path-provisioner/<pv>_needle_<instance>-data`. Find it by claim
rather than guessing:

```bash
ansible sing-1 -u ipni -m shell -a \
  'sudo k3s kubectl get pv -o custom-columns=CLAIM:.spec.claimRef.name,PATH:.spec.hostPath.path --no-headers'
```

`local-path` deletes the volume's data with the claim.

## Rolling out without causing an outage

`production_rollout` is `true` in `group_vars/ipfs_nodes/main.yml` (the boxes
are live behind delegated-ipfs.dev), so a plain run rolls **one box at a time**,
one instance at a time, each warmed up first. `-e production_rollout=false`
rolls all three boxes at once, which is now an outage.

```bash
ansible-playbook routing.yml --check --diff -l sing-1   # always dry-run first
ansible-playbook routing.yml -l sing-1                  # one box
ansible-playbook routing.yml                            # one box at a time, warmed (default)
```

`site.yml` and `platform.yml` apply from CI: a merge that touches one gets a
dry run on the run's summary page, then waits for a required reviewer to
approve the real run in the `production` environment (README, "Running
playbooks from CI"). Prefer that to running them from a controller, so what
the boxes run is what is on `main`. site.yml also follows `production_rollout`:
one box at a time, stopping at the first box that fails or loses admin SSH
access. CI refuses to build a box (no root fallback), so a fresh box is still
an operator's `site.yml -l <box>`.

needle stays degraded for tens of minutes after a restart, long after the pod
reports Ready — measured at 200 req/s: 11 minutes in, p95 2904 ms with 2937
rejected lookups; by 69 minutes, p95 588–691 ms. That is what
`production_rollout` and `roles/needle/tasks/wait_warm.yml` exist for, and why
`-l <box>` is the habit rather than the exception.

## Locally built images

Every image on the fleet normally comes from a registry pinned by digest. A
locally built one exists only on the boxes you imported it to, so the moment a
manifest names it, any run that reaches a box without the import puts that box
into `ImagePullBackOff` — an outage for that box, on all four instances.

```bash
# build once, on the controller, and ship the result - never build per box,
# or the boxes end up running different bytes under the same tag
docker buildx build --platform linux/amd64 --load --provenance=false --sbom=false \
  -t needle:<tag> .
docker save needle:<tag> -o needle-snap.tar

scp needle-snap.tar ipni@<ip>:/tmp/
ssh ipni@<ip> 'sudo k3s ctr images import /tmp/needle-snap.tar'
ssh ipni@<ip> 'sudo k3s ctr images ls | grep needle'   # digest must match everywhere
```

`--provenance=false --sbom=false` matters: buildx otherwise attaches an
attestation manifest, and what lands in containerd is a manifest list rather
than the single-platform image k3s wants.

Import into **k3s's containerd** (`k3s ctr`), not docker — k3s does not read the
docker image store. Import before the manifest naming the image is applied, use
`-l <box>` for the whole life of the local image, and do not merge a branch that
names one: it is safe as a branch and dangerous on `main`.

## Checks CI runs

`ansible-playbook` and `kubectl` are installed; **`yamllint` and `ansible-lint`
are not**, and getting them is more annoying than it looks on this controller:

* there is no `pip`, no `pipx`, no `uv`;
* `python3 -m venv` fails - `ensurepip` is missing, it wants the
  `python3.12-venv` package;
* `sudo` needs a password, so `apt install` is not available unattended.

So bootstrap pip from upstream into a throwaway directory and run both linters
as **modules**. `pip install --target` does not create console scripts (only the
pip bootstrap itself gets one), so `yamllint`/`ansible-lint` on `$PATH` will not
appear no matter what you add to it — `python3 -m yamllint` is the way in:

```bash
LINTDIR=/tmp/ipni-lint            # anywhere disposable, outside the repo
curl -sSL -o /tmp/get-pip.py https://bootstrap.pypa.io/get-pip.py
python3 /tmp/get-pip.py --target "$LINTDIR" pip
PYTHONPATH=$LINTDIR python3 -m pip install --target "$LINTDIR" yamllint ansible-lint

PYTHONPATH=$LINTDIR python3 -m yamllint .
PYTHONPATH=$LINTDIR python3 -m ansiblelint          # NB: no hyphen in the module name
```

ansible-lint wants a `.vault_pass` (`echo ci > .vault_pass`) and reads the
shared collections from `~/.ansible/collections`, so it does not need its own
`ansible-galaxy` run.

It also prints a `Found incompatible custom yamllint configuration (.yamllint)`
warning and disables its fix mode. That is expected and not a failure: the repo
deliberately disables `line-length` and `braces` (see `.ansible-lint`). A pass
looks like `Passed: 0 failure(s), 0 warning(s) ... profile ... 'production'`.

```bash
for pb in site.yml routing.yml bootstrap.yml content.yml k3s-upgrade.yml platform.yml; do
  ansible-playbook --syntax-check "$pb"
done
ANSIBLE_STDOUT_CALLBACK=default ansible-playbook scripts/render-manifests.yml -e dest=rendered
for d in rendered/*/; do [ -f "$d/kustomization.yaml" ] && kubectl kustomize "$d" > /dev/null; done
```

`rendered/` is gitignored and is the way to see what a change actually does to
the manifests before it reaches a box. Diffing `kubectl kustomize
rendered/needle` against the same render on `main` is how you check a manifest
change does only what you meant.

**Two traps when linting locally**, both of which make a clean branch look
broken:

* `yamllint .` walks `rendered*/` if a previous render left one behind. Those
  contain the vendored `cert-manager.yaml`, which is only ignored at its
  in-repo path, so you get screens of indentation errors that CI never sees.
  Delete the render output first, or lint a copy of the tracked files.
* Do **not** try `git ls-files | xargs yamllint` to work around that. `yamllint
  .` only picks up `*.yaml`/`*.yml`; feeding it the file list forces every
  shell script, `.json` and `.md` in the repo through the YAML parser and
  produces hundreds of bogus syntax errors.
