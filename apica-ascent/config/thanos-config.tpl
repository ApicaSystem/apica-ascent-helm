type: s3
{{ if .Values.global.environment.metrics_s3_prefix }}
prefix: logiq-instastore-metrics
{{ end }}
config: 
  {{ if .Values.global.environment.AWS_ACCESS_KEY_ID }}
  access_key: {{ if .Values.global.environment.AWS_ACCESS_KEY_ID }}{{ .Values.global.environment.AWS_ACCESS_KEY_ID }}{{ end }}
  secret_key: {{ if .Values.global.environment.AWS_SECRET_ACCESS_KEY }}{{ .Values.global.environment.AWS_SECRET_ACCESS_KEY }}{{ end }}
  {{ else }}
  access_key: {{ if .Values.global.environment.s3_access }}{{ .Values.global.environment.s3_access }} {{ end }}
  secret_key: {{ if .Values.global.environment.s3_secret }}{{ .Values.global.environment.s3_secret }} {{ end }}
  {{ end }}
  bucket: {{ if .Values.global.environment.s3_bucket }}{{ .Values.global.environment.s3_bucket }} {{ end }}
{{ if .Values.global.chart.s3gateway }}
  endpoint: {{ if .Values.global.environment.s3_url }}{{ .Values.global.environment.s3_url | replace "http://" "" }} {{ end }}
  insecure: true
{{ else if eq .Values.global.cloudProvider "aws" }}
  endpoint: {{ required "AWS S3 Endpoint" .Values.global.environment.awsServiceEndpoint | replace "http://" "" | replace "https://" "" }}
{{ end }}
  region: {{ if .Values.global.environment.s3_region }}{{ .Values.global.environment.s3_region }} {{ end }}
