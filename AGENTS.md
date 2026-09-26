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
| `ansible` | Operators, DataScienceCluster, GatewayClass, Gateway `openshift-ai-inference` (+ its ConfigMap), passthrough `Route/maas-router` (host `router.<appsDomain>`), Kuadrant + Authorino TLS, GPU nodes, the namespaces `local-models` and `maas-routing`, the ESO operator, the `ClusterSecretStore` and its source Secrets (namespace `sovereign-selfheal-secrets`), the model image pre-pull DaemonSets (namespace `sovereign-selfheal-prepull`), Argo CD settings, the root Application |
| `gitops` (this repo) | Every object inside `local-models` and `maas-routing` |

- **Namespaces** are created by Ansible with the label `argocd.argoproj.io/managed-by: openshift-gitops`.
  The default Argo CD instance can manage only namespaces with this label, and it cannot create Namespaces.
  This repo never declares Namespace objects or any other cluster-scoped object.
- **Values set by the seed** (root Application, `helm.valuesObject`): `appsDomain`, `modelProfile`
  (`gpu` or `cpu`), `sota.enabled`, `sota.apiBase`, `sota.model`, `sota.servedMatch`, `sota.reasoning`, `secretStore.enabled`,
  `classifier.mode` (`local`, `external` or `off`), and optionally `tiers`. Defaults are in `bootstrap/values.yaml`.
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
  `Application` (needed for sync waves between components), `InferenceService` and the Kuadrant policies.

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

## 4. Layout

```
bootstrap/            # Helm chart of the root Application: AppProject + one Application per component
components/<name>/    # one Helm chart per component; reads only `.Values.global` from bootstrap
scripts/render.sh     # renders everything like Argo CD does, and checks the contract
scripts/ci-values.yaml
scripts/sync-router-code.sh  # copies the hook code of the router repo at a tag, and checks the copy
```

- The bootstrap chart builds one `global` block (`bootstrap/templates/_helpers.tpl`) and passes it to every
  component. Components never read other values from bootstrap.
- A component's `values.yaml` has `global` defaults only so that `helm lint` works. The real values come
  from bootstrap.

## 5. Conventions

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
  `router/tests/policy/`.
- Comments, docs and commit messages in **English**, level B2/C1: short, clear sentences, no idioms.
- **Python tools with uv** (`uvx`, `uv run --with`), never pip. The CI pins their versions.

## 6. Before you open a PR

```bash
uvx yamllint .
for chart in bootstrap components/*/; do helm lint "$chart"; done
shellcheck scripts/*.sh
scripts/sync-router-code.sh check
for p in gpu cpu; do uv run --no-project --with pyyaml scripts/render.sh "$p" "rendered/$p" && kubeconform -summary -ignore-missing-schemas rendered/$p/*.yaml; done
```

kubeconform does not know the CRDs (KServe, Kuadrant, ESO, Argo CD). To validate those objects, use a
server-side dry run on a cluster: `oc apply --dry-run=server -n <namespace> -f rendered/gpu/<component>.yaml`.

## 7. Out of scope

- Operators, CRDs, RBAC, namespaces, cluster-scoped objects → `ansible` repo.
- Application source code and container builds → `router`, `presidio`, `agents`, `sample-app` repos. The
  LiteLLM hook code is developed in `router` and shipped here in a ConfigMap (see §3).

## 8. When in doubt

- Prefer the smallest change that keeps the rendered output and the contract valid.
- Ask before changing a pin, the ownership of an object, the values contract with the seed, or the
  contract with the `router` and `presidio` repos.
