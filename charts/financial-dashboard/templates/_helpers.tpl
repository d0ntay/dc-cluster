{{- define "financial-dashboard.labels" -}}
app.kubernetes.io/name: financial-dashboard
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "financial-dashboard.selectorLabels" -}}
app.kubernetes.io/name: financial-dashboard
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
