# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

This is a load-testing framework for comparing Kubernetes ingress controllers (nginx via Ingress, Istio via Gateway API). It orchestrates: spin up a Kind cluster → install a traffic controller → deploy a backend server via Helm → run vegeta load tests → collect JSON results → tear down.

## Key Commands

### Run the full test pipeline locally

```bash
# Ingress (nginx) + basic RPS
./scripts/master.sh --traffic ingress --scenario basic-rps --rate 50 --duration 30s --output-file ./results/basic_rps.json

# Gateway (istio) + basic RPS
./scripts/master.sh --traffic gateway --scenario basic-rps --rate 50 --duration 30s --output-file ./results/gateway_basic_rps.json

# Restarting backend scenario
./scripts/master.sh --traffic ingress --scenario restarting-backend-rps --rate 50 --duration 90s --output-file ./results/restarting_backend_rps.json

# With scheduling constraints (multi-node Kind cluster)
./scripts/master.sh --traffic ingress --scenario basic-rps --kind-topology scheduling-e2e --node-selector scheduling=enabled --tolerations-file ./charts/server/ci-scheduling-values.yaml --rate 50 --duration 30s --output-file ./results/scheduling_test.json
```

`master.sh` handles everything including cleanup (via EXIT trap). Requires kubectl, helm, jq, and curl on the host.

### Run individual module tests

```bash
./modules/kind/test/test.sh    # Creates/destroys a real Kind cluster
./modules/vegeta/test/test.sh  # Starts a Docker container, runs a short vegeta attack
./modules/jplot/test/test.sh   # Installs jplot (requires Go)
```

### Build the server

```bash
cd server && go build -o server
```

### Validate Helm chart templates

```bash
helm template server ./charts/server
helm template server ./charts/server --set ingress.enabled=true --set ingress.className=nginx
helm template server ./charts/server --set gateway.enabled=true --set gateway.className=istio
```

### Syntax-check shell scripts

```bash
bash -n scripts/master.sh
bash -n scripts/scenarios/basic_rps.sh
bash -n scripts/scenarios/restarting_backend_rps.sh
```

## Architecture

### Pipeline flow (master.sh)

`scripts/master.sh` is the single entry point that orchestrates these steps in order:

1. **Kind cluster** — `modules/kind/install/install.sh` + `modules/kind/run/run.sh` create a cluster with `extraPortMappings` (port 8080→80). The `--kind-topology` flag controls the cluster shape:
   - `default` — single control-plane node (current behavior)
   - `scheduling-e2e` — control-plane + one worker node labeled `scheduling=enabled` and tainted `scheduling=enabled:NoSchedule`
2. **Traffic controller** — `scripts/install/nginx.sh` (Ingress) or `scripts/install/istio.sh` (Gateway API)
3. **Server deployment** — `scripts/setup/ingress.sh` or `scripts/setup/gateway.sh` deploys `charts/server` via Helm with full readiness polling
4. **URL + readiness** — reads `host_port` from Kind's statefile, constructs the URL, then curl-probes until HTTP 200
5. **Scenario** — `scripts/scenarios/basic_rps.sh` or `scripts/scenarios/restarting_backend_rps.sh` installs vegeta and runs load tests via the vegeta module

### Module pattern

Each module under `modules/` follows the same interface:
- `install/install.sh` — installs the tool
- `run/run.sh` — runs the tool (can be sourced as a library or executed directly)
- `output/output.sh` — reads from `../statefile.json` and emits results
- `merge/merge.sh` — (vegeta only) merges multiple `.bin` files into per-second JSON output using timestamp-based bucketing
- `test/test.sh` — integration test

Modules communicate via **statefile.json** (one per module, gitignored in practice). The kind module writes `{"cluster_name": "...", "host_port": "..."}`. The vegeta module writes streaming jaggr JSON (one line per second of the test).

### Docker entrypoint

The Dockerfile entrypoint routes commands to scripts via prefix matching:
- `master [args...]` → `scripts/master.sh`
- `scenario/<name> [args...]` → `scripts/scenarios/<name>.sh`
- `install/<name> [args...]` → `scripts/install/<name>.sh`
- `setup/<name> [args...]` → `scripts/setup/<name>.sh`
- `module/<name>/<action> [args...]` → `modules/<name>/<action>/<action>.sh`
- `merge [args...]` → `modules/vegeta/merge/merge.sh`
- `server` → starts the Go HTTP server

### Scenario interface

Scenarios accept CLI arguments (`--ingress-url`, `--rate`, `--duration`, `--workers`, `--output-file`, `--request-headers`). Environment variables with the same names (uppercased, underscored) are read as defaults for backward compatibility. Each scenario installs its own dependencies (vegeta).

### Data flow for results

The vegeta run pipeline streams results in real time:

```
vegeta attack | tee statefile.bin | vegeta encode --to csv | gawk -f modules/vegeta/lib/aggregate.awk | tee statefile.json
```

This saves raw binary results to `.bin` alongside the per-second JSON. The scenario script then copies statefile.json content to the `--output-file`. The result file contains **one JSON line per second** of the test, with shape:

```json
{"rps":N,"responded_count":R_n,"response_rate":R_r,"successful_count":M,"success_rate":S_r,"code":{"hist":{...exact codes...},"family":{"0":A,"100":B,"200":C,"300":D,"400":E,"500":F}},"latency":{"p25":x,"p50":y,"p99":z},"bytes_in":{"sum":...},"bytes_out":{"sum":...}}
```

