#!/bin/sh
set -eu
umask 077

EVIDENCE_DIR="${EVIDENCE_DIR:?EVIDENCE_DIR is required}"
RELEASE_DIR="${RELEASE_DIR:?RELEASE_DIR is required}"
EXPECTED_SOURCE_SHA="${EXPECTED_SOURCE_SHA:?EXPECTED_SOURCE_SHA is required}"
QUALIFICATION="$EVIDENCE_DIR/qualification.json"
SUMS="$EVIDENCE_DIR/evidence-files-sha256sums"
MANIFEST="$RELEASE_DIR/router-release-manifest.json"

fail() { printf 'VIRTUALBOX-EVIDENCE-ERROR: %s\n' "$*" >&2; exit 1; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
verify_sums() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c evidence-files-sha256sums
  else
    shasum -a 256 -c evidence-files-sha256sums
  fi
}

printf '%s' "$EXPECTED_SOURCE_SHA" | grep -Eq '^[0-9a-f]{40}$' ||
  fail 'expected source SHA is malformed'
[ -d "$EVIDENCE_DIR" ] && [ ! -L "$EVIDENCE_DIR" ] ||
  fail 'evidence directory is missing or symlinked'
[ -s "$QUALIFICATION" ] && [ ! -L "$QUALIFICATION" ] ||
  fail 'qualification manifest is missing or symlinked'
[ -s "$SUMS" ] && [ ! -L "$SUMS" ] ||
  fail 'complete evidence checksums are missing or symlinked'
[ -s "$MANIFEST" ] || fail 'candidate release manifest is missing'

release_manifest_sha="$(sha256_file "$MANIFEST")"
release_source_sha="$(jq -er '.source_commit' "$MANIFEST")"
release_fingerprint="$(jq -er '.signing_key_fingerprint' "$MANIFEST")"
[ "$release_source_sha" = "$EXPECTED_SOURCE_SHA" ] ||
  fail 'candidate manifest source SHA differs from the requested source'
[ "$release_fingerprint" = d055711acf1d9a5b ] ||
  fail 'candidate is not signed by the required production key fingerprint'

jq -e \
  --arg source "$EXPECTED_SOURCE_SHA" \
  --arg manifest_sha "$release_manifest_sha" \
  --arg fingerprint "$release_fingerprint" '
  .schema_version == 1 and
  .result == "PASS" and
  .source_sha == $source and
  .release_manifest_sha256 == $manifest_sha and
  .signing_key_fingerprint == $fingerprint and
  .provider.platform == "Mac Pro" and
  .provider.hypervisor == "VirtualBox" and
  .provider.qemu_used == false and
  .provider.supervised == true and
  .vm.disposable_clone == true and
  .vm.locally_recoverable == true and
  .vm.hardware_disconnected == true and
  .vm.final_power_state == "poweroff" and
  .vm.clean_snapshot_restored == true and
  .transition.source_version == "0.7.10" and
  .transition.target_version == "0.7.11-rc.6" and
  .transition.candidate_validation.adoption_preview_only == true and
  .transition.candidate_validation.config_unchanged == true and
  .transition.candidate_validation.ownership_absent == true and
  .transition.pending_state == "committed_pending_reboot_validation" and
  .transition.pre_reboot_mutation_refused == true and
  .transition.boot_id_changed == true and
  .transition.post_reboot_state == "committed" and
  .transition.adoption_after_commit == true and
  .luci_apply.rpc_acl_write_path == true and
  .luci_apply.structural_config_update == true and
  .luci_apply.xray_restart == true and
  .luci_apply.rule_removal == true and
  .luci_apply.exact_failure_rollback == true and
  .luci_apply.tailscale_continuously_unchanged == true and
  .transition.exact_rc5_rollback == true and
  .browser.same_workstation == true and
  .browser.localhost_direct == true and
  (.browser.screenshots | type == "array" and length >= 2) and
  (.evidence_files | type == "array" and length >= 6) and
  all((.browser.screenshots + .evidence_files)[];
    type == "string" and length > 0 and
    (startswith("/") | not) and
    (contains("..") | not))
  ' "$QUALIFICATION" >/dev/null || fail 'qualification manifest contract failed'

listed="$(mktemp "${TMPDIR:-/tmp}/virtualbox-evidence-listed.XXXXXX")"
actual="$(mktemp "${TMPDIR:-/tmp}/virtualbox-evidence-actual.XXXXXX")"
cleanup() { rm -f "$listed" "$actual"; }
trap cleanup EXIT INT TERM

(cd "$EVIDENCE_DIR" && verify_sums >/dev/null) ||
  fail 'evidence file checksum verification failed'
[ -z "$(find "$EVIDENCE_DIR" -type l -print -quit)" ] ||
  fail 'evidence bundle contains a symlink'
awk '{sub(/^\*/, "", $2); print $2}' "$SUMS" | LC_ALL=C sort -u > "$listed"
(cd "$EVIDENCE_DIR" &&
  find . -type f ! -name evidence-files-sha256sums -print | LC_ALL=C sort) > "$actual"
cmp -s "$listed" "$actual" || fail 'checksum manifest does not cover every evidence file exactly'

jq -r '.browser.screenshots[], .evidence_files[]' "$QUALIFICATION" |
  while IFS= read -r relative; do
    [ -s "$EVIDENCE_DIR/$relative" ] && [ ! -L "$EVIDENCE_DIR/$relative" ] ||
      fail "referenced evidence file is missing, empty, or symlinked: $relative"
  done

printf 'Mac Pro VirtualBox-only RC6 qualification evidence passed for %s\n' \
  "$EXPECTED_SOURCE_SHA"
