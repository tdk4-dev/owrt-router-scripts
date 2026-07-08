# Repository Instructions

These instructions define how AI agents and humans should work in this
repository. The project configures and ships OpenWrt router software for real
routers, including customer routers that may be outside physical reach. Treat
every installer, updater, image, package, firewall rule, Tailscale/Headscale
change, and reset flow as production-sensitive.

## Project Scope

This repository contains reusable OpenWrt router setup scripts, LuCI panels,
first-boot/setup tooling, owner-preparation tooling, VPN/Xray routing helpers,
Tailscale/Headscale integration, OpenWrt IPK packaging, custom image builds,
release staging, and VM/hardware validation assets.

Primary product surfaces:

- Custom OpenWrt images for x86/64 and Xiaomi AX3000T/RD23 where buildable.
- Package-first updates via OpenWrt `.ipk` packages and local opkg feed.
- LuCI Router UI:
  - `Network > VPN Panel`
  - `Network > Tailscale`
  - `System > Update`
  - `System > Reset`
  - `Status > Overview` VPN include/card
- First-boot customer setup wizard.
- Owner preparation panel for pre-handoff checks, policy, backup, and sealing.

## Non-Negotiable Safety Rules

- Never commit secrets.
- Never print secrets in logs, test output, release notes, screenshots, or
  generated reports.
- Never push directly to `main`.
- Never force-push shared branches unless the user explicitly asks and the risk
  is explained.
- Never push tags unless the user explicitly writes `PUBLISH RELEASE <version>`.
- Never create or edit a GitHub Release unless the user explicitly writes
  `PUBLISH RELEASE <version>`.
- Never publish, overwrite, delete, or replace release assets without explicit
  release publication approval in the current task.
- Never claim hardware verification unless the image was booted and tested on
  the actual hardware.
- Never claim VM verification unless the VM was booted from the exact release
  image/package set and the evidence was recorded.
- Never publish from a dirty worktree, feature branch, unmerged PR, untracked
  local patch, or VM-only hotfix.
- Never run a global `opkg upgrade` on customer routers.
- Never make hidden remote-access backdoors. Any owner/support access must be
  explicit, visible in the UI, revocable, and documented.

## Secret and Privacy Policy

Do not commit or persist:

- Passwords.
- Tailscale/Headscale auth keys, preauth keys, node keys, or API keys.
- Private VLESS URLs.
- Client UUIDs.
- Subscription IDs or full subscription URLs.
- Reality private keys.
- WireGuard private keys.
- SSH private keys.
- Customer names, customer device identifiers, or customer traffic logs.
- Unredacted packet captures.
- Browser screenshots containing live tokens, private URLs, QR codes, or keys.

Allowed in committed docs only when necessary and non-secret:

- Public product names.
- Example domains such as `example.com`.
- Sanitized IP examples from documentation ranges.
- Redacted identifiers such as `uuid: 12345678...hidden`.

When a task needs real secrets, use environment variables, local-only `.env`
files, secure shell input, or explicit user-provided local runtime input. Add
redaction tests when touching parsers, logs, diagnostics, export, release
notes, or evidence files.

## Git Workflow

Use one short-lived branch per task:

- `feat/<short-name>` for features.
- `fix/<short-name>` for normal fixes.
- `hotfix/<version>-<short-name>` for urgent release-line fixes.
- `docs/<short-name>` for documentation-only work.
- `test/<short-name>` for test-only work.
- `chore/<short-name>` for CI/build/refactor housekeeping.

Rules:

1. Start from the latest `origin/main` unless the user explicitly targets a
   release branch.
2. Keep hotfixes separate from feature work.
3. Do not mix unrelated docs, refactors, feature changes, and release changes.
4. Prefer small commits with clear messages.
5. Do not bump version numbers unless the task is explicitly release
   preparation.
6. Do not tag or publish during development tasks.
7. If the current worktree already contains unrelated changes, report them and
   avoid overwriting them.

Recommended flow:

```sh
git fetch --all --prune
git switch main
git pull --ff-only origin main
git switch -c feat/<short-name>
```

Before reporting completion:

```sh
git status --short
git diff --check
```

