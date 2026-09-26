{{/*
Values passed to every component as `global`. Components never read the
bootstrap values directly: this is the only interface between them.
*/}}
{{- define "bootstrap.global" -}}
{{- $profile := required "modelProfile must be gpu or cpu" (index .Values.localModel.profiles .Values.modelProfile) -}}
appsDomain: {{ required "appsDomain is required (set by the seed)" .Values.appsDomain | quote }}
modelProfile: {{ .Values.modelProfile | quote }}
namespaces:
  {{- toYaml .Values.namespaces | nindent 2 }}
sota:
  {{- toYaml .Values.sota | nindent 2 }}
secretStore:
  {{- toYaml .Values.secretStore | nindent 2 }}
classifier:
  {{- toYaml .Values.classifier | nindent 2 }}
observability:
  {{- toYaml .Values.observability | nindent 2 }}
tiers:
  {{- toYaml .Values.tiers | nindent 2 }}
localModel:
  {{- toYaml $profile | nindent 2 }}
{{- end }}
