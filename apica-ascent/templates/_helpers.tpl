{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "logiq.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "logiq.fullname" -}}
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
{{- define "logiq.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "logiq.labels" -}}
helm.sh/chart: {{ include "logiq.chart" . }}
{{ include "logiq.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "logiq.selectorLabels" -}}
app.kubernetes.io/name: {{ include "logiq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "logiq.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "logiq.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}


{{/*
Generate a certificate pair shared with coffee/flash
*/}}
{{- define "logiq.gen-certs" -}}
{{- $ca := genCA "logiq-ca" 2555 -}}
{{- $cn := printf "%s.%s" .Release.Name .Release.Namespace -}}
{{- $cert := genSignedCert $cn nil nil 2555 $ca -}}
tls.crt: {{ $cert.Cert | b64enc }}
tls.key: {{ $cert.Key | b64enc }}
{{- end -}}

{{/*
Whether unauthenticated trace/RELP ingestion (14250/14268/20514) is exposed
through the Envoy Gateway. Normalizes .Values.envoyGateway.traceIngestion.enabled
(bool or string, unset defaults to false) to the literal string "true"/"false".
Single source of truth so envoy-gateway.yaml, envoy-httproute.yaml,
envoy-tcproute.yaml and envoy-httproutefilter.yaml can't drift from each other.
Usage: {{- if eq (include "logiq.traceIngestionEnabled" .) "true" }}
*/}}
{{- define "logiq.traceIngestionEnabled" -}}
{{- $trace := .Values.envoyGateway.traceIngestion | default dict -}}
{{- eq (lower (toString (default false $trace.enabled))) "true" -}}
{{- end -}}

{{/*
Whether Splunk S2S ingestion (9996 plain / 9997 TLS) is exposed through the Envoy
Gateway. Normalizes .Values.envoyGateway.s2sIngestion.enabled (bool or string) to
the literal string "true"/"false". Unlike traceIngestion, an unset value means
true: S2S is on by default and is turned off with enabled: false.
Usage: {{- if eq (include "logiq.s2sIngestionEnabled" .) "true" }}
*/}}
{{- define "logiq.s2sIngestionEnabled" -}}
{{- $s2s := .Values.envoyGateway.s2sIngestion | default dict -}}
{{- if hasKey $s2s "enabled" -}}
{{- eq (lower (toString $s2s.enabled)) "true" -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/*
The opt-in/opt-out TCP ingestion ports that get a Gateway listener and a TCPRoute
each: traceIngestion.ports when trace ingestion is enabled, then
s2sIngestion.ports when S2S ingestion is enabled. Returned as a YAML list so
envoy-gateway.yaml, envoy-tcproute.yaml and the listener check render from the
same list. Usage: {{- range (include "logiq.gatedTcpPorts" . | fromYamlArray) }}
*/}}
{{- define "logiq.gatedTcpPorts" -}}
{{- $ports := list -}}
{{- if eq (include "logiq.traceIngestionEnabled" .) "true" -}}
{{- $ports = concat $ports ((.Values.envoyGateway.traceIngestion | default dict).ports | default list) -}}
{{- end -}}
{{- if eq (include "logiq.s2sIngestionEnabled" .) "true" -}}
{{- $ports = concat $ports ((.Values.envoyGateway.s2sIngestion | default dict).ports | default list) -}}
{{- end -}}
{{- toYaml $ports -}}
{{- end -}}

{{/*
Fail the render when two Gateway listeners share a name or a port. Covers the
http/https listeners, envoyGateway.listeners.tcp and the gated ingestion ports.
A duplicate makes the Gateway invalid, which takes down every listener on it.
*/}}
{{- define "logiq.validateGatewayListeners" -}}
{{- $all := list (dict "name" "http" "port" (.Values.envoyGateway.listeners.http.port | default 80) "from" "listeners.http") -}}
{{- if .Values.gateway.tls.enabled -}}
{{- $all = append $all (dict "name" "https" "port" (.Values.envoyGateway.listeners.https.port | default 443) "from" "listeners.https") -}}
{{- end -}}
{{- range .Values.envoyGateway.listeners.tcp -}}
{{- $all = append $all (dict "name" .name "port" .port "from" "listeners.tcp") -}}
{{- end -}}
{{- $trace := .Values.envoyGateway.traceIngestion | default dict -}}
{{- $s2s := .Values.envoyGateway.s2sIngestion | default dict -}}
{{- if eq (include "logiq.traceIngestionEnabled" .) "true" -}}
{{- range $trace.ports -}}
{{- $all = append $all (dict "name" .name "port" .port "from" "traceIngestion.ports") -}}
{{- end -}}
{{- end -}}
{{- if eq (include "logiq.s2sIngestionEnabled" .) "true" -}}
{{- range $s2s.ports -}}
{{- $all = append $all (dict "name" .name "port" .port "from" "s2sIngestion.ports") -}}
{{- end -}}
{{- end -}}
{{- $names := dict -}}
{{- $ports := dict -}}
{{- range $all -}}
{{- $n := toString .name -}}
{{- $p := toString .port -}}
{{- if hasKey $names $n -}}
{{- fail (printf "envoyGateway: Gateway listener name %q is defined twice (in %s and %s). If it is an S2S port (tcp-9996/tcp-9997), remove it from envoyGateway.listeners.tcp: envoyGateway.s2sIngestion now adds it." $n (get $names $n) .from) -}}
{{- end -}}
{{- if hasKey $ports $p -}}
{{- fail (printf "envoyGateway: Gateway listener port %s is used twice (in %s and %s). If it is an S2S port (9996/9997), remove it from envoyGateway.listeners.tcp: envoyGateway.s2sIngestion now adds it." $p (get $ports $p) .from) -}}
{{- end -}}
{{- $_ := set $names $n .from -}}
{{- $_ := set $ports $p .from -}}
{{- end -}}
{{- end -}}
