#!/usr/bin/env bash
# Render the whole repo the way Argo CD does: the bootstrap chart first, then
# every component with the values that its Application passes.
#
# Usage: scripts/render.sh [gpu|cpu] [output dir]
#   HELM=/path/to/helm3 scripts/render.sh cpu
# Writes <out>/bootstrap.yaml, <out>/<component>.yaml and the values passed to each
# component in <out>/values/, then checks that
#   - components render no Namespace and no Secret objects;
#   - components set no namespace other than the workload namespaces;
#   - the KServe placeholder {{.Name}} survives rendering.
set -euo pipefail

profile="${1:-gpu}"
out="${2:-rendered/${profile}}"
helm="${HELM:-helm}"
root="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "${out}/values"
"${helm}" template root "${root}/bootstrap" \
  -f "${root}/scripts/ci-values.yaml" --set "modelProfile=${profile}" > "${out}/bootstrap.yaml"

python3 - "${root}" "${out}" "${helm}" <<'PY'
import subprocess, sys, yaml
root, out, helm = sys.argv[1:4]
docs = [d for d in yaml.safe_load_all(open(f"{out}/bootstrap.yaml")) if d]
apps = [d for d in docs if d["kind"] == "Application"]
allowed = set()
for d in docs:
    if d["kind"] == "AppProject":
        allowed = {x["namespace"] for x in d["spec"]["destinations"]}
errors = []
for app in apps:
    name = app["metadata"]["name"]
    src = app["spec"]["source"]
    values = f"{out}/values/{name}.yaml"
    with open(values, "w") as fh:
        yaml.safe_dump(src["helm"]["valuesObject"], fh)
    rendered = subprocess.run(
        [helm, "template", name, f"{root}/{src['path']}", "-f", values,
         "--namespace", app["spec"]["destination"]["namespace"]],
        check=True, capture_output=True, text=True).stdout
    with open(f"{out}/{name}.yaml", "w") as fh:
        fh.write(rendered)
    for obj in (o for o in yaml.safe_load_all(rendered) if o):
        kind, ns = obj["kind"], obj["metadata"].get("namespace")
        if kind in ("Namespace", "Secret"):
            errors.append(f"{name}: renders a {kind} ({obj['metadata']['name']})")
        if ns and ns not in allowed:
            errors.append(f"{name}: {kind}/{obj['metadata']['name']} in namespace {ns}")
    if name == "local-model" and "--served-model-name={{.Name}}" not in rendered:
        errors.append("local-model: KServe placeholder {{.Name}} was rendered by Helm")
    print(f"rendered {name} -> {out}/{name}.yaml")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
PY
