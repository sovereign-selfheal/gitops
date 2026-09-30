{{/* Name of the hardware profile: model name plus the profile (gpu or cpu). */}}
{{- define "local-model.hardwareProfileName" -}}
{{ .Values.global.localModel.name }}-{{ gt (int .Values.global.localModel.gpu) 0 | ternary "gpu" "cpu" }}
{{- end }}

{{/*
GPU scheduling, used by the InferenceService and by the hardware profile. Default: the generic
label nvidia.com/gpu.present, set by the GPU operator on every NVIDIA node. With the decision model
the seed adds the node label of the Qwen pool (localModel.profiles.gpu.nodeSelector).
*/}}
{{- define "local-model.gpuNodeSelector" -}}
{{- toYaml (.Values.global.localModel.nodeSelector | default (dict "nvidia.com/gpu.present" "true")) }}
{{- end }}

{{/* GPU nodes carry this taint (roles/gpu_node_prep in the ansible repo). */}}
{{- define "local-model.gpuTolerations" -}}
- key: nvidia.com/gpu
  operator: Exists
  effect: NoSchedule
{{- end }}
