# Package-First OpenWrt Release Guide

This project now releases router software as OpenWrt packages first. Complete
custom images are built from the exact same `.ipk` files that are staged as
standalone update assets.

## Release Gate

Do not create a GitHub release, push a tag, or publish artifacts until the user
explicitly writes `PUBLISH RELEASE <version>` in the current task.

Before publication:

1. Work from a clean release commit contained in `origin/main`.
2. Verify that the tag, release title, changelog, package versions, installed
   UI version, image names, and release manifest all agree.
3. Build packages from the exact release commit.
4. Build images by installing those exact packages into ImageBuilder.
5. Run package, image, migration, and release validation.
6. Stage assets locally and show checksums before publishing.

## Package Split

The v0.8.0 package split is intentionally small:

- `premier-router-core`: backend scripts, update installer, VPN generation,
  health checks, reset control, cron hooks, and version marker.
- `luci-app-premier-router`: LuCI views, menu entries, RPC ACLs, and UI assets.
- `premier-router-setup`: first-boot setup assistant, owner preparation panel,
  reset target files, and image defaults.

All three are architecture-independent OpenWrt packages and currently use
`Architecture: all`.

## Local Dry Run

Build IPKs and the local opkg feed:

```sh
./scripts/build-openwrt-ipks.sh
```

Stage a complete local release directory without publishing:

```sh
./scripts/stage-router-release.sh
```

The staged directory is:

```text
dist/release-v<APP_VERSION>/
```

It contains the package files, opkg feed index files, installer script,
version/changelog/date metadata, `router-release-manifest.json`, and
`SHA256SUMS`. Image archives are included when matching image archives already
exist in `dist/`.

## Fresh Installation and Recovery Images

Build images on an x86_64 Linux host. First build the project IPKs with
`./scripts/build-openwrt-ipks.sh`. The image scripts then add those already
built IPKs to the local ImageBuilder package feed and install the package names
into the image. Do not copy package-owned files directly into rootfs overlays,
and do not rebuild packages inside the image step.

### x86/64

```sh
OPENWRT_VERSION=24.10.5 \
TARGET_DIR=x86/64 \
PROFILE=generic \
PACKAGE_FILE=image/openwrt-fin0-packages.txt \
ARTIFACT_PREFIX=premier-router-0.8.0-openwrt-24.10.5-x86-64 \
./build-openwrt-custom-image-linux.sh
```

### Xiaomi AX3000T / RD23 Stock Layout

```sh
OPENWRT_VERSION=24.10.5 \
TARGET_DIR=mediatek/filogic \
PROFILE=xiaomi_mi-router-ax3000t \
PACKAGE_FILE=image/openwrt-rd23-packages.txt \
ARTIFACT_PREFIX=premier-router-0.8.0-openwrt-24.10.5-mediatek-filogic-xiaomi-ax3000t-stock \
./build-openwrt-custom-image-linux.sh
```

### Xiaomi AX3000T / RD23 U-Boot Layout

```sh
OPENWRT_VERSION=24.10.5 \
TARGET_DIR=mediatek/filogic \
PROFILE=xiaomi_mi-router-ax3000t-ubootmod \
PACKAGE_FILE=image/openwrt-rd23-packages.txt \
ARTIFACT_PREFIX=premier-router-0.8.0-openwrt-24.10.5-mediatek-filogic-xiaomi-ax3000t-ubootmod \
./build-openwrt-custom-image-linux.sh
```

Each image artifact archive includes `router-ui-packages.txt` and
`project-ipk-sha256sums` so the package inputs can be matched to staged release
assets.

## Updating a Running Router

Manual package-first update:

```sh
ROUTER_UI_VERSION=0.8.0 sh install-router-ui-release.sh
```

The installer downloads `router-release-manifest.json`,
`router-ui-packages.txt`, and the referenced IPKs. It verifies SHA-256 and size
before calling `opkg install` in dependency order. It does not run global
`opkg upgrade`.

Future feed-based update can use the generated feed directory:

```text
dist/opkg-feed/Packages
dist/opkg-feed/Packages.gz
dist/opkg-feed/*.ipk
```

No package signing key is configured in this repository. Do not fake
`Packages.sig`; enable signing only with a real private key kept outside the
repo.

## Legacy tar.gz Migration

Routers that received v0.7.5 through `luci-vpn-ui.tar.gz` have unowned files on
disk. The package-first installer detects this state, creates a full
`sysupgrade -b` backup, backs up known legacy files to a migration snapshot,
removes only the explicit legacy allowlist, installs IPKs, and validates the
result.

Preserved local state includes UCI configuration, Xray/VLESS profiles,
subscription data, direct routing rules, device bypass lists, AdGuard state,
Tailscale state, root password, and SSH keys. Logs, caches, generated backups,
private keys, and local secrets are not packaged.

The deprecated tar.gz fallback exists only for older releases that do not
publish package metadata. New v0.8.0+ releases must publish IPKs.

## Validation Checklist

Run static and package checks:

```sh
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

For x86 VirtualBox validation, reinstall from the staged image archive and
verify:

- `http://10.20.0.181:8787/setup/`;
- setup wizard end to end;
- LuCI Status;
- `Network > VPN Panel`;
- `Network > Tailscale`;
- `Update`;
- `System > Reset`;
- reset returns to setup;
- `opkg status` reports the staged package versions.

For RD23 targets, perform static ImageBuilder validation until hardware boot
testing is available.

## Rollback and Recovery

Every running-router update creates a verified full OpenWrt backup under:

```text
/root/router-ui-backups/
```

Legacy migrations also create:

```text
/root/router-ui-backups/router-ui-migration-<version>-<timestamp>/
```

If a package install or validation step fails, the installer removes the
project packages where possible, restores backed-up legacy files, restarts LuCI
services, and exits with an actionable error. Full system recovery remains
available through the `sysupgrade` backup.
