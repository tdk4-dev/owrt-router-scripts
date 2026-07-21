Router UI 0.7.11

Router UI 0.7.11 is an updater migration bridge built from the exact 0.7.10
product baseline. It introduces canonical OpenWrt packages, signed release
metadata, target-owned validation, persistent recovery, exact rollback, and a
generic fail-closed legacy rescue path. It intentionally contains no 0.8
product features.

The active production identity is the locally managed usign key
`production-2026-07`. Only its public key and derived fingerprint are present
in release assets; the private key remains confined to the protected Mac Pro
signing environment and RAM-backed build-VM signing sessions. Routers that
trusted only the lost former identity require the documented authenticated
public-key bootstrap before they can trust this release.

This candidate supports the immutable published 0.7.0 through 0.7.6 and 0.7.8
through 0.7.10 release assets. The tag-only 0.7.7 identity has no published
installation artifact and is refused. Every supported source converges on one
canonical set of three 0.7.11-1 IPKs. Those same packages can be installed on
an already-flashed OpenWrt 24.10.5 router directly or through the signed local
package feed; no firmware flash or global `opkg upgrade` is part of either
path.

Physical RD23 testing remains an explicit hardware-canary gate and is not
represented by VirtualBox or static image proof. This is candidate-channel
material, not a stable publication.

Historical 0.7.10 notes

• Supersedes the already shipped 0.7.9.1 candidate with a strictly newer
  updater-visible version because the final payload is materially different.
• Fixes clean installations with no VLESS profile yet configured. Backend
  health checks now report a healthy, disabled state instead of forcing the
  transactional installer to roll back.
• Fixes standalone release validation for the stable unversioned
  `system/update` LuCI route introduced in 0.7.9 while retaining support for
  older version-suffixed Update routes.
• Fixes the VPN service status card appearing twice on LuCI 24.10 Overview by
  installing one canonical status include and removing the obsolete alias.
• Keeps VPN and automatic switching disabled on an unconfigured router and
  does not enroll Tailscale or install AdGuardHome.
• Retains the stable LuCI assets, mandatory verified backups, automatic
  rollback, background update jobs, and routing fixes from Router UI 0.7.9.
• Makes tag publication retry-safe: an already existing release is accepted
  only when its title and every expected asset are byte-identical, and existing
  assets are never overwritten.
