{{/* LiteLLM config: only the model endpoints are values, the rest is the old config-chain.yaml. */}}
{{- define "litellm-router.config" -}}
{{- $local := .Values.global.localModel.name -}}
{{- $base := printf "http://%s-predictor.%s.svc.cluster.local/v1" $local .Values.global.namespaces.models -}}
model_list:
  # LOCAL tier: self-hosted vLLM (component local-model).
  - model_name: local-fast
    litellm_params:
      model: openai/{{ $local }}
      api_base: {{ $base }}
      api_key: "in-cluster-no-auth"
  {{- if .Values.global.sota.enabled }}
  # SOTA tier: external OpenAI-compatible provider.
  - model_name: sota-smart
    litellm_params:
      model: {{ required "global.sota.model is required" .Values.global.sota.model | quote }}
      api_base: {{ required "global.sota.apiBase is required" .Values.global.sota.apiBase | quote }}
      api_key: os.environ/COMPANY_API_KEY
      timeout: {{ .Values.global.sota.timeout | default 300 }}
  {{- else }}
  # Local-only mode (no SOTA configured): the policies still route to sota-smart,
  # but it is the local model.
  - model_name: sota-smart
    litellm_params:
      model: openai/{{ $local }}
      api_base: {{ $base }}
      api_key: "in-cluster-no-auth"
  {{- end }}
  # The model clients call; the policy hook picks the real target.
  - model_name: auto
    litellm_params:
      model: openai/{{ $local }}
      api_base: {{ $base }}
      api_key: "in-cluster-no-auth"

litellm_settings:
  callbacks: ["policy_hook_chain.proxy_handler_instance"]
  drop_params: true
  num_retries: 2
  request_timeout: 120

router_settings:
  fallbacks: [{"sota-smart": ["local-fast"]}]

general_settings:
  # Streaming answers end with the token usage, even if the client does not ask for it:
  # the TokenRateLimitPolicy counts tokens from that usage.
  always_include_stream_usage: true
{{- end }}
