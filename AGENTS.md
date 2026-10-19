# AGENTS.md: `gitops` repository

Guidance for AI coding agents and humans working in this repo. Read it fully before you change anything.

## 1. Purpose

This repository holds **every workload** of the demo *"The Sovereign, Self-Healing Platform — Smart LLM
Routing & Autonomous AI-Driven Triage on OpenShift AI"*. Argo CD (the default `openshift-gitops` instance)
reconciles it. The `ansible` repository prepares the cluster and creates the root Application that points
here. After that, Argo CD owns every object described in this repo.

## 2. Contract with the `ansible` repo

**Ownership. No object is created by both repos.**

| Owner | Objects |
|---|---|
| `ansible` | Operators (including the RHOAI **MCP lifecycle operator**, needed for the `MCPServer` CRs of `components/prometheus-mcp-server`, `components/ticketing-mcp-server` and `components/ocp-mcp-server`, and the **Custom Metrics Autoscaler** (KEDA) with its `KedaController` and HTTP add-on, needed for the `HTTPScaledObject` of `components/ogx-alert-translator`), DataScienceCluster, GatewayClass, Gateway `openshift-ai-inference` (+ its ConfigMap), passthrough `Route/maas-router` (host `router.<appsDomain>`), Kuadrant + Authorino TLS, the metric monitors of Limitador and Authorino, the `TelemetryPolicy` `openshift-ai-inference-labels` (label `tier` on the Limitador counters, read from the `tier` filter of the AuthPolicy `litellm-apikey`: rename both together), GPU nodes, the namespaces `local-models`, `maas-routing`, `agentic-triage`, `payments`, `rh-reserve` and `reverse-proxy-app` (with their `sovereign-selfheal.io/data-class` labels), the ESO operator, the `ClusterSecretStore` and its source Secrets (namespace `sovereign-selfheal-secrets`), the model image pre-pull DaemonSets (namespace `sovereign-selfheal-prepull`), the `ClusterRoleBinding` of the `prometheus-mcp-server-sa` ServiceAccount (namespace `agentic-triage`) to the built-in `cluster-monitoring-view` ClusterRole, the `ClusterRoleBinding` of the `ocp-mcp-server-sa` ServiceAccount (namespace `agentic-triage`) to the built-in `view` ClusterRole, the **triage-agent-operator** (`TriageAgent` CRD, controller Deployment in `triage-agent-operator`, cluster RBAC, Argo CD health check for `TriageAgent`, RBAC in every monitored-application namespace it reconciles a `TriageAgent` CR in), the ClusterRole that reads namespaces (get/list/watch) and its bindings to the `litellm` and `routing-live-view` ServiceAccounts (namespace `maas-routing`, namespace policy of router v0.11.0), the ClusterRole that patches the demo namespaces only and its binding to `routing-live-view`, Argo CD settings, the root Application, the observability operators (OpenTelemetry, Tempo, Cluster Observability), the `UIPlugin` `distributed-tracing`, the Tempo tenant write permission (ClusterRole + binding), the namespace `observability`, user workload monitoring, team access when `team_users` is set (Keycloak in `keycloak` when Ansible installs it, OAuth IdP, `Group/selfheal-team` + ClusterRoleBinding, the Argo CD RBAC line `g, selfheal-team, role:admin`) |
| `gitops` (this repo) | Every object inside `local-models`, `maas-routing`, `observability`, `agentic-triage`, `payments`, `rh-reserve` and `reverse-proxy-app`. `agentic-triage` holds only the services shared by every agent (`ticketing-system`, the three MCP servers, `ogx-alert-translator`); `payments`, `rh-reserve` and `reverse-proxy-app` (keys `namespaces.payments`, `namespaces.rhReserve`, `namespaces.reverseProxyApp`) are monitored-application namespaces, each with its own buggy app (`components/quarkus-buggy-app`, instance names `payments-buggy-app`, `rh-reserve-buggy-app`, `reverse-proxy-buggy-app`) and its own agent. One exception: with `components/triage-agent-operator-cr`, the `TriageAgent` CR is here, but the objects that the triage-agent-operator creates from it (ServiceAccount, Deployment, Service, Route, ConfigMaps) belong to the operator |

