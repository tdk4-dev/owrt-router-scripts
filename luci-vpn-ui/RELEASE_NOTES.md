# Router UI 0.7.11 RC17 — blocker fixes

This unpublished package-only candidate repairs the legacy routing-init migration,
restores Device VPN bypasses after routing restarts and DHCP lease changes, and
keeps first publication out of GitHub Latest discovery. Legacy routing conffiles
retain their existing rules; package hooks add a shared lifecycle guard and
reject unsupported layouts before installation. No firmware or hardware
qualification is included. Previous stable and RC artifact sets remain immutable.

Validation results for the new candidate are recorded separately after testing.

## Earlier stable promotion (historical, unpublished)

Router UI `0.7.11` is the identity-only stable promotion of fully qualified
RC16 code. Its OpenWrt package version is `0.7.11-1`, its channel is `stable`,
and it contains no Router UI 0.8 feature work. Functional product code is
identical to RC16. This source state is not published until separately
authorized merge, tag, and GitHub Release steps are completed.

RC9 was rejected before publication after exact-byte testing from the retained
public 0.7.10 VM origin proved that `coreutils-nohup` was not installed. RC10
authenticated the target, installed that prerequisite and all three project
IPKs, and reached a green candidate validator, but its supervisor then failed
closed with protected-state exit 40. The exact mismatch was the deterministic
first-install creation of `/etc/config/premier_router`: legacy 0.7.10 has no
such file, while the package post-install creates its non-secret metadata.
Automatic rollback still restored the legacy source.

RC11 authenticated and committed the full package transition, passed reboot
validation, and reached the exact signed UI in a real LuCI browser. It was
rejected when the global Enable control returned success while packaged Xray
remained stopped: the helper invoked the init script without changing its
`xray.enabled.enabled` UCI gate.

Stable 0.7.11 keeps the narrow legacy-rescue repair: after authenticating the target manifest
and enforcing a conservative persistent and temporary storage gate, it updates
the configured signed OpenWrt feeds and installs only that missing upstream
worker prerequisite. It never performs a global package upgrade. If the
project transaction then fails, its ordinary exact application/configuration
rollback still applies; the upstream prerequisite remains installed so a retry
and the asynchronous updater have the required worker launcher.

Stable 0.7.11 also treats that metadata creation as one explicit first-install
transition instead of weakening protected-state checks. The supervisor removes
only byte-exact candidate-owned `-opkg` conffile artifacts, requires every
pre-existing protected path to remain exact, validates the new metadata as a
root-owned mode-0600 regular file with exactly the expected 13 non-secret UCI
fields, and freezes the resulting fingerprint for post-reboot validation.
Rollback continues to restore the metadata file's original absence. Any extra
field, unsafe mode, symlink, unexpected protected path, or mismatched conffile
artifact fails closed.

Stable 0.7.11 also makes the global VPN control persistent for the standard OpenWrt
Xray package. Enable sets and commits the package UCI gate before starting the
service, verifies that Xray reached the running state, and restores the prior
gate if Xray or transparent-proxy startup fails. Disable stops the services and
returns the same gate to disabled. Legacy `xray-exit-st` service behavior is
unchanged.

Every Xray and transparent-proxy mutation path now preserves the exact UCI,
daemon, nftables/policy-routing, and reboot pre-state on failure. Start and
restart success require a live daemon postcondition; transparent-proxy success
requires the complete kernel state. The packaged transparent init registers
its `running` command explicitly, preventing an OpenWrt help-text fallback from
returning success while no transparent state exists.

The release source also contains a 46-control, 84-object runtime ownership
contract. Its clean-baseline guest probe installs only the three canonical
project IPKs, resolves their declared dependency closure, fails on missing or
ambiguous owners, and checks Xray process and transparent kernel postconditions
before and after both enabled and disabled reboots.

The VM legacy fixture now renders its selected non-routable test profile and
records the canonical `/etc/xray/exit-st-cf.json` UCI path before candidate
validation. This corrects qualification state only and does not broaden Xray
adoption behavior.

RC13 completed its exact-source, production-signing, package-only, lifecycle,
runtime-ownership, and guest-object gates, but was rejected by real-browser
qualification. A newly started Update Check could accept an older committed
install journal, while Tailscale Stop and Restart could report success before
the displayed service state reached the requested postcondition. The RC13
artifacts and NO-GO evidence remain preserved; no RC13 tag or release exists.

RC14 repaired that shared asynchronous-success defect class. Update Check and
Apply now return and persist an exact operation identity, workers transition
only their own job record, Apply binds that job to its exact transaction, and
the browser polls only the matching ID and kind. Tailscale mutations now use
fresh bounded runtime observations, preserve boot and registered-identity
state, restore the exact pre-state on failure, and require the read-only status
view to agree before the browser announces success. The management-route
invariant excludes only Tailscale's exact policy rules, so an intentional Stop
does not misclassify their removal as unrelated route drift.

RC14 was production-built and signed, completed the exact 0.7.10 package-first
upgrade and reboot commit, and passed Update stale-job isolation plus real
Tailscale Restart convergence. It was rejected when real-browser Stop reached
the correct stopped/disabled runtime state but exceeded LuCI's RPC window.
After the daemon exited, invariant and response serialization still invoked
blocking Tailscale client reads. The browser therefore rendered an XHR timeout
instead of the proven stopped state. RC14 artifacts and NO-GO evidence remain
immutable; no RC14 tag or release exists.

RC15 distinguishes the real `tailscaled` daemon from client lookalike
processes using `/proc` command identity. When the daemon is absent, invariant
and read-only status paths no longer invoke daemon-dependent Tailscale client
commands. Stop can therefore return its already-proven postcondition within
the browser contract, while running-state Restart, registration, identity,
and management-route checks retain their existing observations.

RC15 passed its candidate qualification and remains preserved with its exact
production bytes. The first identity-only stable build exposed a separate
rollback postcondition defect: package bytes returned to RC14/RC15, but the
transaction could not prove exact source init/service state after `opkg` had
removed the old package-owned `xray-transparent` init before target preinstall.
That stable artifact set is immutable rejected evidence and was not published.

RC16 snapshots the exact transparent init before package mutation, reconstructs
it from the authenticated known-good source IPK when package ordering has
already removed it, and verifies restored service state through bounded fresh
observations. Timeout remains fail-closed. RC16 passed production-signed
exact-byte qualification from 0.7.10 and RC15, including controlled rollback,
reapply, reboot commit, updater correlation, Tailscale convergence, lifecycle,
ownership, and the complete browser census. Its immutable artifacts and
evidence remain the functional qualification source for stable 0.7.11.

Stable 0.7.11 preserves RC16 protocol-2 signed-manifest verification, transactional package
updates, reboot validation, exact rollback/recovery, structured asynchronous
Update Check/Apply results, and fail-closed compatibility, checksum, storage,
and signature handling. RC5, both materially different historical RC6 byte
sets, RC14, RC15, and RC16 are supported protocol-2 source states, but their
retained evidence is not substituted for stable qualification. The missing
signed-manifest digest for the first RC6 byte set remains unknown and is never
replaced with the hotfix digest.

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
`production-2026-07`, fingerprint `d055711acf1d9a5b`. Production-signed
qualification is performed only under Mac Pro signing custody. Signed package
bytes and VM/browser evidence do not authorize images, Factory, hardware,
merge, tags, releases, discovery, or rollout.

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
