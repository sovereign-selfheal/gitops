#!/usr/bin/env bash
# Keep the runbook of the TriageAgent CR equal to the one of components/triage-agent.
#
# components/triage-agent/files/knowledge.md is the source of truth. The chart
# components/triage-agent-operator-cr ships a copy, because Helm reads files only inside
# the chart directory.
#
# Usage:
#   scripts/sync-triage-knowledge.sh sync    # copy the runbook into the CR chart
#   scripts/sync-triage-knowledge.sh check   # fail if the copy differs
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_file="${root}/components/triage-agent/files/knowledge.md"
copy="${root}/components/triage-agent-operator-cr/files/knowledge.md"

case "${1:-}" in
  sync)
    cp "${source_file}" "${copy}"
    echo "copied ${source_file#"${root}/"} to ${copy#"${root}/"}"
    ;;
  check)
    if cmp -s "${source_file}" "${copy}"; then
      echo "OK:   ${copy#"${root}/"} = ${source_file#"${root}/"}"
    else
      echo "FAIL: ${copy#"${root}/"} differs from ${source_file#"${root}/"} (run: $0 sync)" >&2
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 sync | check" >&2
    exit 2
    ;;
esac
