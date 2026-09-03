# Apica Ascent on-prem installer

Installs a [k0s](https://k0sproject.io) Kubernetes cluster (single- or
multi-node) and deploys **Apica Ascent** via helm — automating the full
on-prem procedure from the [PaaS deployment docs](https://docs.apica.io/getting-started/paas-deployment):
host firewall preparation, k0s bootstrap, worker join + node-pool labels,
OpenEBS + MetalLB, Envoy Gateway, (optionally) the CloudNativePG operator,
TLS secrets, values generation, chart install, and verification. Includes
automatic workarounds for Oracle Cloud (OCI) VCN networking that otherwise
breaks self-managed Kubernetes.

## Requirements

- Ubuntu 22.04+, Debian 11+, Amazon Linux 2023 or a RHEL 8+ derivative, x86_64, passwordless sudo
- Run the installer **on the controller node**
- Per node: 4+ CPU (8 recommended), **16 GB RAM** (pod requests total ~13–17 GiB;
  below 14 GiB pods stay Pending), 50 GB free for images plus disk for data
  (the persistent volume claims request ~280–360 GiB on a full stack)
- Swap off, no `firewalld`/`ufw`, clock synchronised (NTP)
- Multi-node: SSH key access from the controller to each worker; unique hostnames
- Outbound internet: github.com, dl.k8s.io, get.helm.sh, docker.io, quay.io
  (+ ghcr.io for CNPG), the chart repos
- An S3-compatible bucket with read/write/delete credentials (AWS S3, OCI
  Object Storage compat, MinIO, …)
- A TLS certificate matching your domain (or `TLS_SELF_SIGNED=true` for a sandbox)
- Helm 4 is **not** supported by the chart; the installer installs Helm 3

See [TESTING.md](TESTING.md) for the step-by-step test procedure (static checks, positive and
negative preflight, failure diagnostics, idempotent re-run, uninstall/cleanup, fresh VM, multi-node).

## Quick start

```bash
cd installer
cp ascent.conf.example ascent.conf                   # non-secret settings
cp ascent-secrets.conf.example ascent-secrets.conf   # passwords + S3 keys, chmod 600
vi ascent.conf ascent-secrets.conf
./ascent-install.sh preflight --config ascent.conf   # full report, nothing is changed
./ascent-install.sh all       --config ascent.conf   # preflight + platform + application (~15-25 min)
```

Then point DNS for your `DOMAIN` at the controller's public IP, log in at
`https://<DOMAIN>` with the configured admin credentials, and configure
outbound mail (Settings → Mail) before relying on password reset.

## Commands

The **platform** (k0s, storage, MetalLB, Envoy Gateway, optional CNPG operator) and the
**application** (the Ascent helm release) have separate lifecycles. Application commands never
touch the platform.

| command | what it does |
|---|---|
| `preflight` | every check, one report (see below) |
| `all` | `preflight` + `platform install` + `app install` |
| `platform install` | network chain, k0s (or adopt), workers, add-ons, Envoy Gateway, CNPG operator |
| `platform uninstall` | removes **everything this installer created** and nothing else (alias `cleanup`) |
| `app install` / `app upgrade` | values, ingest secret, `helm upgrade --install`, verify; `upgrade` requires an existing release |
| `app rollback` | `helm rollback` to the previous revision, then verify |
| `app uninstall` | release + namespace + volumes (alias `uninstall`) |
| `worker join <ip:pool>` | (re)join a single worker and label it |
| `status` | installer state, host, platform and application health in one screen |
| `diagnose` | redacted support bundle `~/ascent-install/diagnostics/ascent-diagnostics-<ts>.tar.gz` |
| `network` `k0s` `workers` `addons` `envoy` `cnpg` `values` `deploy` `verify` | single idempotent phases |

Flags: `--config <file>` (default `./ascent.conf`, then the file next to the script), `--yes`
(skip confirmations), `--help` (documents every command).

`app uninstall`, `platform uninstall` and `app rollback` ask for confirmation; the prompt is written
directly to the terminal. When stdin is not a terminal (cron, CI, `nohup`) they refuse to run
unless `--yes` is given, so nothing ever waits silently for input.

## Configuration and secrets

`ascent.conf` is plain `KEY=value`, parsed line by line and **never sourced**, so values are not
shell-expanded. Secrets (`ADMIN_PASSWORD`, `PG_PASSWORD`, `S3_ACCESS`, `S3_SECRET`) live in
`ascent-secrets.conf` next to it (mode 600, auto-detected) or in `ASCENT_<VAR>` environment
variables; a secret found in the main file only produces a warning. Where secrets live at each
stage:

- on disk: only in `ascent-secrets.conf` (or the environment);
- generated `~/ascent-install/values.yaml`: **no credentials**; they go to helm through a temporary
  600 file under `~/ascent-install/tmp.*` that is deleted when the command ends;
- logs, console, `diagnose` bundle: every line passes through a redaction filter that masks the
  actual secret values plus `password:`, `secret:`, `token:`, `*_KEY:` style fields;
- in the cluster: helm stores the values it received in the release secret and the chart renders
  them into Kubernetes Secrets; that is chart behaviour the installer cannot change.

## State and ownership

`~/ascent-install/state/installer.state` is a `key=value` record of what the installer created or
changed (`created.k0s-cluster`, `firewall.chain.created`, `joined.worker.<ip>`,
`installed.cnpg-operator-release`, …), the cluster identity (`cluster.uid`, the `kube-system` UID),
and per-phase completion times. `cleanup` reads only this file. A running k0s cluster whose UID is
not recorded is treated as foreign: preflight fails unless `ADOPT_EXISTING_CLUSTER="true"`, and an
adopted cluster is never reset.

## Sizing

Set `INGEST_GB_PER_DAY` (plus `INGEST_MODE`, `WORKLOAD_TIER`, `INGEST_DESTINATIONS`,
`PEAK_MULTIPLIER`) and the installer applies the
[capacity planning guide](https://docs.apica.io/getting-started/paas-deployment/paas-architecture):

```text
ingest vCPU = ceil(GB/day ÷ tier baseline × destination factor × peak × HA)   HA ×1.2 on multi-node
flash pods  = ceil(vCPU ÷ 4)   (1 on a single node)      RAM = 4 GB/vCPU (Lake) or 2 GB/vCPU (Flow)
disk/pod    = max(50 GiB, 0.8 × GB/day ÷ pods)           rate limit = GB/day × 1e9 ÷ 86400 bytes/s
core tier   = +10 vCPU, +28 GB RAM, +150 GB disk (static)
```

Preflight prints the plan, fails when a single flash pod cannot fit the node, and warns when the
guide's totals exceed the host. Without `INGEST_GB_PER_DAY` the chart's default rate limit applies
(`-max_bytes_per_sec=346729`, about **30 GB/day**, in chart 3.1.5; 745654, about 64 GB/day, in
newer charts), so production installs must set it.
`INGEST_MODE=flow` enables the chart's `logflow_only` mode. S3 capacity is not derived: size it as
volume × retention × compression.

The flash volume size is a StatefulSet volume claim and therefore immutable: on `app upgrade` the
installer keeps the existing volume size and warns when the sizing suggests another value (the
OpenEBS hostpath class does not support expansion). Replicas, CPU, memory and the rate limit do
change in place. To apply a new volume size, `app uninstall` and `app install`.

## Downloads

k0s, kubectl and helm are downloaded only when missing, into `~/ascent-install/downloads`, and
verified against SHA-256 values pinned in the script. Changing a version without setting the
matching `*_SHA256` fails unless `SKIP_CHECKSUM_VERIFY="true"`.

## Preflight

`preflight` runs every check and prints **one complete report** (it never
stops at the first problem), grouped as `[ OK ]`, `[WARN]`, `[FAIL]` with a
summary list of all failures at the end. `all` refuses to continue while any
check fails. It covers:

| area | checks |
|---|---|
| config file | CRLF line endings, `$`/backticks inside double quotes (bash expansion), unknown variable names, example placeholders left in place |
| host | arch, OS, sudo, required commands, curl ≥ 7.75, CPU/RAM/disk thresholds, swap, kernel modules, cgroups, SELinux, firewalld/ufw, docker, other k8s distros, proxy env, NTP sync, hostname validity + resolution, existing k0s/helm (Helm 4 rejected)/kubectl, ports in use |
| network | PRIVATE_IP on an interface, node subnet derived from the real interface prefix, pod/service CIDR validity and **overlap with the LAN**, LB_IP inside the subnet and unused, OCI detection, DNS, download URLs for the pinned versions, chart repos, **chart version exists in the repo index**, registries, egress public IP |
| application | DOMAIN syntax + DNS, admin name/org/email, **admin password policy** (12+ chars, upper, lower, digit, special — the Ascent rule), **PG_PASSWORD URL-safety** (the chart embeds it unescaped in `postgresql://` URLs), DB_ENGINE, existing release |
| TLS | PEM parse, key matches cert, unencrypted key, expiry (<30 days warns), certificate **covers DOMAIN**, chain completeness, optional CA verification |
| S3 | endpoint URL shape, bucket name, **region vs endpoint hostname**, swapped access/secret heuristic, TLS/DNS/timeout diagnosis (private CA → `S3_CA_FILE`), **clock skew from the Date header**, then a signed **ListObjects + PutObject + GetObject + DeleteObject round-trip** with the real credentials (curl `--aws-sigv4`, boto3 fallback) — 403/404/400/301 are explained |
| workers | entry syntax, pools (ingest/base/common **all covered**), duplicates, controller listed as worker, subnet membership; per worker over SSH: sudo, arch, OS, CPU/RAM/disk, swap, NTP, internet, busy ports, firewall, unique hostnames, existing k0s |

## Phases

`all` runs everything; each phase is idempotent and re-runnable on its own:

| phase       | what it does |
|-------------|--------------|
| `preflight` | full validation report (see above) |
| `network`   | host firewall ACCEPT rules; OCI SNAT fix when applicable |
| `k0s`       | k0s controller + kubectl + helm + kubeconfig (existing k0s is reused, never reconfigured; existing kubeconfig is backed up) |
| `workers`   | firewall, connectivity check to the controller, join, pool labels on every worker |
| `addons`    | waits for OpenEBS/MetalLB extensions, applies the LB address pool |
| `envoy`     | Envoy Gateway (prerequisite of the chart) |
| `cnpg`      | CloudNativePG operator (only when `DB_ENGINE=cnpg`) |
| `values`    | generates a minimal helm **override** file (`~/ascent-install/values.yaml`); self-signed cert if requested |
| `deploy`    | namespace, ingest TLS secret, optional S3 CA configmap, recovers broken/pending releases, `helm upgrade --install` with the temporary secrets values |
| `verify`    | waits for every pod to be healthy, gateway programmed, HTTPS probe with SNI, prints the summary |
| `uninstall` | removes the Ascent release and namespace (all data); cluster and add-ons stay |
| `cleanup`   | removes **everything this script created** and nothing else (see below) |

Flags: `--config <file>`, `--yes` (skip confirmations), `--help`.

### Firewall

Rules live in dedicated chains `ASCENT-INSTALLER` (filter, hooked first in INPUT and FORWARD)
and `ASCENT-INSTALLER-NAT` (nat POSTROUTING, OCI only). Global policies and customer rules are
never changed or deleted; the previous FORWARD policy is recorded for reference. Removal is
"unhook, flush, delete chain". Rules from v0.2.0 that were inserted directly into INPUT are
migrated automatically the next time `network` runs.

### When something already exists

Every phase looks before it creates. Existing pieces are **reused** (k0s running, binaries in
`PATH`, storage class, MetalLB, namespace, PVCs), **updated in place** (the `eg` and
`cnpg-operator` releases, the Ascent release, the MetalLB pool, the ingest secret, the values
file) or **resumed** (a stopped k0s controller is started, a failed first release is
reinstalled, a pending release is rolled back). The installer never reconfigures a running
k0s, never upgrades k0s, and never touches resources it does not know by name. It **fails**
only when reuse is impossible: a k0s worker service on the controller, a `--single` k0s when
workers are configured, Helm 4, a foreign process on the ingress ports, an active
firewalld/ufw, or MetalLB/OpenEBS installed under other namespaces than the k0s extensions use.
Beware that reused PVCs keep their data, so a changed `PG_PASSWORD` will not apply to an
existing Postgres volume — run `uninstall` first if you need a clean database.

### When something fails

Every phase runs under an error trap. On failure the installer prints the
failed command, the phase, and **phase-specific diagnostics** — for k0s the
service journal, for add-ons the k0s extension charts and pods, for deploy /
verify the helm status, every unhealthy pod with its recent events and last log
lines, warning events, unbound PVCs, jobs, gateway status — plus the path of
the full log (`~/ascent-install/logs/`). Re-run the same command after fixing
the cause. `verify` fails (with the same diagnostics) if pods are not healthy
after 15 minutes instead of declaring success. The script body is wrapped in a
`main` function, so bash parses the whole file before running it: copying a
newer version over a running installer cannot corrupt the run in progress.

### uninstall vs cleanup

`uninstall` removes only the application: it deletes the Gateway API objects
first (their finalizers need the chart's in-namespace envoy-gateway controller
to still be running), then the helm release, then the namespace and its
volumes, and frees a GatewayClass left stuck in `Terminating`.

`cleanup` tears down everything the installer itself created, tracked in
`~/ascent-install/state/`: the release and namespace, the CNPG operator and
Envoy Gateway **only if the installer installed them**, the MetalLB pool, worker
nodes it joined (`k0s reset`), the k0s cluster **only if the installer created
it**, its iptables rules, `/etc/k0s/k0s.yaml` and `~/.kube/config` (backups
restored), the k0s/kubectl/helm binaries it downloaded, and the CNPG CRDs when
no CNPG cluster is left. A pre-existing cluster, pool, kubeconfig or Envoy
Gateway is never touched. Both ask for confirmation unless `--yes` is given.
`verify` ends with an admin-login probe (retried for 5 minutes, since coffee
bootstraps the admin account a few minutes after it starts).

## Topology

- **Single node** (`WORKERS` empty): `k0s --single`, node-pool selectors
  disabled, single replicas, reduced prometheus/postgres/redis footprint.
- **Multi node**: controller runs control plane + workloads
  (`--enable-worker --no-taints`); each worker joins via token and gets an
  `apica-node-pool=<pool>` label. All three pools must be covered (the
  controller can take one via `CONTROLLER_POOL`). The chart schedules by pool:

  | pool     | runs                                   |
  |----------|----------------------------------------|
  | `ingest` | logiq-flash (log/trace/metric ingest)  |
  | `base`   | prometheus, thanos, coffee, discovery  |
  | `common` | postgres, redis                        |

  Join tokens are created with a 15-minute expiry, travel to the worker over the SSH channel
  (never on a command line), are stored with mode 0600, invalidated on the controller after the
  join, and deleted from the worker once its kubelet client config exists.

## Existing clusters (EKS, OpenShift, any managed Kubernetes)

`CLUSTER_MODE="existing"` deploys onto the cluster of the current kubeconfig instead of
installing k0s. The network, k0s, workers and addons phases are skipped; Envoy Gateway, the
CNPG operator and the application are installed as usual. Requirements: an operator host with
bash 5, curl, openssl, kubectl and helm 3 (Linux, or macOS with Homebrew bash), cluster-admin
permissions, a storage class named in `STORAGE_CLASS`
(for example `gp3`), and a LoadBalancer implementation (cloud controller, MetalLB, ...).
Preflight checks these, sizes against the cluster's allocatable CPU and memory, and `verify`
probes the gateway through the address the LoadBalancer assigns, IP or hostname.
`CLOUD_PROVIDER="aws"` adds the NLB annotations to the Envoy service; `oci` keeps the chart's
OCI annotations; `none` removes them. On a shared cluster that already runs Envoy Gateway or the
CNPG operator under the same release names, use `app install` rather than `platform install`
so those shared releases are not upgraded. OpenShift additionally needs SCC permissions for the
chart's fixed-UID containers, which the installer does not manage.

## Database

`DB_ENGINE=bitnami` (default) deploys the chart's single-instance Bitnami
Postgres. `DB_ENGINE=cnpg` installs the CloudNativePG operator and lets the
chart create a CNPG cluster (1 instance single-node, 2 multi-node; backups
off — configure `cnpg.backups` via `EXTRA_VALUES_FILE` if wanted).

## TLS

`TLS_CERT_FILE`/`TLS_KEY_FILE` feed the gateway secret (`ascent-external-cert`,
managed by the chart) and the ingest secret `ascent-ingest` (syslog TLS; the
`ca.crt` comes from `TLS_CA_FILE`, else the intermediates found in the cert
file, else the cert itself). `TLS_SELF_SIGNED=true` generates a certificate for
sandboxes. For an S3 endpoint with a private CA set `S3_CA_FILE`: the installer
creates the `ascent-s3-ca` configmap, enables `s3_custom_ca`, and mounts the CA
into every Thanos component as the docs describe.

## Cloud VMs (OCI, AWS EC2) with k0s

OCI VCNs and EC2 ENIs enforce source/destination checks that **silently drop packets with
pod-IP sources**, breaking konnectivity tunnels, `kubectl logs/exec`, and
cross-node pod traffic on self-managed clusters. With
`APPLY_NETWORK_FIXES=auto` (default) the installer detects Oracle Cloud or EC2 and:

1. configures kube-router with `overlay-type=full` (IPIP) + `ipMasq`, and
2. adds a `POSTROUTING` SNAT rule on every node for pod→node traffic
   (kube-router's own masquerade rule excludes node-IP destinations).

The VCN security list or EC2 security group must still allow: 22, 80, 443 (public as needed),
and intra-subnet 6443/8132/9443/10250 **plus IPIP (protocol 4)**. Alternatively, disable the
source/destination check on every VNIC or ENI and set `APPLY_NETWORK_FIXES=false`. On Amazon
Linux install `iptables-nft` (and `iptables-services` if the rules should survive reboots);
`SSH_USER` is `ec2-user` there. OCI Object Storage: the access key is the 40-hex
string and the secret the base64 string — preflight flags them when swapped.

## Upgrades / changing configuration

The generated override file is the single source of truth:

```bash
vi ~/ascent-install/values.yaml
helm upgrade apica-ascent apica-repo/apica-ascent --version <ver> \
  -n apica-ascent -f ~/ascent-install/values.yaml
```

Re-running `./ascent-install.sh values --config ascent.conf` regenerates it
from the config (overwriting manual edits); `EXTRA_VALUES_FILE` is the place
for anything the installer does not model.

## Known chart issues the installer works around

Found while testing chart 3.1.5 on the OCI reference host:

- **Dashboard-upload hook fails with 401.** The `logiqctl` post-install job
  authenticates through casdoor, which has no user in this stack, so it loops
  forever and helm times out after 20 minutes with the release marked
  `failed`. `UPLOAD_DASHBOARD` therefore defaults to `false`. The job also
  prints the admin password in clear text in its log.
- **`helm uninstall` hangs on Gateway API finalizers.** The chart runs its own
  envoy-gateway controller inside the release namespace; helm deletes that
  Deployment before the Gateway/GatewayClass CRs, so their finalizers are never
  processed. `uninstall`/`cleanup`/release recovery delete those objects first
  and free a GatewayClass left in `Terminating`.
- **Gateway `Programmed` status lags.** Right after install the Gateway can
  report `AddressNotAssigned` while the LoadBalancer already serves HTTPS;
  `verify` relies on the HTTPS probe and only warns on the status.
- The first-install-failed state (`helm upgrade --install` → "has no deployed
  releases") is recovered by uninstalling revision 1 and reinstalling;
  persistent volumes are kept.
- **Release name must equal the namespace.** The vendored kube-prometheus template
  points the Thanos sidecar at `<namespace>-thanos-objstore-secret`, while the Thanos
  subchart creates `<release>-thanos-objstore-secret`. With different names the
  Prometheus pod stays in `CreateContainerConfigError`; preflight now rejects the
  combination. Found on the SRE OKE cluster with `RELEASE_NAME=installer-test` in
  namespace `ascent-installer-test`.

## Known limitations

- x86_64 only; air-gapped installs need a registry mirror (`IMAGE_REGISTRY`)
  and pre-staged binaries — not automated
- One controller (no HA control plane) — use k0sctl for HA topologies
- The installer never upgrades an existing k0s
- Docker Hub anonymous pull limits (100/6h per IP) can bite multi-node
  installs behind one NAT address
- TLS secret rotation, backups, and monitoring of the cluster itself are out of scope
