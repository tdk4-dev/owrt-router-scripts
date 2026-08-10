Router UI 0.7.11 RC6

Router UI `0.7.11-rc.6` is the constrained repair candidate for RC5. It keeps
the protocol-2 package, signature, recovery, and rollback foundation while
repairing real asynchronous update launch and making Xray configuration
ownership explicit. It intentionally contains no 0.8 product features.

The core package now depends on `coreutils-nohup`, `ucode`, and
`ucode-mod-fs`, and uses an ownership-bound child-start handshake with
structured launch errors. Check and Apply remain asynchronous through LuCI;
the synchronous worker override remains test-only.

Xray ownership has two modes. The existing generated
`/etc/xray/exit-st-cf.json` path remains `native-generated`. A manual active
configuration such as `/etc/xray/config.json` requires authenticated preview
and exact-hash confirmation before becoming `adopted-overlay`. Adoption imports
only one unambiguous isolated direct-domain array and one isolated direct-IP
array, and does not rewrite or restart Xray. Later rule application changes
only those selectors, proves every other JSON semantic is unchanged, validates
the candidate, atomically installs it, and automatically restores exact private
preimages if validation, commit, restart, or Tailscale/route invariants fail.

Profile switching and automatic profile mutation are disabled in adopted mode.
The native renderer no longer adds BitTorrent or TCP 8080 direct bypass rules.
Existing adopted bypasses remain untouched because all non-managed rules are
preserved.

The active production identity is the usign key `production-2026-07`. Only its
public key and derived fingerprint are present in source and release assets;
the protected workflow supplies the private key only to signing jobs. Routers
that trusted only the former identity require the documented authenticated
public-key bootstrap before they can trust this release.

This candidate supports the immutable published 0.7.0 through 0.7.6 and 0.7.8
through 0.7.10 release assets. The tag-only 0.7.7 identity has no published
installation artifact and is refused. Every supported source converges on one
canonical set of three `0.7.11~rc6-1` IPKs. A signed initial-install bootstrap
installs those packages on an already-flashed OpenWrt 24.10.5 router and seeds
the exact known-good package set required for rollback and the later stable
update. No firmware flash or global `opkg upgrade` is part of that path.

The RC identity is embedded independently as the user-facing version
`0.7.11-rc.6`, OpenWrt package version `0.7.11~rc6-1`, and release channel
`candidate`. The LuCI Update page labels the build as prerelease software, but
continues to follow the signed stable channel by default. Stable `0.7.11` is
therefore considered newer and remains available as the next update.

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
