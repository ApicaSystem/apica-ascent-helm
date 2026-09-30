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
Compute the -workers count as 150 × CPU request in whole CPUs.
CPU request may be expressed as milliCPUs (e.g. "1250m") or whole CPUs (e.g. "2").
Integer division is intentional, as fractional CPUs round down.
*/}}
{{- define "logiq-flash.flashWorkers" -}}
{{- $cpuStr := .Values.resources.ingest.requests.cpu | toString -}}
{{- $perCPU := .Values.flash.workersPerCPU | int64 -}}
{{- if hasSuffix "m" $cpuStr -}}
{{- mul $perCPU (div (trimSuffix "m" $cpuStr | int64) 1000) -}}
{{- else -}}
{{- mul $perCPU ($cpuStr | int64) -}}
{{- end -}}
{{- end -}}

{{- define "logiq-flash.confighash" -}}
{{- $pghash := printf "postgresql://%s:%s@%s:%s/%s" .Values.global.environment.postgres_user .Values.global.environment.postgres_password .Values.global.environment.postgres_host .Values.global.environment.postgres_port .Values.global.environment.postgres_db -}}
{{- $redishash := printf "redis://%s:%s" .Values.global.environment.redis_host .Values.global.environment.redis_port -}}
{{- printf "%s-%s" $pghash $redishash | sha256sum -}}
{{- end -}}
