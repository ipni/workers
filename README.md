# IPFS/IPNI worker nodes

Ansible base preparation for three geographically distributed hosts that will
run IPFS-related services (someguy, a bootstrapper node, and the "content
cluster" node serving website content and documentation).

This repository currently covers **base preparation only**. Service workloads
are deployed in a later pass.

| Box    | Site      | IP              | Role                   |
|--------|-----------|-----------------|------------------------|
| sing-1 | singapore | 5.199.165.77    | standalone k3s cluster |
| lith-1 | lithuania | 46.166.169.131  | standalone k3s cluster |
| chic-1 | chicago   | 84.32.48.211    | standalone k3s cluster |

The **box** name is the inventory name, hostname, k3s node name and kubeconfig
context. The **site** is the location, carried as the `site` variable and the
`site=` node label, so a second box in the same place (e.g. `chic-2`) shares a
site without sharing an identity.

Each host: Ubuntu 24.04 LTS, 32 cores, 123 GiB RAM, 2 × 894 GiB NVMe.

## Why three clusters instead of one

These sites are 150–250 ms apart. etcd's raft defaults assume a 100 ms
heartbeat and a 1000 ms election timeout, so a single control plane stretched
across all three would suffer constant leader elections and slow writes. The
IPFS workloads do not need shared cluster state, so each host runs its **own
independent single-node k3s cluster**. Geographic redundancy belongs above
Kubernetes (DNS/anycast), not inside it.

## Quick start

```bash
ansible-playbook site.yml                  # all three hosts
ansible-playbook site.yml -l chic-1        # one host
ansible-playbook site.yml --tags hardening # one concern
ansible-playbook site.yml --check --diff   # dry run
```

The playbook is idempotent and safe to re-run.

## Accessing the clusters

The k3s API server is **not exposed to the internet** — ufw denies 6443. Access
goes over an SSH tunnel:

```bash
./scripts/kubectl-tunnel.sh chic-1
export KUBECONFIG=$(pwd)/kubeconfigs/.chic-1-tunnel.yaml
kubectl get nodes
```

Each box's kubeconfig names its cluster, user and context after the box, so
all three can be merged into a single `KUBECONFIG` without colliding.

## What the playbook does

**`common`** — hostname, UTC, full apt upgrade, base packages, chrony,
unattended security upgrades (no automatic reboots: these nodes should be
drained deliberately). Disables swap, since kubelet behaves unpredictably with
it and 123 GiB of RAM makes it unnecessary. Applies sysctl tuning for libp2p's
very high connection counts and QUIC/UDP throughput, and raises file descriptor
limits to 1048576.

It also binds **Postfix to loopback only**. The provider image left an MTA
listening on `0.0.0.0:25`, which is an unnecessary abuse target on a fresh host.

**`storage`** — formats the second, blank NVMe and mounts it at `/data`, then
points k3s's local-path provisioner there so IPFS blockstores never compete
with the OS disk.

> The two NVMe devices are **not** named consistently across hosts — chic-1
> has its OS on `nvme1n1` while the others use `nvme0n1`. The role therefore
> identifies the target by shape (a whole NVMe with no partition table, no
> filesystem signature, and no mount) and **refuses to run** unless exactly one
> candidate is found. It never selects a disk by name.
>
> Every storage check reads live state (`blkid`, `lsblk`, `findmnt`), never
> cached Ansible facts. Facts are cached for an hour, and a cache written before
> `/data` existed would otherwise make the in-use data disk look blank. Once a
> volume labelled `ipfsdata` exists, the format step is skipped outright.

**`hardening`** — creates the `ipni` admin user with your ed25519 key and
passwordless sudo, then locks SSH down to key-only with root login disabled,
enables ufw with a default-deny inbound policy, and configures fail2ban.

> **The key file is the single source of truth.** `authorized_key` runs with
> `exclusive: true`, so any key added to the `ipni` account by hand is removed
> on the next run. To give a second operator access, turn `admin_pubkey_file`
> into a list in `group_vars` rather than editing the host.

fail2ban is kept mainly to cut log noise: with password authentication
disabled there are few credential guesses left for it to ban.

The task order is load-bearing:

1. create the admin user, install the key, grant sudo
2. **prove** key login + sudo works — a hard gate that aborts the play on failure
3. allow SSH through ufw, *then* enable ufw
4. only now disable root login and password authentication

If step 2 fails, the play stops while password auth is still enabled, so the
host stays reachable. Step 3's ordering matters just as much: enabling a
default-deny firewall before allowing SSH would lock everyone out.

**`k3s`** — installs a pinned k3s version as a standalone single-node cluster,
disables traefik (ingress is chosen deliberately when services land), waits for
the node to become Ready, and fetches a per-box kubeconfig. If the node name
changes (as when the boxes were renamed), stale `NotReady` node objects are
removed; a live node is never deleted.

## Secrets

Credentials live in per-host `ansible-vault` files under
`host_vars/<box>/vault.yml`, encrypted with `.vault_pass`. They were generated
from a plaintext `servers.txt` by `scripts/bootstrap-vault.sh`; that file was
gitignored, never committed, and has since been deleted, so **the vault files
are now the only copy**. Edit them in place with
`ansible-vault edit host_vars/<box>/vault.yml`.

The password fact is set with `no_log: true`, so the root password does not
appear in output even at `-vvv`.

**Back up `.vault_pass`.** Without it the vault files cannot be decrypted.

Recovery is via the **provider KVM/web console** using the console password in
the vault. SSH has no password fallback by design.

## Outstanding manual steps

- [ ] **Back up `.vault_pass`** somewhere off this machine.
- [ ] **Rotate the root passwords.** They sat in plaintext in `servers.txt`.
      Root SSH login is now disabled, so they only matter for console access,
      but rotating is good hygiene. Then record the new values with
      `ansible-vault edit` (`bootstrap-vault.sh` needs `servers.txt`, which is gone).
- [x] ~~Delete the plaintext file~~ — `servers.txt` has been deleted
- [ ] Decide service placement across the three sites
- [ ] Choose and deploy an ingress controller (traefik was deliberately disabled)
- [ ] Open service ports in `firewall_allowed_tcp` / `firewall_allowed_udp`
      when workloads land — IPFS swarm is 4001/tcp+udp, HTTP 80/443
- [ ] Set up monitoring/alerting

## Layout

```
ansible.cfg               inventory, vault and SSH defaults
inventory/hosts.yml       the three hosts
group_vars/ipfs_nodes/    tunables (admin user, firewall, k3s, sysctl)
host_vars/<box>/vault.yml   encrypted per-box credentials
roles/{common,storage,hardening,k3s}/
scripts/bootstrap-vault.sh  servers.txt -> encrypted vaults (one-time; source now deleted)
scripts/kubectl-tunnel.sh   SSH tunnel to a box's API server
site.yml                  the playbook
```
