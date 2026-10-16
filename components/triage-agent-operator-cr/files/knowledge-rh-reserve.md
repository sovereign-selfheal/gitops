# Application Knowledge Base — rh-reserve-buggy-app

## Overview

**Application name:** `rh-reserve-buggy-app`  
**Namespace:** one instance per namespace. Use the namespace of the alert (label `namespace`) or the one named in the question, and put it in place of `<namespace>` in every query and command below. Only when neither gives a namespace, use `agentic-triage` as the fallback instance name.  
**Technology:** Quarkus 3.8 (Java), RESTEasy Reactive, Micrometer + Prometheus metrics, SmallRye Health  
**Purpose:** HTTP API for product catalog, orders, and inventory. All HTTP errors, elevated latency, and pod instability are **production incidents** until you have evidence otherwise.

**How to use this document:** Gather symptoms from alerts, Prometheus, and pod logs. Compare patterns (status codes, URIs, log signatures, metric shapes) to the **Known failure modes** section. When a pattern matches, follow that entry’s diagnosis and remediation. When nothing matches, treat the situation as an unknown defect or infrastructure issue and continue root-cause analysis.

---

## Incident ticket caller

When calling `create_incident`, always set `caller_id` to `triage-agent-<namespace>` —
substitute `<namespace>` the same way as elsewhere in this document (the alert's
`namespace` label, the namespace named in the question, or the `agentic-triage`
fallback). Do not leave `caller_id` at the tool's default (`ocp-troubleshooter`):
the caller must identify which agent instance opened the ticket. `add_work_note`
has no `caller_id` field; this only applies to `create_incident`.

---

## Deployment Topology

| Resource | Details |
|----------|---------|
| Deployment | `rh-reserve-buggy-app` in namespace `<namespace>` |
| Service | `rh-reserve-buggy-app` port 8080 (HTTP) |
| Route | `rh-reserve-buggy-app-<namespace>.<appsDomain>` |
| Replicas | 1 |
| Container port | 8080 |
| Health endpoints | `/q/health/live` (liveness), `/q/health/ready` (readiness) |
| Metrics endpoint | `/q/metrics` (Prometheus format) |
| Image | `quay.io/sovereign-selfheal/quarkus-buggy-app` (pinned by digest, see gitops `components/quarkus-buggy-app`) |

---

## REST Endpoints (expected behaviour)

### GET /api/products
- **Purpose:** Returns a list of products
- **Healthy behaviour:** HTTP 200 with JSON array of products
- **Symptoms often reported:** Intermittent HTTP 500
- **Typical log signature:** `java.lang.NullPointerException` in `ProductResource.getProducts()`
- **Useful Prometheus signal:** `http_server_requests_seconds_count{uri="/api/products", status="500"}` elevated or increasing

### GET /api/orders
- **Purpose:** Returns a list of orders
- **Healthy behaviour:** HTTP 200 with low latency (roughly tens of milliseconds under normal load)
- **Symptoms often reported:** Slow responses without HTTP errors
- **Typical log signature:** Often no errors; latency visible only in metrics
- **Useful Prometheus signal:** High ratio `http_server_requests_seconds_sum{uri="/api/orders"}` / `_count` (e.g. hundreds of ms to seconds)

### GET /api/inventory
- **Purpose:** Returns current inventory levels
- **Healthy behaviour:** HTTP 200 with JSON inventory data
- **Symptoms often reported:** Intermittent HTTP 503 Service Unavailable
- **Typical log signature:** May show no stack trace (application returns 503 without throwing)
- **Useful Prometheus signal:** `http_server_requests_seconds_count{uri="/api/inventory", status="503"}` elevated or increasing

---

## Background traffic

The application runs an internal `TrafficGenerator` every 5 seconds (after a 10-second startup delay) and calls all three endpoints on `localhost:8080`. Metrics can show request volume and error rates **without external clients**. A `Running` pod with passing health checks can still exhibit non-zero error rates if the application or its dependencies are unhealthy.

---

## Key Prometheus Queries

