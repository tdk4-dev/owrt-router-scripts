# Premier Router VM Release Testing Methodology

Last updated: 2026-07-08

This document is the release testing contract for Router UI / Premier Router
releases. A release is not ready for publication until the relevant checklist
below has been executed and the evidence is recorded.

## Release Rule

- Production release commits must be contained in `origin/main` before tagging.
- Do not publish from a dirty worktree, feature branch, unmerged PR, or local
  VM-only patch.
- Do not create a GitHub release, push a tag, or publish artifacts unless the
  user explicitly writes `PUBLISH RELEASE <version>` in the current task.
- Release assets must be built from one exact commit and one exact package set.
- Do not overwrite router configuration, VPN profiles, secrets, Tailscale
  identity, or generated state during upgrade tests.

## Expected Release Assets

Every distribution release should contain:

- x86/64 custom OpenWrt image archive.
- Xiaomi AX3000 / RD23 compatible image archive for stock layout, when buildable.
- Xiaomi AX3000 / RD23 compatible image archive for ubootmod layout, when buildable.
- OpenWrt IPK packages for installing/upgrading a running router:
  - `premier-router-core`
  - `luci-app-premier-router`
  - `premier-router-setup`
- Installer or updater script used by the Update panel / legacy updater path.
- Machine-readable release manifest.
- `SHA256SUMS`.
- Changelog and version metadata.
- Local opkg feed output:
  - `Packages`
  - `Packages.gz`
  - package files
  - optional signature only when real signing is configured.

Images must include the exact same IPKs that are attached as release assets.
Do not copy application files directly into an image if those files are owned by
the project packages.

## Developed Feature Inventory

### Router UI / LuCI

- Network > VPN panel.
- Network > Tailscale panel.
- System > Update panel.
- System > Reset panel.
- Status overview VPN card/include.
- Footer branding: `Router Scripts vX.Y.Z`.
- Stable LuCI asset names:
  - `network/vpn.js`
  - `network/tailscale.js`
  - `system/update.js`
  - `system/reset.js`
  - `status/include/35_vpn.js`
  - `status/include/_35_vpn.js`
- Transitional legacy LuCI asset aliases for older updaters.

### VPN Features

- Direct VLESS link import.
- HTTPS subscription link import.
- Subscription refresh and removal.
- Profile list with selected profile highlighting.
- Profile switching.
- Active profile health check through SOCKS/Xray.
- Saved profile endpoint TCP reachability display.
- Xray config generation and validation.
- Xray global on/off.
- Per-device VPN bypass using active DHCP leases.
- Direct routing rules for domains and IP addresses.
- Direct-domain empty-list guard for Xray 25+.
- Notification deduplication so repeated actions do not stack banners.
- Automatic server switching:
  - failover after repeated failed checks;
  - periodic optimization only when a materially faster server exists;
  - user-selected eligible pool.

### Runtime Maintenance

- Xray access/error log size caps under `/tmp`.
- AdGuardHome querylog hardening for OpenWrt tmpfs:
  - `querylog.interval: 24h`
  - `querylog.file_enabled: false`
  - accumulated tmpfs querylog cleanup.

### First-Boot Setup

- Account setup and root password setting.
- Authorized SSH keys.
- LAN defaults.
- Wi-Fi setup screen and disabled/no-radio path.
- VPN setup with direct VLESS or HTTPS subscription link.
- AdGuard filter selection.
- Tailscale/Headscale setup prompts.
- Review/apply progress state.
- Durable setup progress behavior.
- Success screen links.
- Reset note: router reset is available in System > Reset.

### Router Preparation / Dev Flow

- Dev/prep policy controls for customer-facing feature availability.
- Optional hiding/disabling of customer panels such as Tailscale.
- Wi-Fi placeholder/prep controls.
- Setup reset back to first-boot assistant.

### Package / Image / Update System

- Package-first OpenWrt IPK build.
- Local opkg feed generation.
- Release staging manifest and checksum generation.
- Legacy tar.gz migration compatibility path.
- Update panel with check/install/status.
- Automatic weekly update scheduling.
- Backups and rollback instructions.

