# Change Log

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
