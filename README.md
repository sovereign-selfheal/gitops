# gitops: workloads of the demo

Argo CD reconciles this repository. It contains every workload of the demo *The Sovereign, Self-Healing
Platform*. The cluster preparation and the root Application are in the `ansible` repo. Read
[`AGENTS.md`](AGENTS.md) before changing anything.

## Request flow

```
client ──> Route maas-router (ansible) ──> Gateway openshift-ai-inference (ansible)
           │  AuthPolicy: API key per tier, sets x-team      ┐ component frontdoor
           │  TokenRateLimitPolicy: token budget per tier     ┘
           └──> LiteLLM (component litellm-router): efficiency gate, then privacy gate
                  ├── Presidio analyzer (component presidio): PII detection, EN + IT
                  ├── local model (component local-model): Granite 3.3 8B on GPU, or Qwen2.5 0.5B on CPU
                  └── external SOTA model (OpenAI compatible), fallback to the local model
```

## Components

| Component | Namespace | Sync wave | Objects |
|---|---|---|---|
| `observability` | `observability` | 0 | `TempoMonolithic` `tempo` (traces on a 10Gi volume, 72h, multi-tenancy `openshift`, tenant `router`), `OpenTelemetryCollector` `otel` (OTLP in, Tempo gateway out). Only with `observability.enabled` |
| `secrets` | `maas-routing` | 0 | ESO `Password` generator, ExternalSecrets for the API keys, SOTA key, classifier |
| `local-model` | `local-models` | 1 | ServingRuntime (copy of the RHOAI template), InferenceService, NetworkPolicies |
| `presidio` | `maas-routing` | 1 | Deployment (2 replicas), PodDisruptionBudget, Service, NetworkPolicy (no egress) |
| `litellm-router` | `maas-routing` | 2 | ConfigMap (config + hook code + policies), Deployment (2 replicas), PodDisruptionBudget, Service, NetworkPolicy |
| `frontdoor` | `maas-routing` | 3 | HTTPRoute, AuthPolicy, TokenRateLimitPolicy |

Presidio and LiteLLM run 2 replicas each (value `replicas` of the component), so one pod or node can
fail without stopping the router. A preferred pod anti-affinity puts the replicas on different nodes
when it can; it never blocks scheduling. The SOTA token cap of the router (`sota_token_budget` in
`components/litellm-router/files/chain.yaml`) is counted in memory per pod, so with 2 replicas the real
cap is up to twice the value. The token budgets per tier (TokenRateLimitPolicy) are shared and are the
real limit.

## Values

The seed in the `ansible` repo sets these values on the root Application. All the defaults are in
[`bootstrap/values.yaml`](bootstrap/values.yaml).

| Value | Example | Meaning |
|---|---|---|
| `appsDomain` | `apps.cluster.example.com` | Apps domain; the router answers on `router.<appsDomain>` |
| `modelProfile` | `gpu` | `gpu`: Granite 3.3 8B Instruct on a GPU node; `cpu`: Qwen2.5 0.5B on CPU |
| `sota.enabled` | `true` | `false` = local-only mode (see below) |
| `sota.apiBase` | `https://provider.example.com/v1` | External OpenAI-compatible endpoint |
| `sota.model` | `openai/<model-id>` | LiteLLM model string of the external model |
| `sota.servedMatch` | `<model-id>` | Part of the served model id, used by the cost gate |
| `sota.reasoning` | `false` | `false`: the SOTA model answers without reasoning (see "Long answers and streaming"); `true`: the model decides |
| `secretStore.enabled` | `false` | `true` when the ClusterSecretStore exists (see below) |
| `classifier.mode` | `local` | C2 classifier of the privacy gate: `local` (the local model), `external`, `off` (see below) |
| `observability.enabled` | `true` | `false`: no Tempo, no collector, no traces (see "Observability") |

## Observability

The routing decisions are visible as traces in the console (*Observe → Traces*) and as metrics
(*Observe → Metrics*). Everything stays in the cluster.

- **Traces**: component `observability`. The OpenTelemetry collector `otel` receives OTLP on
  `otel-collector.observability.svc:4318` (http) and `:4317` (grpc) and writes to the Tempo instance
  `tempo`. Tempo runs with multi-tenancy in `openshift` mode, the supported setup on OpenShift: the
  collector writes the tenant `router` with its service account token. The ansible repo installs the
  operators, grants that write permission and adds the console plugin. Reading the traces needs the
  read permission on the tenant (cluster-admin has it).
- **Metrics**: user workload monitoring is turned on by the ansible repo. RHOAI creates the
  ServiceMonitor of the local model (`<model>-metrics`, vLLM metrics on port 8080) by itself.
- `observability.enabled: false` (seed value, from `observability_enabled` in the ansible repo)
  removes the component. The rest of the platform works as before.

> **Support status:** the collector and Tempo come from the Red Hat build of OpenTelemetry and the
> Tempo Operator. LiteLLM, which produces the router traces, is community software, not supported by
> Red Hat.

## Long answers and streaming

- A SOTA model with reasoning and a large token budget can take a few minutes. LiteLLM waits
  `sota.timeout` seconds (default 300) for one SOTA call; the other models keep 120 s.
- Without streaming, no byte flows until the answer is complete, so every hop needs a long idle timeout.
  The `ansible` repo sets 10 minutes on the Route and on the AWS load balancer of the ingress (the AWS
  default is 60 s).
