# Change Log

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