## Pull Request Expectations

Every PR or task report must include:

- Branch name.
- Base branch.
- Summary of changed behavior.
- Changed files grouped by area.
- Risk level: low / medium / high / release-critical.
- Exact tests run.
- Tests not run and why.
- VM/hardware evidence if applicable.
- Rollback path where applicable.
- Secret-safety statement.

Risk levels:

- `low`: docs, comments, formatting, static tests only.
- `medium`: LuCI UI behavior, parsing, non-critical docs/tests.
- `high`: installer, updater, package, image, first-boot, reset, firewall,
  Xray, Tailscale, AdGuard, backup/rollback, migration, authentication.
- `release-critical`: anything that can brick, lock out, disconnect, erase,
  leak, or break a remote customer router.

High-risk and release-critical changes need VM or targeted runtime validation
before merge unless explicitly deferred.

## Required Project Context Before Touching Network Behavior

For home-network, OpenWrt, VPN, DNS, DHCP, SSH alias, selfhost service,
device-topology, relay, exit-node, packet capture, or incident work:

1. Read `NETWORK_INVENTORY.md`.
2. Read `INCIDENT_LOG.md`.
3. Check existing incident history before rediscovery.
4. Preserve the distinction between verified facts, hypotheses, and fixes.
5. Update `NETWORK_INVENTORY.md` in the same task when durable topology,
   addresses, services, routes, DNS rewrites, ports, VPN policy, or SSH aliases
   change.
6. Update `INCIDENT_LOG.md` in the same task when investigating or resolving an
   outage.

If these files are absent on a public branch, treat them as local/private
operational records and ask the user before creating or publishing sanitized
versions. Do not reconstruct private inventory from memory or screenshots.

Do not start, stop, or switch macOS VPN/Network Extension services on the admin
Mac during remote recovery. That can disconnect the active management path. Use
ordinary SSH, Tailscale diagnostics, router-local checks, or remote relay hosts
unless the user explicitly authorizes a Mac VPN change for that task.

## Remote Router Safety

Before modifying any running OpenWrt router:

- Confirm target host.
- Confirm whether it is local, friend/customer, VM, or production.
- Create a full `sysupgrade -b` backup when touching config, packages, update,
  reset, network, firewall, Xray, Tailscale, AdGuard, or authentication.
- Print the backup path.
- Preserve VPN profiles, selected profile, direct rules, subscriptions, device
  bypasses, Tailscale identity, SSH keys, root password, and AdGuard state
  unless the task explicitly says to change them.
- Validate generated Xray config before restart.
- Avoid service restarts not required by the change.
- Keep a rollback command.

OpenWrt file transfer should use `ssh` + `cat` or `ssh` + `tar`. Do not assume
SFTP/SCP is available on Dropbear-based routers.

## Package-First Release Policy

Starting with v0.8.0, release installs and updates are package-first.

Package split:

- `premier-router-core`: backend scripts, update installer, VPN generation,
  health checks, reset control, cron hooks, version marker.
- `luci-app-premier-router`: LuCI views, menu entries, RPC ACLs, UI assets.
- `premier-router-setup`: first-boot setup assistant, owner preparation panel,
  reset target files, image defaults.

Rules:

- Build IPKs first.
- Build custom images from those exact IPKs.
- Do not copy package-owned application files directly into image overlays.
- Do not rebuild packages inside the image step.
- Release assets must come from one exact source commit and one exact package
  set.
- Image archives must include enough metadata to match their input IPK hashes
  to staged/released IPKs.
- The installer must verify manifest size and SHA-256 before installing.
- The installer must install only this project's packages and must not run
  global `opkg upgrade`.
- No fake package signatures. Only publish `Packages.sig` after real signing is
  implemented with private keys kept outside the repository.

## Release Gate

A release may only be published when all are true:

1. The user explicitly writes `PUBLISH RELEASE <version>` in the current task.
2. The release commit is clean and contained in `origin/main`.
3. Version files, package versions, changelog, release title, tag, image names,
   manifest, installed UI version, and footer version agree.
