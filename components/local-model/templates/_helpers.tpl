{{/* Name of the hardware profile: model name plus the profile (gpu or cpu). */}}
{{- define "local-model.hardwareProfileName" -}}
{{ .Values.global.localModel.name }}-{{ gt (int .Values.global.localModel.gpu) 0 | ternary "gpu" "cpu" }}
{{- end }}

{{/*
GPU scheduling, used by the InferenceService and by the hardware profile. Both labels are generic:
the GPU operator sets nvidia.com/gpu.present on every NVIDIA node, whatever the GPU model.
*/}}
{{- define "local-model.gpuNodeSelector" -}}
nvidia.com/gpu.present: "true"
{{- end }}

{{/* GPU nodes carry this taint (roles/gpu_node_prep in the ansible repo). */}}
{{- define "local-model.gpuTolerations" -}}
- key: nvidia.com/gpu
  operator: Exists
  effect: NoSchedule
{{- end }}
