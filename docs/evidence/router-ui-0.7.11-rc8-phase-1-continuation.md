# Router UI 0.7.11 RC8 Phase 1 continuation record

- **Continuation date:** 2026-08-13 (Europe/Moscow)
- **Target identity:** application `0.7.11-rc.8`; package `0.7.11~rc8-1`; channel `candidate`
- **Reserved future tag:** `vpn-panel-v0.7.11-rc.8`
- **Stable successor:** application `0.7.11`; package `0.7.11-1`
- **Starting `origin/main`:** `18562f49bcac914acf3b07749f5b8863d8016e00`
- **Starting main tree:** `3ee316a845f3d1dff1835ab0f35660b7d8a456ef`
- **Failed predecessor PR:** draft PR #24 at `97da893062ebed1e27e9b35dbf0b68f248c12dd7`, tree `db5e610c25eeda74f0ec0c931145249669eced69`
- **Local provenance merge:** `f47060aab1b1aaf965caf914af65894962551aeb`, parents exact main then exact PR #24 head

## Immutable entry proof

The primary checkout remained on
`wip/package-first-v0.8-safety-20260709-145349` at
`582024c2ea821295fd5b4945b641273ef70efac9`, tree
`200a762ed7c03421cc5b7a667927c56b8a3a724c`. Its complete
`git status --short --branch` fingerprint was
`5f651af8a8fc9cae49f0d1bda64af146422d8ebc47dff72e2d4d77eaa463c8a3`; its
tracked binary-diff fingerprint remained
`c40a83012c2716e3756a44d265b198351f57146dcafacaceb7f0213c8972936f`.
No primary-checkout or pre-existing worktree file was switched, stashed,
reset, cleaned, restored, or modified.

Fresh host-permission GitHub inspection proved that PR #24 remained open,
draft, unmerged, and exactly at the predecessor head above. PR #20 remained
open, draft, unmerged, and unchanged at
`f1c8bf0eb81a663340351276f3cafd3fdeab53f5`. PR #21 and the Phase 0 governance
head remained ancestors of fetched `origin/main`. The canonical scope digest
remained `795065bc4a9555ef283903ee757b9076d7cbfff6261d24bd1eda8258e1b8ff82`.

## RC7 invalidation and errata

RC7 is consumed and permanently invalid for this release train. This is a
conservative owner decision because RC7-labelled source was pushed publicly
and one RC7-labelled provisional package set was built and installed in a
disposable VM. This record does not claim that pre-freeze governance
mechanically required the RC8 number.

The RC7 provisional packages remain immutable failed evidence:

| Package | Size | SHA-256 |
|---|---:|---|
| `premier-router-core` | 61,503 | `beb5883cfdde8eb1a6e0ede83048c09d7e69b9c3a4caefb92eeb521c2ed7e5c5` |
| `luci-app-premier-router` | 14,429 | `14b27fb61ef65e83b41eabfa9655865f19aedfd0c15fb20d721050a3ed7c9b72` |
| `premier-router-setup` | 15,155 | `53689ebb7fa212c65190f34558eee943ff31cdc89c24ae57ae9cf95c3554f444` |

The checkpoint was invalidated because Tailscale Stop and Logout rendered with
an HTML `disabled` attribute even when the backend reported `running=true` and
`connected=true`. Passing boolean false produced `disabled="false"`, which is
still disabled under HTML boolean-attribute semantics. The prior 41-control
browser result is retained only as failure evidence and cannot satisfy any RC8
census gate.

The RC7 source record and independent review incorrectly described its source
preflight as build-free. Each of RC7 CI runs `31687159095` and `31687214144`
invoked `tests/test-updater-transaction-v2.sh`; that test built both the current
RC7 packages and historical RC5 packages. The workflow also installed `usign`
and `ucode`, compiling them with a CMake/compiler toolchain. RC8 Tier 0 removes
all such package, staging, signing, installation, and compilation behavior
rather than rewriting the historical RC7 reports.

