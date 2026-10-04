# Router UI 0.7.11 Phase 1 source record

- **Recorded before implementation:** 2026-08-13 (Europe/Moscow)
- **Target release:** Router UI `0.7.11-rc.7`
- **Risk:** release-critical
- **Worktree:** `.worktrees/router-ui-0.7.11-rc7-phase1`
- **Branch:** `codex/router-ui-0.7.11-rc7-phase1`
- **Starting `origin/main`:** `18562f49bcac914acf3b07749f5b8863d8016e00`
- **Starting tree:** `3ee316a845f3d1dff1835ab0f35660b7d8a456ef`
- **Starting status digest:** SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (empty `git status --porcelain=v1 -uall`)

## Preconditions and state separation

Fresh live verification proved that PR #21 was merged first at
`3a8e77f661453d3db223b1e6ce5cae36f21a0366`, and PR #23 was subsequently
merged at the starting `origin/main`. Both PR heads and merge commits are
ancestors of `origin/main`. The canonical scope SHA-256 is
`795065bc4a9555ef283903ee757b9076d7cbfff6261d24bd1eda8258e1b8ff82`.

PR #20 remains open, draft, and unmerged at
`f1c8bf0eb81a663340351276f3cafd3fdeab53f5`. It is a historical implementation
reference only. The distinct RC6 source/tree pairs `68976508...` /
`b8362d85...` and `f1c8bf0e...` / `c976abd2...` remain quarantined. The signed
manifest digest for `68976508...` remains unknown; no other digest may be
substituted for it.

The dirty primary checkout remains on
`582024c2ea821295fd5b4945b641273ef70efac9`; its tracked diff SHA-256 is
`c40a83012c2716e3756a44d265b198351f57146dcafacaceb7f0213c8972936f` and its
complete status digest at Phase 1 entry is
`1ed63aa2b14a611d7c3c60e0e61008e3ea376629de776a72daa82703e19fea0b`.
Existing worktrees were fingerprinted separately before this worktree was
created and must remain unchanged.

## Intended changed surfaces

1. Reconcile the existing 0.7.11 trust/update bridge from the exact PR #20 RC5
   integration, without importing Router UI 0.8 features or unrelated cleanup.
2. Reconcile the Phase 0-approved adopted-Xray overlay repair and its bounded
   mutation, rollback, recovery, RPC, ACL, and LuCI paths.
3. Replace the RC6 same-version-hotfix identity with app `0.7.11-rc.7`, package
   `0.7.11~rc7-1`, channel `candidate`, future tag convention
   `vpn-panel-v0.7.11-rc.7`, and stable successor `0.7.11` / `0.7.11-1`.
4. Correct release notes, ordinary-user Markdown guidance, status/issue
   templates, VM methodology, and draft-PR text.
5. Add a portable manifest-driven collateral generator plus an explicitly
   non-production fixture manifest and rendered fixture PDF.
6. Add a machine-readable Update/VPN/Tailscale control census, stable UI
   selectors, mocked LuCI/RPC/ACL/backend/restoration tests, and visible-control
   completeness enforcement.
7. Add a cheap exact-source-SHA preflight and workflow-dependency tests that
   keep package/image/signing work ineligible after failure or a SHA mismatch.

No image, Factory, production-signing, protected-candidate, hardware, tag,
release, merge, distribution, or rollout surface is in scope.

## Acceptance criteria

- Every active version source and candidate-facing filename/template agrees on
  RC7, while immutable historical RC6 evidence remains labeled RC6.
- Version-order tests cover RC5 to RC7, both historical RC6 identities to RC7,
  RC7 to stable, stable-to-RC7 rejection, repeat identity, and rollback rules.
- The complete adopted panel is enabled only for a healthy adopted overlay and
  fails closed for adoption-required, drift/recovery, reboot-pending, and
  read-only states.
- Every visible Update, VPN, and Tailscale control has a stable selector, a
  census entry, applicable-state expectations, RPC/ACL/backend expectations,
  success/failure behavior, and a restoration assertion.
- Cheap tests fail before any build when syntax, census, UI, ACL/security,
  adopted-Xray, backend, or workflow dependency behavior is wrong.
- Ordinary Phase 1 CI executes no canonical/double IPK build, image build,
  production signing, or release workflow.
- Only after the committed exact-SHA preflight is green may one provisional
  three-IPK build and one disposable direct-localhost VM/browser checkpoint
  begin. Any required tracked-source change invalidates that checkpoint and
  ends this run without replacement bytes.

## Cheapest disproof tests

- `node --check` on every affected LuCI JavaScript file.
- Mocked DOM/LuCI tests for selector presence, rendering, state gating,
  dispatch, backend responses, console errors, and restoration.
- Machine-readable census schema and source-completeness validation.
- Read-only ACL and unauthenticated mutation-negative tests.
- Focused updater transaction/version-order tests.
- Focused adopted-overlay lock, preimage, TOCTOU, rollback, recovery, and
  Tailscale/admin-route-invariant tests.
- Static workflow DAG tests using synthetic pass, fail, and wrong-SHA results.

Package builds are not a diagnostic step for any failure above.

## Historical evidence invalidated by these changes