4. IPKs are built from the release commit.
5. Images are built from those exact IPKs.
6. `SHA256SUMS` and `router-release-manifest.json` are staged.
7. Required static/package tests passed.
8. Required VM tests passed or missing tests are explicitly listed as release
   blockers/risks.
9. RD23/Xiaomi artifacts are labeled only as static/ImageBuilder-verified
   unless actual hardware boot evidence exists.
10. Release notes include verification labels and unresolved risks.

Allowed without publication approval:

- Build local IPKs.
- Stage a local release directory.
- Build local test images.
- Produce checksums.
- Produce release candidate notes.
- Run tests.

Forbidden without publication approval:

- `git push origin vpn-panel-v*`
- `gh release create`
- `gh release upload`
- replacing existing assets
- marking a draft release as public
- editing public release notes to claim stronger verification

## Required Release Assets

Every distribution release should stage/publish:

- x86/64 custom OpenWrt image archive.
- Xiaomi AX3000T/RD23 stock-layout image archive when buildable.
- Xiaomi AX3000T/RD23 ubootmod-layout image archive when buildable.
- IPKs:
  - `premier-router-core`
  - `luci-app-premier-router`
  - `premier-router-setup`
- Installer/update script used by Update panel and legacy updater path.
- `router-release-manifest.json`.
- `SHA256SUMS`.
- Version metadata.
- Changelog/release notes.
- Local opkg feed:
  - `Packages`
  - `Packages.gz`
  - IPK files
  - optional signature only when real signing exists.

## Testing Policy

Run the smallest useful test set for normal changes, but never skip release
tests for distribution releases.

Static/package baseline:

```sh
git diff --check
sh tests/test-openwrt-ipk-packages.sh
sh tests/test-release-staging.sh
sh tests/test-router-reset-ui.sh
sh tests/test-luci-status-include.sh
sh tests/test-firstboot-root-auth.sh
sh tests/test-firstboot-vless-import.sh
sh tests/test-firstboot-wifi.sh
sh tests/test-router-prep-policy.sh
sh tests/test-vpn-ui-empty-direct-domains.sh
node tests/test-tailscale-ping-ui.mjs
```

Also run syntax checks for touched shell and JavaScript files. If a test file
does not exist on the current branch, report it instead of inventing success.

Release VM testing must follow `docs/vm-release-testing-methodology.md`.
Tailscale/Headscale registration must be tested through the GUI paths, not only
through terminal commands:

- First-boot setup wizard registration.
- LuCI Tailscale panel registration after setup skipped Tailscale.

IPK release testing must include:

- Clean IPK install on a compatible OpenWrt VM.
- Package-to-package upgrade preserving local state.
- Legacy tar.gz migration preserving local state.
- Update panel install from staged assets/test release.
- Failure simulations: corrupt checksum, missing asset, missing package, wrong
  architecture, health-check failure, network timeout.

Use verification labels precisely:

- `source-verified`
- `package-build-verified`
- `OpenWrt-runtime-verified`
- `VM-verified`
- `hardware-verified`

Do not use a stronger label unless the corresponding evidence exists.

## Customer / Owner Access Policy

The product must support different ownership modes without hidden access.

### Policy Modes

`owner-prepared-managed`

- Used when the seller prepares a router before shipping.
- Owner/support may enroll the router into a support tailnet during preparation.
- Customer-facing UI may hide advanced Tailscale settings.
- Customer must still see support-access state and be able to disable/revoke it
  through a clear control.
- Any ongoing owner/support access must be documented in the handoff notes.

`owner-prepared-standard`

- Used for non-technical customers.
- Owner performs factory prep, WAN/Wi-Fi/VPN health checks, backup, and seal.
- Customer gets a simplified UI: VPN status, server/profile controls when
  allowed, updates, reset, and support-access toggle.
- Advanced package/Tailscale/Xray settings are hidden unless policy enables
  them.

`self-managed-image`

- Used when a technical customer flashes a custom image and owns the router.
- Customer receives full root/admin control.
- No owner support tailnet enrollment is created by default.
- Tailscale panel and advanced settings are visible unless the customer chooses
  otherwise.

`manual-ipk-install`