## Mac Pro VM Test Environment

Use the Mac Pro as the VirtualBox host for release testing.

Recommended VM layout:

- Keep the long-running 0.8 development VM untouched unless testing that exact
  branch.
- Create one fresh VM per release candidate, named with the version, for
  example `PremierRouter-0.8.0-rc1-x86`.
- Use the built x86 image archive as the VM disk.
- Use a NAT adapter with explicit port forwards for browser testing:
  - host `127.0.0.1:8787` -> guest `80`
  - host `127.0.0.1:2225` -> guest `22`
  - host `127.0.0.1:3000` -> guest `3000` when AdGuardHome is included
- Do not change Mac Pro host IP addresses for VM testing.
- If LAN reachability from other machines is required, use VirtualBox NAT
  forwarding or a VM network mode that does not require host IP changes.

Record for every VM run:

- VM name.
- Image filename and SHA-256.
- Source commit.
- Project IPK filenames and SHA-256 hashes.
- OpenWrt version.
- Router UI version.
- Test start/end time.
- Exact failure logs if any step fails.

## Fresh Image Runtime Test

For every x86 release candidate:

1. Import or recreate the VirtualBox VM from the built x86 image.
2. Boot and wait for HTTP/SSH availability.
3. Open setup wizard through the forwarded URL.
4. Complete first-boot setup with:
   - root password;
   - at least one SSH public key when available;
   - Wi-Fi disabled path if no radio exists;
   - AdGuard filters selected;
   - VPN enabled with direct VLESS link;
   - VPN enabled with HTTPS subscription link in a separate run;
   - Tailscale disabled path;
   - Tailscale enabled path in a separate run.
5. Verify setup completion:
   - LuCI login works with the configured password;
   - Status page loads without JS/XHR errors;
   - footer includes `Router Scripts vX.Y.Z`;
   - AdGuardHome loads;
   - VPN panel loads;
   - Tailscale panel loads or is hidden according to policy;
   - Update panel loads;
   - Reset panel loads.
6. Verify reset:
   - confirm reset in System > Reset;
   - browser is redirected or recoverable to setup;
   - previous root password no longer authenticates;
   - setup wizard is available again;
   - no ugly/intermediate unstyled screen is left visible.

## VPN Panel Functional Test

Run these checks after setup:

1. Import a direct VLESS link.
2. Import a subscription URL.
3. Confirm subscription profile count.
4. Refresh profile pings.
5. Select at least three profiles from the subscription.
6. For each selected profile:
   - `vpn-ui check` is OK;
   - Xray service is running;
   - SOCKS egress changes to the expected server IP;
   - HTTP connectivity through SOCKS works;
   - LuCI selected row updates.
7. Verify endpoint pings are not misrepresented as full VPN health.
8. Add direct domain rules and apply them.
9. Add direct IP rules and apply them.
10. Toggle global Xray off/on.
11. Test per-device bypass:
    - list DHCP leases;
    - disable VPN for one device/MAC;
    - confirm rule is present;
    - enable again;
    - confirm rule is removed.
12. Enable failover auto-switch with a small selected pool.
13. Simulate unreachable current profile and confirm switch to a pool member.
14. Enable periodic optimization and confirm it does not flap between similar
    latency servers.
15. Confirm yellow notifications never stack beyond one visible banner.

## Tailscale / Headscale GUI Test

This must be tested through the GUI, not only through terminal commands.

Run at least two separate VM tests:

### Setup Wizard Registration

1. Start from a fresh setup state.
2. Enable Tailscale in the setup wizard.
3. Enter the login server URL.
4. Enter a short-lived reusable preauth key.
5. Apply setup.
6. Verify:
   - `tailscale status` shows the VM/router online;
   - the expected tailnet/headscale node appears server-side;
   - LuCI Tailscale panel shows connected state;
   - tailnet IP is displayed;
   - SSH/LuCI access over tailnet works if routing permits it.

### LuCI Tailscale Panel Registration

