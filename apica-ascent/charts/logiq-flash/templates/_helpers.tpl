{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "logiq-flash.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "logiq-flash.fullname" -}}
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
{{- define "logiq-flash.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Compute the -workers count as workersPerCPU × CPU request in whole CPUs.
CPU request may be expressed as milliCPUs (e.g. "1250m") or whole CPUs (e.g. "2").
Integer division is intentional, as fractional CPUs round down.
The result has a floor of 150: a CPU request below one whole CPU would otherwise
render -workers 0, and Flash then rejects every S2S connection.
*/}}
{{- define "logiq-flash.flashWorkers" -}}
{{- $cpuStr := .Values.resources.ingest.requests.cpu | toString -}}
{{- $perCPU := .Values.flash.workersPerCPU | int64 -}}
{{- $workers := 0 -}}
{{- if hasSuffix "m" $cpuStr -}}
{{- $workers = mul $perCPU (div (trimSuffix "m" $cpuStr | int64) 1000) -}}
{{- else -}}
{{- $workers = mul $perCPU ($cpuStr | int64) -}}
{{- end -}}
{{- max $workers 150 -}}
{{- end -}}

{{/*
Ingest pod terminationGracePeriodSeconds. preStop runs inside the grace period,
so it must be shorter; the remainder is Flash's SIGTERM drain window.
*/}}
{{- define "logiq-flash.flashTerminationGracePeriod" -}}
{{- $grace := .Values.flash.terminationGracePeriodSeconds | int64 -}}
{{- $preStop := .Values.flash.preStopSleepSeconds | int64 -}}
{{- if le $grace $preStop -}}
{{- fail (printf "logiq-flash: flash.terminationGracePeriodSeconds (%d) must be longer than flash.preStopSleepSeconds (%d)" $grace $preStop) -}}
{{- end -}}
{{- $grace -}}
{{- end -}}

{{- define "logiq-flash.confighash" -}}
{{- $pghash := printf "postgresql://%s:%s@%s:%s/%s" .Values.global.environment.postgres_user .Values.global.environment.postgres_password .Values.global.environment.postgres_host .Values.global.environment.postgres_port .Values.global.environment.postgres_db -}}
{{- $redishash := printf "redis://%s:%s" .Values.global.environment.redis_host .Values.global.environment.redis_port -}}
{{- printf "%s-%s" $pghash $redishash | sha256sum -}}
{{- end -}}

{{/*
Convert a Prometheus duration ("30s", "2m", "1m30s", "500ms") to milliseconds.
Fails the render on anything that is not a valid duration.
*/}}
{{- define "logiq-flash.durationMs" -}}
{{- $d := toString . -}}
{{- if not (regexMatch "^([0-9]+(ms|s|m|h|d|w|y))+$" $d) -}}
{{- fail (printf "logiq-flash: %q is not a valid Prometheus duration (examples: 30s, 2m, 1m30s)" $d) -}}
{{- end -}}
{{- $units := dict "ms" 1 "s" 1000 "m" 60000 "h" 3600000 "d" 86400000 "w" 604800000 "y" 31536000000 -}}
{{- $total := 0 -}}
{{- range regexFindAll "[0-9]+(ms|s|m|h|d|w|y)" $d -1 -}}
{{- $n := regexFind "^[0-9]+" . -}}
{{- $total = add $total (mul ($n | int64) (get $units (trimPrefix $n .))) -}}
{{- end -}}
{{- $total -}}
{{- end -}}

{{/*
Settings shared by every endpoint of the flash, flash-ml and flash-sync ServiceMonitors:
interval, scrapeTimeout, relabelings and metricRelabelings from metrics.serviceMonitor.
Render with: {{- include "logiq-flash.serviceMonitorEndpointSettings" . | nindent 4 }}
*/}}
{{- define "logiq-flash.serviceMonitorEndpointSettings" -}}
{{- $sm := .Values.metrics.serviceMonitor -}}
{{- $interval := $sm.interval | default "2m" -}}
{{- $intervalMs := include "logiq-flash.durationMs" $interval | int64 -}}
interval: {{ $interval }}
{{- with $sm.scrapeTimeout }}
{{- if gt (include "logiq-flash.durationMs" . | int64) $intervalMs }}
{{- fail (printf "logiq-flash: metrics.serviceMonitor.scrapeTimeout (%s) must not be longer than metrics.serviceMonitor.interval (%s)" . $interval) }}
{{- end }}
scrapeTimeout: {{ . }}
{{- end }}
{{- with $sm.relabelings }}
relabelings:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- with $sm.metricRelabelings }}
metricRelabelings:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Extra metadata labels for the ServiceMonitors: metrics.serviceMonitor.selector (existing)
plus metrics.serviceMonitor.labels (labels wins on a duplicate key). Render with:
{{- with (include "logiq-flash.serviceMonitorLabels" . | trim) }}
{{- . | nindent 4 }}
{{- end }}
*/}}
{{- define "logiq-flash.serviceMonitorLabels" -}}
{{- $l := merge (dict) (.Values.metrics.serviceMonitor.labels | default dict) (.Values.metrics.serviceMonitor.selector | default dict) -}}
{{- range $key := keys $l | sortAlpha }}
{{ $key }}: {{ get $l $key | quote }}
{{- end }}
{{- end -}}
