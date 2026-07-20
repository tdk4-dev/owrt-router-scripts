# Router UI update protocol v2

Protocol v2 has three trust layers: an installed usign public key, a signed
stable pointer that pins one tag and manifest hash, and a signed target
manifest. Downloaded JSON is parsed as data; it is never sourced or evaluated.
The manifest is the sole authority for package names, order, byte sizes,
SHA-256 hashes, target compatibility, source transitions, validator, and bridge
assets.

The supervisor validates the source, downloads all target material, creates an
OpenWrt configuration recovery archive, prepares exact application rollback,
checks both persistent and temporary space, and only then records
`mutation_started=true`. Candidate-specific health rules live in the verified
target validator. The supervisor only implements protocol, transaction,
legacy-source, and rollback invariants.

Each transaction has one atomically replaced `state.json` below
`/root/premier-router-updates/<transaction-id>/`. It records source and target
identity, completed state, mutation flag, recovery and rollback paths, error,
boot identity, invocation, and worker ownership token. The persistent lock
binds token, PID, boot ID, and process start identity. A tuple of source
version, target tag, and manifest hash is quarantined after an automatic
failure and requires an explicit clear before automatic retry.

States before mutation recover to `failed_before_mutation`. Ambiguous applying,
validating, or committing states run the target validator and either commit or
roll back. Rollback reinstalls exact cached prior IPKs for package sources, or
restores and fingerprints the complete legacy application union plus its opkg
records. A rollback is reported as successful only after source validation.
`rollback_failed` and `recovery_required` are terminal, truthful failures.

Candidate validation ends in `committed_pending_reboot_validation`, not final
success. Only a later boot with a different boot ID may clean compatibility
files, run the target post-reboot validator, and advance the transaction to
`committed`.

The pre-mutation reservation is derived from the verified target archives and
accounts for target assets, extracted package and opkg overhead, exact legacy
rollback bytes when applicable, configuration recovery, installed manifests,
journal evidence, compatibility files, and a safety margin. Both persistent
storage and RAM-backed `/tmp` must satisfy the reservation before mutation.

The recovery init service runs before normal use. A committed 0.7.9 bridge is
post-reboot validated and its no-op compatibility include is removed. The
signed installed manifest and exact known-good IPKs remain for manual rollback
and the next transaction.

After final post-reboot validation, transient target downloads are removed.
The current known-good package set, the active transaction's exact source
rollback set, and at most two superseded successful transaction records are
retained. Active, rollback-pending, rollback-failed, recovery-required, and
reboot-validation-pending transactions are never pruned. Known-good package
sets are removed only when no retained transaction or installed manifest
references their exact manifest hash.

The production public key, fingerprint, and key ID are committed under
`release/keys/` and are the only trust root accepted by strict builds. The
private key is never stored in Git; it exists only as the protected
`ROUTER_UI_USIGN_SECRET_KEY` environment secret and is materialized for signing
as a mode-0600 temporary file. Test keys remain under `tests/fixtures/`; strict
validation refuses `test-*`, `dev-*`, and development identities. Rotation
requires a separately reviewed bridge release trusted by the old key that
installs the new public key, followed by manifests signed by the new key.