- **Reasoning is off by default** (`sota.reasoning: false`). With reasoning on, the tested SOTA model often
  spent the whole token budget on hidden reasoning and returned an empty answer, and its provider sends
  nothing while the model reasons, even with streaming. Set `sota.reasoning: true` (Ansible:
  `sota_reasoning: true`) to show a reasoning model; then give the calls a large token budget.
- **Clients should use streaming** (`"stream": true`): the text arrives while it is generated, and no
  idle timeout applies. LiteLLM adds the token usage at the end of every stream
  (`always_include_stream_usage`), so the token limits count streaming calls too.

## Privacy classifier (C2)

The privacy gate scores each prompt with rules (regex, lexicons, Presidio NER). When the score is in the
gray zone and the efficiency gate wants to send the prompt to the SOTA model, an LLM classifier gives an
extra opinion. `classifier.mode` selects that LLM:

| Mode | Classifier | Notes |
|---|---|---|
| `local` (default) | The local model (Granite on GPU) | The prompt never leaves the cluster, also while it is classified. No secret needed |
| `external` | An external model | Settings from the secret store (`classifier-provider-secret`) |
| `off` | None | The rules alone decide |

The classifier can only make a prompt more sensitive, never less. On an error or a timeout (8 s), the
prompt is treated as sensitive and stays on the local model.

## Local-only mode

The external SOTA model is optional. Its settings and key come from the ansible-vault of the `ansible`
repo. Without them the seed sets `sota.enabled: false`, and the router runs in **local-only mode**:
the alias `sota-smart` points to the local model, so the gates and policies work as usual, but every
request is served by the local model. The router logs still show `routed_to: sota-smart` when a gate
chooses "SOTA".

## Router code and images

Two custom images and the router code come from other repos of the project:

| Item | Source | Pinned in |
|---|---|---|
| Hook code `components/litellm-router/files/*.py` | [`router`](https://github.com/sovereign-selfheal/router), at the tag `routerVersion` | `components/litellm-router/values.yaml` (`routerVersion`) |
| LiteLLM image (LiteLLM + fastText) | `quay.io/sovereign-selfheal/router`, same tag | `components/litellm-router/values.yaml` (`image`, by digest) |
| Presidio image (English and Italian NER) | [`presidio`](https://github.com/sovereign-selfheal/presidio), `quay.io/sovereign-selfheal/presidio` | `components/presidio/values.yaml` (`image`, by digest) |

Never edit the `*.py` files here. To move to a new router release:

```bash
scripts/sync-router-code.sh sync vX.Y.Z   # copies the hook code at the tag, sets routerVersion
# then pin the digest of quay.io/sovereign-selfheal/router:vX.Y.Z in components/litellm-router/values.yaml
scripts/sync-router-code.sh check         # also run by CI
```

The policies (`chain.yaml`, `privacy-plus.yaml`) stay in this repo.

## Secrets

No Secret is stored in git. The External Secrets Operator creates them:

| Secret (namespace `maas-routing`) | Keys | Source |
|---|---|---|
| `apikey-<tier>-1` | `api_key` (`sk-` + 40 random characters) | ESO `Password` generator, in the cluster, generated once |
| `sota-provider-secret` | `COMPANY_API_KEY` | Store: key `sota`, property `api_key` |
| `classifier-provider-secret` (only `classifier.mode: external`) | `CLASSIFIER_BASE_URL`, `CLASSIFIER_MODEL`, `CLASSIFIER_API_KEY`, `CLASSIFIER_ENABLED`, `CLASSIFIER_GRAY_LOW` | Store: key `classifier`, properties `base_url`, `model`, `api_key` |

The store is the `ClusterSecretStore` `sovereign-selfheal`, created by Ansible (`roles/secrets_bootstrap`).
Today it uses the ESO provider `kubernetes`: Ansible takes the values from ansible-vault (or from
AgnosticV) and writes them into Secrets of the namespace `sovereign-selfheal-secrets`; ESO copies them
here. Another backend (for example HashiCorp Vault) needs only a different store, not changes in this repo.

Without a SOTA key the store does not exist and `secretStore.enabled` is `false`: the API keys still work,
and LiteLLM starts without the SOTA key (the Secret reference is optional). The expected result is that
SOTA calls fail and LiteLLM falls back to the local model.

To read an API key:

```bash
oc get secret apikey-research-1 -n maas-routing -o jsonpath='{.data.api_key}' | base64 -d
```

## Check your changes

```bash
uvx yamllint .
for chart in bootstrap components/*/; do helm lint "$chart"; done
for p in gpu cpu; do uv run --no-project --with pyyaml scripts/render.sh "$p" "rendered/$p"; done
kubeconform -summary -ignore-missing-schemas rendered/gpu/*.yaml
```

The Python tools (yamllint, and PyYAML for `scripts/render.sh`) run with [uv](https://docs.astral.sh/uv/),
never pip; the CI pins their versions.

`scripts/render.sh` renders the charts the way Argo CD does, then checks that no component renders a
Namespace or a Secret, or uses a namespace outside the contract. Use Helm 3 (`HELM=/path/to/helm3`):
Argo CD uses Helm 3 too.

## License

Apache License 2.0, see [LICENSE](LICENSE).