- **Namespaces** are created by Ansible with the label `argocd.argoproj.io/managed-by: openshift-gitops`.
  The default Argo CD instance can manage only namespaces with this label, and it cannot create Namespaces.
  This repo never declares Namespace objects or any other cluster-scoped object.
- **Values set by the seed** (root Application, `helm.valuesObject`): `appsDomain`, `modelProfile`
  (`gpu` or `cpu`), `sota.enabled`, `sota.apiBase`, `sota.model`, `sota.servedMatch`, `sota.reasoning`, `secretStore.enabled`,
  `classifier.mode` (`local`, `external` or `off`), `observability.enabled`, `namespaces.observability`,
  `decisionModel.enabled`, `namespacePolicy.scan`, `namespacePolicy.hint`, `namespaces.payments`,
  `namespaces.rhReserve`, `namespaces.reverseProxyApp`, `sotaBudget.enabled`, `triageAgentOperator.enabled`,
  and optionally `tiers`. With the decision model and managed GPU nodes the seed
  also sets `localModel.profiles.gpu.nodeSelector` to `node-role.kubernetes.io/gpu: ""` (Helm merges it
  with the default `nvidia.com/gpu.present`). Defaults are in `bootstrap/values.yaml`.
- **Per-component value overrides**: a `components.<name>.values` map in `bootstrap/values.yaml`, if set,
 is passed to that component's Application alongside `global` (`bootstrap/templates/applications.yaml`).
 Components still read only `.Values.global` for shared, cluster-wide settings; `values` is for the rare
 case where the *same chart* is deployed more than once with a different per-instance setting (for
 example `apiKeyTier` of the three `triage-agent-operator-cr` instances, or `appName` of the three
 `components/quarkus-buggy-app` instances, one per monitored-application namespace). Do not use it to
 duplicate something `global` already carries.
- **Decision model** (`decisionModel.enabled`, only with `modelProfile: gpu`): the component `decision-model`
  runs on the `gpu-decision` GPU pool of the ansible repo (node label `node-role.kubernetes.io/gpu-decision`).
  When you change `decisionModel.storageUri` or `.runtimeImage`, update `model_prepull_decision_images` in
  the ansible repo with the same digests.
- **Tiers**: `tiers` (bootstrap/values.yaml) lists both human API-key tiers (`research`, `legal`) and one
  tier per monitored-application agent (`agents-payments`, `agents-rh-reserve`, `agents-reverse-proxy-app`),
  each used by one `components/triage-agent-operator-cr` instance's own router credential
  (`values.apiKeyTier` of that instance, see "Per-component value overrides" above). Each tier gets a
  token-budget rule (`TokenRateLimitPolicy`, component `frontdoor`); a component that needs its own
  credential (because it runs in a different namespace than `components/secrets`) generates its own
  `Password`/`ExternalSecret` labelled with one of these tier names (see
  `components/triage-agent-operator-cr/templates/apikey.yaml`). A tier with `sotaTokens` also gets a SOTA
  token budget in the router (v0.12.0, with `sotaBudget.enabled`): the per-agent tiers above, plus
  `agents-critical` (business-critical applications not covered by a dedicated tier) and `validation`
  (used by the `validation` repo, check B1), exist for it. The optional `agent` of a tier is the name that
  the live page `routing-live-view` shows in its column Agent (env `TIER_LABELS`): set it when an agent
  gets its tier.
- **Observability**: this repo deploys the Tempo instance `tempo` (kind `TempoMonolithic`, multi-tenancy
  `openshift`, tenant `router`) and the OpenTelemetry collector `otel` (kind `OpenTelemetryCollector`; the
  operator names its Service and ServiceAccount `otel-collector`) in the namespace `observability`. OTLP
  http on `otel-collector.observability.svc:4318`, grpc on `:4317`. The ansible repo lets the ServiceAccount
  `otel-collector` write the tenant `router`: keep the tenant name equal in both repos. With
  `observability.enabled: false` the component is not deployed.
- **Local model images**: the ansible repo pre-pulls the images of the local model on the model nodes
  (`roles/model_prepull`), so a new or restarted model pod does not wait for the download. When you change
  `localModel.profiles.<profile>.storageUri` or `.runtimeImage` in `bootstrap/values.yaml`, update
  `model_prepull_images` in the ansible repo (`roles/model_prepull/defaults/main.yml`) with the same digests.
  Otherwise the pre-pull downloads images nobody uses; the ansible seed prints a warning after the sync.