- Used when a user installs project IPKs on an existing OpenWrt router.
- Do not change ownership policy by default.
- Do not create support access by default.
- Installer must not remove existing admin access, SSH keys, VPN state,
  Tailscale identity, AdGuard state, or local config unless explicitly asked.

`dev-vm`

- Used only for testing.
- May use temporary firewall exceptions and test-only credentials.
- Must never be described as production-safe.

### Important OpenWrt Limitation

If a customer has root SSH or full root LuCI access, UI restrictions are only
advisory because root can edit files and services directly. Real separation
requires a scoped LuCI/rpcd customer user without SSH/root privileges, while a
separate owner/root path remains for support. Do not pretend that hiding a page
from root is a security boundary.

### Support Access Principles

- No hidden owner tunnel.
- No irreversible lock-in.
- No silent re-enrollment after customer disables support access.
- No long-lived preauth keys stored after enrollment.
- Support status should be visible in LuCI and preferably in the footer/status
  card.
- Provide a one-click disable/revoke flow where possible.
- Provide an emergency local reset path.

## Footer Branding

The footer should append Router Scripts metadata to the existing LuCI/OpenWrt
footer.

Preferred format:

```text
Powered by LuCI openwrt-24.10 branch (...) / OpenWrt 24.10.5 (...) / Router Scripts vX.Y.Z (owner-prepared-standard)
```

Allowed install-mode labels:

- `owner-prepared-managed`
- `owner-prepared-standard`
- `self-managed-image`
- `manual-ipk-install`
- `dev-vm`
- `unknown`

If a shorter UI is required:

```text
Router Scripts vX.Y.Z (registered)
Router Scripts vX.Y.Z (manual installation)
```

Use `registered`, not `registred`.

`registered` must mean a clearly defined state, preferably "enrolled into an
owner/support registry or support tailnet". If that state is not implemented,
use `manual installation`, `self-managed`, or `unknown` instead.

## Owner Preparation Panel

The owner preparation panel must remain separate from the customer first-boot
wizard.

Required behavior:

- Token is retrievable only through trusted SSH/local console.
- Token is temporary and not committed.
- Panel can perform WAN/DNS/SSH/Xray/AdGuard/Tailscale health checks.
- Panel can configure support enrollment without exposing the preauth key after
  use.
- Panel can select customer policy mode.
- Panel can create a verified pre-handoff backup.
- Seal action disables/removes the preparation API from normal customer access.
- Reopening after seal requires SSH/local console.
- Sealed state and policy must survive reboot and package upgrade.
- Reset-to-setup must clear customer setup state safely.

## Authentication and RBAC Guidance

When implementing restricted customer access:

- Prefer explicit policy stored in UCI, for example
  `/etc/config/premier-router`.
- Do not rely on CSS-only hiding as a security boundary.
- Enforce permissions in backend RPC/helper commands.
- Keep dangerous actions behind root/owner permission:
  - changing Tailscale login server/auth key;
  - joining a new tailnet;
  - enabling SSH;
  - package installation/removal;
  - arbitrary command execution;
  - direct editing of Xray JSON;
  - reset/factory wipe;
  - support tunnel enrollment.
- Customer-level controls may include:
  - VPN on/off;
  - select allowed VPN profile/server;
  - update check/install when policy allows;
  - support access enable/disable;
  - read-only Tailscale status;
  - reset request when policy allows.

## Documentation Rules

Update docs in the same task when behavior changes:

- `README.md` for user-facing install/update instructions.
- `docs/custom-image-release-guide.md` for package/image/release process.
- `docs/vm-release-testing-methodology.md` for release test contract.
- `NETWORK_INVENTORY.md` for durable real network state.
- `INCIDENT_LOG.md` for incidents and live fixes.
- Release notes/changelog for user-visible changes.

Do not let docs claim a feature is production-ready unless tests/evidence match
that claim.

## Standard Task Completion Report

End every agent task with:

```text
Branch:
Base:
Commit(s):
Changed files:
Behavior changes:
Risk level:
Tests run:
Tests not run:
VM/hardware evidence:
Secrets checked:
Release impact:
Next recommended step:
```

If no commit was made, say so. If no push was made, say so. If release/tag was
not published, say so.
