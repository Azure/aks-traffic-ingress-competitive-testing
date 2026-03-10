# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

This is a load-testing framework for comparing Kubernetes ingress controllers (nginx via Ingress, Istio via Gateway API). It orchestrates: spin up a Kind cluster → install a traffic controller → deploy a backend server via Helm → run vegeta load tests → collect JSON results → tear down.

## Key Commands

### Run the full test pipeline locally

```bash
# Ingress (nginx) + basic RPS
./scripts/master.sh --traffic ingress --scenario basic-rps --rate 50 --duration 30s --workers 10 --output-file ./results/basic_rps.json

# Gateway (istio) + basic RPS
./scripts/master.sh --traffic gateway --scenario basic-rps --rate 50 --duration 30s --workers 10 --output-file ./results/gateway_basic_rps.json

# Restarting backend scenario
./scripts/master.sh --traffic ingress --scenario restarting-backend-rps --rate 50 --duration 90s --workers 10 --output-file ./results/restarting_backend_rps.json
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

1. **Kind cluster** — `modules/kind/install/install.sh` + `modules/kind/run/run.sh` create a cluster with `extraPortMappings` (port 8080→80)
2. **Traffic controller** — `scripts/install/nginx.sh` (Ingress) or `scripts/install/istio.sh` (Gateway API)
3. **Server deployment** — `scripts/setup/ingress.sh` or `scripts/setup/gateway.sh` deploys `charts/server` via Helm with full readiness polling
4. **URL + readiness** — reads `host_port` from Kind's statefile, constructs the URL, then curl-probes until HTTP 200
5. **Scenario** — `scripts/scenarios/basic_rps.sh` or `scripts/scenarios/restarting_backend_rps.sh` installs vegeta and runs load tests via the vegeta module

### Module pattern

Each module under `modules/` follows the same interface:
- `install/install.sh` — installs the tool
- `run/run.sh` — runs the tool (can be sourced as a library or executed directly)
- `output/output.sh` — reads from `../statefile.json` and emits results
- `test/test.sh` — integration test

Modules communicate via **statefile.json** (one per module, gitignored in practice). The kind module writes `{"cluster_name": "...", "host_port": "..."}`. The vegeta module writes streaming jaggr JSON (one line per second of the test).

### Docker entrypoint

The Dockerfile entrypoint routes commands to scripts via prefix matching:
- `master [args...]` → `scripts/master.sh`
- `scenario/<name> [args...]` → `scripts/scenarios/<name>.sh`
- `install/<name> [args...]` → `scripts/install/<name>.sh`
- `setup/<name> [args...]` → `scripts/setup/<name>.sh`
- `module/<name>/<action> [args...]` → `modules/<name>/<action>/<action>.sh`
- `server` → starts the Go HTTP server

### Scenario interface

Scenarios accept CLI arguments (`--ingress-url`, `--rate`, `--duration`, `--workers`, `--output-file`, `--request-headers`). Environment variables with the same names (uppercased, underscored) are read as defaults for backward compatibility. Each scenario installs its own dependencies (vegeta).

### Data flow for results

Vegeta attack → `vegeta encode` → `jaggr` (aggregates per-second) → `tee` to `modules/vegeta/statefile.json`. The scenario script then copies statefile content to the `--output-file`. The result file contains **one JSON line per second** of the test. The CI validation reads the **last line** (`tail -n 1`) to check for HTTP 200 responses.

### Helm chart (charts/server)

Single chart with two mutually exclusive traffic modes controlled by values:
- `ingress.enabled=true` + `ingress.className=nginx` — creates an Ingress resource
- `gateway.enabled=true` + `gateway.className=istio` — creates Gateway + HTTPRoute resources

The server image is `ghcr.io/azure/aks-traffic-ingress-competitive-testing` (a Go HTTP server returning "hello world!" on `/`).

### CI (validate.yaml)

The validation workflow runs on PRs to main. The `test-scenarios` job uses a matrix over `traffic: [ingress, gateway]` × `scenario: [basic-rps, restarting-backend-rps]` — each combination gets its own runner and Kind cluster. Other jobs: module tests (matrix over discovered modules), chart validation, and project structure validation.

## Conventions

- All scripts expect to be **run from the repository root**.
- All shell scripts use `set -ex` (or `set -e` for library-style scripts).
- The `--traffic` flag accepts `ingress` or `gateway`. The `--scenario` flag accepts `basic-rps` or `restarting-backend-rps`.
- Releases are driven by CHANGELOG.md — the Release workflow reads it to create GitHub releases. Follow [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format.
