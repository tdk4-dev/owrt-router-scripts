# Router UI 0.7.11 package-only release checklist

Authority: [package-only amendment](decisions/2026-10-04-router-ui-0.7.11-package-only-amendment.md)
and [RC20 transition amendment](decisions/2026-10-04-router-ui-0.7.11-rc20-rc7-contract.md).
Current source is RC20; the future stable tuple is app `0.7.11`, package
`0.7.11-1`, channel `stable`. Production key ID is `production-2026-07`,
derived public fingerprint `d055711acf1d9a5b`.

The canonical software deliverables are exactly `premier-router-core`,
`luci-app-premier-router` and `premier-router-setup`, together with their signed
feed/manifests/checksums, provenance, and installation/update/rollback guidance.
Firmware and Factory production qualification are deferred to 0.8.0. Images
and Factory assets must be absent, not merely optional, in this package set.

## Before any canonical build or production signing

- Verify the exact clean source commit and tree, reviewed integration ancestry,
  version files, transition contract and active public trust registry.
- Run fresh exact-head Tier 0 and CI. Previous RC18 and unsigned stable
  provisional evidence cannot qualify a changed source or byte set.
- Verify the operator-private custody record under
  [local-signing-key-lifecycle.md](local-signing-key-lifecycle.md): two separately
  checksum-verified encrypted copies, at least one off-host, and successful
  recovery yielding the expected fingerprint. Custody and recipient-key
  protection passed the current operator-authorized procedure. Recheck the private record before signing; a historical pass alone
  cannot establish its current assertions. Follow [the operator procedure](operator-signing-custody.md).
- Record only a non-secret pass/fail attestation and opaque private-record
  digest in public evidence. Never include private key bytes or backup paths.

Source-only contract check, using the identity actually present in the clean
checkout (stable is valid only after a separate reviewed promotion):

```sh
SOURCE_SHA="$(git rev-parse HEAD)"
SOURCE_TREE="$(git rev-parse 'HEAD^{tree}')"
APP_VERSION="$(sed -n '1p' luci-vpn-ui/VERSION)"
PACKAGE_VERSION="$(sed -n '1p' luci-vpn-ui/PACKAGE_VERSION)"
case "$APP_VERSION" in *-rc.*) CHANNEL=candidate ;; *) CHANNEL=stable ;; esac
python3 scripts/verify-router-ui-package-candidate.py source \
  --source-sha "$SOURCE_SHA" --source-tree "$SOURCE_TREE" \
  --app-version "$APP_VERSION" --package-version "$PACKAGE_VERSION" \
  --channel "$CHANNEL"
EXPECTED_SOURCE_SHA="$SOURCE_SHA" EXPECTED_SOURCE_TREE="$SOURCE_TREE" \
  tests/run-router-ui-source-preflight.sh
```

## Canonical preparation after custody is verified

- The active `validate-router-ui-candidate.yml` is a manual, parameterized
  package-only preparation path. Supply the exact source SHA and expected
  app/package/channel tuple, explicit custody confirmation and private-record
  SHA-256. Keep workflow-definition SHA/run identity distinct from product
  source SHA/tree. Preparation is not VM or hardware qualification.
- Build the three packages from two independent clean checkouts with the same
  pinned production inputs. Retain source/tree/epoch, toolchain/feed inputs,
  commands and outputs. Require byte equality of all IPKs and unsigned feed
  files; retain one canonical set. Do not rebuild it during qualification.
- Use the protected production signing path. Derive the private and public
  fingerprints and require the expected active identity; an environment
  selector or filename alone is insufficient. Remove ephemeral signing
  material before reporting success.
- Sign and verify the retained feed, installed/release manifests, channel
  pointer and checksums. Verify every filename, size and SHA-256, and test
  rejection of test/development signing identities. Require exactly three
  project IPKs, zero firmware images and zero Factory contracts.
- Retain immutable artifact ID/digest, complete provenance and strict
  verification results. The active `release-vpn-panel.yml` only verifies a
  retained package artifact by exact ID/digest; it does not rebuild, create a
  tag, create a release, publish, or enable discovery.

## Exact-byte qualification and hardware handoff

- Complete the real authenticated 46-control browser census and every
  applicable state through LuCI/RPC/ACL/backend, with console/network capture,
  enabled/disabled state, mutations and exact restoration. Exclusions require
  a specific governing contract. Read-only state requires backend ACL denial.
- Complete every declared supported baseline, reinstall/idempotence, reboot
  validation/commit, exact rollback/reapply, storage/download/checksum/signature/
  compatibility failure, ownership/configuration/init restoration, legacy init
  migration and effective bypass restart/DHCP/reboot matrix on those exact
  signed bytes. RC18 is unsupported: verify pre-mutation refusal unchanged.
  RC7 is also unsupported under the RC20 amendment: no canonical signed RC7
  bundle exists, so its real-package transition is non-applicable. Verify
  manifest exclusion and fail-closed authorization without fabricating RC7 bytes.
- Preserve immutable source/tree/package/manifest hashes and all test results.
  Write `READY_FOR_HARDWARE.md` outside the qualified source tree. Report NO-GO
  if any mandatory gate is incomplete. Changing source, tooling or bytes
  invalidates affected evidence and follows the new-RC rule.
- Only after all preceding gates pass, obtain separate authorization for one
  owner-controlled physical canary. Use the frozen VM-qualified bytes unchanged;
  validate actual application/network behavior, management access, reboot,
  persistence, rollback and recovery. VM success does not satisfy this gate.

## Publication remains separate

No hardware, merge, final tag, GitHub Release, GitHub Latest, normal discovery
or automatic rollout is authorized by this checklist or the current task.
Before any separately authorized publication, require the exact release commit
contained in `origin/main`, completed hardware evidence and immutable assets.
Never rebuild or re-sign after qualification to fit a new publication commit.
The first public stable release remains manual-first and must not implicitly
become GitHub Latest. The explicit publisher authorization and main-ancestry
guards remain in force; do not dispatch historical RC publication workflows.

RC8/RC15 evidence workflows and the archived old candidate/release definitions
are historical contracts. Their fixed source versions, VM layout, synthetic
successor, image and evidence assumptions do not qualify this package-only
stable path and must not be relabeled as current evidence.