Two count/rate pairs describe distinct phases of the request lifecycle: `responded_count` / `response_rate` is how many of the `rps` requests came back as a non-0 status (server actually responded), and `successful_count` / `success_rate` is how many of the responded records were 2xx (server accepted and fulfilled the request). Latency percentiles are computed over `responded_count` records — any non-0 status is a real measurement of server response time; vegeta uses `status_code=0` for transport-level failures whose "latency" is failure-detection time. `success_rate = successful_count / responded_count`, or `0` when `responded_count` is `0` (entire bucket was transport failures). **Consumers should check `responded_count > 0` before treating `success_rate` as meaningful** — `success_rate: 0` literally means "0/0" in that case, not "0% of responses succeeded." `code.hist` preserves the exact status codes seen this second (e.g. `"200":5,"503":2`); `code.family` aggregates the same counts into hundreds families (`0`, `100`, `200`, `300`, `400`, `500`) and always emits all six keys, so downstream plotters see a stable schema. `sum(code.hist[*]) == sum(code.family[*]) == rps` is an invariant. The CI validation sums `code.hist["200"]` across **all lines** and fails only if the total is zero (i.e., no connection was ever successfully routed).

For multi-pod tests, `modules/vegeta/merge/merge.sh` combines multiple `.bin` files into unified per-second JSON. It shares the `modules/vegeta/lib/aggregate.awk` aggregator with the live runner, so live and merged outputs have identical schemas. The merge path sorts by timestamp before aggregating, so it correctly interleaves results from pods that started at slightly different times. The first and last second-buckets may be partial.

### Helm chart (charts/server)

Single chart with two mutually exclusive traffic modes controlled by values:
- `ingress.enabled=true` + `ingress.className=nginx` — creates an Ingress resource
- `gateway.enabled=true` + `gateway.className=istio` — creates Gateway + HTTPRoute resources
- `nodeSelector: {}` + `tolerations: []` — optional pod scheduling values rendered only when non-empty

`scripts/setup/ingress.sh` and `scripts/setup/gateway.sh` accept `--node-selector <key=value>` and `--tolerations-file <path>` to wire these values into the Helm release. `master.sh` also accepts these flags and passes them through to the appropriate setup script.

`--tolerations-file` must point to a Helm values fragment with a top-level `tolerations:` key, not a bare YAML list, because the chart reads `.Values.tolerations`.

The server image is `ghcr.io/azure/aks-traffic-ingress-competitive-testing` (a Go HTTP server returning "hello world!" on `/`).

### CI (validate.yaml)

The validation workflow runs on PRs to main. The `test-scenarios` job uses a matrix over `traffic: [ingress, gateway]` × `scenario: [basic-rps, restarting-backend-rps]` × `variant: [default]` — each combination gets its own runner and Kind cluster. An additional `scheduling-e2e` variant tests pod placement with node selectors and tolerations on a multi-node Kind cluster. The `test-merge` job validates multi-pod merge by running 4 simultaneous vegeta attacks against a Docker server and verifying the merged output (RPS totals, code histograms, JSON structure). The `test-dns-resources` job runs a matrix over `resource: [ingresses, httproutes]`, deploys the server chart to namespace `server`, and exercises the setup/cleanup DNS scripts with positive (count=5, asserting created/deleted via `kubectl get -n server`) and negative paths (missing service, invalid domain, count=0). Because the chart deploys into namespace `server`, all DNS script invocations must pass `--namespace server`. Other jobs: module tests (matrix over discovered modules), chart validation (including scheduling render checks), and project structure validation.

### DNS test scripts

`scripts/setup/dns-ingresses.sh`, `scripts/setup/dns-httproutes.sh`, `scripts/cleanup/dns-ingresses.sh`, and `scripts/cleanup/dns-httproutes.sh` bulk-create or delete N `Ingress` / `HTTPRoute` resources (each with a unique `test-{i}.{domain}` hostname, all labeled `dns-test=true`) for external-DNS reconciliation testing in downstream telescope pipelines (app-routing-nginx, app-routing-istio). They are intentionally **not** wired into `master.sh` — that script remains RPS-focused. The httproutes setup script requires an existing parent `Gateway`; the ingresses setup script requires an existing backend `Service`. Defaults: namespace `default`, service/gateway `server`, port `8080`. Setup scripts accept `--existing-n <N>` to offset the index range (objects are numbered `(existing-n+1)..(existing-n+count)`) so additional batches can be appended without colliding with existing hostnames. Setup scripts stream the generated multi-document YAML to a unique `mktemp` file under `$TMPDIR` (path printed at the top of the run) and apply it with a single `kubectl apply --server-side -f`. Cleanup uses label selector `dns-test=true` with `--wait=false --ignore-not-found` and leaves the parent Gateway intact.

## Conventions

- All scripts expect to be **run from the repository root**.
- All shell scripts use `set -ex` (or `set -e` for library-style scripts). Scripts with data-processing pipelines also use `set -o pipefail` so that failures in any pipeline stage propagate correctly.
- The `--traffic` flag accepts `ingress` or `gateway`. The `--scenario` flag accepts `basic-rps` or `restarting-backend-rps`.
- Releases are driven by CHANGELOG.md — the Release workflow reads it to create GitHub releases. Follow [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format.