1. Start from a setup where Tailscale was skipped.
2. Open Network > Tailscale.
3. Configure login server and preauth key through the panel.
4. Start/login from the panel.
5. Verify the same connected-state checks as above.
6. Logout/disable through the panel if supported.
7. Confirm customer policy can hide or disable this panel when needed.

Use disposable auth keys. Do not commit keys or store them in logs.

## IPK Runtime Tests

IPK testing is required in a VM before release.

### Clean IPK Install

1. Boot a clean compatible OpenWrt 24.10.5 x86 VM without project files.
2. Copy or serve the release IPKs.
3. Install in dependency order:
   - `premier-router-core`
   - `luci-app-premier-router`
   - `premier-router-setup`
4. Verify:
   - `opkg status` shows the expected versions;
   - `opkg files` owns project files;
   - LuCI pages are available;
   - setup wizard is available;
   - footer version appears;
   - services and cron jobs are configured;
   - no generated secrets, logs, backups, VLESS URLs, or machine identity are
     included in package contents.

### Package-To-Package Upgrade

1. Install an older package-managed version.
2. Configure VPN, rules, Tailscale, AdGuard, and customer policy.
3. Upgrade to the release candidate IPKs.
4. Verify:
   - conffiles are preserved;
   - user VPN profiles survive;
   - selected profile survives;
   - Tailscale identity survives;
   - AdGuard selections survive unless intentionally changed;
   - service restarts are minimal and expected;
   - repeated install is idempotent.

### Legacy Tar.gz Migration

1. Create a VM that represents a real legacy `luci-vpn-ui.tar.gz` install.
2. Include representative user config:
   - VLESS profiles;
   - selected profile;
   - direct rules;
   - subscription metadata;
   - device bypass list;
   - update settings.
3. Run the new installer/update path.
4. Verify:
   - legacy install is detected;
   - backup is created;
   - packages become opkg-owned;
   - only allowlisted obsolete files are removed;
   - unrelated files survive;
   - UI/services work;
   - second run is idempotent.

## Update Panel Test

Before publishing a release:

1. Point a VM/router at the staged release assets or a test release.
2. Open System > Update.
3. Run Check again.
4. Confirm latest version, changelog, release date, and availability are correct.
5. Click Download and install.
6. Watch progress states.
7. Verify:
   - backup path is shown;
   - install succeeds;
   - current version changes;
   - no stale failure message remains;
   - LuCI reloads cleanly;
   - status include still loads;
   - stable LuCI assets and legacy transition aliases behave as expected.

Failure simulations:

- corrupt checksum;
- missing asset;
- missing package;
- wrong architecture;
- health-check failure;
- network timeout.

Expected behavior:

- installation stops;
- error is actionable;
- no silent fallback;
- backup path is printed;
- recovery command is valid;
- router remains reachable.

## Image Build Validation

For each image archive:

1. Confirm image artifact name includes:
   - project version;
   - OpenWrt version;
   - target/subtarget/profile.
2. Confirm manifest includes:
   - source commit;
   - source dirty flag;
   - package hashes;
   - image input IPK hashes.
3. Confirm the image used the exact release IPKs:
   - compare recorded image input hashes to staged IPK hashes.
4. For x86:
   - boot in VirtualBox and run the full runtime checklist.
5. For RD23/Xiaomi AX3000:
   - perform static ImageBuilder validation;
   - inspect included packages and metadata;
   - do not claim hardware verification unless booted on actual hardware.

## Evidence Template

Record results in the release notes or an incident/release validation file:

```text
Version:
Commit:
OpenWrt version:
Image artifacts:
IPK artifacts:
SHA256SUMS:
VM name:
VM host:
Setup wizard:
LuCI status:
VPN panel:
Subscription import:
Profile switching:
Direct rules:
Device bypass:
Tailscale setup wizard registration:
Tailscale panel registration:
Update panel:
Reset:
IPK clean install:
IPK upgrade:
Legacy migration:
Failure simulations:
RD23 static validation:
Unresolved risks:
Release decision:
```

Use these status labels:

- `source-verified`
- `package-build-verified`
- `OpenWrt-runtime-verified`
- `VM-verified`
- `hardware-verified`

Do not use a stronger label unless the corresponding runtime evidence exists.
