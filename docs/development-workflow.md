# Development Workflow

This project ships software that can affect routers outside physical reach.
Treat installer, updater, image, package, firewall, Xray, Tailscale, reset, and
authentication changes as production-sensitive.

## Branches

Start each task from `origin/main` unless the user explicitly targets a release
line:

```sh
git fetch origin --prune --tags
git switch main
git pull --ff-only origin main
git switch -c fix/<short-name>
```

Use one branch per task:

- `feat/<short-name>` for features.
- `fix/<short-name>` for normal fixes.
- `hotfix/<version>-<short-name>` for urgent release-line fixes.
- `docs/<short-name>` for documentation-only work.
- `test/<short-name>` for test-only work.
- `chore/<short-name>` for CI/build housekeeping.

Do not mix unrelated release, docs, feature, and refactor changes in the same
branch.

## Pull Requests

Use PRs for every change intended for `main`. A PR must record risk, changed
router state, sensitive areas touched, tests run, tests not run, VM/hardware
evidence, release impact, rollback path, and the secret-safety check.

Do not merge PRs that claim VM or hardware verification without evidence from
the exact tested build.

## VM Testing Requirements

VM testing is required before merge for changes that affect:

- first-boot/setup wizard;
- LuCI VPN, Tailscale, Update, Reset, or Status views;
- root password/authentication behavior;
- installer/update flow;
- package/IPK installation or migration;
- image defaults;
- reset-to-setup behavior.

Release VM testing must follow `docs/vm-release-testing-methodology.md`.

## Release Candidate vs Publication

Allowed during normal development:

- build local IPKs;
- stage a local release candidate directory;
- build local test images;
- produce local checksums and manifests;
- write release candidate notes.

Forbidden unless the user explicitly writes `PUBLISH RELEASE <version>`:

- push `vpn-panel-v*` tags;
- create or edit GitHub Releases;
- upload, replace, or delete public release assets;
- mark a draft release public;
- claim release verification stronger than the evidence supports.

The current legacy workflow `.github/workflows/release-vpn-panel.yml` publishes
on `vpn-panel-v*` tag pushes. Treat tag pushes as production release actions.

## Verification Labels

Use these labels exactly:

- `source-verified`: source and tests were inspected or run locally.
- `package-build-verified`: valid release packages were built and inspected.
- `OpenWrt-runtime-verified`: packages were installed on a compatible OpenWrt
  runtime and checked with real `opkg`/services.
- `VM-verified`: a VM booted from the exact release image/package set and the
  requested flows passed.
- `hardware-verified`: the image/package set booted and passed checks on the
  actual target hardware.

Do not use a stronger label unless the corresponding evidence exists.
