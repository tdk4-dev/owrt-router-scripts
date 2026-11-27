# Custom Image and Package Release Guide

This guide describes the package-first release model planned for v0.8.0 and
later. It is a release contract, not evidence that a release has passed.

## Build Order

1. Resolve `APP_VERSION` and `OPENWRT_VERSION`.
2. Build project IPKs from the exact source commit:
   - `premier-router-core`
   - `luci-app-premier-router`
   - `premier-router-setup`
3. Validate package metadata, file ownership, conffiles, dependencies,
   permissions, and absence of secrets/runtime state.
4. Copy those exact IPKs into the OpenWrt ImageBuilder package source.
5. Build every custom image from those exact IPKs.
6. Record input IPK SHA-256 hashes in image metadata and
   `router-release-manifest.json`.
7. Stage release assets, `SHA256SUMS`, release notes, and local opkg feed files.

Do not copy package-owned application files directly into rootfs overlays when
the same files are provided by IPKs.

## Fresh Installation / Recovery

Fresh installation uses a complete image archive for the target:

- x86/64 OpenWrt image archive;
- Xiaomi AX3000T/RD23 stock-layout archive when buildable;
- Xiaomi AX3000T/RD23 ubootmod-layout archive when buildable.

An image may be labeled `hardware-verified` only after booting and testing on
the actual target hardware.

## Updating a Running Router

Running-router updates use project IPKs installed through `opkg`. The updater
must:

- download a manifest;
- verify file size and SHA-256;
- install only this project's packages;
- never run global `opkg upgrade`;
- preserve user configuration and runtime identity;
- run health checks after installation;
- print backup and recovery instructions on failure.

## Legacy tar.gz Migration

Routers installed from `luci-vpn-ui.tar.gz` must be migrated carefully:

- detect legacy unmanaged files;
- create a backup before changes;
- preserve UCI configuration, VPN profiles, subscriptions, selected profile,
  direct rules, device bypasses, Tailscale identity, SSH keys, root password,
  and AdGuard state;
- remove only allowlisted obsolete legacy files;
- install IPKs so future files are package-owned;
- verify UI and services after migration.

Do not recursively delete broad directories to clean legacy installs.

## Publication Gate

Publication is allowed only when the user explicitly writes
`PUBLISH RELEASE <version>` in the current task and the release commit is clean,
contained in `origin/main`, fully staged, checksum-verified, and tested.

Without that approval, local release candidates, images, packages, manifests,
and checksums may be built for testing only.
