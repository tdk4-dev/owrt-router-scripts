# Router UI 0.7.11 RC9 Phase 1 continuation record

- **Continuation date:** 2026-08-13 (Europe/Moscow)
- **Target identity:** application `0.7.11-rc.9`; package `0.7.11~rc9-1`; channel `candidate`
- **Reserved future tag only:** `vpn-panel-v0.7.11-rc.9`
- **Starting `origin/main`:** `18562f49bcac914acf3b07749f5b8863d8016e00`
- **Starting main tree:** `3ee316a845f3d1dff1835ab0f35660b7d8a456ef`
- **Exact PR #25 source:** `ded0d472efb2452ba40dd2847912f0230e899bb5`
- **Exact PR #25 tree:** `5db998924088f2b8aa1e95c70baf797f10830557`
- **Local provenance merge:** `6522e2ce7de0f31020213a5d66051a3d4a2693b`, parents exact main then exact PR #25 head

## Entry and preservation proof

Fresh fetched state matched both required preconditions. PRs #20, #24, and #25
remained open, draft, and unmerged; none was modified, closed, merged, or
rebased. Work proceeded only in
`codex/router-ui-0.7.11-rc9-phase1-continuation` and its isolated worktree.

The dirty primary checkout was not switched, stashed, reset, cleaned, or
edited. Its starting status fingerprint was
`1ed63aa2b14a611d7c3c60e0e61008e3ea376629de776a72daa82703e19fea0b`;
its tracked-diff fingerprint was
`c40a83012c2716e3756a44d265b198351f57146dcafacaceb7f0213c8972936f`.

Historical RC8 records remain byte-identical. In particular, the RC8 scope
ledger remains
`067045afce3fa4b6ab3698669f6dbfd18dc6f2307e5e25d46617ea458311bf72`,
and the historical RC8 manifest fixture remains
`8a9fa937aa18c8ad0a42d13c0f043636683b1eeaa2e6f2b6c9b5bb699b223b1e`.
The unknown signed-manifest digest for commit `68976508...` remains JSON
`null`; no digest is inferred or substituted.

## RC9 technical corrections

### Adopted Xray

One structural inspection now proves both the unique managed rule arrays and
the supported single-server VLESS Reality TCP capability. Preview,
confirmation, extraction, ownership health/status, and mutation all consume
that inspection. An unsupported configuration cannot become healthy and all
persistent controls, including Profile Use, remain fail closed.

The exact planned VM fixture is
`tests/vm/fixtures/phase1-adopted-xray.json`, with SHA-256
`dcfa1d5d3ead7c965f19eb548dc55bf669da84e75d801a53678285b866b9f00d`.
It explicitly declares `streamSettings.network = "tcp"`. The pre-RC9 fixture
without that field is retained as a negative regression and must fail the real
`inspect`, `extract`, and `patch-profile` helper path.

### Firstboot

The setup IPK treats AdGuardHome as optional. When the service and binary are
absent, the RD23/no-AdGuard path records an explicit skip, leaves DNS state
unchanged, and completes firstboot. Selecting AdGuard when it is absent fails
closed. Tailscale uses a unique temporary log, removes it on both success and
failure, and accepts registration only when `BackendState=Running` and a
Tailscale IPv4 address are both observed.

### Scope and Tier 0

The RC9 ledger retains the 158 inherited PR #24 paths and the independent 104
PR #20-identical result. Its explicit classifications are 83 trust/update, 11
adopted-overlay repair, 28 Phase 1 identity/test/workflow/documentation, 17
excluded 0.8-only surfaces, 19 preserved current-main paths, and zero
unexplained paths. Every path must be explicitly mapped; the default is
classification 6, `unexplained`, which is a binding stop.

Tier 0 declares its controlled temporary/output roots, shadows product,
compiler, signing, image, and VM commands, and separately guards 25 package,
compiler-adjacent, signing, staging, publication, and VM entrypoints. Its
machine-readable report has distinct zero counters for product builds, image
builds, compilers, signing/staging, publication, tool installation, VM
execution, forbidden invocations, and generated artifacts.

### Tier 0 renderer false positive and source-only continuation

The first frozen RC9 source commit
`92937e0cabf70e493596aba85bdba4d2a1ebb1bd` (tree
`ab071329367405b711442914eb0bf2cb7ef213a9`) stopped at the exact-tree Tier 0
`collateral-contracts` test. The renderer's entrypoint-local guard ran before
argument parsing and therefore mislabeled the source-only `--validate-only`
path as staging. The immutable NO-GO bundle remains outside this worktree at
`/private/tmp/router-ui-rc9-phase1-nogo-92937e0cabf70e493596aba85bdba4d2a1ebb1bd`;
its existing `SHA256SUMS` continues to verify. No package build or VM execution
occurred, so RC9 was not consumed.

The follow-up moves the guard decision after structured argument parsing.
Exactly `--validate-only` without `--output` may validate inputs and emit JSON
to stdout. Every other parsed execution path is blocked with exit 97 under
Tier 0 before input validation or PDF rendering, and an explicit
`--validate-only` plus `--output` combination is invalid even outside Tier 0.
Focused regressions require an empty validation guard log and no artifact,
exactly one staging event for guarded output mode with no output file, and
canonical validation refusal when valid signature proof is absent.

## Phase boundaries

Before packaging, the final committed tree must pass source closure,
independent review, exact-tree Tier 0, real helper inspection/extraction/profile
patching against the locked fixture, and one exact-head PR CI run. Only then
may the sole unsigned, non-production three-IPK build be invoked.

This record authorizes no canonical/double build, image generation, production
signing, protected workflow, Factory work, VirtualBox qualification, physical
router work, tag, release, distribution, rollout, or merge. A technical Phase
1 pass does not approve the inherited rollback/reconciliation scope for merge.
