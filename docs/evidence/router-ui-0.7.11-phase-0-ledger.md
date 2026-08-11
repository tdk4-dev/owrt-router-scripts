# Router UI 0.7.11 Phase 0 evidence ledger

- **Snapshot:** 2026-08-11 19:16 MSK (`+03:00`)
- **Scope:** governance, identity, acceptance contract, and declared deliverables only
- **Repository:** `tdk4-dev/owrt-router-scripts`
- **Decision record:** [Router UI 0.7.11 Phase 0 decision record](../decisions/2026-08-11-router-ui-0.7.11-phase-0.md)

## Classification

- **Current verified:** rechecked in this Phase 0 run from the fetched local
  repository or live GitHub metadata.
- **Retained historical:** recorded by immutable or operational evidence from
  an earlier exact source and not re-executed in Phase 0.
- **Owner decision:** a governance choice explicitly directed for this Phase 0
  package; it is not runtime evidence.
- **Still unverified:** deliberately unresolved; no positive claim or evidence
  transfer is permitted.

## Ledger

| ID | Classification | Fact | Evidence and constraint |
|---|---|---|---|
| CV-01 | Current verified | After a host-permission fetch, `origin/main` was `0db8355263914a6c0cd3fcafb409e565ed22ea0c`. | `git fetch origin --prune --tags`; `git rev-parse origin/main`. This is the Phase 0 base snapshot, not a permanent claim about future main. |
| CV-02 | Current verified | The primary checkout remained on `wip/package-first-v0.8-safety-20260709-145349` at `582024c2ea821295fd5b4945b641273ef70efac9` with modified `AGENTS.md`, modified `setup-rd23-vpn-ap.sh`, and the pre-existing untracked `.package-build/`, scope proposal, `docs/incidents/`, `output/`, and `tmp/`. | Initial `git status --short --branch`; tracked-diff SHA-256 `c40a83012c2716e3756a44d265b198351f57146dcafacaceb7f0213c8972936f`. Phase 0 must leave this state unchanged. |
| CV-03 | Current verified | The untracked 2026-07-24 scope proposal had SHA-256 `795065bc4a9555ef283903ee757b9076d7cbfff6261d24bd1eda8258e1b8ff82`. | Controller-side `shasum -a 256`; the tracked copy must remain byte-identical. |
| CV-04 | Current verified | The isolated task worktree was created as `codex/router-ui-0.7.11-phase0` from `origin/main` at `0db8355263914a6c0cd3fcafb409e565ed22ea0c`. | `git worktree add -b ... origin/main`, followed by clean status, branch, and log checks. |
| CV-05 | Current verified | The RC6 worktree was clean on `codex/router-ui-0.7.11-rc6`, tracking the same remote head `f1c8bf0eb81a663340351276f3cafd3fdeab53f5`. | Read-only status, branch, log, and revision checks in `.worktrees/router-ui-0.7.11-rc6`. |
| CV-06 | Current verified | `68976508e231cf8ab6fb441f8587de03c1903a3b` has tree `b8362d85404f47a07abd6f556fbe55f998de68e8`; `f1c8bf0eb81a663340351276f3cafd3fdeab53f5` has tree `c976abd2e4c47853f330dda500400d2f17bbacc7`. | `git rev-parse <commit>^{tree}`. The range contains `f385728...` and `f1c8bf0...` and changes nine files by 494 insertions/97 deletions. |
| CV-07 | Current verified | Both RC6 trees declare app `0.7.11-rc.6` and package `0.7.11~rc6-1`. | `git grep` at both exact commits over `luci-vpn-ui/VERSION`, installed-version source, and `PACKAGE_VERSION`. This proves the visible identity collision. |
| CV-08 | Current verified | PR #20 was open, draft, unmerged, mergeable, and clean at head `f1c8bf0eb81a663340351276f3cafd3fdeab53f5`, base `main` at `0db8355...`; CI runs `31422039526` and `31422040381` were successful. | Live GitHub connector plus host-permission `gh pr view` on 2026-08-11. [PR #20](https://github.com/tdk4-dev/owrt-router-scripts/pull/20). |
| CV-09 | Current verified | PR #20's description still names an earlier validation source and describes the pre-hotfix constrained adopted-control behavior. | Live PR metadata. The description is stale relative to its `f1c8bf0...` head and must not be treated as the canonical acceptance contract. Phase 0 did not rewrite it. |
| CV-10 | Current verified | PR #21 was open, draft, unmerged, mergeable, and clean at head `67451618cc94d76d920dc1c30fb5204c879b30af`, base `main` at `0db8355...`; CI runs `31495595408` and `31495667013` were successful. | Live GitHub connector plus host-permission `gh pr view` on 2026-08-11. [PR #21](https://github.com/tdk4-dev/owrt-router-scripts/pull/21). |
| CV-11 | Current verified | The saved readiness-plan commit `a06a2c9d87e3cbc76948ca6cf3b3b361cb0c0fa1` was not an ancestor of `origin/main`. | `git merge-base --is-ancestor`; Phase 0 used the saved worktree path and did not claim the plan was merged. |
| CV-12 | Current verified | No GitHub release matching `0.7.11` or RC6, no `vpn-panel-v0.7.11-rc.6` GitHub tag, and no matching fetched local tag existed at the snapshot. | Host-permission `gh release list`, `gh api .../matching-refs/tags/...`, and fetched `git tag --list`. This proves unpublished state only at the snapshot time. |
| CV-13 | Current verified | No fetched branch/tag/ref matched an RC7 candidate identity. | `git for-each-ref` after fetch. Phase 0 reserves a future name; it does not bind bytes. |
| RH-01 | Retained historical | Exact source `6897650...` passed the full Mac Pro VirtualBox RC5 to RC6 update/reboot/commit/rollback path, adoption/direct-rule gates, and the initial supervised Valera commit. | Controller incident record `INC-2026-08-10-04`. This evidence remains bound to source/tree/start state and does not transfer to the hotfix or RC7. |
| RH-02 | Retained historical | Exact hotfix source `f1c8bf0...` enabled all declared controls on a healthy adopted overlay; its push and PR CI passed; a production-signed package-only stage had manifest SHA-256 `3c1e3159fd208dac77689fb997f10d98bd5847f0db274903510726d7232e3c32`. | `INC-2026-08-10-06`, saved readiness plan, and retained memory cross-check. It had 37 assets and zero images. |
| RH-03 | Retained historical | The hotfix's focused VirtualBox path began from an already-adopted RC6 and the Valera transaction `20260810T191838Z-b4577fb771899d01` committed with an exact profile switch/back. | `INC-2026-08-10-06` and `NETWORK_INVENTORY.md`. It is canary evidence, not a fresh bootstrap, image, Factory, or RC7 qualification. |
| RH-04 | Retained historical | Valera's Xray and transparent-routing services remained disabled for autostart and the earlier OOM incident remained under monitoring. | `INC-2026-08-10-01` and `NETWORK_INVENTORY.md`. No Phase 0 router contact was made. |
| OD-01 | Owner decision | The next candidate identity is `0.7.11-rc.7` / `0.7.11~rc7-1`; both RC6 byte sets are quarantined and must never be published or overwritten under one identity. | Current Phase 0 direction, recorded in the decision record. This is governance, not evidence that RC7 exists. |
| OD-02 | Owner decision | Healthy adopted overlays retain global VPN, profiles, subscriptions, ping refresh, automatic switching, direct rules, and device VPN; adoption-required, drift/recovery, reboot-pending, and read-only states fail closed. | Current Phase 0 direction and acceptance matrix. |
| OD-03 | Owner decision | Three IPKs, x86, RD23 stock, RD23 ubootmod, signed manifests/contracts, and ordinary-user guidance are included. | Current Phase 0 direction. No variant is deferred; a future defer requires another explicit pre-freeze owner decision. |
| OD-04 | Owner decision | `0.7.11` is a trust/update bridge and narrow regression repair, not a feature release. | 2026-07-24 scope proposal plus current Phase 0 direction. |
| UV-01 | Still unverified | The authoritative signed release-manifest digest for the `6897650...` RC6 byte set was not found in the authorized local records inspected. | Keep unknown. Do not substitute the `f1c8bf0...` digest or reconstruct a retrospective manifest. |
| UV-02 | Still unverified | RC7 source/tree, package/image bytes, manifests, signatures, contracts, and test evidence do not exist as Phase 0 outputs. | Deliberate stop boundary. They require later implementation and separate authorization. |
| UV-03 | Still unverified | None of the declared RC7 variants has exact-byte VM, Factory, hardware, or ordinary-user qualification. | RC6 evidence cannot close these gates. |
| UV-04 | Still unverified | PR #21 containment in `origin/main`, Phase 0 ratification/merge, PR #20 disposition, and any later RC7 freeze/release approvals remain open. | Required merge/order gates; Phase 0 creates only a draft documentation PR. |

## Evidence-use rules

1. A current-verified GitHub or ref fact must be rechecked after any remote
   state change.
2. A retained-historical fact may explain risk or select a future test, but it
   cannot qualify changed bytes.
3. An owner decision defines scope; it does not prove implementation or
   readiness.
4. A still-unverified item remains open until exact, attributable evidence
   exists. Absence of a record is not permission to infer success.

No secrets, private configuration bodies, subscription material, signing
private keys, or backup contents are included in this ledger.
