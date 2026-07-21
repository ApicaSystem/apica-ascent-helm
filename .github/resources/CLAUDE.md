# apica-ascent-helm — PR Review Context

Context for the automated Claude PR review. State only what the diff shows; when unsure, stay silent.

## What this is
Umbrella Helm 3 chart (`apica-ascent`, Chart apiVersion v2, chart 3.1.5, appVersion v2.16.6, kubeVersion >=1.24.0) that deploys the Apica Ascent observability platform (logging, metrics, tracing) onto Kubernetes. Ingress is Gateway API via **Envoy Gateway v1.6.0**. First-party subcharts: `logiq-flash` (ingest), `flash-coffee` (UI/worker), `flash-discovery`, `logiqctl`. Vendored deps: `cluster` (cnpg/CloudNativePG), plus Bitnami `postgresql`, `redis`, `grafana`, `kube-prometheus`, `thanos`, `common`.

## Layout
- `apica-ascent/` — the chart; everything below is relative to it.
- `Chart.yaml` — deps + condition flags; `values.yaml` — default values (source of truth).
- `values.{single,small,medium,large}.yaml` — t-shirt sizing presets, selected with `-f`; identical structure, differ only in `replicaCount`/`resources`.
- `templates/` — mostly Envoy Gateway / Gateway API objects, `perfectscale-*` autoscaling automation, Secret templates (`shared-secret`, `vault-secrets`, `thanos-secret`, `cnpg-secrets`), thanos-ruler configmap, storageclass, metrics-server.
- `charts/logiq-flash|flash-coffee|flash-discovery|logiqctl/` — first-party subcharts (full templates, legacy `logiq.*` helpers, `logiqai/*` images).
- `charts/cluster|postgresql|redis|grafana|kube-prometheus|thanos|common/` — vendored upstream subcharts.
- `update-onprem-values.pl` — values-manipulation helper.

## Build / conventions
- `global.*` carries cross-cutting config: `imageRegistry` (override for air-gapped, default `docker.io`), `nodeSelectors`/`taints` (`apica-node-pool` pool labels), `environment.*` (app config incl. DB/S3/admin settings), `persistence.storageClass`.
- Subcharts are gated by conditions: `global.chart.<name>` (e.g. `global.chart.prometheus`, `global.chart.redis`) and `cnpg.enabled`. Adding a subchart means wiring both `Chart.yaml` dependency + condition + a `global.chart` toggle.
- Images are pinned to explicit tags in values (e.g. `logiqai/flash:v3.21.4`, `envoyproxy/gateway:v1.6.0`, cnpg `postgresql:18`); no `:latest`.
- TLS Secrets self-generate via `logiq.gen-certs` when cert values are empty; secret data is `b64enc`-ed from values.
- No `helm lint`/kubeconform in-repo; `deploy-test.yaml` fires an external Jenkins deploy test. Mentally render templates for correctness — CI won't catch a broken template here.

## Review focus (priority order)
1. Template rendering: unquoted values, bad indent/`nindent`, missing `if`/`with` guards, refs to values that don't exist, broken helper includes — these ship untested.
2. Condition/dependency drift: a new subchart or value added without its `global.chart` toggle or `Chart.yaml` condition; a value referenced in a subchart but absent from `values.yaml`.
3. Insecure changes to first-party templates: new `privileged: true`, `hostPath`/`hostNetwork`, `allowPrivilegeEscalation: true`, dropped/loosened `securityContext`, removed resource limits.
4. Secrets: real credentials or keys committed into `values*.yaml` or templates (defaults there are placeholders — see below).
5. Image tag pinning: any tag changed to `latest` or floating; registry hardcoded instead of honoring `global.imageRegistry`.
6. RBAC scope: new/widened cluster-scoped roles or bindings (existing cluster roles: envoy-gateway controller, `logiq-flash` PV/storageclass read, vault, metrics-server).

## Do NOT flag (known-intentional)
- Vendored subcharts under `charts/` (`cluster`, `postgresql`, `redis`, `grafana`, `kube-prometheus`, `thanos`, `common`) — upstream code, not maintained here; skip their internals.
- Repo-root `apica-ascent-*.tgz`, `index.yaml`, `index.html`, `github-markdown.css` — generated Helm chart-repository artifacts.
- Placeholder creds in `values*.yaml` (`postgres/postgres`, `admin_password: password`, `s3_access`/`s3_secret`, example S3 URLs) — defaults meant to be overridden at install; not leaked secrets.
- The four `values.*` sizing files being near-identical — deliberate; they diverge only in replicas/resources.
- `redis.usePassword: false`, `cluster ... enableSuperuserAccess: true`, disabled subchart exporters/kube* scrapers — intentional in-cluster defaults.
- Legacy `logiq*`/`logiqai/*` naming — historical brand, not a bug.
