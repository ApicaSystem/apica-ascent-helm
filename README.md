# Apica Ascent Helm Charts

Deploys the Apica Ascent observability platform (logging, metrics, tracing) on
Kubernetes. Single-namespace deployment. Requires Kubernetes >= 1.24.0 and
Helm 3.

There are two ways to deploy it:

- **Installer** (recommended for on-prem, single-VM and customer installs): one script that
  sets up the platform and the chart, with prerequisite checks and diagnostics. See
  [Installing on-prem (installer)](#installing-on-prem-installer) below.
- **Helm directly** (for existing Kubernetes platforms managed by your own tooling): the
  chart in `apica-ascent/`, documented in the sections that follow the installer.

## Installing on-prem (installer)

For customer and single-VM installs use the installer in [`installer/`](installer/README.md)
instead of running helm by hand. It installs k0s, MetalLB, OpenEBS, Envoy Gateway and
optionally the CloudNativePG operator, then this chart, and it also works against an
existing cluster (EKS, OKE, MKE, OpenShift) with `CLUSTER_MODE=existing`.

```bash
BASE=https://apicasystem.github.io/apica-ascent-helm/installer
curl -fsSLO "$BASE/ascent-install.sh" && curl -fsSLO "$BASE/SHA256SUMS" && sha256sum -c SHA256SUMS
chmod +x ascent-install.sh
./ascent-install.sh                     # asks for every setting, saves ascent.conf, runs the install
./ascent-install.sh status              # health of platform and application
./ascent-install.sh --help              # all commands and options
```

Cloning the repository and running `installer/ascent-install.sh` works the same way.

What it adds over plain helm: a preflight that reports every failing prerequisite in one
pass (host, network, TLS, live S3 read/write test, password policy, sizing from the capacity
planning guide), idempotent phases with resume guidance and diagnostics on failure, separate
platform and application lifecycles, an uninstall/cleanup that removes only what it created,
and a redacted support bundle (`diagnose`). Details, requirements and the test procedure are in
[installer/README.md](installer/README.md).

## Chart structure

```
apica-ascent/
├── Chart.yaml              # Dependencies declared here
├── values.yaml             # Canonical defaults
├── values-test.yaml        # Live test deployment on OKE (cnpg-test namespace)
├── values.{small,medium,large,single}.yaml   # Sizing profiles
├── templates/              # ~37 templates; most are Envoy Gateway and PerfectScale
└── charts/                 # Vendored apica subcharts (third-party charts are downloaded)
```

## Components

| Subchart / alias | What it is | Toggle |
|---|---|---|
| `logiq-flash` | Core ingest, ML, sync | always on |
| `flash-coffee` | Query / analytics engine | always on |
| `flash-discovery` | Service discovery | always on |
| `logiqctl` | CLI init job | always on |
| `redis` (valkey) | Session cache, log tailing | `global.chart.redis` |
| `prometheus` (kube-prometheus-stack) | Metrics | `global.chart.prometheus` |
| `thanos` | Long-term metrics storage | `global.chart.thanos` | 
| `cnpg` (cloudnative-pg/cluster) | CloudNativePG Postgres cluster | `cnpg.enabled` |

**Envoy Gateway** is wired up via ~15 custom templates (not a subchart). It
provides the external LoadBalancer and handles HTTP, HTTPS, and TCP listeners
(ports 9999 and 8081).

The unauthenticated ingestion ports — 14250 (Jaeger gRPC), 14268 (Jaeger HTTP,
also behind the `/api/traces` HTTP route) and 20514 (RELP logs) — are **opt-in
as of chart 3.1.6** and are not exposed by the Gateway unless
`envoyGateway.traceIngestion.enabled` is set to `true`. Enable it only where the
Gateway is reachable from a trusted network. The `logiq-flash` Service keeps
these ports for in-cluster clients either way.

> **Upgrading from 3.1.5 or earlier:** these three ports were previously always
> exposed. Upgrading with the default (`false`) removes their Gateway listeners
> and TCPRoutes, which will break external Jaeger clients *and* external RELP log
> shippers on 20514.

**PerfectScale** resource automation configs are present but off by default
(`perfectscale.enabled: false`).

## Ingest rate limiting

Flash supports token-bucket ingest rate limiting, configured via a dedicated
value (applies when `logflow_only` is disabled; the limit is per flash
replica):

```yaml
global:
  environment:
    rate_limit_flags: "-rl_type=tokenbucket -max_bytes_per_sec=346729"
```

## Database: CNPG

### CloudNativePG (`cnpg.enabled: true`, default)

High-availability Postgres cluster via the `cloudnative-pg/cluster` subchart
(v0.6.1, alias `cnpg`).

For a fresh CNPG deployment:
```yaml
global:
  environment:
    postgres_host: "<release>-cnpg-rw"   # or pooler service if poolers are configured
    postgres_port: "5432"
cnpg:
  enabled: true
  mode: standalone
```

#### Credentials — critical gotcha

`cnpg.superuserSecret` is pre-created by `templates/cnpg-secrets.yaml` and CNPG
reads from it to set the postgres superuser password. **Do not set
`cluster.initdb.owner: postgres`.** If you do, CNPG treats the superuser as the
application owner, generates a random password for it in the auto-created
`<release>-app` secret, and overrides the superuser secret — breaking all
application connections.

The `initdb` section should be omitted entirely (CNPG defaults to an `app`
user/database, leaving the superuser alone):
```yaml
cnpg:
  cluster:
    # no initdb section
```

Also: `postgres` is a **reserved database name** in CNPG. Do not use it as
`initdb.database`.

#### OCI Object Storage backup — required env vars

Two env vars are required on the cluster pods for WAL archiving and backups to
work against OCI's S3-compatible endpoint:

```yaml
cnpg:
  cluster:
    env:
      - name: AWS_DEFAULT_REGION           # must match the OCI region in the endpoint URL
        value: us-ashburn-1
      - name: AWS_REQUEST_CHECKSUM_CALCULATION  # disables botocore 1.35+ trailing-checksum behaviour
        value: when_required
```

Setting any element of `cnpg.cluster.env` (with `--set` or a GitOps
parameter) replaces the whole list from values.yaml, so a per-environment
override must pass all four parameters:

```
cnpg.cluster.env[0].name=AWS_DEFAULT_REGION
cnpg.cluster.env[0].value=<region>
cnpg.cluster.env[1].name=AWS_REQUEST_CHECKSUM_CALCULATION
cnpg.cluster.env[1].value=when_required
```

Without `AWS_DEFAULT_REGION`: SigV4 signing uses `us-east-1`; OCI returns 403.
Without `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`: botocore 1.35+ adds
trailing CRC32 checksums via `Transfer-Encoding: chunked`, omitting
`Content-Length`; OCI returns `MissingContentLength` on every PutObject.

#### Node placement

`cnpg` is the upstream `cloudnative-pg/cluster` chart, downloaded like the other
third-party dependencies. No upstream version (0.6.1 through 0.9.0) reads
`global.nodeSelectors`, so the database node pool is set directly and must be
kept in sync with `global.nodeSelectors.label` / `global.nodeSelectors.db`:

```yaml
cnpg:
  cluster:
    affinity:
      nodeSelector:
        apica-node-pool: common
```

Setting `global.nodeSelectors.enabled: false` does not remove it; set
`cnpg.cluster.affinity.nodeSelector: {}` as well. Other affinity fields (e.g.
`topologyKey`, which defaults to `topology.kubernetes.io/zone`) can be set
alongside it.

#### Failover characteristics

- **Planned switchover** (node drain, rolling upgrade): CNPG does a graceful
  handoff — ~2–5 seconds. With a PgBouncer pooler in front, client connections
  are queued transparently (zero errors).
- **Unplanned failover** (pod killed): CNPG waits for the primary's Kubernetes
  lease to expire before promoting the standby. Typically 15–60 seconds on a
  healthy cluster; can be longer if the pod is stuck in `Terminating`.
- Adding more replicas does **not** speed up failover — CNPG is
  operator-driven, not quorum-driven.

For zero-downtime planned operations, add a pooler:
```yaml
cnpg:
  poolers:
    - name: rw
      instances: 2
      type: rw
      pgbouncer:
        poolMode: transaction
        parameters:
          max_client_conn: "1000"
          default_pool_size: "25"
```
Application connects to `<release>-<pooler-name>-rw` instead of
`<release>-cnpg-rw`.

#### Restoring from backup

To bootstrap a new CNPG cluster from an existing barman backup (disaster
recovery, environment recreation):

1. Set `cnpg.mode: recovery` and `cnpg.recovery.method: object_store`
2. Set `cnpg.recovery.clusterName` to the serverName used in the backup — this
   is the top-level directory visible in the backup bucket (e.g.
   `s3://bucket/cnpg-test/` → `clusterName: "cnpg-test"`)
3. Provide the same S3/OCI credentials and endpoint URL as the `cnpg.backups`
   section
4. Optionally set `cnpg.recovery.pitrTarget.time` (RFC3339) for point-in-time
   recovery; leave empty to restore to the latest available backup
5. Set `cnpg.recovery.secret.create: true` — the cluster subchart creates the
   S3 credentials Secret automatically

Once the cluster reaches `Cluster in healthy state`, the bootstrap section is
immutable; `mode` can be left as-is or changed to `standalone` for
documentation purposes only.

A ready-to-use example for the test environment is in `values-test.yaml` as a
commented block above the active `recovery:` section.

## Test environment

`values-test.yaml` targets Oracle OKE, namespace `cnpg-test`. It has CNPG
enabled with backups to OCI Object Storage. The S3 credentials in that file are
test credentials — do not commit real credentials.

Test install/upgrade:
```bash
helm install cnpg-test apica-ascent -n cnpg-test -f apica-ascent/values-test.yaml
helm upgrade cnpg-test apica-ascent -n cnpg-test -f apica-ascent/values-test.yaml
```

## Creating Releases

1. Ensure Flash and Coffee tags in `apica-ascent/values.yaml` match current
production release. Update the on-prem example values files using the script in
`apica-ascent/`.
1. Change the `version` value in `apica-ascent/Chart.yaml`.
1. Set `appVersion` to match the Ascent release indicated by the Flash and
Coffee tags in `apica-ascent/values.yaml`.
1. Run `helm package apica-ascent` from the top-level directory. This will
generate a new tarball. If there are more than two tarballs, `git rm` the
oldest one(s).
1. Run `helm repo index .` from the top-level directory. This will update
`index.yaml` so clients see the new version.
1. If the installer changed, refresh its checksum file:
`(cd installer && shasum -a 256 ascent-install.sh > SHA256SUMS)`.
1. Open a pull request to get the changes merged.
1. Once the PR is merged, create an annotated tag matching the release version
and push it.
   ```
   git tag -a <semver> <commit-hash> -m "Release <semver>"
   git push origin <semver>
   ```
1. Create a [Github
Release](https://github.com/ApicaSystem/apica-ascent-helm/releases).
  * Use the previous release tag to generate release notes. Edit release notes for clarity
(e.g., remove Jira ticket references from descriptions). 
  * Name it `apica-ascent v<semver>`