- **Local-only mode**: without SOTA settings in the ansible-vault, `sota.enabled` is `false` and the alias
  `sota-smart` points to the local model. Every template must keep working in this mode.
- **Hostnames**: the HTTPRoute here and the Route in Ansible both use `router.<appsDomain>`.
- **Secrets**: never in git. The External Secrets Operator creates them, either from the external store
  or from an in-cluster generator (see README "Secrets").
- **Argo CD health checks**: Ansible configures the ArgoCD CR so that Argo CD reports the health of
  `Application` (needed for sync waves between components), `InferenceService`, the Kuadrant policies,
  `TempoMonolithic`, MCP lifecycle `MCPServer` (`mcp.x-k8s.io`) and `TriageAgent`
  (`triage.sovereign-selfheal.io`). Argo CD 3.4 knows `OpenTelemetryCollector` by itself.

## 3. Contract with the `router` and `presidio` repos

These two repos build the custom images and own the router code. The same rules are in
`router/AGENTS.md` and `presidio/AGENTS.md`: keep them in sync.

| Owner | Items |
|---|---|
| `router` | Hook code (`policy_hook_chain.py`, `privacy_scoring.py`), its tests and evaluation, image `quay.io/sovereign-selfheal/router` (LiteLLM + fastText) |
| `presidio` | Image `quay.io/sovereign-selfheal/presidio` (Presidio analyzer + English and Italian NER models) |
| `gitops` (this repo) | The policies `chain.yaml` and `privacy-plus.yaml` (source of truth), `config-chain.yaml`, the ConfigMap with a **copy** of the hook code, every Kubernetes object, the image digests in use |

1. **One router version.** `routerVersion` in `components/litellm-router/values.yaml` names a git tag of
   `router`. The hook code in `components/litellm-router/files/*.py` and the router image both come from
   that tag.
2. **Checked copy.** The `*.py` files are byte-identical to `router` at `routerVersion`. Never edit them
   here: change the code in `router`, release a tag, then run `scripts/sync-router-code.sh sync vX.Y.Z`.
   The CI runs `scripts/sync-router-code.sh check`.
3. **Images by digest.** Both images are pinned by digest, with `# tag vX.Y.Z, resolved on quay.io on
   <date>`. This repo never follows a tag automatically: a new version is a PR here.
4. **Policy keys.** New keys that the router code reads have a default that keeps the old behaviour.
   Turn a key on only with a `routerVersion` that reads it (the comment next to the key says which).
5. **Interface.** The router hook logs one `[policy-router] {...}` line per request, and the Presidio
   image serves `POST /analyze` on port 3000 for `en` and `it`. Changes to these come with a minor
   version of the other repo (see its AGENTS.md).

## 4. Contract with the AI-driven triage demo repos

Five repos own the source and the build of the AI-driven triage workloads (the original demo
imported from `matteo-grimaldi/ocp-trobleshooter-demo`, plus `ogx-alert-translator`), split today across
the shared-services namespace `agentic-triage` and the three monitored-application namespaces
`payments`, `rh-reserve` and `reverse-proxy-app` (keys `namespaces.triage`, `namespaces.payments`,
`namespaces.rhReserve`, `namespaces.reverseProxyApp`). Unlike `router`, none of them has a code-copy
contract with this repo: this repo only pins their image digests, same as `presidio`.

