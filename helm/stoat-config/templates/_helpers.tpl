{{/*
Generate a deterministic secret from seed and ID.
Usage: {{ include "deriveSecret" (dict "seed" .Values.secretSeed "clientId" "mongo-root") }}
Optional: {{ include "deriveSecret" (dict "seed" .Values.secretSeed "clientId" "key" "length" 12) }}
*/}}
{{- define "deriveSecret" -}}
{{- $input := printf "%s:%s" .seed .clientId -}}
{{- $length := .length | default 50 -}}
{{- $input | sha256sum | trunc (int $length) -}}
{{- end -}}

{{/*
Override-aware secret: uses secretOverrides value if present, otherwise derives.
Usage: {{ include "getSecret" (dict "seed" .Values.secretSeed "clientId" "mongo-user" "overrides" .Values.secretOverrides) }}
Optional suffix (only appended to derived secrets, not overrides):
  {{ include "getSecret" (dict "seed" .Values.secretSeed "clientId" "example" "overrides" .Values.secretOverrides "suffix" "!Ab1") }}
*/}}
{{- define "getSecret" -}}
{{- $overrides := .overrides | default dict -}}
{{- if hasKey $overrides .clientId -}}
{{- index $overrides .clientId -}}
{{- else -}}
{{- include "deriveSecret" . -}}{{ .suffix | default "" }}
{{- end -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "stoat-config.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: stoat
{{- end -}}

{{/*
Reflector annotations for cross-namespace secret replication.
Usage: {{ include "reflector.annotations" "stoat" }}
*/}}
{{- define "reflector.annotations" -}}
reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: {{ . | quote }}
reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: {{ . | quote }}
{{- end -}}
