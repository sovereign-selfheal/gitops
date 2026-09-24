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
| `ansible` | Operators, DataScienceCluster, GatewayClass, Gateway `openshift-ai-inference` (+ its ConfigMap), passthrough `Route/maas-router` (host `router.<appsDomain>`), Kuadrant + Authorino TLS, GPU nodes, the namespaces `local-models` and `maas-routing`, the ESO operator, the `ClusterSecretStore` and its credential Secret, Argo CD settings, the root Application |
| `gitops` (this repo) | Every object inside `local-models` and `maas-routing` |

- **Namespaces** are created by Ansible with the label `argocd.argoproj.io/managed-by: openshift-gitops`.
  The default Argo CD instance can manage only namespaces with this label, and it cannot create Namespaces.
  This repo never declares Namespace objects or any other cluster-scoped object.
- **Values set by the seed** (root Application, `helm.valuesObject`): `appsDomain`, `modelProfile`
  (`gpu` or `cpu`), `sota.apiBase`, `sota.model`, `sota.servedMatch`, and optionally `secretStore.*`,
  `classifier.*`, `tiers`. Defaults are in `bootstrap/values.yaml`.
- **Hostnames**: the HTTPRoute here and the Route in Ansible both use `router.<appsDomain>`.
- **Secrets**: never in git. The External Secrets Operator creates them, either from the external store
  or from an in-cluster generator (see README "Secrets").
- **Argo CD health checks**: Ansible configures the ArgoCD CR so that Argo CD reports the health of
  `Application` (needed for sync waves between components), `InferenceService` and the Kuadrant policies.

## 3. Layout

```
bootstrap/            # Helm chart of the root Application: AppProject + one Application per component
components/<name>/    # one Helm chart per component; reads only `.Values.global` from bootstrap
scripts/render.sh     # renders everything like Argo CD does, and checks the contract
scripts/ci-values.yaml
```

- The bootstrap chart builds one `global` block (`bootstrap/templates/_helpers.tpl`) and passes it to every
  component. Components never read other values from bootstrap.
- A component's `values.yaml` has `global` defaults only so that `helm lint` works. The real values come
  from bootstrap.

## 4. Conventions

- **Helm 3.** Argo CD renders the charts with Helm 3, so do not use Helm 4-only features. CI uses Helm 3.
- **No cluster-specific values in templates.** Domains, endpoints and model choices are values.
- **Pins**: every image or model is pinned by digest, with a comment that says where and when it was
  resolved (`# ... resolved on OCP 4.22.14 on 2026-09-24`). Runtime images come from the RHOAI
  ServingRuntime templates in `redhat-ods-applications`; read them on the target cluster.
- **Go templates of other tools**: KServe (`{{.Name}}`) and ESO (`{{ .password }}`) use the same syntax as
  Helm. Escape them: `{{ "{{.Name}}" }}`. `scripts/render.sh` checks the KServe one.
- **Files copied from other repos** (`components/litellm-router/files/`) stay byte-identical to their
  source. Change them in the source first.
- Comments, docs and commit messages in **English**, level B2/C1: short, clear sentences, no idioms.

## 5. Before you open a PR

```bash
yamllint .
for chart in bootstrap components/*/; do helm lint "$chart"; done
shellcheck scripts/*.sh
for p in gpu cpu; do scripts/render.sh "$p" "rendered/$p" && kubeconform -summary -ignore-missing-schemas rendered/$p/*.yaml; done
```

kubeconform does not know the CRDs (KServe, Kuadrant, ESO, Argo CD). To validate those objects, use a
server-side dry run on a cluster: `oc apply --dry-run=server -n <namespace> -f rendered/gpu/<component>.yaml`.

## 6. Out of scope

- Operators, CRDs, RBAC, namespaces, cluster-scoped objects → `ansible` repo.
- Application source code and container builds → `router`, `agents`, `sample-app` repos. The LiteLLM hook
  code is shipped in a ConfigMap for now; it should move into the router image later.

## 7. When in doubt

- Prefer the smallest change that keeps the rendered output and the contract valid.
- Ask before changing a pin, the ownership of an object, or the values contract with the seed.
