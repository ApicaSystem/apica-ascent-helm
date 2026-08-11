{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "flash-coffee.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "flash-coffee.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "flash-coffee.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Shared pod-scheduling block for coffee/coffee_worker/ssr_report_gen StatefulSets:
topologySpreadConstraints, affinity, tolerations, securityContext.
Call with (dict "root" $ "app" "<pod app label>" "values" .Values.<workload>).
*/}}
{{- define "flash-coffee.podScheduling" -}}
{{- $root := .root -}}
{{- $app := .app -}}
{{- $values := .values -}}
# Soft spread across nodes and zones — ScheduleAnyway never blocks scheduling.
{{- if $values.topologySpreadConstraints.enabled }}
topologySpreadConstraints:
  - maxSkew: {{ $values.topologySpreadConstraints.maxSkew }}
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: {{ $values.topologySpreadConstraints.whenUnsatisfiable }}
    labelSelector:
      matchLabels:
        app: {{ $app }}
  - maxSkew: {{ $values.topologySpreadConstraints.maxSkew }}
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: {{ $values.topologySpreadConstraints.whenUnsatisfiable }}
    labelSelector:
      matchLabels:
        app: {{ $app }}
{{- end }}

{{- if or $root.Values.global.nodeSelectors.enabled $values.podAntiAffinity.enabled }}
{{- if or $root.Values.global.nodeSelectors.enabled $values.podAntiAffinity.enabled }}
affinity:
  {{- if $root.Values.global.nodeSelectors.enabled }}
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: {{ $root.Values.global.nodeSelectors.label }}
              operator: In
              values:
                - {{ $root.Values.global.nodeSelectors.other }}
  {{- end }}
  {{- if $values.podAntiAffinity.enabled }}
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: {{ $values.podAntiAffinity.weight }}
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app: {{ $app }}
  {{- end }}
{{- end }}
  {{- if $root.Values.global.nodeSelectors.enabled }}
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: {{ $root.Values.global.nodeSelectors.label }}
              operator: In
              values:
                - {{ $root.Values.global.nodeSelectors.other }}
  {{- end }}
  # Preferred anti-affinity: adds scheduling pressure without ever blocking.
  {{- if $values.podAntiAffinity.enabled }}
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: {{ $values.podAntiAffinity.weight }}
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app: {{ $app }}
  {{- end }}
{{- end }}

{{- if $root.Values.global.taints.enabled }}
tolerations:
  - key: dedicated
    operator: Equal
    value: {{ $root.Values.global.taints.other }}
    effect: NoSchedule
{{- end }}

securityContext:
  fsGroup: 1000
  runAsUser: 1000
  runAsGroup: 1000
{{- end -}}

{{- define "flash-coffee.confighash" -}}
{{- $pghash := printf "postgresql://%s:%s@%s:%s/%s" .Values.global.environment.postgres_user .Values.global.environment.postgres_password .Values.global.environment.postgres_host .Values.global.environment.postgres_port .Values.global.environment.postgres_coffee_db -}}
{{- $redishash := printf "redis://%s:%s" .Values.global.environment.redis_host .Values.global.environment.redis_port -}}
{{- printf "%s-%s" $pghash $redishash | sha256sum -}}
{{- end -}}