All RC5, `68976508...` RC6, and `f1c8bf0e...` RC6 package, manifest, VM,
browser, canary, signing, Factory, image, and release evidence remains bound to
its original source/tree/inputs/start state and cannot qualify RC7. The
0.8.0RC2 source currently on `origin/main` is not RC7 evidence. Any Phase 1
package or VM result will be provisional only and cannot qualify canonical
artifacts, hardware, Factory, or release readiness.

## Exact PR #20 references

The trust/update bridge reference is the exact RC5 ancestry ending at
`d02b3bcd187a44d366469ed1f37bb1b273e60529` (beginning with bridge commit
`0c792b60494c21907f042e70c00a6a9189f0516e`) as reconciled onto the then-main
base by merge result `af32f51607f7780467d251f082ae85147055cb4e`.

The adopted/update follow-up reference is this exact first-parent sequence:

- `9c8dec94fbfe61d0583fd21cb01b634bbae2b8dd`
- `8b7b0a99ad70293f47964dbb202794e699d35ab0`
- `29db6e5fb7ca20548a41d61e3e90544fe43a1cf4`
- `22db981bdb0d7714b653d629382e1c356337a663`
- `997fab729f4c13922c1f3be70c67defeed7a8fa5`
- `e2dc29f15bfdc2fe4d17fc7a08d4b6cef4663999`
- `d164a55f7457e74376e23c79365ddccfffb90083`
- `0afb284cab40317ed6736391ba70e28ae6e53bd6`
- `492390cb9f023ee1dd3c4e570ba9664686fd42ea`
- `b5ed1357f8c4398fd0a19ef36002f3a5a5bda9e2`
- `9cfaf064a6e352bf0bd40315b3f4e26ee02fbc4d`
- `75fa6e914c4e22431c6259add64e26edc80ca57e`
- `b86881610e919ccbaf9bd679f70a4efcdec4d344`
- `68976508e231cf8ab6fb441f8587de03c1903a3b`
- `f3857289b176383dc2ce21b87c5dc4223c143316`
- `f1c8bf0eb81a663340351276f3cafd3fdeab53f5`

The exact 52-file post-merge reference surface is:

- `.github/workflows/ci.yml`
- `.github/workflows/publish-router-ui-rc6-virtualbox-evidence.yml`
- `.github/workflows/release-vpn-panel.yml`
- `.github/workflows/validate-router-ui-candidate.yml`
- `docs/issue-10-rc-status-template.md`
- `docs/ordinary-user-ipk-installation.md`
- `docs/update-protocol-v2.md`
- `docs/vm-release-testing-methodology.md`
- `image/openwrt-fin0-packages.txt`
- `image/openwrt-rd23-packages.txt`
- `luci-vpn-ui/PACKAGE_VERSION`
- `luci-vpn-ui/RELEASE_NOTES.md`
- `luci-vpn-ui/VERSION`
- `luci-vpn-ui/files/etc/init.d/premier-router-update-recovery`
- `luci-vpn-ui/files/usr/libexec/premier-router/candidate-validator`
- `luci-vpn-ui/files/usr/libexec/premier-router/xray-overlay.uc`
- `luci-vpn-ui/files/usr/sbin/vpn-ui`
- `luci-vpn-ui/files/usr/sbin/vpn-ui-readonly`
- `luci-vpn-ui/files/usr/sbin/vpn-ui-update`
- `luci-vpn-ui/files/usr/share/vpn-ui/version`
- `luci-vpn-ui/files/www/luci-static/resources/view/network/vpn.js`
- `release/transition-matrix.json`
- `rescue-router-ui.sh`
- `scripts/build-openwrt-ipks.sh`
- `scripts/install-ci-ucode.sh`
- `scripts/stage-router-release.sh`
- `scripts/validate-staged-release.sh`
- `tests/fixtures/xray/adopted-overlay.json`
- `tests/fixtures/xray/valera-manual-config.json`
- `tests/integration/repro-recovery-lock-mac-pro.sh`
- `tests/integration/repro-recovery-lock.sh`
- `tests/integration/run-router-ui-virtualbox-matrix-mac-pro.sh`
- `tests/integration/run-vanilla-ipk-install-mac-pro.sh`
- `tests/integration/validate-rc6-virtualbox-evidence.sh`
- `tests/test-candidate-evidence-aggregation.sh`
- `tests/test-rc6-virtualbox-evidence.sh`
- `tests/test-rescue-support-matrix.sh`
- `tests/test-router-ui-release-v2.sh`
- `tests/test-security-boundaries-0.7.11.sh`
- `tests/test-updater-transaction-v2.sh`
- `tests/test-updater-worker-start.sh`
- `tests/test-vm-architecture.sh`
- `tests/test-vm-controller-contract.sh`
- `tests/test-vpn-hotfixes.sh`
- `tests/test-vpn-luci-adopted-apply.mjs`
- `tests/test-xray-adopted-overlay.sh`
- `tests/vm/README.md`
- `tests/vm/aggregate-candidate-evidence.sh`
- `tests/vm/download-immutable-actions-artifact.sh`
- `tests/vm/router-ui-vm-gate.sh`
- `tests/vm/run-preimage-rescue-smoke.sh`
- `tests/vm/write-candidate-content-descriptor.sh`

RC6-specific evidence publication files are references only; they must not be
treated as active RC7 evidence, and Phase 1 CI must not dispatch them.
