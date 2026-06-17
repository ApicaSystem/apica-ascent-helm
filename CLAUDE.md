# Apica Ascent Helm Chart

Deploys the Apica Ascent observability platform (logging, metrics, tracing) on Kubernetes. Single-namespace deployment. Requires Kubernetes >= 1.24.0 and Helm 3.

## Chart structure

```
apica-ascent/
├── Chart.yaml              # Dependencies declared here
├── values.yaml             # Canonical defaults
├── values-test.yaml        # Live test deployment on OKE (cnpg-test namespace)
├── values.{small,medium,large,single}.yaml   # Sizing profiles
├── templates/              # ~37 templates; most are Envoy Gateway and PerfectScale
└── charts/                 # Vendored subcharts (apica + cnpg/cluster)
```

## Components

| Subchart / alias | What it is | Toggle |
|---|---|---|
| `logiq-flash` | Core ingest, ML, sync | always on |
| `flash-coffee` | Query / analytics engine | always on |
| `flash-discovery` | Service discovery | always on |
| `logiqctl` | CLI init job | always on |
| `postgres` (bitnami) | Metadata DB | `global.chart.postgres` |
| `redis` (bitnami) | Session cache, log tailing | `global.chart.redis` |
| `prometheus` (bitnami kube-prometheus) | Metrics | `global.chart.prometheus` |
| `grafana` (bitnami) | Dashboards | `global.chart.grafana` (off by default) |
| `thanos` | Long-term metrics storage | `thanos.*` |
| `cnpg` (cloudnative-pg/cluster) | CloudNativePG Postgres cluster | `cnpg.enabled` |

**Envoy Gateway** is wired up via ~15 custom templates (not a subchart). It provides the external LoadBalancer and handles HTTP, HTTPS, and TCP listeners (ports 9999, 8081, 14250, 20514, 14268).

**PerfectScale** resource automation configs are present but off by default (`perfectscale.enabled: false`).

## Database: Bitnami vs CNPG

