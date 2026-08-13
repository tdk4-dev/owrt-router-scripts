Router UI 0.7.11 RC8

Router UI `0.7.11-rc.8` is the conservative continuation candidate identity for the
0.7.11 trust/update bridge. Its OpenWrt package version is `0.7.11~rc8-1`, its
channel is `candidate`, its future tag convention is
`vpn-panel-v0.7.11-rc.8`, and its stable successor is `0.7.11` /
`0.7.11-1`. It contains no Router UI 0.8 feature work.

RC8 is not immutable release evidence merely because this identity is present
in source. It becomes consumed when its sole provisional package-build
invocation begins; Phase 1 can only nominate the exact source for a separately
authorized Phase 2 freeze decision.

RC8 preserves protocol-2 signed-manifest verification, transactional package
updates, reboot validation, exact rollback/recovery, structured asynchronous
Update Check/Apply results, and fail-closed compatibility, checksum, storage,
and signature handling. RC5 and both materially different historical RC6 byte
sets are supported source states, but their retained evidence does not qualify
RC8. The missing signed-manifest digest for the first RC6 byte set remains
unknown and is never replaced with the hotfix digest.

Xray ownership has two supported modes. The generated
`/etc/xray/exit-st-cf.json` path remains `native-generated`. A manual active
configuration such as `/etc/xray/config.json` requires an authenticated,
read-only preview and explicit confirmation before becoming an adopted
overlay. Adoption records ownership without rewriting or restarting Xray.

The complete VPN panel is enabled only while an adopted overlay is healthy:
global VPN, profile add/use/delete, subscription import/sync/delete, ping
refresh, automatic switching, direct rules, and device VPN. Adoption-required,
drift/recovery, reboot-pending, and read-only states fail closed. Every adopted
mutation is serialized, rechecks the live hash before persistence, changes only
supported fields, validates Xray, preserves Tailscale and management-route
invariants, and restores exact private preimages on failure.

The active production trust identity remains the public contract for key
`production-2026-07`, fingerprint `d055711acf1d9a5b`. Phase 1 does not use its
private key, production signing environment, canonical build path, images,
Factory, hardware, tags, releases, or rollout. Provisional Phase 1 packages and
VM/browser evidence are explicitly non-production and do not establish full
release readiness.

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