| Owner | Items |
|---|---|
| `triage-agent` | Gradio UI (`app.py`, `agent.py`), a thin client of the OGX sidecar's Responses API, image `quay.io/sovereign-selfheal/triage-agent` |
| `ogx-alert-translator` | FastAPI Alertmanager webhook bridge to the `/trigger` endpoint of the agent of the alert's own namespace (see point 5), image `quay.io/sovereign-selfheal/ogx-alert-translator` |
| `mock-ticketing-system` | Two subfolders, two images: `ticketing-system` (FastAPI ServiceNow simulator) and `ticketing-mcp-server` (FastMCP wrapper), `quay.io/sovereign-selfheal/ticketing-system` and `quay.io/sovereign-selfheal/ticketing-mcp-server` |
| `quarkus-buggy-app` | Quarkus 3 source, built with the Jib extension, image `quay.io/sovereign-selfheal/quarkus-buggy-app` |
| `prometheus-mcp-server` | FastMCP server wrapping PromQL against Thanos, image `quay.io/sovereign-selfheal/prometheus-mcp-server` |
| `routing-live-view` | Live page of the routing decisions and of the namespace labels (FastAPI, parses the `[policy-router]` log line of the router), image `quay.io/sovereign-selfheal/routing-live-view`; deployed by `components/routing-live-view` in `maas-routing` |
| `gitops` (this repo) | Every Kubernetes object in `agentic-triage` (`components/ticketing-system`, `components/ticketing-mcp-server`, `components/prometheus-mcp-server`, `components/ocp-mcp-server`, `components/triage-agent` (legacy, disabled), `components/ogx-alert-translator`) and in each of `payments`, `rh-reserve`, `reverse-proxy-app` (one `components/quarkus-buggy-app` instance, with its own per-namespace `appName` (`payments-buggy-app`, `rh-reserve-buggy-app`, `reverse-proxy-buggy-app`), and one `TriageAgent` CR of `components/triage-agent-operator-cr`, with its own API key, per namespace; the operator owns the objects it creates from each CR, including the stack-run config it builds from the CR spec), the image digests in use, including the third-party OGX sidecar image and the agent's `knowledge.md` (`components/triage-agent-operator-cr/files/knowledge.md`, mounted via ConfigMap; the payments instance uses this file, a copy of `components/triage-agent/files/knowledge.md` (see `scripts/sync-triage-knowledge.sh`), the other two instances use `knowledge-rh-reserve.md`/`knowledge-reverse-proxy-app.md`, copies with the app's real per-namespace name substituted in) |

- **MCP servers and ticketing stay shared.** `prometheus-mcp-server`, `ticketing-mcp-server`,
  `ocp-mcp-server` and `ticketing-system` run once, in `agentic-triage` (`namespaces.triage`), not in each
  monitored-application namespace. Every agent (one TriageAgent CR per monitored-application namespace)
  calls them cross-namespace by FQDN (`*.agentic-triage.svc`, see point 3). Do not duplicate these
  components per application namespace.
- **One agent per monitored-application namespace.** `components/triage-agent-operator-cr` is deployed
  once per monitored-application namespace (bootstrap components `triage-agent-payments`,
  `triage-agent-rh-reserve`, `triage-agent-reverse-proxy-app`), each with its own router credential tier
  (`values.apiKeyTier`, see §2 "Per-component value overrides" and "Tiers"). All three use the same CR
  name (`triage-agent`, chart default): ogx-alert-translator relies on that name being equal in every
  namespace (see point 5).

1. **Images by digest.** Same pin convention as §3: `# tag vX.Y.Z, resolved on quay.io on <date>`. A new
   version is a PR here. The OGX sidecar (`docker.io/ogxai/distribution-starter`) and the Kubernetes-API
   MCP server (`quay.io/containers/kubernetes_mcp_server`, `components/ocp-mcp-server`) follow the same
   rule even though neither is a `sovereign-selfheal` image and neither has a source-code contract with
   this repo (comment says `# tag <tag>, resolved on <registry> on <date>`).
2. **No external model backend.** `triage-agent`'s OGX sidecar has no external MaaS endpoint (unlike the
   upstream demo it is based on): it is configured (`VLLM_URL` in the Deployment, `stack_run_config.yaml`)
   to call the platform's own gateway (`https://router.<appsDomain>/v1`, model `auto`), so the same policy
   hook and privacy gate that apply to every other client also apply to the agent's traffic. OGX itself
   (the server-side agentic loop and native MCP tool calling) is kept — only its backend target changed.
3. **MCP servers.** `components/prometheus-mcp-server`, `components/ticketing-mcp-server` and
   `components/ocp-mcp-server` render `MCPServer` CRs (`mcp.x-k8s.io/v1alpha1`), reconciled by the
   ansible-owned MCP lifecycle operator (§2). OGX calls their `server_url` directly
   (`tools=[{"type": "mcp", ...}]`); `components/triage-agent` does not run its own MCP client.
