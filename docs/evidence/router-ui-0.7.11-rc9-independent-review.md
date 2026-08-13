# Router UI 0.7.11 RC9 pre-package independent review

- **Review date:** 2026-08-13 (Europe/Moscow)
- **Review boundary:** complete RC9 continuation delta over exact PR #25 source and complete branch diff over exact starting main
- **Disposition:** no source-level blocking finding before the final exact-tree gates

This is a separate source and workflow review. It is not package, VM,
canonical-artifact, hardware, signing, release, rollout, or merge
qualification.

## Source and inherited-scope closure

The reviewed ledger uses explicit sets for every one of the 158 inherited PR
#24 paths; its default is `unexplained`, not trust/update. The 17 deferred paths
are specifically 0.8-only navigation, owner preparation, Reset, dynamic
AdGuard installation, or new onboarding behavior. Existing firstboot package
files, root-only setup, VLESS import, lean RD23/no-AdGuard policy, registered
Tailscale behavior, and metadata safety are preserved or narrowly
reimplemented. No class-6 path remains.

Historical RC6/RC7/RC8 evidence and the unknown `68976508...` manifest digest
were checked separately from active RC9 identity. RC8 is recorded as
source-only with no package set; the review does not invent RC8 bytes or reuse
its browser evidence.

## Adopted-Xray capability boundary

The real ucode helper now calls the Reality-TCP capability inspection before
any command-specific operation. Shell preview and confirmation already route
through `inspect` and `extract`; ownership status and mutation now repeat the
same inspection and compare the recorded selectors. Health requires matching
bytes, active path, capability, and selectors. The LuCI mutation predicate
therefore cannot enable Profile Use for the old unsupported layout.

Focused real-helper tests proved `inspect`, `extract`, and synthetic
`patch-profile` on the hash-locked planned fixture, rejection of the old
missing-network fixture, unhealthy status after synthetic capability drift,
and mutation refusal. Non-managed Xray JSON semantics, config hashes,
transaction preimages, route snapshots, and rollback contracts remain covered.

## Firstboot, secrets, and service readiness

The no-AdGuard branch returns before any service probe or mutation and the
complete mocked apply path still writes the completion marker. Availability is
reported truthfully in the backend and UI; the simulator defaults to absent
unless explicitly enabled. Tailscale output uses a PID-unique file in the
declared runtime directory, removes it before all returns, and never treats
`Running` without an IP or `NeedsLogin` with an IP as success. Failure messages
contain no preauth key.

## Identity, updater, and evidence contracts

Active application/package/channel/tag surfaces use `0.7.11-rc.9`,
`0.7.11~rc9-1`, `candidate`, and reserved-only
`vpn-panel-v0.7.11-rc.9`. Stable remains newer than RC9; same identity with
different bytes is rejected. The first historical RC6 manifest digest remains
`null`. The planned VM fixture hash is source-controlled, and the provisional
manifest fixture is non-production and unsigned.

## Tier 0 and CI

The review traced the reusable exact-SHA workflow and all Tier 0 commands.
Tier 0 performs syntax, ledger, census, seven-state rendering, ACL/security,
updater, firstboot, metadata, collateral, and methodology tests. It does not
run the real package builder, ucode installer, signing/staging tools, VM gate,
or a release publisher. Both PATH wrappers and 25 entrypoint-local guards stop
transitive build, signing, staging, publication, tool-install, image, and VM
execution. Repository and controlled temporary roots are inventoried for new
artifacts.

The prior GNU `tr` warning is removed by placing `-` last in the deletion set.
The `sed | grep -q` pipeline that produced a broken-pipe warning now consumes
the full section before deciding. Linux CI remains the binding confirmation.

## Disposition

No source-level blocker remains. Any tracked change after the final source
commit invalidates this review and requires a new exact-tree Tier 0 and CI run.
Packaging is not authorized until those gates and the locked real-helper run
all pass. Once the sole RC9 package build is invoked, any package/VM/browser
failure that requires changed bytes consumes RC9 and requires a future RC10.
