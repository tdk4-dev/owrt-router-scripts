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
`committed`. VPN configuration mutations, including Xray adoption and direct
rule application, are blocked until that final state. A compatible,
unambiguous manual Xray configuration may pass candidate and post-reboot
validation through a read-only adoption preview; validation never adopts it.

Protocol-v2 protected state includes `/etc/premier-router/xray-ownership.json`
as well as the Xray and UCI configuration trees. Its presence, absence, bytes,
fingerprint, snapshot, and exact rollback are therefore part of the update
transaction contract.

Adopted-overlay changes use a separate exclusive lock and schema-2 phase
journal under `/etc/premier-router/xray-transactions`. Each transaction keeps
exact configuration, rule-list, and ownership preimages, rechecks the live
configuration immediately before every persistent mutation, and recovers
deterministically before rpcd, uhttpd, or cron starts. Unknown external Xray
bytes are never overwritten during recovery. Completed transaction retention
is bounded; unresolved recovery evidence is retained.

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

The public trust registry is committed as `release/keys/trusted-keys.json`.
New signing requires its one active identity; verification accepts active and
the optional previous identity, and rejects revoked or unknown IDs. The
private key is never stored in Git. It is selected explicitly with
`ROUTER_UI_SIGNING_KEY`, `ROUTER_UI_SIGNING_KEY_ID`, and an absolute
`USIGN_BIN`, then fingerprint-checked before use. Production signing streams
the key from the Mac Pro into `/dev/shm` in the Linux build VM and removes it
immediately. See `docs/local-signing-key-lifecycle.md` for rotation, encrypted
backup, and manual fleet-bootstrap requirements.