4. **Kubernetes-API MCP server.** `components/ocp-mcp-server` runs the upstream
   `containers/kubernetes-mcp-server` project (`--read-only --toolsets core`: pods, logs, events and
   generic-resource reads only, no write tool). `triage-agent`'s `OCP_MCP_URL` comes from
   `components/triage-agent` values `ocpMcpUrl` and `ocpMcpUseInClusterService`: an explicit URL, or
   the in-cluster Service when the bootstrap has the component on (`global.ocpMcpServer.enabled`), or
   empty (no tool). `triage-agent-operator-cr` follows the same rules with `mcpServers.ocp` and
   `mcpServers.ocpUseInClusterService`. Its ServiceAccount `ocp-mcp-server-sa` is bound (ansible repo, §2) to the
   built-in `view` ClusterRole, cluster-wide.
5. **Alertmanager bridge (`ogx-alert-translator`).** A single, stateless webhook receiver in
   `components/ogx-alert-translator` (deployed once, in `agentic-triage`) accepts Alertmanager POSTs on
   `/webhook`, builds a plain-text prompt from the alert labels/annotations, and forwards it to the
   agent that runs in the **alert's own namespace** (plain JSON `{"input": "<text>"}`). One agent per
   monitored-application namespace shares this one translator: the translator does not hardcode a single
   namespace. It derives the target from the alert's `namespace` label and two env vars,
   `TRIAGE_AGENT_SERVICE` (default `triage-agent`) and `TRIAGE_AGENT_PORT` (default `7860`):
   `http://<TRIAGE_AGENT_SERVICE>.<alert namespace>.svc:<TRIAGE_AGENT_PORT>/trigger`. This only works
   because every TriageAgent CR keeps the same name (`triage-agent`, see point above) — renaming one
   agent's CR without updating this convention breaks the bridge for that namespace. This reuses the
   agent's existing Service port (`7860`, shared with the Gradio UI) — `triage-agent`'s `app.py` mounts
   Gradio inside a FastAPI app that also serves `/trigger`. **No new Service port and no OGX access**
   for the translator: it never calls OGX, MCP servers, or the router, and never redefines the system
   prompt, tool list, or model — that definition lives exactly once, per agent, in `triage-agent/agent.py`.
   Scale-from-zero uses KEDA (`HTTPScaledObject` when the HTTP add-on is installed by Ansible, or
   optional Prometheus `ScaledObject` in values). No public Route: Alertmanager (or the KEDA HTTP
   interceptor) calls the cluster Service only.
   - **One `AlertmanagerConfig` per monitored-application namespace**
     (`alertmanager.namespaceRefs` of `components/ogx-alert-translator`, keep in sync with
     `alerts.quarkusBuggyApp.namespaceRefs` of `components/observability`), all routing to the same
     webhook URL; the translator tells them apart by the alert's `namespace` label, not by a different
     URL per namespace.
   - **Callers use the interceptor.** With the HTTP add-on, a sender (Alertmanager) must POST to
     `http://keda-add-ons-http-interceptor-proxy.openshift-keda.svc:8080/webhook`: the interceptor
     holds the request and KEDA starts the pod. The Service of the translator has no endpoints while
     it is scaled to zero. Checked on 2026-10-05: HTTP 202 after a 26 s cold start, and the agent
     started its run.
   - **No `replicas` with KEDA.** With KEDA on, the Deployment has no `replicas` field: KEDA owns the
     number of pods. With a value in Git, Argo CD (selfHeal) sets it again and stops the pod that KEDA
     started.
   - **Alertmanager routing.** Ansible sets `alertmanagerMain.enableUserAlertmanagerConfig` in
     `cluster-monitoring-config` (`roles/user_workload_monitoring`, when the KEDA HTTP add-on is on).
     This repo declares the matching `AlertmanagerConfig` in `components/ogx-alert-translator` (webhook
     to the KEDA interceptor for `AppHighErrorRate`, once per monitored-application
     namespace).
   - **Translator code contract.** The `ogx-alert-translator` repo reads `TRIAGE_AGENT_SERVICE` and
     `TRIAGE_AGENT_PORT` and builds the URL from the alert's `namespace` label, instead of a single
     fixed `TRIAGE_AGENT_URL`. This is a behaviour change of that repo's code, not only of this repo's
     objects: bump its version together with this change.