The two distinct RC6 histories remain unchanged. In particular, the signed
manifest digest for `68976508e231cf8ab6fb441f8587de03c1903a3b` remains
unknown and represented as `null`; no digest is substituted from the
`f1c8bf0eb81a663340351276f3cafd3fdeab53f5` hotfix history.

## Complete inherited-diff disposition

The machine-readable ledger is
`docs/evidence/router-ui-0.7.11-rc8-scope-ledger.json`. It mechanically records
all 158 paths changed by PR #24 relative to its exact main base. Independent
blob comparison confirms that 104 of those 158 PR #24 final states are
byte-identical to PR #20; 54 are not.

The semantic disposition contains:

- 83 trust/update bridge paths;
- 11 adopted-overlay regression-repair paths;
- 28 RC identity, Phase 1 test, workflow, documentation, or evidence paths;
- 26 explicitly deferred Router UI 0.8-only paths;
- 10 current-main functionality or infrastructure paths requiring
  preservation or narrow reimplementation;
- zero unexplained or scope-conflicting paths.

The excluded user-visible behavior is limited to the explicit Phase 0
non-goals: the Router UI 0.8 first-boot/owner-preparation flow, its progress and
reset-to-setup UX, the 0.8 shared footer/navigation presentation, the new
AdGuard product page and dynamic installation, and the new Reset product page.
The existing VPN, Tailscale, and Update routes remain.

Current-main ownership metadata, Tailscale registered-running and secret-safe
log behavior, stable-asset guards, version-variable guards, lean RD23 policy,
registry data, relay behavior, and generic release safety are preserved or
narrowly reimplemented. The registry, relay, and canonical owner-policy files
were already byte-identical to main after PR #24 and therefore are outside the
158-path ledger; they remain untouched.

The RC8 browser correction is deliberately narrow: enabled Stop and Logout
controls omit the HTML `disabled` attribute, while unavailable and read-only
controls retain it. A complete LuCI view audit found and normalized every
reachable composite false-valued `disabled` expression; the mocked DOM now
interprets boolean attributes by presence, like a browser. Current-main
version-variable protection remains at the generic image-builder boundary;
the x86 compatibility entrypoint is required to delegate to that guarded
builder.

Tier 0 is now literally source-only. Repository entrypoints for package,
image, canonical/reproducibility, signing, staging, publishing, tool
installation, and buildful package-integration work fail immediately under an
exported runtime guard. Compiler and product-build command names are shadowed
by failing wrappers, and a before/after artifact inventory rejects generated
package, image, signed-manifest, release, or compiled outputs. The result JSON
records exact source SHA/tree and enforced invocation/artifact counts.
Automatic CI now runs feature-branch work only for `pull_request`, runs `push`
only on `main`, and retains optional `workflow_dispatch`; this prevents paired
push and pull-request runs for one feature SHA.

## RC8 acceptance and stop boundaries

Before the only package-build invocation, RC8 must have a clean exact draft-PR
head; a literally build-free Tier 0 with enforced zero product builds, zero
compiler calls, and zero artifacts; one automatic pull-request run and no
feature-branch push run for that SHA; and a complete independent diff review
with no blocker.

Once the sole RC8 package-build invocation begins, RC8 is consumed. That
invocation may produce only the core, LuCI, and setup IPKs. No tracked source
may change afterward. A build, hash, browser, RPC, ACL, backend, route, census,
or restoration failure invalidates RC8, requires exact guest restoration, and
ends this continuation without a retry or replacement bytes. A later
continuation must use RC9.

Even a complete Phase 1 continuation pass establishes only eligibility for a
separately authorized Phase 2 freeze decision. It does not authorize canonical
or reproducible builds, images, production signing, protected workflows,
VirtualBox release qualification, Factory, routers, hardware, tags, releases,
distribution, rollout, or merges.
