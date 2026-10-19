#!/usr/bin/env bash
# Reset demo UI state on a live cluster so you can record the scenario again from a clean slate.
#
# This is an operational script. It is NOT applied by Argo CD and does not touch git. It
# deletes runtime data and restarts workloads that keep counters or in-memory views.
#
# Targets (see AGENTS.md for namespace ownership):
#   - ticketing-system  (agentic-triage) : incident dashboard; SQLite file on a PVC.
#   - tempo             (observability)  : trace store (Observe -> Traces, Perses trace panels).
#   - litellm-redis     (maas-routing)   : SOTA token-budget counters (no persistence).
#   - litellm           (maas-routing)   : router Prometheus metrics since pod start (Perses dashboards).
#   - routing-live-view (maas-routing)   : live routing-decision page (in-memory only).
#
# Alerts are not cleared: AppHighErrorRate stays firing while the buggy apps error. After a
# reset, the alert-driven path behaves as follows (see README "AI-driven triage demo"):
#   - First investigation from a cold cluster: about 5.5 minutes (rule for: 5m plus grouping).
#   - Repeat Alertmanager webhooks to ogx-alert-translator: about once per hour (repeatInterval).
#   - To investigate on your own schedule, use an agent chat UI Route instead of waiting.
#
# Usage:
#   scripts/reset-demo-state.sh [--dry-run] [--yes]
#
# Env overrides (defaults match bootstrap/values.yaml `namespaces`):
#   TRIAGE_NS   (default: agentic-triage)
#   OBS_NS      (default: observability)
#   ROUTING_NS  (default: maas-routing)
#
# Requires: oc, logged in with enough RBAC in the namespaces above.

set -euo pipefail

TRIAGE_NS="${TRIAGE_NS:-agentic-triage}"
OBS_NS="${OBS_NS:-observability}"
ROUTING_NS="${ROUTING_NS:-maas-routing}"

DRY_RUN=0
ASSUME_YES=0

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
  esac
done

log() { printf '[reset-demo-state] %s\n' "$*"; }

# Runs a mutating command, or just prints it in --dry-run mode.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ (dry-run) %s\n' "$*"
  else
    printf '+ %s\n' "$*"
    "$@"
  fi
}

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

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  local user server
  user=$(oc whoami)
  server=$(oc whoami --show-server)
  printf 'Cluster: %s (user %s)\n' "$server" "$user"
  printf 'This deletes ticketing data and traces and restarts the router, Redis, and live view. Continue? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) echo "Aborted."; exit 1 ;;
  esac
}