## 5. Layout

```
bootstrap/            # Helm chart of the root Application: AppProject + one Application per component
components/<name>/    # one Helm chart per component; reads only `.Values.global` from bootstrap
scripts/render.sh     # renders everything like Argo CD does, and checks the contract
scripts/ci-values.yaml
scripts/sync-router-code.sh  # copies the hook code of the router repo at a tag, and checks the copy
scripts/sync-triage-knowledge.sh  # copies the triage-agent runbook into the TriageAgent CR chart, and checks it
scripts/reset-demo-state.sh       # operational: clear demo runtime state on a cluster (not run by Argo CD)
```

- The bootstrap chart builds one `global` block (`bootstrap/templates/_helpers.tpl`) and passes it to every
  component. Components never read other values from bootstrap.
- A component's `values.yaml` has `global` defaults only so that `helm lint` works. The real values come
  from bootstrap.

## 6. Conventions

- **Helm 3.** Argo CD renders the charts with Helm 3, so do not use Helm 4-only features. CI uses Helm 3.
- **No cluster-specific values in templates.** Domains, endpoints and model choices are values.
- **Pins**: every image or model is pinned by digest, with a comment that says where and when it was
  resolved (`# ... resolved on OCP 4.22.14 on 2026-09-24`). Runtime images come from the RHOAI
  ServingRuntime templates in `redhat-ods-applications`; read them on the target cluster.
- **Go templates of other tools**: KServe (`{{.Name}}`) and ESO (`{{ .password }}`) use the same syntax as
  Helm. Escape them: `{{ "{{.Name}}" }}`. `scripts/render.sh` checks the KServe one.
- **Router code and policies** (`components/litellm-router/files/`): the hook code (`*.py`) is a copy of
  the `router` repo at `routerVersion` (see §3). The policies (`chain.yaml`, `privacy-plus.yaml`) are
  maintained here: this repo is their source of truth. They came from the old repo `rhocpai-mvp-routing`
  (read-only); `chain.yaml` has Italian keywords added. When a policy changes, refresh the test copy in
  `router/tests/policy/` and the expected decisions in `cases/routing.yml` of the `validation` repo.
- **Names used by the `validation` repo**: namespaces, Deployments, labels, PDBs, the ConfigMap
  `litellm-config`, the API key Secrets and the InferenceService names are listed in `validation/AGENTS.md`
  §5. When you rename one of them, update that repo too.
- Comments, docs and commit messages in **English**, level B2/C1: short, clear sentences, no idioms.
- **Python tools with uv** (`uvx`, `uv run --with`), never pip. The CI pins their versions.

## 7. Before you open a PR

```bash
uvx yamllint .
for chart in bootstrap components/*/; do helm lint "$chart"; done
shellcheck scripts/*.sh
scripts/sync-router-code.sh check
scripts/sync-triage-knowledge.sh check
for p in gpu cpu; do uv run --no-project --with pyyaml scripts/render.sh "$p" "rendered/$p" && kubeconform -summary -ignore-missing-schemas rendered/$p/*.yaml; done
```

kubeconform does not know the CRDs (KServe, Kuadrant, ESO, Argo CD). To validate those objects, use a
server-side dry run on a cluster: `oc apply --dry-run=server -n <namespace> -f rendered/gpu/<component>.yaml`.

## 8. Out of scope

- Operators, CRDs, RBAC, namespaces, cluster-scoped objects → `ansible` repo.
- Application source code and container builds → `router`, `presidio`, `triage-agent`,
  `ogx-alert-translator`, `mock-ticketing-system`, `quarkus-buggy-app`, `prometheus-mcp-server` repos.
  The LiteLLM hook code is developed in `router` and shipped here in a ConfigMap (see §3).
- KEDA / Custom Metrics Autoscaler operator and HTTP add-on → `ansible` repo (not declared here except
  as CRs under `components/ogx-alert-translator`).

## 9. When in doubt

- Prefer the smallest change that keeps the rendered output and the contract valid.
- Ask before changing a pin, the ownership of an object, the values contract with the seed, or the
  contract with the `router`, `presidio` and AI-driven triage demo repos.
