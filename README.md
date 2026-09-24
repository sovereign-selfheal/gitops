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
| `secrets` | `maas-routing` | 0 | ESO `Password` generator, ExternalSecrets for the API keys, SOTA key, classifier |
| `local-model` | `local-models` | 1 | ServingRuntime (copy of the RHOAI template), InferenceService, NetworkPolicies |
| `presidio` | `maas-routing` | 1 | Deployment, Service, NetworkPolicy (no egress) |
| `litellm-router` | `maas-routing` | 2 | ConfigMap (config + hook code + policies), Deployment, Service, NetworkPolicy |
| `frontdoor` | `maas-routing` | 3 | HTTPRoute, AuthPolicy, TokenRateLimitPolicy |

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
| `secretStore.enabled` | `false` | `true` when the ClusterSecretStore exists (see below) |
| `classifier.mode` | `local` | C2 classifier of the privacy gate: `local` (the local model), `external`, `off` (see below) |

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
yamllint .
for chart in bootstrap components/*/; do helm lint "$chart"; done
for p in gpu cpu; do scripts/render.sh "$p" "rendered/$p"; done
kubeconform -summary -ignore-missing-schemas rendered/gpu/*.yaml
```

`scripts/render.sh` renders the charts the way Argo CD does, then checks that no component renders a
Namespace or a Secret, or uses a namespace outside the contract. Use Helm 3 (`HELM=/path/to/helm3`):
Argo CD uses Helm 3 too.

## License

Apache License 2.0, see [LICENSE](LICENSE).
