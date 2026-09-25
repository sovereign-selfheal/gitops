#!/usr/bin/env bash
# Keep the hook code in components/litellm-router/files/ equal to the router repo.
#
# The router repo (github.com/sovereign-selfheal/router) is the source of truth of the
# hook code. This repo ships a copy in the LiteLLM ConfigMap, at the version named by
# `routerVersion` in components/litellm-router/values.yaml (see AGENTS.md §3).
#
# Usage:
#   scripts/sync-router-code.sh sync vX.Y.Z   # copy the code at tag vX.Y.Z, set routerVersion
#   scripts/sync-router-code.sh check         # fail if the copy differs from routerVersion
#
# The files come from raw.githubusercontent.com (public repo, no token). With
# ROUTER_GIT_DIR=<local clone of router> they come from that clone instead (git show).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
files_dir="${root}/components/litellm-router/files"
values="${root}/components/litellm-router/values.yaml"
raw_base="${ROUTER_RAW_BASE:-https://raw.githubusercontent.com/sovereign-selfheal/router}"
# Hook files taken from the router repo (litellm/<file>). Keep in sync with router/litellm/.
hook_files=(policy_hook_chain.py privacy_scoring.py)

usage() {
  echo "Usage: $0 sync vX.Y.Z | check" >&2
  exit 2
}

# fetch <tag> <file> <destination>
fetch() {
  if [[ -n "${ROUTER_GIT_DIR:-}" ]]; then
    git -C "${ROUTER_GIT_DIR}" show "refs/tags/$1:litellm/$2" > "$3"
  else
    curl -fsSL -o "$3" "${raw_base}/refs/tags/$1/litellm/$2"
  fi
}

current_version() {
  sed -n 's/^routerVersion: *\(v[0-9][0-9.]*\) *$/\1/p' "${values}"
}

case "${1:-}" in
  sync)
    tag="${2:-}"
    [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
    for f in "${hook_files[@]}"; do
      fetch "${tag}" "${f}" "${files_dir}/${f}.tmp"
      mv "${files_dir}/${f}.tmp" "${files_dir}/${f}"
    done
    sed -i "s/^routerVersion: .*/routerVersion: ${tag}/" "${values}"
    echo "hook code synced to router ${tag}; now pin the image digest of ${tag} in ${values#"${root}/"}"
    ;;
  check)
    tag="$(current_version)"
    [[ -n "${tag}" ]] || { echo "FAIL: no routerVersion in ${values}" >&2; exit 1; }
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    status=0
    for f in "${hook_files[@]}"; do
      fetch "${tag}" "${f}" "${tmp}/${f}"
      if cmp -s "${tmp}/${f}" "${files_dir}/${f}"; then
        echo "OK:   ${f} = router ${tag}"
      else
        echo "FAIL: ${f} differs from router ${tag} (run: $0 sync ${tag})" >&2
        status=1
      fi
    done
    # Every .py in files/ must come from the router repo.
    for path in "${files_dir}"/*.py; do
      name="$(basename "${path}")"
      if [[ ! " ${hook_files[*]} " == *" ${name} "* ]]; then
        echo "FAIL: ${name} is not a hook file of the router repo" >&2
        status=1
      fi
    done
    exit "${status}"
    ;;
  *)
    usage
    ;;
esac
