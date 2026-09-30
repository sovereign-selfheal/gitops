{{/* Name of the hardware profile: model name plus the profile. */}}
{{- define "decision-model.hardwareProfileName" -}}
{{ .Values.global.decisionModel.name }}-gpu
{{- end }}

{{/* GPU nodes carry this taint (roles/gpu_node_prep in the ansible repo). */}}
{{- define "decision-model.gpuTolerations" -}}
- key: nvidia.com/gpu
  operator: Exists
  effect: NoSchedule
{{- end }}