| What to check | PromQL |
|---------------|--------|
| HTTP 5xx rate (all endpoints) | `rate(http_server_requests_seconds_count{namespace="<namespace>",outcome="SERVER_ERROR"}[5m])` |
| HTTP 500 rate on /api/products | `rate(http_server_requests_seconds_count{namespace="<namespace>",uri="/api/products",status="500"}[5m])` |
| HTTP 503 rate on /api/inventory | `rate(http_server_requests_seconds_count{namespace="<namespace>",uri="/api/inventory",status="503"}[5m])` |
| Avg latency on /api/orders | `rate(http_server_requests_seconds_sum{namespace="<namespace>",uri="/api/orders"}[5m]) / rate(http_server_requests_seconds_count{namespace="<namespace>",uri="/api/orders"}[5m])` |
| Avg latency all endpoints | `rate(http_server_requests_seconds_sum{namespace="<namespace>"}[5m]) / rate(http_server_requests_seconds_count{namespace="<namespace>"}[5m])` |
| Request rate (all endpoints) | `rate(http_server_requests_seconds_count{namespace="<namespace>"}[5m])` |
| Pod restarts | `kube_pod_container_status_restarts_total{namespace="<namespace>"}` |
| Pod ready | `kube_pod_status_ready{namespace="<namespace>"}` |

---

## Service level objectives

| Endpoint | Target |
|----------|--------|
| /api/products | 99% availability (minimal HTTP 500 rate) |
| /api/inventory | 99% availability (minimal HTTP 503 rate) |
| /api/orders | 99% of requests with p99 latency under 500 ms |

Deviations from these targets require investigation and remediation recommendations.

---

## Known failure modes

Match observed symptoms to one of these entries when the pattern fits. If multiple entries could apply, use metrics and logs to separate per-URI behaviour.

### 1. NullPointerException on GET /api/products
- **Pattern:** HTTP 500 on `/api/products`, `SERVER_ERROR` in Prometheus, stack traces mentioning `ProductResource.getProducts()`
- **Likely root cause:** Null dereference in product listing logic (missing null guard or uninitialized dependency)
- **Remediation:** Add defensive null checks and validate upstream data in `ProductResource.java`; redeploy after fix; verify 500 rate drops toward zero

### 2. HTTP 503 on GET /api/inventory
- **Pattern:** HTTP 503 on `/api/inventory` without necessarily a Java stack trace in logs
- **Likely root cause:** Inventory backend or integration unavailable, or application logic returning unavailable when dependency health check fails
- **Remediation:** Verify dependency connectivity and access configuration; inspect `InventoryResource` and related clients; restore downstream service or fix integration configuration

### 3. High latency on GET /api/orders
- **Pattern:** HTTP 200 but elevated average or p99 latency on `/api/orders`; outcome may still be `SUCCESS` in metrics
- **Likely root cause:** Slow downstream dependency (database, remote API) or blocking work on the request path (e.g. long waits in `OrderResource`)
- **Remediation:** Trace slow calls in `OrderResource.getOrders()`; tune timeouts; fix or scale the downstream dependency; confirm latency returns under SLO

### 4. Pod CrashLoopBackOff
- **Pattern:** Pod not stable; `CrashLoopBackOff`, `OOMKilled`, `ImagePullBackOff`, or repeated restarts
- **Likely root cause:** OOMKill (JVM heap vs limits), missing or wrong image, bad environment configuration
- **Remediation:** `oc describe pod` and events; adjust memory limits or JVM settings; fix image pull or config

### 5. No metrics in Prometheus
- **Pattern:** PromQL for this namespace returns empty series while the workload should be running
- **Likely root cause:** ServiceMonitor missing or mislabeled, pod not running, or scrape target mismatch
- **Remediation:** Check `oc get servicemonitor -n <namespace>` and Service labels; ensure pod is `Running` and metrics port is reachable

---

## Troubleshooting checklist

When diagnosing `rh-reserve-buggy-app`:

1. **Pod phase** — `Running` with 0 restarts is healthy; any other state is a problem
2. **Prometheus** — run the queries above; note which URIs and status codes are affected
3. **Correlate URI and symptom** — products (500/NPE), inventory (503), orders (latency) produce distinct signatures
4. **Pod logs** — search for `NullPointerException` and other exceptions; absence of stack traces with 503s still points at the inventory path
5. **Map to known failure modes** — if metrics and logs match an entry above, cite it and propose that remediation; if not, continue open-ended RCA (config, resources, platform)
6. **Quantify impact** — report error rates and latency (average and, when available, percentiles) from Prometheus