# ----- ticketing-system: wipe the SQLite file, let the Deployment (Recreate strategy)
# restart the pod with an empty DB. -----
reset_ticketing() {
  log "Resetting ticketing-system dashboard in namespace ${TRIAGE_NS}..."
  local pod
  pod=$(oc get pod -n "$TRIAGE_NS" -l app=ticketing-system -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$pod" ]; then
    log "  no ticketing-system pod found in ${TRIAGE_NS}, skipping."
    return 0
  fi
  log "  found pod ${pod}"
  run oc exec -n "$TRIAGE_NS" "$pod" -- rm -f /data/incidents.db
  run oc delete pod -n "$TRIAGE_NS" "$pod" --wait=false
  if [ "$DRY_RUN" -eq 0 ]; then
    oc rollout status deployment/ticketing-system -n "$TRIAGE_NS" --timeout=120s
  fi
  log "  ticketing-system dashboard reset."
}

# ----- tempo: delete the trace storage PVC(s) and the pod, so the Tempo operator
# reconciles a fresh, empty PVC on the next pass. Resources are found by label, since the
# Tempo operator (not this repo) decides the exact object kind (Deployment/StatefulSet). -----
reset_tempo() {
  log "Resetting Tempo traces in namespace ${OBS_NS}..."
  local selector="app.kubernetes.io/instance=tempo"
  local pods pvcs
  pods=$(oc get pod -n "$OBS_NS" -l "$selector" -o name 2>/dev/null || true)
  pvcs=$(oc get pvc -n "$OBS_NS" -l "$selector" -o name 2>/dev/null || true)

  if [ -z "$pods" ] && [ -z "$pvcs" ]; then
    log "  no resources matched '${selector}' in ${OBS_NS}; falling back to name match 'tempo'."
    pods=$(oc get pod -n "$OBS_NS" -o name 2>/dev/null | grep -i '/tempo' || true)
    pvcs=$(oc get pvc -n "$OBS_NS" -o name 2>/dev/null | grep -i tempo || true)
  fi

  if [ -z "$pods" ] && [ -z "$pvcs" ]; then
    log "  still no Tempo pod/PVC found in ${OBS_NS}; skipping. Check the TempoMonolithic status manually."
    return 0
  fi

  # Delete the PVC(s) first (they will sit in Terminating while the pod holds the finalizer),
  # then delete the pod to release it. The Tempo operator recreates both on reconcile.
  if [ -n "$pvcs" ]; then
    # shellcheck disable=SC2086
    run oc delete $pvcs -n "$OBS_NS" --wait=false
  fi
  if [ -n "$pods" ]; then
    # shellcheck disable=SC2086
    run oc delete $pods -n "$OBS_NS" --grace-period=0 --force --wait=false
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    log "  waiting for the Tempo operator to reconcile a fresh pod..."
    local tries=0
    until oc get pod -n "$OBS_NS" -l "$selector" -o name 2>/dev/null | grep -q .; do
      tries=$((tries + 1))
      if [ "$tries" -ge 30 ]; then
        log "  WARNING: no new Tempo pod appeared after 60s. Check the TempoMonolithic CR status."
        return 0
      fi
      sleep 2
    done
    oc wait --for=condition=Ready pod -n "$OBS_NS" -l "$selector" --timeout=180s || \
      log "  WARNING: new Tempo pod did not become Ready in time; check it manually."
  fi
  log "  Tempo traces reset. Old traces also disappear from Observe -> Traces in the console."
}

# ----- litellm-redis: no persistence; a restart clears per-tier SOTA token budgets. -----
reset_litellm_redis() {
  log "Restarting litellm-redis in namespace ${ROUTING_NS}..."
  if ! oc get deployment/litellm-redis -n "$ROUTING_NS" >/dev/null 2>&1; then
    log "  deployment/litellm-redis not found in ${ROUTING_NS}, skipping."
    return 0
  fi
  run oc rollout restart deployment/litellm-redis -n "$ROUTING_NS"
  if [ "$DRY_RUN" -eq 0 ]; then
    oc rollout status deployment/litellm-redis -n "$ROUTING_NS" --timeout=120s
  fi
  log "  litellm-redis restarted (SOTA budget counters cleared)."
}

# ----- litellm: router metrics count since pod start (Perses routing-decisions / at-a-glance). -----
reset_litellm() {
  log "Restarting litellm in namespace ${ROUTING_NS}..."
  if ! oc get deployment/litellm -n "$ROUTING_NS" >/dev/null 2>&1; then
    log "  deployment/litellm not found in ${ROUTING_NS}, skipping."
    return 0
  fi
  run oc rollout restart deployment/litellm -n "$ROUTING_NS"
  if [ "$DRY_RUN" -eq 0 ]; then
    oc rollout status deployment/litellm -n "$ROUTING_NS" --timeout=180s
  fi
  log "  litellm restarted (router metric counters reset on new pods)."
}

# ----- routing-live-view: no persistent storage, just an in-memory view. A rollout restart
# is enough to clear it. -----
reset_routing_live_view() {
  log "Restarting routing-live-view in namespace ${ROUTING_NS}..."
  if ! oc get deployment/routing-live-view -n "$ROUTING_NS" >/dev/null 2>&1; then
    log "  deployment/routing-live-view not found in ${ROUTING_NS}, skipping."
    return 0
  fi
  run oc rollout restart deployment/routing-live-view -n "$ROUTING_NS"
  if [ "$DRY_RUN" -eq 0 ]; then
    oc rollout status deployment/routing-live-view -n "$ROUTING_NS" --timeout=120s
  fi
  log "  routing-live-view restarted."
}

main() {
  require_oc
  log "Targets: ticketing-system/${TRIAGE_NS}, tempo/${OBS_NS}, litellm+redis+routing-live-view/${ROUTING_NS}"
  [ "$DRY_RUN" -eq 1 ] && log "Dry-run mode: no changes will be made."
  confirm

  reset_ticketing
  reset_tempo
  reset_litellm_redis
  reset_litellm
  reset_routing_live_view

  log "Done. Reload the ticketing Route, Observe -> Traces and Dashboards (maas-routing), and routing-live-view."
  log "Alert path: first fire ~5.5m from cold; repeat webhook ~1h; or start from an agent chat UI."
}

main "$@"
