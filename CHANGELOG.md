# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.1] - 2026-05-01

### Changed
- Out-of-capacity (all ADs exhausted) now exits 0 instead of 1 — this is the
  expected steady-state for free-tier ARM and shouldn't mark GitHub Actions
  / launchd runs as failed. Truly fatal errors (auth, missing config) still
  exit 1.

## [1.0.0] - 2026-05-01

### Added
- Multi-account architecture: `oracle-launch.sh <account>` reads `accounts/<account>.env`
- Per-account isolation: lock file, log file, and OCI profile keyed by account name
- Telegram notifications with account-prefixed messages
- macOS launchd templates and installer script (`scripts/install-launchd.sh`)
- GitHub Actions workflows for unattended cloud-side scheduling (one per account)
- Staggered scheduling: GMX at `:00`/`:30`, CDW at `:15`/`:45`
- Idempotency check: skips creation if a non-terminated instance already exists
- AD rotation across retries within a single run
- Rate-limit (HTTP 429) backoff and connection-timeout handling
- Documentation for both deployment paths (local launchd + GitHub Actions)

### Security
- Secrets read from per-account `.env` files (gitignored) or from GitHub Secrets in CI
- OCI API keys never committed; `~/.oci/config` synthesized per workflow run

[Unreleased]: https://github.com/cesarwerlich/oracle-cloud-launcher/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/cesarwerlich/oracle-cloud-launcher/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/cesarwerlich/oracle-cloud-launcher/releases/tag/v1.0.0
