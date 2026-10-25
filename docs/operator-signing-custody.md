# Operator procedure: production signing custody

This is a procedure, not evidence that custody is complete. At preparation,
the operator confirmed that no private custody record exists. Production
signing remains blocked. Do not run these commands in CI or a build VM.

Run locally in an interactive terminal on the Mac Pro signing authority.
Keep the output and resulting record private. Nothing below signs release
artifacts or authorizes a release, hardware contact, discovery, or rollout.
The governing requirements remain
[local-signing-key-lifecycle.md](local-signing-key-lifecycle.md#encrypted-backups).

## Required operator choices

Choose these before running the command block:

1. An existing offline backup-recipient X.509 certificate and its matching
   recipient private key. The recipient key must remain under the operator's
   separate custody. Do not generate a replacement production signing key.
   If the recipient certificate/key or its passphrase is unavailable, stop.
2. Two new encrypted-backup filenames in existing operator-chosen directories.
   Neither destination may be inside a repository or build/artifact directory.
   This command block uses an on-host first copy. The second must be on
   mounted storage physically outside the Mac Pro, such
   as an independently held removable device or another host. A second
   directory or volume on the same Mac Pro is not off-host custody.
3. The private custodian label and confirmation that the second destination
   really is off-host. The script cannot infer physical custody from a path.
4. A private record filename outside every repository. The default below uses
   a new file under the authority account's private configuration directory.
   Keep this record private: it deliberately contains backup locations.

The operator must also retain access to the recipient key/passphrase separately
from these encrypted copies. Do not enter a passphrase into a shell variable,
command argument, repository file, transcript, or build log. OpenSSL may prompt
for it on the terminal during recovery.

## Exact local commands

Open a fresh shell with `bash --noprofile --norc` on the Mac Pro. Paste the
following block after replacing the path and label placeholders and
setting `OFF_HOST_CONFIRMED=yes` after physically verifying destination B.
Run it as the authority account, without `sudo` and without shell tracing.
The script refuses existing output files and does not overwrite the key.

```bash
set +x
set +o history
set -euo pipefail
umask 077

AUTHORITY_DIR=/Users/mac-pro-host/.config/premier-router/signing
KEY_ID=production-2026-07
EXPECTED_FP=d055711acf1d9a5b
USIGN=/Users/mac-pro-host/.local/libexec/premier-router/usign-c4c72b1

# EDIT: use existing operator-controlled paths; do not paste them into GitHub.
RECIPIENT_CERT="/absolute/operator-chosen/offline-recipient-cert.pem"
RECIPIENT_KEY="/absolute/operator-chosen/offline-recipient-private-key.pem"
BACKUP_A="/absolute/operator-chosen/on-host-destination-a/production-2026-07.sec.p7m"
BACKUP_B="/absolute/operator-chosen/off-host-destination-b/production-2026-07.sec.p7m"
CUSTODIAN_LABEL="REPLACE_WITH_PRIVATE_OPERATOR_LABEL"
OFF_HOST_CONFIRMED=no

RECORD_DIR=/Users/mac-pro-host/.config/premier-router/custody
RECORD="$RECORD_DIR/$KEY_ID-$(date -u +%Y%m%dT%H%M%SZ).json"
PRIVATE_KEY="$AUTHORITY_DIR/$KEY_ID.sec"
PUBLIC_KEY="$AUTHORITY_DIR/$KEY_ID.pub"

test "$(id -un)" = mac-pro-host
test "$OFF_HOST_CONFIRMED" = yes
test -n "$CUSTODIAN_LABEL"
test "$CUSTODIAN_LABEL" != REPLACE_WITH_PRIVATE_OPERATOR_LABEL
test -x "$USIGN"
test -f "$PRIVATE_KEY" && test ! -L "$PRIVATE_KEY"
test -f "$PUBLIC_KEY" && test ! -L "$PUBLIC_KEY"
test "$(/usr/bin/stat -f %Lp "$AUTHORITY_DIR")" = 700
test "$(/usr/bin/stat -f %Lp "$PRIVATE_KEY")" = 600
test "$(cat "$AUTHORITY_DIR/ACTIVE_KEY")" = "$KEY_ID"
test "$("$USIGN" -F -s "$PRIVATE_KEY")" = "$EXPECTED_FP"
test "$("$USIGN" -F -p "$PUBLIC_KEY")" = "$EXPECTED_FP"
test "$(cat "$AUTHORITY_DIR/$KEY_ID.fingerprint")" = "$EXPECTED_FP"
test -f "$RECIPIENT_CERT" && test -f "$RECIPIENT_KEY"
/usr/bin/openssl x509 -in "$RECIPIENT_CERT" -noout -checkend 0 >/dev/null

# Refuse placeholders, relative paths, aliases of one destination, repositories,
# and already-existing outputs before producing either encrypted copy.
export BACKUP_A BACKUP_B RECORD RECORD_DIR RECIPIENT_CERT RECIPIENT_KEY
/usr/bin/python -E - <<'PY'
import os
paths = [os.environ[k] for k in
         ('BACKUP_A', 'BACKUP_B', 'RECORD', 'RECIPIENT_CERT', 'RECIPIENT_KEY')]
for p in paths:
    assert os.path.isabs(p) and not p.startswith('/absolute/operator-chosen/'), 'Replace placeholder with an absolute private path'
for p in (os.environ['BACKUP_A'], os.environ['BACKUP_B']):
    assert os.path.isdir(os.path.dirname(p)), 'Backup parent must already exist'
    assert not os.path.lexists(p) and not os.path.lexists(p + '.sha256'), 'Refusing existing backup/checksum'
    assert p.endswith('.p7m'), 'Use an encrypted .p7m output'
assert os.path.realpath(os.environ['BACKUP_A']) != os.path.realpath(os.environ['BACKUP_B']), 'Destinations must be distinct'
for p in (os.environ['BACKUP_A'], os.environ['BACKUP_B'], os.environ['RECORD']):
    parent = os.path.realpath(os.path.dirname(p))
    while parent != os.path.dirname(parent):
        assert not os.path.exists(os.path.join(parent, '.git')), 'Custody output must be outside repositories'
        parent = os.path.dirname(parent)
assert not os.path.lexists(os.environ['RECORD']), 'Refusing existing custody record'
PY

ENCRYPTED_TEMP=
RECOVERY_FILE=
cleanup_custody() {
  test -z "$ENCRYPTED_TEMP" || rm -f "$ENCRYPTED_TEMP"
  test -z "$RECOVERY_FILE" || rm -f "$RECOVERY_FILE"
}
trap cleanup_custody EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for backup in "$BACKUP_A" "$BACKUP_B"; do
  ENCRYPTED_TEMP="$(mktemp "$(dirname "$backup")/.encrypted-backup.XXXXXX")"
  /usr/bin/openssl smime -encrypt -binary -aes256 \
    -in "$PRIVATE_KEY" -outform DER -out "$ENCRYPTED_TEMP" "$RECIPIENT_CERT"
  chmod 0600 "$ENCRYPTED_TEMP"
  # Hard-link installation fails atomically if the chosen output already exists.
  ln "$ENCRYPTED_TEMP" "$backup"
  rm -f "$ENCRYPTED_TEMP"
  ENCRYPTED_TEMP=
  test -s "$backup"
  test "$(/usr/bin/stat -f %Lp "$backup")" = 600
  (
    cd "$(dirname "$backup")"
    set -o noclobber
    /usr/bin/shasum -a 256 "$(basename "$backup")" > "$(basename "$backup").sha256"
    /usr/bin/shasum -a 256 -c "$(basename "$backup").sha256" >/dev/null
  )

  # Plaintext recovery exists only briefly inside the protected authority dir.
  RECOVERY_FILE="$(mktemp "$AUTHORITY_DIR/.recovery-test.sec.XXXXXX")"
  chmod 0600 "$RECOVERY_FILE"
  /usr/bin/openssl smime -decrypt -binary -inform DER -in "$backup" \
    -recip "$RECIPIENT_CERT" -inkey "$RECIPIENT_KEY" -out "$RECOVERY_FILE"
  test "$(/usr/bin/stat -f %Lp "$RECOVERY_FILE")" = 600
  test "$("$USIGN" -F -s "$RECOVERY_FILE")" = "$EXPECTED_FP"
  rm -f "$RECOVERY_FILE"
  test ! -e "$RECOVERY_FILE"
  RECOVERY_FILE=
done

# Write completion only after BOTH destination checksums and recovery tests pass.
test ! -L "$RECORD_DIR"
mkdir -p "$RECORD_DIR"
test "$(/usr/bin/stat -f %u "$RECORD_DIR")" = "$(id -u)"
chmod 0700 "$RECORD_DIR"
test "$(/usr/bin/stat -f %Lp "$RECORD_DIR")" = 700
export KEY_ID EXPECTED_FP CUSTODIAN_LABEL OFF_HOST_CONFIRMED
/usr/bin/python -E - <<'PY'
import datetime, hashlib, json, os
backups = []
for variable, off_host in [('BACKUP_A', False), ('BACKUP_B', True)]:
    path = os.environ[variable]
    with open(path, 'rb') as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    with open(path + '.sha256') as f:
        assert f.read().split()[0] == digest, 'Destination checksum changed'
    backups.append({'encrypted_file': path, 'sha256': digest,
                    'checksum_verified': True, 'off_host': off_host,
                    'recovery_test_passed': True,
                    'recovered_fingerprint': os.environ['EXPECTED_FP']})
record = {'schema_version': 1,
          'key_id': os.environ['KEY_ID'],
          'expected_fingerprint': os.environ['EXPECTED_FP'],
          'verified_at_utc': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
          'custodian': os.environ['CUSTODIAN_LABEL'],
          'off_host_custody_confirmed_by_operator': os.environ['OFF_HOST_CONFIRMED'] == 'yes',
          'backups': backups,
          'plaintext_recovery_files_removed': True,
          'complete': True}
fd = os.open(os.environ['RECORD'], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    json.dump(record, f, sort_keys=True, indent=2)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
PY
test "$(/usr/bin/stat -f %Lp "$RECORD")" = 600
cleanup_custody
trap - EXIT HUP INT TERM
printf 'Custody checks passed: two encrypted copies, one operator-confirmed off-host, two recovery tests, fingerprint %s. Private record created.\n' "$EXPECTED_FP"
```

If any command fails, no completion claim is valid. Keep any already-created
encrypted copy; do not delete or overwrite it automatically. Diagnose the
failure, choose new output filenames where necessary, and rerun all checks.
The destination filesystem must support restrictive file modes and hard links;
otherwise select suitable protected storage instead of weakening the checks.
Recovery tests run only on the Mac Pro and remove temporary plaintext on exit.

## Private record verification and public attestation

After creation, privately inspect the record and independently confirm its
custody choices. The following command checks record assertions and identity;
it does not repeat recovery or independently establish physical custody.
To verify the recorded assertions without displaying any
backup locations, run in the same shell:

```bash
export RECORD
/usr/bin/python -E - <<'PY'
import hashlib, json, os
with open(os.environ['RECORD'], 'rb') as f:
    raw = f.read()
d = json.loads(raw)
assert d['complete'] is True and d['key_id'] == 'production-2026-07'
assert d['expected_fingerprint'] == 'd055711acf1d9a5b'
assert d['plaintext_recovery_files_removed'] is True
assert d['off_host_custody_confirmed_by_operator'] is True
assert len(d['backups']) >= 2 and any(b['off_host'] is True for b in d['backups'])
assert all(b['checksum_verified'] is True and b['recovery_test_passed'] is True
           and b['recovered_fingerprint'] == 'd055711acf1d9a5b'
           for b in d['backups'])
print('custody_record_assertions_verified=true')
print('public_fingerprint=d055711acf1d9a5b')
print('custody_record_sha256=' + hashlib.sha256(raw).hexdigest())
PY
```

Retain the record and backup locations only in the operator's private inventory.
For later verification, provide the private **record path** through the private
operator channel; do not paste its contents or backup locations into an issue,
PR, repository, release evidence, or Actions input. Public evidence may retain
only the pass/fail attestation, verification time, public fingerprint and opaque
record SHA-256. The digest is an identity for the privately verified record, not
an independent proof of physical custody.
