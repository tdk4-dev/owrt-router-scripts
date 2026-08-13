# Local release-signing key lifecycle

## Authority and current identity

The Mac Pro is the production signing authority. Production private keys live
outside repositories and build directories at:

```text
/Users/mac-pro-host/.config/premier-router/signing/
```

The current identity is `production-2026-07`, fingerprint
`d055711acf1d9a5b`. Its persistent files are:

```text
production-2026-07.sec          mode 0600
production-2026-07.pub          mode 0644
production-2026-07.fingerprint  mode 0644
ACTIVE_KEY                      mode 0644
```

The directory is mode `0700`. `ACTIVE_KEY` contains only the non-secret key
ID. Never place `.sec` files below a repository, build directory, shared
folder, release staging directory, shell history, log directory, or artifact
directory. Never copy a production private key to a controller laptop.

The pinned signing implementation is OpenWrt `usign` commit
`c4c72b1b07945ee192361dc751291a7c98d6adcd`. The Mac Pro binary used for this
identity is:

```text
/Users/mac-pro-host/.local/libexec/premier-router/usign-c4c72b1
```

## Non-overwriting key creation

For each future identity, choose a new stable ID and fail if any identity file
already exists. Generate directly inside the protected Mac Pro directory with
a restrictive umask, derive both fingerprints, and install the identity only
when they agree:

```sh
KEY_ID=production-YYYY-NN
SIGNING_DIR=/Users/mac-pro-host/.config/premier-router/signing
USIGN_HOST=/Users/mac-pro-host/.local/libexec/premier-router/usign-c4c72b1
umask 077
mkdir -p "$SIGNING_DIR"
chmod 0700 "$SIGNING_DIR"
for target in "$SIGNING_DIR/$KEY_ID.sec" "$SIGNING_DIR/$KEY_ID.pub" \
  "$SIGNING_DIR/$KEY_ID.fingerprint"; do
  test ! -e "$target"
done
"$USIGN_HOST" -G -s "$SIGNING_DIR/$KEY_ID.sec" \
  -p "$SIGNING_DIR/$KEY_ID.pub" \
  -c "Premier Router production signing key $KEY_ID"
chmod 0600 "$SIGNING_DIR/$KEY_ID.sec"
chmod 0644 "$SIGNING_DIR/$KEY_ID.pub"
PRIVATE_FP="$("$USIGN_HOST" -F -s "$SIGNING_DIR/$KEY_ID.sec")"
PUBLIC_FP="$("$USIGN_HOST" -F -p "$SIGNING_DIR/$KEY_ID.pub")"
test "$PRIVATE_FP" = "$PUBLIC_FP"
printf '%s\n' "$PUBLIC_FP" > "$SIGNING_DIR/$KEY_ID.fingerprint"
chmod 0644 "$SIGNING_DIR/$KEY_ID.fingerprint"
```

For initial provisioning, also require `ACTIVE_KEY` to be absent before
creating it. For a later rotation, verify its current value, review the public
registry change and fleet plan, and replace only that pointer atomically; never
overwrite an existing `.sec`, `.pub`, or `.fingerprint` identity file.

## Repository trust registry

`release/keys/trusted-keys.json` is the public source of truth. It permits
exactly one `active` key, no more than one `previous` key, and any number of
`revoked` identities. Every entry contains a key ID, derived fingerprint,
status, creation date, optional retirement date, and repository-relative
public-key path.

New signatures may use only `active`. Verification accepts `active` and
`previous`; it rejects `revoked` and unknown IDs. The former lost identity
`router-ui-prod-5b001ed1f9e63c96` is retained as verification-only `previous`;
its missing private key cannot be used for new signing.

For a planned future rotation, add the new public identity first, change the
current active entry to `previous`, set the new entry and `active_key_id`, and
bootstrap the fleet before signing normal updates with the new key. Once the
migration window closes, mark the previous entry `revoked` and add its
retirement date.

## Required local interface

Every signing command must explicitly set:

```sh
export ROUTER_UI_SIGNING_KEY=/absolute/path/to/private-key
export ROUTER_UI_SIGNING_KEY_ID=production-2026-07
export USIGN_BIN=/absolute/path/to/usign
```

`scripts/release-key-lib.sh` rejects a relative, missing, symlinked, or
non-`0600` private key. It derives the private-key fingerprint, resolves the
selected ID in the registry, requires that identity to be `active`, verifies
the committed public key and fingerprint, and refuses a mismatch. Release
provenance records only `signing_key_id` and `signing_key_fingerprint`.

Sign compact inputs locally with:

```sh
./scripts/sign-release-inputs.sh \
  --output-dir /absolute/path/to/signatures \
  --provenance /absolute/path/to/signing-provenance.json \
  /absolute/path/to/input-one /absolute/path/to/input-two
```

Verify a detached signature with a registry-authorized active or previous
identity:

```sh
./scripts/verify-release-signature.sh \
  production-2026-07 /absolute/path/to/input /absolute/path/to/input.sig
```

## Ephemeral Linux build-VM signing

`scripts/sign-in-linux-build-vm.sh` runs inside the Linux build VM. It disables
shell tracing, reads the private key only from stdin, creates a mode-`0600`
file below a mode-`0700` random `/dev/shm/router-ui-signing.*` directory, and
removes both before success. Private bytes never appear in argv.

From a Mac Pro shell, stream the key directly to the already configured build
VM connection. Replace only the non-secret VM connection and build paths:

