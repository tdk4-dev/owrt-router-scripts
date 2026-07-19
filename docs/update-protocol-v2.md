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

The recovery init service runs before normal use. A committed 0.7.9 bridge is
post-reboot validated and its no-op compatibility include is removed. The
signed installed manifest and exact known-good IPKs remain for manual rollback
and the next transaction.

Production keys are never stored in the repository. CI renders the public key
and key ID into canonical packages and public bootstrap scripts. PR jobs use an
ephemeral key whose ID starts with `test-`; strict validation refuses it.
Rotation requires a separately reviewed bridge release trusted by the old key
that installs the new public key, followed by manifests signed by the new key.
