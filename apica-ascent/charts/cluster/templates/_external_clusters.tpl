{{/*
Builds the externalClusters list items only. Renders empty when the selected
mode/method needs no external cluster - notably recovery.method=backup, which
restores from an in-cluster CNPG Backup object.
*/}}
{{- define "cluster.externalClustersItems" -}}
{{- if eq .Values.mode "recovery" }}
  {{- if eq .Values.recovery.method "pg_basebackup" }}
  - name: pgBaseBackupSource
     {{- include "cluster.externalSourceCluster" .Values.recovery.pgBaseBackup.source | nindent 4 }}
  {{- else if eq .Values.recovery.method "import" }}
  - name: importSource
     {{- include "cluster.externalSourceCluster" .Values.recovery.import.source | nindent 4 }}
  {{- else if eq .Values.recovery.method "object_store" }}
  - name: objectStoreRecoveryCluster
    barmanObjectStore:
      serverName: {{ .Values.recovery.clusterName }}
      {{- $d := dict "chartFullname" (include "cluster.fullname" .) "scope" .Values.recovery "secretPrefix" "recovery" -}}
      {{- include "cluster.barmanObjectStoreConfig" $d | nindent 4 }}
  {{- end }}
{{- else if eq .Values.mode "replica" }}
  - name: originCluster
  {{- if not (empty .Values.replica.origin.objectStore.provider) }}
    barmanObjectStore:
      serverName: {{ .Values.replica.origin.objectStore.clusterName }}
      {{- $d := dict "chartFullname" (include "cluster.fullname" .) "scope" .Values.replica.origin.objectStore "secretPrefix" "origin" -}}
      {{- include "cluster.barmanObjectStoreConfig" $d | nindent 4 -}}
  {{- end }}
  {{- if not (empty .Values.replica.origin.pg_basebackup.host) }}
    {{- include "cluster.externalSourceCluster" .Values.replica.origin.pg_basebackup | nindent 4 }}
  {{- end }}
{{- else if ne .Values.mode "standalone" }}
  {{ fail "Invalid cluster mode!" }}
{{- end }}
{{- end }}

{{/*
Emits the externalClusters key ONLY when the list above is non-empty. Emitting
a bare "externalClusters:" yields null, which the CNPG CRD rejects with
"spec.externalClusters in body must be of type array: null".
*/}}
{{- define "cluster.externalClusters" -}}
{{- $items := include "cluster.externalClustersItems" . -}}
{{- if trim $items }}
externalClusters:
{{ trimSuffix "\n" $items }}
{{- end }}
{{ end }}
