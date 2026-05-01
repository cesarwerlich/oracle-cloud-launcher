# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-05-01

### Changed (BREAKING)
- **Account-agnostic naming convention.** All committed identifiers now use
  generic keys (`account-a`, `account-b`, …) instead of leaking your real
  account names. Workflow files renamed:
  - `.github/workflows/oracle-gmx.yml` → `.github/workflows/oracle-account-a.yml`
  - `.github/workflows/oracle-cdw.yml` → `.github/workflows/oracle-account-b.yml`
- **GitHub Secrets migrated to GitHub Environments.** Each account corresponds
  to a GitHub Environment (`account_a`, `account_b`) with same-named secrets
  (`OCI_USER`, `OCI_TENANCY`, `INSTANCE_NAME`, `ACCOUNT_LABEL`, …) instead of
  prefixed repo-level secrets (`GMX_OCI_USER`, `CDW_OCI_USER`, …).
- Local `accounts/<key>.env` files renamed to match (gitignored either way).
- Friendly account labels (e.g. `🇩🇪 GMX`) now live exclusively in
  `ACCOUNT_LABEL` — set in the env file (local) or environment secret (CI).
  They appear in Telegram messages but are never committed.

### Added
- `.github/dependabot.yml` — weekly auto-update PRs for GitHub Actions versions.

### Migration

Existing users:

1. Rename your local files: `mv accounts/gmx.env accounts/account-a.env`
   (and the same for any others).
2. Re-install launchd jobs under the new keys:
   ```
   ./scripts/install-launchd.sh uninstall gmx
   ./scripts/install-launchd.sh install account-a 0 30
   ```
3. In GitHub: create environments `account_a` / `account_b`, move each old
   `<ACCT>_*` repo secret to its environment as the un-prefixed name, then
   delete the old repo secrets.

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

[Unreleased]: https://github.com/cesarwerlich/oracle-cloud-launcher/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/cesarwerlich/oracle-cloud-launcher/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/cesarwerlich/oracle-cloud-launcher/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/cesarwerlich/oracle-cloud-launcher/releases/tag/v1.0.0
