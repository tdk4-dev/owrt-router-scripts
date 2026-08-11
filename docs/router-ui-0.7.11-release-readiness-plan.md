# Router UI 0.7.11 Release Readiness Plan

- **Status:** active working plan; stable publication is `NO-GO`
- **Plan date:** 2026-08-11
- **Current implementation reference:**
  `f1c8bf0eb81a663340351276f3cafd3fdeab53f5`
- **Current implementation PR:**
  [PR #20](https://github.com/tdk4-dev/owrt-router-scripts/pull/20)
- **Recommended next candidate:** `0.7.11-rc.7` / `0.7.11~rc7-1`

This document is the ordered working checklist for reaching a fully releasable
Router UI `0.7.11`. It distinguishes evidence already earned for RC6 from the
exact-byte evidence that must be produced for the next immutable candidate and
for stable publication.

## How to use this plan

- Execute phases in order.
- Do not start canonical double builds, image builds, production signing, or
  full VM qualification until the Phase 1 functional preflight is green and the
  candidate source is frozen.
- Check an item only when its stated closure evidence exists.
- Keep implementation, VM, Factory, hardware, and publication evidence in
  separate approval buckets.
- A change to source, feed lock, build/staging scripts, contracts, signing
  identity, package/image bytes, or verification-affecting metadata invalidates
  all affected downstream evidence.
- If candidate bytes have left controlled build storage or reached a router,
  any replacement byte set receives the next RC identity.

Gate labels used below:

- **RC blocker:** must close before distributing the next release candidate.
- **Stable blocker:** may be exercised during the candidate period but must
  close before stable publication.
- **Release blocker:** must close before tag or GitHub release publication.

## Current evidence snapshot

The following evidence is useful, but it is not transferable to changed RC7
bytes:

- exact RC6 hotfix source `f1c8bf0eb81a663340351276f3cafd3fdeab53f5`,
  tree `c976abd2e4c47853f330dda500400d2f17bbacc7`;
- green push and pull-request CI runs `31422039526` and `31422040381`;
- reproducible RC6 IPKs and a production-signed package-only stage containing
  37 assets and zero images;
- signed release manifest SHA-256
  `3c1e3159fd208dac77689fb997f10d98bd5847f0db274903510726d7232e3c32`;
- focused disposable VirtualBox qualification of the RC6-to-RC6 hotfix;
- Valera RD23 transaction `20260810T191838Z-b4577fb771899d01`, supervised
  reboot, preserved adopted configuration, and exact profile switch/back;
- production key ID `production-2026-07` and public fingerprint
  `d055711acf1d9a5b`.

Known limitations of that evidence:

- `6897650...` and `f1c8bf0...` used the same RC6/package identity despite
  containing different bytes;
- the complete RC5-to-RC6 update/reboot/rollback gate belongs to `6897650...`,
  while the final hotfix gate started from already-installed RC6;
- the final hotfix stage has no exact x86, RD23 stock, or RD23 ubootmod images;
- no protected candidate-authorization run exists for `f1c8bf0...`;
- Valera was not a fresh exact-hotfix bootstrap and is not the designated DNS
  RD23 hardware fixture;
- Valera's Xray and transparent-routing services remained disabled for
  autostart, and the earlier OOM incident remains under monitoring.

## Ordered readiness checklist

### Phase 0 — identity, governance, and scope

- [ ] **P0.1 — Track and ratify the release scope.** **RC blocker**

  The agreed `0.7.11` scope currently exists as an untracked controller-side
  document. Preserve it, review it as a dedicated governance change, and place
  the accepted version under source control. Do not alter release scope as a
  side effect of candidate implementation.

  **Closure evidence:** a reviewed canonical scope commit/PR, plus an explicit
  owner decision for any difference from the 2026-07-24 proposal.

- [ ] **P0.2 — Adopt the functional-first agentic loop.** **RC blocker**

  Merge or otherwise reconcile the policy in
  [PR #21](https://github.com/tdk4-dev/owrt-router-scripts/pull/21) before more
  expensive release work. This ensures cheap UI/runtime disproof precedes
  canonical builds and defines when evidence may be reused.

  **Closure evidence:** the policy is contained in `origin/main`, and the
  release task references it before implementation begins.

- [ ] **P0.3 — Retire RC6 as a publishable identity and select RC7.**
  **RC blocker**

  Quarantine both internal RC6 byte sets as historical canaries. Use
  `0.7.11-rc.7` / `0.7.11~rc7-1` for the next bytes. Preserve safe upgrade
  handling from both known RC6 deployments, but do not reuse or overwrite an
  RC6 tag or release asset.

  **Closure evidence:** an owner-approved decision record naming both RC6
  source/manifest identities, the RC7 naming contract, and the required
  RC6-to-RC7 and RC7-to-stable ordering tests.

- [ ] **P0.4 — Ratify full adopted-overlay controls as a regression repair.**
  **RC blocker**

  A healthy adopted configuration must support the operator workflows exposed
  by the panel: global VPN, profiles, subscriptions, ping refresh, automatic
  switching, direct rules, and device VPN. Adoption-required, drift/recovery,
  reboot-pending, and read-only states must remain fail-closed. Treat this as a
  compatibility repair discovered on Valera, not permission for adjacent 0.8
  feature work.

  **Closure evidence:** a reviewed state/control acceptance matrix and an owner
  decision retaining this behavior in `0.7.11`.

- [ ] **P0.5 — Lock the declared deliverables and variants.** **RC blocker**

  The intended deliverables are three IPKs, x86 image, RD23 stock image, RD23
  ubootmod image, signed manifests/contracts, and ordinary-user installation
  guidance. Qualify each image variant independently. If a variant is removed,
  record that as an explicit owner scope decision before candidate freeze; do
  not silently omit it or add it after publication.

  **Closure evidence:** a variant/deliverable table with `included`, `deferred`,
  and required-evidence columns, approved by the owner.

### Phase 1 — cheap functional closure before canonical builds

- [ ] **P1.1 — Correct release documentation and collateral templates.**
  **RC blocker**

  Update release notes, Markdown installation guidance, issue/status templates,
  PR text, and VM methodology so they describe the accepted full adopted panel
  and current hardware evidence truthfully. Remove hardcoded RC6 source hashes,
  IPK hashes, sizes, and storage thresholds from the PDF generator. Generate
  final collateral from the signed manifest after the build without committing
  derived hashes back into frozen candidate source.

  **Closure evidence:** documentation link audit, rendered PDF QA, and agreement
  between version, behavior, limitations, hashes, sizes, and calculated storage
  gates.

- [ ] **P1.2 — Add an exact-SHA preflight before build workflows.**
  **RC blocker**

  Move JavaScript syntax and focused UI tests ahead of expensive host/release
  tests. Require a green exact-source preflight before canonical IPK or image
  jobs may start. Generalize RC6-specific candidate/evidence workflows for the
  selected RC identity.

  **Closure evidence:** workflow tests prove a failing UI/preflight check skips
  all build/sign/image jobs, while an exact green SHA unlocks them.

- [ ] **P1.3 — Add a real-browser control census.** **RC blocker**

  Maintain a machine-readable manifest for every interactive Update, VPN, and
  Tailscale control. Verify rendering, enabled state, click behavior, RPC/ACL
  dispatch, backend result, exact rollback/restoration, route invariants, and
  browser-console errors in all applicable states:

  - native-generated and empty/unconfigured;
  - manual unadopted/adoption-required;
  - adopted healthy;
  - adopted drift/recovery;
  - reboot pending;
  - read-only.

  Exercise Update Check/Apply, adoption preview/confirm, global VPN,
  profile add/use/delete, subscription import/sync/delete, ping refresh,
  automatic switching, direct-rule Apply, and device VPN controls.

  **Closure evidence:** exact-SHA browser report, screenshots/DOM evidence,
  zero console errors, pre/post configuration hashes, and no untested visible
  controls.

- [ ] **P1.4 — Run one provisional changed-surface VM checkpoint.**
  **RC blocker**

  Build at most one provisional package set and install it into a reusable
  disposable VM snapshot. Run the complete browser census and changed backend
  paths. Do not double-build, build release images, production-sign, or run the
  full baseline matrix at this stage.

  **Closure evidence:** focused runtime PASS with retained failure excerpts or
  evidence paths and exact restoration of disposable fixtures.

- [ ] **P1.5 — Review and freeze one exact candidate source.** **RC blocker**

  Independently review updater transactions, adopted-Xray mutation boundaries,
  ACL/security boundaries, build/staging scripts, documentation templates, and
  the complete diff. Freeze a clean source commit, tree, toolchain, feed lock,
  contract inputs, and signing identity. A later source/input change becomes
  RC8.

  **Closure evidence:** clean-worktree proof, source/tree hashes, version-source
  audit, review disposition, input lock inventory, and freeze decision.

### Phase 2 — canonical artifacts and exact-byte qualification

- [ ] **P2.1 — Run exact-source host, security, updater, and storage tests.**
  **RC blocker**

  Cover unauthenticated setup mutations, read-only ACLs, signature/checksum and
  compatibility failures, unsupported/dev versions, transaction/reboot paths,
  exact rollback, and insufficient persistent or temporary storage. Failures
  must occur before mutation and must not be reported as success.

  **Closure evidence:** exact-SHA CI and host-suite results with immutable logs.

- [ ] **P2.2 — Build, compare, sign, and stage all declared artifacts.**
  **RC blocker**

  Build canonical IPKs and every declared image twice from independent clean
  roots. Images must derive from the retained canonical IPKs. Compare expected
  bytes, production-sign one canonical set, and generate full provenance.

  **Closure evidence:** A/B hashes, feed/toolchain/ImageBuilder identities,
  input-IPK and output-image hashes, signed manifests/contracts, source-dirty
  false, and no unexplained drift.

- [ ] **P2.3 — Run the impacted exact-byte candidate matrix.** **RC blocker**

  At minimum cover RC5 to candidate, both known RC6 states to candidate,
  update/reboot/commit, adoption, all panel controls, direct-rule add/remove,
  profile switch/back, injected rollback, repeat update, and candidate-to-stable
  ordering.

  **Closure evidence:** immutable VM bundle bound to source, manifest, package,
  and image hashes, with transaction IDs, changed boot IDs, configuration
  hashes, Tailscale/Xray invariants, and browser results.

- [ ] **P2.4 — Complete the full supported-baseline matrix.**
  **Stable blocker**

  On exact final bytes, test published `0.7.0` through `0.7.6` and `0.7.8`
  through `0.7.10`, idempotent reinstall, all declared failure families, and
  refusal of tag-only `0.7.7`, unknown, dev, and unsupported sources before
  mutation.

  **Closure evidence:** an immutable external evidence index that closes every
  required transition without modifying frozen candidate source.

- [ ] **P2.5 — Publish evidence and run protected candidate authorization.**
  **RC blocker**

  Publish the already-supervised evidence through a main-only trusted workflow,
  then run the protected exact-source candidate workflow against the signed
  manifest and evidence archive.

  **Closure evidence:** publisher and authorization run IDs, evidence ZIP hash,
  signed manifest digest, source/tree hashes, and candidate descriptor.

- [ ] **P2.6 — Complete real Factory schema-2 qualification.**
  **Stable blocker**

  For every included image, generate the schema-2 contract, detached signature,
  and image-package-manifest digest. Import them into the current real Factory
  and complete provisioning, first boot, setup, and handoff. Fixture tests alone
  are insufficient.

  **Closure evidence:** secret-free Factory evidence bound to exact image and
  contract hashes.

### Phase 3 — hardware and operational gates

- [ ] **P3.1 — Prove the ordinary-user path on a fresh XMiR/RD23.**
  **RC blocker for external distribution**

  Use a separate recoverable factory-reset router over wired LAN. Test fresh
  package bootstrap, identity, storage/RAM preflight, safe below-threshold
  refusal, reboot commit, rollback seed, LuCI controls, and service health.
  Valera is not this fixture because its path was RC5 to two RC6 byte sets.

  **Closure evidence:** pre-install recovery data, board/release identity,
  artifact hashes, storage/RAM checks, boot and transaction IDs, package state,
  service checks, and sanitized browser evidence.

- [ ] **P3.2 — Run the designated DNS RD23 stock hardware gate.**
  **Stable blocker**

  Record model, board, NAND/layout, stock firmware, and recovery backup. Prove
  Factory provisioning, WAN, LAN, Wi-Fi 2.4/5 GHz, reboot, reset, repeat setup,
  update, commit, exact rollback, controlled power interruptions, recovery, and
  reinstall. Preserve this unit as the stock-layout fixture unless another is
  explicitly assigned.

  **Closure evidence:** complete exact-byte hardware evidence bundle and tested
  recovery path.

- [ ] **P3.3 — Repeat a bounded final canary and soak on Valera.**
  **Stable blocker**

  After non-hardware gates pass and with explicit maintenance approval, verify
  final candidate identity, authenticated browser controls, one sentinel
  direct-rule add/remove, profile switch/back, exact restoration, Tailscale
  management, and resource state. Run a 24-48 hour read-only soak that exceeds
  the earlier approximately 26-hour OOM recurrence interval. Decide whether
  disabled Xray/transparent-routing autostart is an accepted documented
  limitation or a defect.

  **Closure evidence:** package/manifest identity, transaction and boot IDs,
  pre/mid/post hashes, route/service checks, timestamped memory/RSS/log/storage
  samples, and no new OOM or lock marker.

- [ ] **P3.4 — Prove signing-key recovery and publish the rescue runbook.**
  **Stable blocker**

  Maintain at least two encrypted production-key backups, including one outside
  the Mac Pro, and prove recovery of the expected public fingerprint without
  exposing private material. Document emergency rotation/revocation and test
  rollback/rescue commands against exact release assets.

  **Closure evidence:** fingerprint-only recovery transcript, backup custody
  record, and tested rollback/rescue runbook.

### Phase 4 — source-of-truth publication and rollout

- [ ] **P4.1 — Merge and tag only the qualified source.** **Release blocker**

  Merge normally, verify the qualified commit is contained in `origin/main`,
  create a unique annotated tag, independently rebuild from it, and compare
  every draft-release asset with the qualified set.

  **Closure evidence:** merge commit, ancestry proof, annotated tag target,
  protected workflow results, and complete byte-comparison report.

- [ ] **P4.2 — Qualify stable `0.7.11` as a new immutable byte set.**
  **Release blocker**

  Stable version/channel metadata changes package bytes. Do not rename RC
  assets. Reproducibly build and sign the stable set, run candidate-to-stable
  update/rollback and exact-byte smoke gates, then download and independently
  verify the complete draft release.

  **Closure evidence:** stable source/tag, A/B build proof, signed manifests,
  updater/rollback evidence, and draft asset checksum comparison.

- [ ] **P4.3 — Roll out by rings.** **Release blocker**

  Publish only after explicit owner authorization. Begin with manual stable
  discovery using the exact qualified bytes. Observe before enabling normal
  discovery, and require a separate authorization for that final step.

  **Closure evidence:** owner approval, Ring 2 observation record with no
  blockers, and Ring 3 authorization.

## Explicitly out of scope for 0.7.11

Do not add:

- the Router UI 0.8 navigation or page architecture;
- new product pages or onboarding UX;
- dynamic AdGuard installation;
- a major localization or visual redesign;
- new hardware profiles without separate evidence;
- unrelated dependency/toolchain upgrades;
- opportunistic cleanup or general refactoring.

The adopted-overlay repair is a narrowly ratified compatibility fix. It does
not broaden the release into a feature train.

## Copy-ready Codex prompt for Phase 0

```text
Execute Phase 0 of the Router UI 0.7.11 release-readiness plan. Phase 0 is a
governance and identity task only. Do not begin implementation, package/image
builds, signing, VM qualification, Factory execution, or router work.

Repository:
- /Users/glebaleksejcuk/Documents/owrt
- GitHub: tdk4-dev/owrt-router-scripts

Primary objective:
Create a reviewable, canonical Phase 0 decision package that establishes the
release scope, process policy, next candidate identity, adopted-overlay
acceptance contract, and declared release variants. Preserve all existing work
and stop before merging or touching candidate/runtime bytes.

Working decisions to encode unless current verified evidence reveals a direct
conflict:
1. The next candidate is 0.7.11-rc.7 / 0.7.11~rc7-1. The two materially
   different RC6 byte sets are quarantined as internal historical canaries and
   must never be published or overwritten under one shared identity.
2. Full controls for a healthy adopted Xray overlay are retained as a narrowly
   scoped compatibility regression repair: global VPN, profiles,
   subscriptions, ping refresh, automatic switching, direct rules, and device
   VPN. Adoption-required, drift/recovery, reboot-pending, and read-only states
   remain fail-closed.
3. Intended deliverables remain three IPKs, x86 image, RD23 stock image, RD23
   ubootmod image, signed manifests/contracts, and ordinary-user guidance. A
   variant may be deferred only through an explicit owner decision before
   candidate freeze.
4. Router UI 0.7.11 remains a trust/update bridge, not a feature release. Keep
   all listed 0.8 features and unrelated cleanup out of scope.

Required inputs to inspect:
- Read the repository AGENTS.md completely.
- Read the saved plan at
  /Users/glebaleksejcuk/Documents/owrt/.worktrees/router-ui-0.7.11-readiness-plan/docs/router-ui-0.7.11-release-readiness-plan.md.
  If that branch has already been merged, use the same path under the primary
  repository instead.
- Read the proposed normative scope without modifying it in place:
  /Users/glebaleksejcuk/Documents/owrt/docs/RELEASE_SCOPE_0.7.11_TO_0.8.0.md
- Inspect the exact RC6 worktree read-only:
  /Users/glebaleksejcuk/Documents/owrt/.worktrees/router-ui-0.7.11-rc6
- Verify current PR #20 and PR #21 state live. Every gh command must run with
  host permissions because credentials are in the macOS Keychain.
- Read the relevant NETWORK_INVENTORY.md and
  /Users/glebaleksejcuk/Documents/INCIDENT_LOG.md entries for Valera and the
  RC6 hotfix. Do not contact the router.
- Use retained memory only as historical context; re-check cheap, drift-prone
  repository and GitHub facts.

Mandatory state separation:
- dirty primary checkout;
- isolated task worktree;
- origin/main;
- PR #20 RC branch and exact source f1c8bf0...;
- historical 6897650... RC6 bytes;
- retained VM/canary evidence;
- unpublished candidate state;
- future RC7 identity.

Before modifying files:
1. Run git status --short --branch, git fetch origin --prune --tags,
   git branch --show-current, and git log --oneline --decorate -10.
2. Confirm the primary checkout is dirty and preserve it exactly.
3. Create a new isolated codex/* documentation worktree from current
   origin/main. Do not switch, stash, clean, reset, or edit the primary
   checkout or the RC6 worktree.

Authorized actions:
- read local files, retained evidence, and live GitHub metadata;
- create or edit only Phase 0 governance/documentation files in the isolated
  worktree;
- copy the proposed scope into the isolated worktree for review, preserving
  its content and recording any proposed change separately;
- create a Phase 0 decision record;
- run documentation/static validation;
- commit only the intended documentation files, push the isolated branch, and
  open a draft pull request.

Not authorized:
- do not merge PR #20, PR #21, or the new Phase 0 PR;
- do not close or rewrite existing PRs/issues;
- do not change VERSION, PACKAGE_VERSION, updater transitions, runtime code,
  release workflows, packages, images, manifests, or candidate bytes;
- do not build packages/images, sign anything, run a VM/Factory gate, publish a
  tag/release, or contact Valera, the DNS RD23, the Mac Pro, or other hosts;
- do not modify the original dirty/untracked scope file in place;
- do not mark downstream readiness items complete based on RC6 evidence.

Required deliverables:
1. A tracked proposed canonical scope document, preserving the 2026-07-24
   proposal unless a clearly labeled decision amendment is required.
2. A Phase 0 decision record containing:
   - the exact identities of 6897650... and f1c8bf0... and why their evidence is
     non-transferable;
   - the RC7 version/identity decision and future transition tests;
   - the adopted-overlay control/state acceptance matrix;
   - the included/deferred variant and deliverable table;
   - the 0.7.11 non-goals;
   - the required merge/order dependencies for the agentic-loop policy,
     governance scope, and later RC7 implementation.
3. An evidence ledger that labels each fact as current verified, retained
   historical, owner decision, or still unverified.
4. A draft PR containing only the Phase 0 documentation changes.

Definition of done:
- the dirty primary checkout and RC6 worktree are unchanged;
- every claimed current GitHub/source fact was reverified;
- no secret or private configuration is included;
- the scope, RC7 identity, adopted-control behavior, variants, and non-goals
  are explicit and internally consistent;
- the draft PR diff contains only intended Phase 0 documentation;
- documentation checks pass;
- no merge, release, build, signing, VM, Factory, or router action occurred;
- the final report gives the branch, commit, draft PR URL, changed files,
  checks, unresolved owner approvals, and the exact stop boundary.

Stop and ask for direction if live evidence contradicts one of the working
decisions, if the proposed scope cannot be preserved without substantive
reinterpretation, or if completing Phase 0 would require modifying candidate
bytes or performing an external operational action beyond the authorized draft
PR.
```
