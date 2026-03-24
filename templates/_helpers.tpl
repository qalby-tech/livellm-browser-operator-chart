{{/*
Chart name.
*/}}
{{- define "livellm-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fullname — used for resource names.
*/}}
{{- define "livellm-operator.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Namespace to deploy into.
*/}}
{{- define "livellm-operator.namespace" -}}
{{- .Values.namespace.name | default "livellm-system" }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "livellm-operator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- .Values.serviceAccount.name | default (include "livellm-operator.fullname" .) }}
{{- else }}
{{- .Values.serviceAccount.name | default "default" }}
{{- end }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "livellm-operator.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "livellm-operator.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "livellm-operator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "livellm-operator.name" . }}
{{- end }}

{{/*
Operator image tag — defaults to Chart.AppVersion.
*/}}
{{- define "livellm-operator.operatorTag" -}}
{{- .Values.operator.image.tag | default .Chart.AppVersion }}
{{- end }}

{{/*
Browser image — full <repo>:<tag> string.
Tag comes from Chart.AppVersion (e.g. "2.0.1" or "dev-2.0.1").
*/}}
{{- define "livellm-operator.browserImage" -}}
{{ .Values.browser.image.repository }}:{{ .Chart.AppVersion }}
{{- end }}

{{/*
Controller image tag.
Uses Chart.Annotations.controllerVersion if set.
Otherwise derives from Chart.AppVersion:
  "dev-X.Y.Z" → "dev-controller-X.Y.Z"
  "X.Y.Z"     → "controller-X.Y.Z"
*/}}
{{- define "livellm-operator.controllerTag" -}}
{{- $anno := index .Chart.Annotations "controllerVersion" -}}
{{- if $anno -}}
{{ $anno }}
{{- else if hasPrefix "dev-" .Chart.AppVersion -}}
dev-controller-{{ trimPrefix "dev-" .Chart.AppVersion }}
{{- else -}}
controller-{{ .Chart.AppVersion }}
{{- end -}}
{{- end }}

{{/*
Controller image — full <repo>:<tag> string.
*/}}
{{- define "livellm-operator.controllerImage" -}}
{{ .Values.controller.image.repository }}:{{ include "livellm-operator.controllerTag" . }}
{{- end }}
