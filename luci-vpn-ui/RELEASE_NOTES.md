Router UI 0.7.11

Router UI 0.7.11 is an updater migration bridge built from the exact 0.7.10
product baseline. It introduces canonical OpenWrt packages, signed release
metadata, target-owned validation, persistent recovery, exact rollback, and a
generic fail-closed legacy rescue path. It intentionally contains no 0.8
product features.

The production public trust root is committed with the source; its private key
remains confined to the protected signing environment. Physical RD23 testing
is explicitly pending and is not represented by VM or image-extraction proof.

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
