{{- define "network-automation.labels" -}}
app.kubernetes.io/name: network-automation
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "network-automation.selectorLabels" -}}
app.kubernetes.io/name: network-automation
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