```sh
SIGNING_DIR=/Users/mac-pro-host/.config/premier-router/signing
KEY_ID=production-2026-07
USIGN_HOST=/Users/mac-pro-host/.local/libexec/premier-router/usign-c4c72b1
test "$("$USIGN_HOST" -F -s "$SIGNING_DIR/$KEY_ID.sec")" = \
  "$(cat "$SIGNING_DIR/$KEY_ID.fingerprint")"

ssh BUILD_VM_SSH_TARGET \
  'cd /absolute/path/to/checkout &&
   ROUTER_UI_SIGNING_KEY_ID=production-2026-07 \
   USIGN_BIN=/absolute/path/to/usign \
   ./scripts/sign-in-linux-build-vm.sh \
     --output-dir /absolute/path/to/signatures \
     --provenance /absolute/path/to/signing-provenance.json \
     /absolute/path/to/compact-input' \
  < "$SIGNING_DIR/$KEY_ID.sec"
```

For canonical release tooling, the helper has a narrow allowlist:

```sh
ssh BUILD_VM_SSH_TARGET \
  'cd /absolute/path/to/checkout &&
   ROUTER_UI_SIGNING_KEY_ID=production-2026-07 \
   USIGN_BIN=/absolute/path/to/usign \
   IPK_DIR=/absolute/path/to/canonical-ipks \
   OUT_DIR=/absolute/path/to/installed-package-set \
   ./scripts/sign-in-linux-build-vm.sh \
     --release-tool stage-installed-package-set.sh' \
  < "$SIGNING_DIR/$KEY_ID.sec"
```

The other allowed tool is `stage-router-release.sh`. Set its documented
`IPK_DIR`, `OUT_ROOT`, `RELEASE_DIR`, source, and strict-release variables in
the remote environment. After either command, require the final
`ephemeral signing key removed` line and confirm that `/dev/shm` has no
`router-ui-signing.*` entry. Never use `set -x` around either command.

## Routers that trust only the lost key

A new-key signature is not trusted automatically by a router that has never
received the new public key. Each such router requires an authenticated local
SSH session or the existing owner-support channel before normal automatic
updates are re-enabled:

1. Copy `production-2026-07.pub` as data through stdin to a mode-`0600`
   temporary router file. Do not use a public download as the trust decision.
2. Run `usign -F -p` on the router and compare the result out of band with
   `d055711acf1d9a5b`.
3. Install the public key as
   `/usr/share/premier-router/keys/release/production-2026-07.pub`. Also update
   the compatibility `release.pub` and `release-key-id` files for older
   updater code.
4. Install the reviewed router form of `trusted-keys.json` at
   `/usr/share/premier-router/keys/trusted-keys.json`; its public-key paths are
   basenames below `/usr/share/premier-router/keys/release/`.
5. Transfer a small fixture and detached signature produced by the Mac Pro,
   then verify them on the router with `usign -q -V -p NEW_PUBLIC_KEY -m
   FIXTURE -x FIXTURE.sig`.
6. Only after the fingerprint and signed fixture both pass may normal
   automatic updates be enabled.

Record the router identity, old and new fingerprints, bootstrap time with
timezone, and verification result without recording credentials or owner
tokens.

## Encrypted backups

Do not copy plaintext private material outside the protected signing
directory. The Mac Pro provides `/usr/bin/openssl`; use envelope encryption
with a pre-existing offline backup-recipient X.509 certificate. Neither its
password nor its recipient private key belongs in this repository.

Choose each destination explicitly and refuse overwrite:

```sh
SIGNING_DIR=/Users/mac-pro-host/.config/premier-router/signing
KEY_ID=production-2026-07
RECIPIENT_CERT=/absolute/path/to/offline-backup-recipient-cert.pem
ENCRYPTED_BACKUP=/absolute/operator-chosen/path/$KEY_ID.sec.p7m
umask 077
test ! -e "$ENCRYPTED_BACKUP"
/usr/bin/openssl smime -encrypt -binary -aes256 \
  -in "$SIGNING_DIR/$KEY_ID.sec" -outform DER \
  -out "$ENCRYPTED_BACKUP" "$RECIPIENT_CERT"
chmod 0600 "$ENCRYPTED_BACKUP"
/usr/bin/shasum -a 256 "$ENCRYPTED_BACKUP" > "$ENCRYPTED_BACKUP.sha256"
```

Produce at least two separately checked encrypted copies. At least one must be
on media or storage outside the Mac Pro. Copy only the `.p7m` file and its
checksum, verify the checksum at each destination, and keep destination choice
and custody as an operator action rather than an automated repository script.
Production release signing remains blocked until both copies and their custody
locations are recorded in the operator's private inventory.

Test recovery without placing plaintext elsewhere. Decrypt only to a temporary
mode-`0600` file inside the protected signing directory, derive its public
fingerprint, compare it with the committed expected fingerprint, and remove it
immediately:

```sh
RECIPIENT_CERT=/absolute/path/to/offline-backup-recipient-cert.pem
RECIPIENT_KEY=/absolute/path/to/offline-backup-recipient-private-key.pem
RECOVERY_FILE="$(mktemp "$SIGNING_DIR/.recovery-test.XXXXXX.sec")"
trap 'rm -f "$RECOVERY_FILE"' EXIT HUP INT TERM
/usr/bin/openssl smime -decrypt -binary -inform DER \
  -in "$ENCRYPTED_BACKUP" -recip "$RECIPIENT_CERT" \
  -inkey "$RECIPIENT_KEY" -out "$RECOVERY_FILE"
chmod 0600 "$RECOVERY_FILE"
test "$("$USIGN_HOST" -F -s "$RECOVERY_FILE")" = \
  "$(cat "$SIGNING_DIR/$KEY_ID.fingerprint")"
rm -f "$RECOVERY_FILE"
trap - EXIT HUP INT TERM
test ! -e "$RECOVERY_FILE"
```

An encrypted copy is not accepted as a backup until its checksum and this
fingerprint recovery test both pass.
