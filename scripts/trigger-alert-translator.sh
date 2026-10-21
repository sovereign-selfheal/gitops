#!/usr/bin/env bash
# Manually fire the alert path: KEDA HTTP interceptor -> ogx-alert-translator -> triage-agent.
#
# Sends a synthetic AppHighErrorRate Alertmanager webhook (same shape as production).
# The translator reads the alert `namespace` label and forwards to that namespace's agent.
#
# Operational script — not applied by Argo CD.
#
# Usage:
#   scripts/trigger-alert-translator.sh [rh-reserve|payments|all] [--dry-run]
#
# Default target is rh-reserve.
#
# Env overrides (defaults match bootstrap/values.yaml and ogx-alert-translator):
#   RH_RESERVE_NS        (default: rh-reserve)
#   PAYMENTS_NS          (default: payments)
#   KEDA_WEBHOOK_URL     (default: http://keda-add-ons-http-interceptor-proxy.openshift-keda.svc:8080/webhook)
#   CURL_POD_NAMESPACE   (default: default) — where the ephemeral curl pod runs
#
# Requires: oc (logged in), python3.

set -euo pipefail

RH_RESERVE_NS="${RH_RESERVE_NS:-rh-reserve}"
PAYMENTS_NS="${PAYMENTS_NS:-payments}"
KEDA_WEBHOOK_URL="${KEDA_WEBHOOK_URL:-http://keda-add-ons-http-interceptor-proxy.openshift-keda.svc:8080/webhook}"
CURL_POD_NAMESPACE="${CURL_POD_NAMESPACE:-default}"

DRY_RUN=0
TARGET="rh-reserve"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    rh-reserve|payments|all) TARGET="$arg" ;;
    --dry-run) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage
      exit 1
      ;;
  esac
done

log() { printf '[trigger-alert-translator] %s\n' "$*"; }

require_oc() {
  if ! command -v oc >/dev/null 2>&1; then
    echo "oc CLI not found in PATH." >&2
    exit 1
  fi
  if ! oc whoami >/dev/null 2>&1; then
    echo "Not logged in with oc (oc whoami failed). Run 'oc login' first." >&2
    exit 1
  fi
}

require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found in PATH (needed to build the webhook JSON)." >&2
    exit 1
  fi
}

# Args: namespace, buggy-app service name (Prometheus `service` label).
build_webhook_json() {
  local namespace="$1"
  local app="$2"
  python3 - "$namespace" "$app" <<'PY'
import json
import sys
from datetime import datetime, timezone

namespace, app = sys.argv[1], sys.argv[2]
starts_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
summary = "Quarkus demo app HTTP error rate is above the configured threshold"
description = (
    f"The share of HTTP 5xx responses from {app} in namespace {namespace} "
    f'(http_server_requests_seconds_count, status=~"5..") exceeded 0.10 over the last 5 minutes.'
)
payload = {
    "version": "4",
    "groupKey": f'{{}}:{{alertname="AppHighErrorRate", namespace="{namespace}"}}',
    "status": "firing",
    "receiver": "ogx-translator",
    "groupLabels": {
        "alertname": "AppHighErrorRate",
        "namespace": namespace,
    },
    "commonLabels": {
        "alertname": "AppHighErrorRate",
        "namespace": namespace,
        "severity": "warning",
    },
    "commonAnnotations": {"summary": summary},
    "externalURL": "http://alertmanager:9093",
    "alerts": [
        {
            "status": "firing",
            "labels": {
                "alertname": "AppHighErrorRate",
                "namespace": namespace,
                "severity": "warning",
            },
            "annotations": {
                "summary": summary,
                "description": description,
            },
            "startsAt": starts_at,
            "endsAt": "0001-01-01T00:00:00Z",
            "fingerprint": f"manual-{namespace}-app-high-error-rate",
        }
    ],
}
print(json.dumps(payload))
PY
}

post_webhook() {
  local namespace="$1"
  local app="$2"
  local payload payload_b64 pod_name

  payload=$(build_webhook_json "$namespace" "$app")
  payload_b64=$(printf '%s' "$payload" | base64 | tr -d '\n')
  pod_name="trigger-alert-${namespace//[^a-z0-9-]/-}-$(date +%s)"

  log "Posting AppHighErrorRate webhook for namespace ${namespace} (${app})"
  log "  -> ${KEDA_WEBHOOK_URL}"
  log "  (translator will forward to triage-agent.${namespace}.svc:7860/trigger)"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "  (dry-run) would run ephemeral curl pod ${pod_name} in ${CURL_POD_NAMESPACE}"
    return 0
  fi

  oc run "$pod_name" --rm -i --restart=Never -n "$CURL_POD_NAMESPACE" \
    --image=curlimages/curl:latest \
    --env="PAYLOAD_B64=${payload_b64}" \
    --env="KEDA_WEBHOOK_URL=${KEDA_WEBHOOK_URL}" \
    --command -- sh -c \
    "echo \"\$PAYLOAD_B64\" | base64 -d | curl -sS -w \"\\nHTTP %{http_code}\\n\" -X POST \"\$KEDA_WEBHOOK_URL\" -H \"Content-Type: application/json\" -d @-"
}

run_target() {
  case "$1" in
    rh-reserve)
      post_webhook "$RH_RESERVE_NS" "rh-reserve-buggy-app"
      ;;
    payments)
      post_webhook "$PAYMENTS_NS" "payments-buggy-app"
      ;;
    *)
      echo "internal error: unknown target $1" >&2
      exit 1
      ;;
  esac
}

main() {
  require_oc
  require_python3
  [ "$DRY_RUN" -eq 1 ] && log "Dry-run mode: no requests will be sent."

  case "$TARGET" in
    all)
      run_target rh-reserve
      run_target payments
      ;;
    rh-reserve | payments)
      run_target "$TARGET"
      ;;
    *)
      echo "Unknown target: $TARGET" >&2
      exit 1
      ;;
  esac

  log "Done. Expect HTTP 202 from the interceptor/translator (cold start may take ~20-30s)."
  log "  oc logs -n agentic-triage -l app=ogx-alert-translator -f"
  log "  oc logs -n ${RH_RESERVE_NS} -l app=triage-agent -f"
}

main
