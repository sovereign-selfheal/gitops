# Known issues

Problems of the platform components that the demo works around. Each entry says what fails, the
workaround in this repo and how to check if it is still needed.

## Token budgets count POST requests only (RHCL 1.4.3)

**Problem.** The TokenRateLimitPolicy of `components/frontdoor` counts tokens from the response:
`responseBodyJSON("/usage/total_tokens")`. Kuadrant turns each tier into two actions of its wasm
module on the gateway: a check on the request and a report on the response. The actions of all
tiers run in one list, in alphabetical order of the tier names.

A response without `usage` (for example `GET /v1/models`) makes the report fail
(Envoy log: `Missing json property: /usage/total_tokens`, then `Task failed`). When the failed report
is the last action of the list (today the tier `research`), the response ends normally. When it is
not the last one (today `agents` and `legal`), Envoy never ends the response (access log:
`DC downstream_remote_disconnect`). The client gets the full body, but the next request on the same
HTTP/1.1 keep-alive connection waits forever.

**Effect seen on 2026-10-02 (ocp.48hlt).** At startup, OGX of the triage-agent (tier `agents`) sends
two `GET /v1/models` on one connection. The second one never got an answer, OGX never started and
the liveness probe restarted the pod in a loop. Validation did not see it: it uses the tier
`research` and opens a new connection for each request.

**Workaround.** Each tier has the extra condition `request.method == 'POST'`. Only inference calls
are counted, and their responses always have `usage` (also when streamed). `GET /v1/models` and the
other GET requests no longer run the report. Authentication (AuthPolicy) does not change.

**Check if it is still needed.** After an RHCL upgrade, remove the condition and send two requests
on one connection with an `agents` or `legal` key:

```bash
curl -s --http1.1 -m 10 -H "Authorization: Bearer <agents key>" \
  -o /dev/null -o /dev/null -w "%{http_code} %{time_total}s\n" \
  https://router.<appsDomain>/v1/models https://router.<appsDomain>/v1/models
```

Both must answer `200`. With the bug, the second one ends with `000` after the timeout.
