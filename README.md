# IPFS/IPNI worker nodes

Ansible base preparation for three geographically distributed hosts that will
run IPFS-related services (someguy, a bootstrapper node, and the "content
cluster" node serving website content and documentation).

`site.yml` prepares the boxes; `routing.yml` deploys the routing service (someguy, the primary
workload, behind an Envoy origin for Cloudflare). The bootstrapper and content
cluster node come later.

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

It **reserves every host-network listener port** (`net.ipv4.ip_local_reserved_ports`).
These ports sit inside the ephemeral range, so without the reservation any
outbound socket could take one as its source port. A `Recreate` restart would
then fail to re-bind with "address already in use". Update the list in
`group_vars` whenever a host-network port is added.

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

The provider's unused **`ubuntu` account (uid 1000, in `sudo`) is removed**.
Several container images run as uid 1000, including k3s's own
metrics-server, and a container escape as that uid should not land in a
privileged login. Console recovery uses `root`.

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
changes (as when the boxes were renamed), leftover node objects are removed:
those with this box's own IP (the same machine under its old name) and any
that are not Ready. A Ready node on another IP is never deleted.

## someguy

[someguy](https://github.com/ipfs/someguy) is a Delegated Routing V1 HTTP
server (`/routing/v1/providers`, `/peers`, `/ipns`, `/dht/closest/peers`). It
answers lookups from the Amino DHT (accelerated client) and cid.contact.

```bash
ansible-playbook routing.yml                  # someguy + origin, all boxes
ansible-playbook routing.yml -l chic-1        # one box
ansible-playbook routing.yml --tags someguy   # someguy only
ansible-playbook routing.yml --check --diff   # dry run, validated by the API server
```

Manifests live in `k8s/someguy/` (kustomize, same conventions as
`storetheindex/deploy`). The role opens the libp2p port, ships the manifests,
applies them, waits for the rollout and checks `/version` on the box.

**Version:** v0.16.0, pinned by image digest in `k8s/someguy/kustomization.yaml`.
To upgrade, change the digest.

**Design points, and why**

- **`hostNetwork: true`.** someguy has no option to announce an address, and
  libp2p advertises the addresses it sees on its interfaces. On the pod network
  those are unreachable `10.42.x` addresses. With the host network each box
  advertises its public IP on TCP, QUIC, WebTransport and WebRTC.
- **Ports.** libp2p on **4004 tcp+udp is open** to the internet. The HTTP API
  listens on **127.0.0.1:8190 only**, the host's loopback, where its single
  client (the Envoy origin, also `hostNetwork`) lives. It is unreachable from
  any interface even without the firewall. There is deliberately no Service for
  it.
- **`strategy: Recreate`, and restarts are per-box outages.** With
  `hostNetwork` a second pod cannot bind the same ports, so a rolling update
  would deadlock. Every rollout, OOM kill or reboot takes that box's hostname
  down until the new process binds. Cloudflare does **not** cover the gap:
  responses are not cached (`cf-cache-status: DYNAMIC`), so someguy's
  `stale-if-error` header has no effect. Redundancy comes from the **live
  Cloudflare router** these boxes are meant to sit behind, which health-checks
  them and routes around a box that is down. There is no preStop pause: with
  no Service in front, it would only lengthen rollouts.
- **Upstreams.** The DHT plus the autoconf default endpoints, which means
  cid.contact for providers. **These boxes must never be configured as an
  upstream of cid.contact**, or provider lookups would loop.
- **No persistent state.** someguy keeps no identity or datastore on disk. Each
  restart gets a new PeerID and re-crawls the DHT, about 1–2 minutes before the
  accelerated client is ready. Requests are still served during the crawl,
  through the standard DHT client.
- **Memory.** The libp2p resource manager defaults to 85% of *host* RAM,
  ignoring the pod limit. It is capped explicitly at 64 GiB, below the 86 GiB
  container limit, with `GOMEMLIMIT=80GiB`.
- **Health checks.** someguy has no health endpoint, so the probes use `/version`.
- **Runs as uid 10001,** a uid with no account on the host, rather than the
  image's default 1000.

**Resources.** About 70% of each box is reserved: 20 CPU and 80 GiB requested,
86 GiB memory limit, no CPU limit (to avoid throttling). The remaining ~30% is
for the bootstrapper, the content cluster node and the OS. This is a
reservation, not measured need. Soon after deploy each box used about
0.5 GiB and a fraction of a core. Peaks come during the hourly DHT crawl (about
1,600 FDs and 800 sockets). Tune against `/debug/metrics/prometheus` once real
traffic arrives.

## Public endpoint: route-<box>.ipni.io

The public names deliberately avoid "someguy", since the implementation may
change.

```
client -> Cloudflare (proxied, Full strict) -> :443 Envoy on the box -> 127.0.0.1:8190 someguy
```

| Box    | Hostname             |
|--------|----------------------|
| sing-1 | route-sing-1.ipni.io |
| lith-1 | route-lith-1.ipni.io |
| chic-1 | route-chic-1.ipni.io |

Envoy (`k8s/route-origin`, `roles/route_origin`, v1.39.1 pinned by digest)
terminates TLS with a **Cloudflare Origin CA certificate**.

- **Paths are allowlisted, not blocklisted.** Only `/routing/v1/*` and
  `/version` reach someguy. Everything else returns 404, including
  `/debug/metrics/prometheus`, which shares a port with the API.
- **Paths are canonicalized before matching** (`normalize_path`,
  `merge_slashes`, escaped slashes rejected with 400). Without this,
  `/routing/v1/../debug/...` matched the allowlisted prefix and was forwarded
  unchanged. `/debug` stayed hidden only because someguy happened to redirect
  unclean paths.
- **Host allowlist.** Only the three `route-<box>.ipni.io` names are served; any
  other Host gets **421**. If the live Cloudflare router sends a different Host,
  add it to `domains` in `k8s/route-origin/envoy.yaml`.
- **The Cloudflare IP allowlist is not authentication.** ufw allows 443 only
  from Cloudflare's published ranges (pinned in
  `roles/route_origin/defaults/main.yml`). But *any* Cloudflare account can
  proxy its own hostname to these IPs and connect from those same ranges. The
  Host allowlist stops casual misuse. The real fix, **Authenticated Origin
  Pulls, is prepared but deferred** (see "Deferred: Authenticated Origin Pulls"
  below) until it is clear which Cloudflare zones will send traffic here.
  Until then, another Cloudflare account that rewrites Host can still reach
  someguy through these origins. The data is public, but that bypasses any
  `ipni.io` zone controls such as rate limiting.
- **Envoy runs with `hostNetwork` so the ufw rule applies at all.** Traffic to a
  LoadBalancer or hostPort is DNATed into the FORWARD chain, where kube-proxy
  accepts it before ufw sees it. With `hostNetwork` the traffic goes to the
  host's INPUT chain and ufw enforces it. Verified: a non-Cloudflare IP is
  dropped (logged as `UFW BLOCK ... DPT=443`). Stale Cloudflare rules are
  removed automatically, and `scripts/check-cloudflare-ranges.sh` compares the
  pinned list with Cloudflare's API (exit 1 on drift).
- **IPNS publishing is open, deliberately.** `PUT /routing/v1/ipns/{name}`
  reaches someguy, matching production `delegated-ipfs.dev`. Records are
  self-certifying, but each PUT fans out to the DHT, so it has its own small
  rate limit.
- **Rate limits.** A Cloudflare rate limiting rule limits per client. Envoy
  adds per-box ceilings that still apply if Cloudflare is bypassed:
  - lookups: 1,000 req/s, burst 2,000;
  - IPNS PUT: 20 req/s, burst 50.

  Over the limit, Envoy returns **429** with `x-local-rate-limit`. These are
  **starting values, not measured capacity**; tune them before production
  traffic arrives. Circuit breakers are 20,000, matching the downstream
  connection cap and well under loopback's ~64k source ports.
- **Streaming and timeouts.** NDJSON responses stream unbuffered (first byte in
  about 0.1s). The route timeout is 60s: above someguy's 25s lookup cap, below
  Cloudflare's 100s proxy timeout.
- **Binding 443 as non-root.** Kubernetes does not give added capabilities to
  non-root processes. The role instead sets the host's
  `net.ipv4.ip_unprivileged_port_start=443`. This lets *any* host process bind
  443–1023. That was accepted over moving Envoy to 8443 with a Cloudflare Origin
  Rule: these boxes are single-tenant, and a process without the origin
  certificate would be rejected by Full (strict) anyway.

### Certificate

- **Private key:** generated locally, stored only in
  `group_vars/ipfs_nodes/vault.yml`.
- **CSR:** `certs/route-origin.csr`.
- **Certificate:** issued by Cloudflare from that CSR, stored at
  `certs/route-origin.crt`. It is public, so it is committed. It covers
  **`*.ipni.io`** and is valid until 2041-09-10. Cloudflare issues for the
  hostnames entered in its dashboard, not the CSR's list. The wildcard covers
  every `route-<box>.ipni.io`, and the hostname check understands wildcards.
  **Accepted trade-off:** a key leaked from any box would be a valid origin
  identity for every `ipni.io` hostname using Full (strict). Authenticated
  Origin Pulls is the stronger control. To narrow it, reissue for the three
  exact names; the preflight handles exact names too.
- **TLS secret:** created from the vault straight into Kubernetes. The key is
  never in a manifest or a plaintext file.

**Preflight.** Before touching a box, the role checks:

- the certificate matches the vaulted key;
- it covers the box's hostname;
- it has more than 30 days left;
- with AOP enforced only: the origin-pull client certificate chains to our CA
  and has more than 30 days left.

**After deploy** it checks that Envoy serves exactly that certificate (by
SHA-256 fingerprint), then runs `roles/route_origin/tasks/verify.yml`:
allowlisted and hidden paths, IPNS PUT reaching someguy, four path-traversal
cases, and a wrong Host (421). With AOP enforced it also checks that a
connection without the client certificate is refused. Any unexpected result
fails the deploy.

**Renewal.** Replace `certs/route-origin.crt` and run
`ansible-playbook routing.yml --tags origin`. Envoy restarts to load it.

### Cloudflare configuration (manual, `ipni.io` zone)

1. Proxied A records: `route-sing-1` → `5.199.165.77`,
   `route-lith-1` → `46.166.169.131`, `route-chic-1` → `84.32.48.211`.
2. The Origin CA certificate from the CSR, as above.
3. SSL mode **Full (strict) via a Configuration Rule scoped to these three
   hostnames**: Rules → Overview → Create rule → Configuration Rule, filter
   Hostname *is in* the three names, then set **SSL → Strict** and Deploy. Not
   zone-wide: `ipni.io` has other sites (the apex and `www` are already proxied).
4. **Rate limiting rule:** Security rules → Create rule → Rate limiting rules.
   Match the three hostnames, count per IP, then Block. The Free plan allows
   one rule, a 10s period and a 10s block.

### Deferred: Authenticated Origin Pulls

**Prepared but not enabled.** It waits until it is known which Cloudflare zones
will send traffic to these origins: `ipni.io` today, plus the live router's
zone once the boxes join it. Enforcing it before every such zone presents the
certificate would refuse that zone's traffic.

Already in place:

- **Private CA:** `certs/origin-pull-ca.crt`, valid 10 years. Its key is
  `vault_origin_pull_ca_key`.
- **Client certificate:** `certs/origin-pull-client.crt`, valid until
  2029-09-14. Its key is `vault_origin_pull_client_key`. This is what gets
  uploaded.
- **Role support behind one switch,** `route_origin_aop_enforced` (default
  `false`): certificate preflight, the CA in the TLS secret, and a
  no-client-certificate test that must be refused.

To enable, **in this order**:

1. In **every** zone that proxies to these origins: SSL/TLS → Origin Server →
   Authenticated Origin Pulls → zone-level **Upload certificate**. Paste
   `certs/origin-pull-client.crt` and the key from
   `ansible-vault view group_vars/ipfs_nodes/vault.yml`, then switch zone-level
   AOP **On**. Origins that do not request a client certificate never see it,
   so other sites in the zone are unaffected. Do **not** use Cloudflare's shared
   global AOP certificate: every Cloudflare customer has it.
2. Add to the `DownstreamTlsContext` in `k8s/route-origin/envoy.yaml`:
   ```yaml
   require_client_certificate: true
   common_tls_context:
     validation_context:
       trusted_ca: { filename: /etc/envoy/tls/ca.crt }
     # ...existing alpn_protocols, tls_params, tls_certificates
   ```
3. Set `route_origin_aop_enforced: true`, then run
   `ansible-playbook routing.yml -l chic-1 --tags origin`. Confirm through
   Cloudflare, then roll out to the other boxes.

**If the client certificate expires, Envoy rejects all traffic.** The
preflight fails deploys 30 days before that.

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
- [x] ~~Cloudflare DNS records, Full (strict) configuration rule, origin
      certificate~~ — done. Verified end to end through Cloudflare on all three
      boxes: `/version` 200, streaming provider lookups, `/debug/` 404, and each
      request's `cf-ray` appears in the correct box's Envoy access log.
- [ ] Run `scripts/check-cloudflare-ranges.sh` periodically (cron or CI).
- [ ] **Before putting these boxes behind the live Cloudflare router:**
  - find out which Host it sends and which zone it lives in;
  - add that Host to `domains` in `k8s/route-origin/envoy.yaml` (otherwise 421);
  - point the router's health check at `/version`.
- [ ] **Enable Authenticated Origin Pulls** once the zones are known (see
      "Deferred: Authenticated Origin Pulls").
- [ ] Add the Cloudflare rate limiting rule (see Cloudflare configuration).
- [ ] Tune someguy resources and Envoy's rate limits against real traffic metrics.
- [ ] Deploy the bootstrapper and the content cluster node. Service ports are
      opened by each service's own role, as someguy's are.
- [ ] Set up monitoring/alerting, and scrape `/debug/metrics/prometheus`.
- [ ] Optional: every box's host `resolv.conf` lists its two provider
      nameservers twice, so kubelet warns and keeps only three entries. DNS
      works; de-duplicating would silence the warning.

## Layout

```
ansible.cfg               inventory, vault and SSH defaults
inventory/hosts.yml       the three hosts
group_vars/ipfs_nodes/    tunables (admin user, firewall, k3s, sysctl)
host_vars/<box>/vault.yml   encrypted per-box credentials
roles/{common,storage,hardening,k3s}/   base preparation
roles/someguy/            someguy firewall + deploy
roles/route_origin/       Envoy origin: cert preflight, Cloudflare allowlist, TLS secret
  tasks/verify.yml        post-deploy request checks (paths, Host, traversal; AOP when enforced)
roles/kustomize_apply/    shared: ship, dry-run/apply, wait, prune stale ConfigMaps
k8s/someguy/              someguy kustomize manifests
k8s/route-origin/         Envoy kustomize manifests and envoy.yaml
certs/                    origin CSR + certificate, origin-pull CA + client certificate (public)
group_vars/ipfs_nodes/vault.yml  encrypted origin TLS key, origin-pull CA and client keys (AOP, deferred)
scripts/bootstrap-vault.sh  servers.txt -> encrypted vaults (one-time; source now deleted)
scripts/kubectl-tunnel.sh   SSH tunnel to a box's API server
scripts/check-cloudflare-ranges.sh  pinned Cloudflare ranges vs Cloudflare's API
site.yml                  base preparation playbook
routing.yml               routing service playbook (someguy + origin)
```
