# Change Log

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.11] - 2026-04-23

### Added

- DNS test scripts (`scripts/setup/dns-ingresses.sh`, `scripts/setup/dns-httproutes.sh`, `scripts/cleanup/dns-ingresses.sh`, `scripts/cleanup/dns-httproutes.sh`) that bulk-create or delete N `Ingress` / `HTTPRoute` resources with unique `test-{i}.{domain}` hostnames (all labeled `dns-test=true`) for external-DNS reconciliation testing in downstream telescope pipelines
- CI `test-dns-resources` job with matrix over `[ingresses, httproutes]` covering positive (count=5) and negative paths (missing service, invalid domain, count=0)
- Docker entrypoint coverage and README/CLAUDE.md documentation for the new DNS subcommands

## [0.0.10] - 2026-04-07

### Changed

- Increased wait timeouts in `scripts/setup/gateway.sh` and `scripts/setup/ingress.sh` to 30 minutes for large-scale deployments (e.g., 50,000 replicas), including resource creation checks, readiness polling, and Helm install retries
- Removed `--timeout` from `kubectl rollout status` in both setup scripts, relying on Kubernetes' built-in `progressDeadlineSeconds` (default 600s) to detect stalls while allowing arbitrarily long rollouts that are making progress
- Gateway and HTTPRoute readiness checks now fail hard instead of silently continuing when not ready

### Fixed

- Added `kubectl wait` for Istio gateway proxy pod in `scripts/setup/gateway.sh` to prevent port-forward failures when the proxy pod is still Pending

## [0.0.9] - 2026-04-01

### Added

- Multi-pod merge script (`modules/vegeta/merge/merge.sh`) that combines multiple vegeta `.bin` files into per-second JSON output using timestamp-based bucketing
- CI `test-merge` job that validates multi-pod merge by running 4 simultaneous vegeta attacks and verifying merged output (RPS, code histograms, JSON structure)
- `gawk` added to Dockerfile base image for merge script support
- `merge` command added to Docker entrypoint routing

### Changed

- `modules/vegeta/run/run.sh` now uses a streaming tee pipeline (`vegeta attack | tee binfile | vegeta encode | jaggr`) instead of writing to a temp file then replaying, saving raw `.bin` results alongside jaggr output
- Added `set -o pipefail` to `modules/vegeta/run/run.sh` and `modules/vegeta/merge/merge.sh` so pipeline failures propagate correctly
- Expanded vegeta module tests (`.bin` file production, per-second bucketing, single-file merge, multi-file merge, synthetic percentile verification)

## [0.0.8] - 2026-03-30

### Changed

- `modules/vegeta/run/run.sh` now streams attack output to a temp file before processing, reducing memory usage from O(n) to O(buffer_size) for high-RPS workloads
- Added `sleep 2` delay after streaming vegeta results to jaggr to ensure the final time bucket is flushed before the pipe closes

## [0.0.7] - 2026-03-26

### Added

- Pod scheduling support via `--node-selector` and `--tolerations-file` flags in `scripts/master.sh`, `scripts/setup/ingress.sh`, and `scripts/setup/gateway.sh`
- Multi-node Kind topology (`--kind-topology scheduling-e2e`) that creates a control-plane node plus a labeled/tainted worker node for scheduling validation
- Pod placement verification in `master.sh` that checks server pods are scheduled on expected nodes when `--node-selector` is provided
- CI scheduling test variant that validates pod placement on multi-node Kind clusters
- Helm chart scheduling render checks in CI workflow

### Changed

- `modules/kind/run/run.sh` now accepts `--topology` flag to select cluster shape (`default` or `scheduling-e2e`)
- `scripts/install/nginx.sh` patches the ingress-nginx manifest to add control-plane tolerations to admission Jobs, fixing scheduling on multi-node Kind clusters

## [0.0.6] - 2026-03-23

### Changed

- The `--workers` flag is now optional in `scripts/master.sh` and the scenario scripts; when omitted, Vegeta uses its default worker scaling
- `modules/vegeta/run/run.sh` now uses named flags (`--target-url`, `--rate`, `--duration`, `--workers`, `--request-headers`) instead of the old positional argument interface
- Documentation and Docker examples were updated to show the named-flag Vegeta invocation format

## [0.0.5] - 2026-03-10

### Added

- Docker entrypoint routing for all scripts: `master`, `scenario/<name>`, `install/<name>`, `setup/<name>`, and `module/<name>/<action>`

### Changed

- Scenarios now accept CLI arguments (`--ingress-url`, `--rate`, `--duration`, `--workers`, `--output-file`, `--request-headers`) instead of requiring environment variables; env vars are still supported as defaults for backward compatibility
- Vegeta installation is now handled by the scenario scripts themselves rather than a separate step in master.sh
- Dockerfile updated: fixed broken `scenarios/*.sh` glob, replaced with `find`-based chmod, updated entrypoint for new script locations
- CI validation now sums HTTP 200 counts across all output intervals instead of checking only the last line, preventing false failures when a pod rollout is in progress at the end of a test

### Fixed

- Docker build failure caused by referencing removed `scenarios/` directory

## [0.0.4] - 2026-03-09

### Added

- Master orchestration script (`scripts/master.sh`) that runs the full test pipeline end-to-end: cluster creation, tool installation, traffic controller setup, server deployment, load test execution, and cleanup
- Dedicated traffic controller install scripts (`scripts/install/nginx.sh`, `scripts/install/istio.sh`)
- Dedicated server deployment scripts with readiness checks (`scripts/setup/ingress.sh`, `scripts/setup/gateway.sh`)
- Cleanup trap in master script to delete Kind cluster on exit
- HTTP readiness probe that waits for the ingress to return 200 before starting load tests
- Full traffic/scenario matrix in CI validation (ingress and gateway x basic-rps and restarting-backend-rps)

### Changed

- Moved scenarios from `scenarios/` to `scripts/scenarios/` and removed inline Helm deployment logic
- Refactored `kind/run/run.sh` to no longer install nginx (now handled by dedicated install scripts)
- Refactored `kind/output/output.sh` to expose `cluster_name` and `host_port` instead of `ingress_class` and `ingress_url`
- Refactored CI validation workflow to use `master.sh` instead of inline orchestration

### Fixed

- CI validation now reads the last line of test results instead of the first, avoiding false failures from warm-up errors

## [0.0.3] - 2025-12-01
### Added

- Gateway API CRDs
- Changes to Vegeta script to allow for header customization
- Changes to basic and restarting backend scenarios to skip helm deployment


## [0.0.2] - 2025-07-15

### Added

- replica count parameter
- restarting backend RPS scenario
- templates for Gateway API for server backend chart
- annotation configuration for service for server backend chart
- add params to basic RPS test

### Changed

- switch to JSON input for scenario parameters


## [0.0.1] - 2025-07-02

### Added

- Initial release 🚢
- Basic rps scenario
- HTTP hello world backend server and chart
- jplot, kind, and vegeta modules
