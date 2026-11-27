# Router UI 0.7.11 RC8 pre-package independent review

- **Review date:** 2026-08-13 (Europe/Moscow)
- **Review boundary:** complete branch diff against exact starting main
  `18562f49bcac914acf3b07749f5b8863d8016e00`
- **Predecessor boundary:** exact failed RC7 PR #24 head
  `97da893062ebed1e27e9b35dbf0b68f248c12dd7`, tree
  `db5e610c25eeda74f0ec0c931145249669eced69`
- **Disposition:** no blocking finding before the final source commit

This is a source and workflow review, not package, VM, canonical-artifact,
hardware, signing, release, or rollout qualification. Runtime evidence is
recorded separately after the exact-head gates.

## Complete inherited diff and final delta

The machine-generated ledger covers all 158 inherited PR #24 paths and
independently confirms 104 PR #20-identical final states. Its six allowed
classifications contain 83 trust/update paths, 11 adopted-overlay repair
paths, 28 Phase 1 identity/test/workflow/documentation/evidence paths, 26
explicitly deferred 0.8-only paths, 10 preserved current-main paths, and zero
unexplained paths.

The complete staged RC8 source changes 168 paths relative to exact starting
main. The continuation delta changes 79 paths relative to exact PR #24,
including the RC8-only ledger/review records, source-only contracts, preserved
main repairs, identity renames, and narrow runtime corrections. Both comparisons
were reviewed; the additional paths do not widen the canonical product scope.

Every deletion or major replacement involving firstboot Wi-Fi, progress,
recovery, reset, owner preparation, metadata, navigation/footer, AdGuard,
Reset, relay behavior, and their tests was inspected semantically. Exclusions
are limited to new Router UI 0.8 navigation, pages, onboarding, dynamic
AdGuard installation, and product UX expressly prohibited by canonical scope
lines 195-207. Existing setup-closure security, ownership metadata, safe
Tailscale registration, version/asset guards, lean RD23 policy, registry,
relay, and generic infrastructure remain preserved or narrowly reimplemented.
No unrelated current-main fix is removed by the final source.

## Tailscale and HTML boolean attributes

Stop and Logout omit `disabled` only when their backend availability permits
interaction. Mock DOM tests require both `getAttribute("disabled") === null`
and native `.disabled === false` for independently restored running/connected
fixtures; read-only and unavailable fixtures require presence plus
`.disabled === true` and block dispatch. The view-wide audit normalized every
reachable composite false-valued boolean-attribute expression in the VPN and
Tailscale views. No blocking false-valued HTML boolean serialization remains.

## Updater transactions and version ordering

Source-only contracts cover RC5, both exact historical RC6 identities, and
invalidated RC7 ordering to RC8; identical RC8 repeat; same identity with
different bytes rejection; downgrade rejection; RC8 to stable; and stable not
treating RC8 as an upgrade. Synthetic filesystem tests cover live/stale locks,
pre-mutation recovery, journal state, protected-state snapshot, exact restore,
and unexpected-file removal without building any historical package. The
unknown first-RC6 signed-manifest digest remains `null`. No blocker remains;
real archive/package integration is deferred to the one provisional package
checkpoint or separately authorized Phase 2.

## Adopted Xray mutation and recovery

The review traced the real LuCI to RPC/ACL to shell-backend route while using
synthetic metadata and filesystem fixtures. Source contracts retain active
path and live-hash rechecks, serialized mutation, validator gates, private
preimages, exact rollback, non-managed-object preservation, and management and
Tailscale route invariants. Adoption-required, drift/recovery, reboot-pending,
and read-only states fail closed. No mutation/rollback blocker remains.

## RPC, ACL, and security boundaries

The 46-control census supplies stable selectors, state applicability,
visibility/enabled/blocked expectations, RPC/ACL/backend paths, success,
failure, and restoration assertions across seven top-level states. Focused
tests retain authenticated mutation, read-only rejection, setup closure,
secret-safe Tailscale logging, console-error checks, and route invariants.
No unresolved ACL, setup-reopen, secret-disclosure, or fail-open finding
remains.

## Workflows and transitive build dependencies

Tier 0 has one exact-SHA source-preflight job. Feature branches trigger it only
by `pull_request`; `push` is restricted to `main`. Downstream candidate and
release jobs require a green reusable result for their exact source SHA. The
runtime guard fails package, image, compiler, signing, staging, publishing,
tool-installation, buildful updater-integration, and double-build entrypoints,
including transitive calls. Artifact inventories make the zero-build result
enforced rather than self-reported. No workflow dependency blocker remains.

## Release documents, collateral, secrets, and generated files

Active candidate surfaces consistently use application `0.7.11-rc.8`, package
`0.7.11~rc8-1`, channel `candidate`, reserved future tag
`vpn-panel-v0.7.11-rc.8`, and stable successor `0.7.11` / `0.7.11-1`.
Historical Phase 0 and failed-RC7 evidence is not rewritten. Release notes,
ordinary-user guidance, status template, and VM methodology state the adopted
panel's healthy-only/fail-closed boundary and preserve Phase 2/production
prohibitions. The collateral generator remains manifest-driven and its
non-production fixture is validated without rendering a new binary. Tracked
secret scanning, JSON/shell/JavaScript/Python syntax, generated-ledger
comparison, and `git diff --check` are mandatory Tier 0 checks. No secret,
generated binary, package, VM overlay, screenshot, PDF, signing key, or release
artifact is intended for the branch.

## Final disposition

All source-review categories are clear for the final exact-SHA Tier 0 gate.
Any later tracked source, packaged-document, build/staging input, or contract
input change invalidates this disposition. Starting the one RC8 package build
consumes RC8; a package or browser failure requiring changed bytes ends this
run and requires a separately authorized RC9 continuation.