Two Postgres options. In steady state only one should be active. During migration from Bitnami to CNPG both run simultaneously — see [Migration from Bitnami](#migration-from-bitnami).

### Bitnami (default, `global.chart.postgres: true`)
Simple single-instance Postgres. Set `cnpg.enabled: false`.

### CloudNativePG (`cnpg.enabled: true`)
High-availability Postgres cluster via the `cloudnative-pg/cluster` subchart (v0.6.1, alias `cnpg`).

For a fresh CNPG deployment (no existing Bitnami data):
```yaml
global:
  chart:
    postgres: false       # disable Bitnami
  environment:
    postgres_host: "<release>-cnpg-rw"   # or pooler service if poolers are configured
    postgres_port: "5432"
cnpg:
  enabled: true
  mode: standalone
```

#### Credentials — critical gotcha

`cnpg.superuserSecret` is pre-created by `templates/cnpg-secrets.yaml` and CNPG reads from it to set the postgres superuser password. **Do not set `cluster.initdb.owner: postgres`.** If you do, CNPG treats the superuser as the application owner, generates a random password for it in the auto-created `<release>-app` secret, and overrides the superuser secret — breaking all application connections.

The `initdb` section should be omitted entirely (CNPG defaults to an `app` user/database, leaving the superuser alone):
```yaml
cnpg:
  cluster:
    # no initdb section
```

Also: `postgres` is a **reserved database name** in CNPG. Do not use it as `initdb.database`.

#### OCI Object Storage backup — required env vars

Two env vars are required on the cluster pods for WAL archiving and backups to work against OCI's S3-compatible endpoint:

```yaml
cnpg:
  cluster:
    awsDefaultRegion: us-ashburn-1          # must match the OCI region in the endpoint URL
    awsRequestChecksumCalculation: when_required  # disables botocore 1.35+ trailing-checksum behaviour
```

These are named string fields (not array elements) so they can be overridden individually via `--set cnpg.cluster.awsDefaultRegion=<region>` or a GitOps string-value override. The cluster subchart patch (see patch #3 below) injects them as `AWS_DEFAULT_REGION` and `AWS_REQUEST_CHECKSUM_CALCULATION` env vars on the cluster pods, merged with any entries in `cluster.env`.

Without `AWS_DEFAULT_REGION`: SigV4 signing uses `us-east-1`; OCI returns 403.  
Without `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`: botocore 1.35+ adds trailing CRC32 checksums via `Transfer-Encoding: chunked`, omitting `Content-Length`; OCI returns `MissingContentLength` on every PutObject.

#### Cluster subchart patches

The vendored `cloudnative-pg/cluster` subchart at `apica-ascent/charts/cluster/` contains local patches that have not been upstreamed yet. When upgrading the subchart version, these must be reapplied manually.

**1. `templates/_backup.tpl` — conditional compression fields**

Both `wal.compression` and `data.compression` are wrapped in `{{- if }}` guards:

```yaml
{{- if .Values.backups.wal.compression }}
compression: {{ .Values.backups.wal.compression }}
{{- end }}
```

**Why:** The CNPG CRD does not accept empty string or `null` for `compression` — the field must be omitted entirely to mean "no compression". The upstream template renders `compression: ` unconditionally, which the Kubernetes API rejects. The patch allows `compression: ""` in values to produce no field in the rendered manifest.

**2. `templates/ca-bundle.yaml` — recovery endpoint CA Secret**

A second Secret block has been added for `recovery.endpointCA`:

```yaml
{{- if and (eq .Values.mode "recovery") .Values.recovery.endpointCA.create }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Values.recovery.endpointCA.name | default (printf "%s-recovery-ca-bundle" ...) | quote }}
  ...
{{- end }}
```

**Why:** The upstream template only creates a CA bundle Secret for `backups.endpointCA.create`. The `_barman_object_store.tpl` references a CA Secret for both backup and recovery paths, but without this patch the recovery CA Secret is never created, causing the cluster to fail to start when a custom CA is required for the recovery object store endpoint.

**3. `templates/cluster.yaml` — named string fields for OCI env vars**

The `{{- with .Values.cluster.env }}` block is replaced with logic that builds the env list from named scalar values before rendering:

```yaml
{{- $env := default list .Values.cluster.env }}
{{- if .Values.cluster.awsDefaultRegion }}
{{- $env = append $env (dict "name" "AWS_DEFAULT_REGION" "value" (.Values.cluster.awsDefaultRegion | toString)) }}
{{- end }}
{{- if .Values.cluster.awsRequestChecksumCalculation }}
{{- $env = append $env (dict "name" "AWS_REQUEST_CHECKSUM_CALCULATION" "value" (.Values.cluster.awsRequestChecksumCalculation | toString)) }}
{{- end }}
{{- if $env }}
env:
  {{- toYaml $env | nindent 4 }}
{{- end }}
```

**Why:** GitOps tools such as Harness can only override named string values in values.yaml — they cannot target array elements by index. The upstream template puts these env vars in `cluster.env` (an array), making them impossible to override without redefining the whole array. The patch extracts the two OCI-required env vars into named scalar fields (`awsDefaultRegion`, `awsRequestChecksumCalculation`) that can be targeted directly, then merges them with any remaining entries in `cluster.env`.

**4. `templates/_backup.tpl` — string-safe `backups.enabled` guard**

The `{{- if .Values.backups.enabled }}` guard is replaced with an explicit string comparison:

```yaml
{{- if eq (.Values.backups.enabled | toString) "true" }}
```

**Why:** Go templates treat any non-empty string as truthy. Without this patch, passing `backups.enabled: "false"` as a string (required by GitOps tools like ArgoCD that only support string pipeline variables) would incorrectly enable backups. Converting to string first and comparing against `"true"` makes the field accept both boolean `true`/`false` and string `"true"`/`"false"`.

#### Failover characteristics

- **Planned switchover** (node drain, rolling upgrade): CNPG does a graceful handoff — ~2–5 seconds. With a PgBouncer pooler in front, client connections are queued transparently (zero errors).
- **Unplanned failover** (pod killed): CNPG waits for the primary's Kubernetes lease to expire before promoting the standby. Typically 15–60 seconds on a healthy cluster; can be longer if the pod is stuck in `Terminating`.
- Adding more replicas does **not** speed up failover — CNPG is operator-driven, not quorum-driven.

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
Application connects to `<release>-<pooler-name>-rw` instead of `<release>-cnpg-rw`.

#### Migration from Bitnami

**Both `global.chart.postgres: true` and `cnpg.enabled: true` must be set simultaneously during migration** — Bitnami must be running so CNPG can import from it.

Do all of the following in a **single `helm upgrade`** (not two separate upgrades):
- Set `cnpg.enabled: true` and `cnpg.mode: recovery`
- Set `global.environment.postgres_host` to `<release>-cnpg-rw`
- Keep `global.chart.postgres: true`

Switching `postgres_host` to CNPG in a later upgrade would create a window where Bitnami continues receiving writes after the CNPG snapshot was taken — those writes would be lost.

Once the CNPG cluster reaches `Cluster in healthy state`, do a second upgrade setting `global.chart.postgres: false` to decommission Bitnami.

Note: the `postgres` database is reserved in CNPG and is **not imported** — only user databases (`coffee`, `flash`, etc.) are migrated. Verify no application schema lives in the `postgres` database before running migration (the default Ascent setup stores none there).

#### Restoring from backup

To bootstrap a new CNPG cluster from an existing barman backup (disaster recovery, environment recreation):

1. Set `cnpg.mode: recovery` and `cnpg.recovery.method: object_store`
2. Set `cnpg.recovery.clusterName` to the serverName used in the backup — this is the top-level directory visible in the backup bucket (e.g. `s3://bucket/cnpg-test/` → `clusterName: "cnpg-test"`)
3. Provide the same S3/OCI credentials and endpoint URL as the `cnpg.backups` section
4. Optionally set `cnpg.recovery.pitrTarget.time` (RFC3339) for point-in-time recovery; leave empty to restore to the latest available backup
5. Set `cnpg.recovery.secret.create: true` — the cluster subchart creates the S3 credentials Secret automatically

Once the cluster reaches `Cluster in healthy state`, the bootstrap section is immutable; `mode` can be left as-is or changed to `standalone` for documentation purposes only.

A ready-to-use example for the test environment is in `values-test.yaml` as a commented block above the active `recovery:` section.

## Test environment

`values-test.yaml` targets Oracle OKE, namespace `cnpg-test`. It has CNPG enabled with backups to OCI Object Storage. The S3 credentials in that file are test credentials — do not commit real credentials.

Test install/upgrade:
```bash
helm install cnpg-test apica-ascent -n cnpg-test -f apica-ascent/values-test.yaml
helm upgrade cnpg-test apica-ascent -n cnpg-test -f apica-ascent/values-test.yaml
```
