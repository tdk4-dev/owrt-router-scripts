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
is_png() {
  python3 -c '
import struct, sys
p = sys.argv[1]
d = open(p, "rb").read()
assert len(d) >= 1024 and d[:8] == b"\x89PNG\r\n\x1a\n"
assert d[12:16] == b"IHDR" and d[-8:-4] == b"IEND"
w, h = struct.unpack(">II", d[16:24])
assert w >= 800 and h >= 600
' "$1"
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
  .observations.vm_file == "observations/vm.json" and
  .observations.transition_file == "observations/transition.json" and
  .observations.tailscale_file == "observations/tailscale.json" and
  .observations.luci_file == "observations/luci.json" and
  .observations.browser_file == "observations/browser.json" and
  .transition.source.app_version == "0.7.11-rc.5" and
  .transition.source.package_version == "0.7.11~rc5-1" and
  .transition.source.protocol == 2 and
  .transition.source.source_commit == "d02b3bcd187a44d366469ed1f37bb1b273e60529" and
  .transition.target.app_version == "0.7.11-rc.14" and
  .transition.target.package_version == "0.7.11~rc14-1" and
  .transition.target.protocol == 2 and
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
  .browser.screenshots == ["screenshots/update.png", "screenshots/vpn-rules.png"] and
  .evidence_files == [
    "observations/vm.json", "observations/transition.json",
    "observations/tailscale.json", "observations/luci.json",
    "observations/browser.json", "logs/controller.log",
    "logs/vbox-showvminfo.txt"
  ] and
  ((.browser.screenshots + .evidence_files) as $paths |
    ($paths | length) == ($paths | unique | length)) and
  all((.browser.screenshots + .evidence_files)[];
    type == "string" and length > 0 and
    (startswith("/") | not) and
    (contains("..") | not))
  ' "$QUALIFICATION" >/dev/null || fail 'qualification manifest contract failed'

VM_OBS="$EVIDENCE_DIR/observations/vm.json"
TRANSITION_OBS="$EVIDENCE_DIR/observations/transition.json"
TAILSCALE_OBS="$EVIDENCE_DIR/observations/tailscale.json"
LUCI_OBS="$EVIDENCE_DIR/observations/luci.json"
BROWSER_OBS="$EVIDENCE_DIR/observations/browser.json"

jq -e --arg source "$EXPECTED_SOURCE_SHA" --arg manifest "$release_manifest_sha" '
  .schema_version == 1 and .source_sha == $source and
  .release_manifest_sha256 == $manifest and
  .host_os == "Darwin" and
  (.virtualbox_version | test("^6\\.1\\.50r[0-9]+$")) and
  .base_vm == "RouterUI-RC5-X86-d02b3bcd" and
  .base_snapshot == "exact-image-preboot" and
  .base_archive_sha256 == "a3ac22e653fc8b0fa818163a4ae04b0693bf6a8bcf2e968feb4fdc791f3f5ad4" and
  .base_vdi_sha256 == "54e37fdc012cb9d905219aeaf6c04e5da650b49bebfe5d6dfa8765fb3fb6614d" and
  (.clone_name | startswith("RouterUI-RC14-Valera-")) and
  (.clone_uuid | test("^[0-9a-fA-F-]{36}$")) and
  .clone_uuid != .base_vm_uuid and .nic2 == "none" and
  .final_power_state == "poweroff" and .qemu_processes_started == 0
' "$VM_OBS" >/dev/null || fail 'observed VirtualBox identity contract failed'

jq -e '
  .schema_version == 1 and
  .source.app_version == "0.7.11-rc.5" and
  .source.package_version == "0.7.11~rc5-1" and .source.protocol == 2 and
  .source.source_commit == "d02b3bcd187a44d366469ed1f37bb1b273e60529" and
  .target.app_version == "0.7.11-rc.14" and
  .target.package_version == "0.7.11~rc14-1" and .target.protocol == 2 and
  (.boot_id_before | test("^[0-9a-f-]{36}$")) and
  (.boot_id_after | test("^[0-9a-f-]{36}$")) and
  .boot_id_before != .boot_id_after and
  .candidate_state == "committed_pending_reboot_validation" and
  .post_reboot_state == "committed" and
  .ownership_before == "absent" and .ownership_after == "adopted-overlay" and
  (.config_sha256_before | test("^[0-9a-f]{64}$")) and
  .config_sha256_before == .config_sha256_after_candidate and
  .config_sha256_before == .config_sha256_after_adoption and
  .exact_rc5_rollback == true and .rc14_reapplied == true and
  (.packages | type == "array" and length == 3) and
  ([.packages[].name] | sort) == [
    "luci-app-premier-router", "premier-router-core", "premier-router-setup"
  ] and
  all(.packages[];
    .version == "0.7.11~rc14-1" and (.sha256 | test("^[0-9a-f]{64}$")))
' "$TRANSITION_OBS" >/dev/null || fail 'observed transition contract failed'

jq -e '
  .schema_version == 1 and .enrolled_test_identity == true and
  .sample_count >= 60 and .failed_samples == 0 and
  (.pid_before | type == "number" and . > 1) and .pid_before == .pid_after and
  (.identity_sha256 | test("^[0-9a-f]{64}$")) and
  (.route_sha256_before | test("^[0-9a-f]{64}$")) and
  .route_sha256_before == .route_sha256_after and
  .service_restarts == 0 and .admin_path_interruptions == 0
' "$TAILSCALE_OBS" >/dev/null || fail 'observed Tailscale continuity contract failed'

jq -e '
  .schema_version == 1 and .rpc_acl_write_path == true and
  .sentinel_count_before == 0 and .sentinel_count_after_apply == 1 and
  .sentinel_count_after_remove == 0 and
  (.xray_pid_before | type == "number" and . > 1) and
  (.xray_pid_after_apply | type == "number" and . > 1) and
  .xray_pid_before != .xray_pid_after_apply and
  (.config_sha256_before | test("^[0-9a-f]{64}$")) and
  .config_sha256_before == .config_sha256_after_remove and
  .config_sha256_before == .config_sha256_after_injected_failure and
  .injected_restart_failure == true and .rollback_verified == true
' "$LUCI_OBS" >/dev/null || fail 'observed LuCI/Xray transaction contract failed'

jq -e '
  .schema_version == 1 and .host_os == "Darwin" and
  .same_workstation == true and .browser == "Firefox" and
  .direct_localhost == true and
  .update_url == "http://127.0.0.1:18076/cgi-bin/luci/admin/update" and
  .vpn_url == "http://127.0.0.1:18076/cgi-bin/luci/admin/network/vpn" and
  .update_page_rc_badge == "0.7.11-rc.14" and
  .vpn_page_mode == "adopted-overlay" and
  .console_errors == 0
' "$BROWSER_OBS" >/dev/null || fail 'observed same-workstation browser contract failed'

listed="$(mktemp "${TMPDIR:-/tmp}/virtualbox-evidence-listed.XXXXXX")"
actual="$(mktemp "${TMPDIR:-/tmp}/virtualbox-evidence-actual.XXXXXX")"
cleanup() { rm -f "$listed" "$listed.expected" "$actual"; }
trap cleanup EXIT INT TERM

(cd "$EVIDENCE_DIR" && verify_sums >/dev/null) ||
  fail 'evidence file checksum verification failed'
[ -z "$(find "$EVIDENCE_DIR" -type l -print -quit)" ] ||
  fail 'evidence bundle contains a symlink'
if grep -RIE 'vless://|tskey-|BEGIN [A-Z ]*PRIVATE KEY|subscription_url' \
  "$EVIDENCE_DIR" >/dev/null 2>&1; then
  fail 'evidence bundle contains secret-shaped text'
fi
awk '{sub(/^\*/, "", $2); print $2}' "$SUMS" | LC_ALL=C sort > "$listed"
(cd "$EVIDENCE_DIR" &&
  find . -type f ! -name evidence-files-sha256sums -print | LC_ALL=C sort) > "$actual"
cmp -s "$listed" "$actual" || fail 'checksum manifest does not cover every evidence file exactly'

cat > "$listed.expected" <<'EOF'
./logs/controller.log
./logs/vbox-showvminfo.txt
./observations/browser.json
./observations/luci.json
./observations/tailscale.json
./observations/transition.json
./observations/vm.json
./qualification.json
./screenshots/update.png
./screenshots/vpn-rules.png
EOF
cmp -s "$listed.expected" "$actual" || fail 'evidence bundle file allowlist failed'

jq -r '.browser.screenshots[], .evidence_files[]' "$QUALIFICATION" |
  while IFS= read -r relative; do
    [ -s "$EVIDENCE_DIR/$relative" ] && [ ! -L "$EVIDENCE_DIR/$relative" ] ||
      fail "referenced evidence file is missing, empty, or symlinked: $relative"
  done

jq -r '.browser.screenshots[]' "$QUALIFICATION" |
  while IFS= read -r relative; do
    is_png "$EVIDENCE_DIR/$relative" || fail "browser evidence is not a PNG: $relative"
  done

printf 'Mac Pro VirtualBox-only RC14 qualification evidence passed for %s\n' \
  "$EXPECTED_SOURCE_SHA"
