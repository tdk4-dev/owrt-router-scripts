#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VALIDATOR="$ROOT_DIR/tests/integration/validate-rc6-virtualbox-evidence.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rc6-virtualbox-evidence.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
RELEASE_DIR="$TMP_ROOT/release"
EVIDENCE_DIR="$TMP_ROOT/evidence"
mkdir -p "$RELEASE_DIR" "$EVIDENCE_DIR/screenshots" "$EVIDENCE_DIR/logs"

jq -n --arg source "$SOURCE_SHA" '{
  source_commit:$source,
  signing_key_fingerprint:"d055711acf1d9a5b"
}' > "$RELEASE_DIR/router-release-manifest.json"
manifest_sha="$(sha256sum "$RELEASE_DIR/router-release-manifest.json" | awk '{print $1}')"

for file in candidate post-reboot luci-apply rollback tailscale vm-final; do
  printf '%s verified\n' "$file" > "$EVIDENCE_DIR/logs/$file.txt"
done
printf 'sanitized status page\n' > "$EVIDENCE_DIR/screenshots/status.png"
printf 'sanitized direct rules page\n' > "$EVIDENCE_DIR/screenshots/rules.png"

jq -n --arg source "$SOURCE_SHA" --arg manifest_sha "$manifest_sha" '{
  schema_version:1,
  result:"PASS",
  source_sha:$source,
  release_manifest_sha256:$manifest_sha,
  signing_key_fingerprint:"d055711acf1d9a5b",
  provider:{platform:"Mac Pro",hypervisor:"VirtualBox",qemu_used:false,supervised:true},
  vm:{disposable_clone:true,locally_recoverable:true,hardware_disconnected:true,
    final_power_state:"poweroff",clean_snapshot_restored:true},
  transition:{
    source_version:"0.7.10",target_version:"0.7.11-rc.6",
    candidate_validation:{adoption_preview_only:true,config_unchanged:true,ownership_absent:true},
    pending_state:"committed_pending_reboot_validation",pre_reboot_mutation_refused:true,
    boot_id_changed:true,post_reboot_state:"committed",adoption_after_commit:true,
    exact_rc5_rollback:true
  },
  luci_apply:{rpc_acl_write_path:true,structural_config_update:true,xray_restart:true,
    rule_removal:true,exact_failure_rollback:true,tailscale_continuously_unchanged:true},
  browser:{same_workstation:true,localhost_direct:true,
    screenshots:["screenshots/status.png","screenshots/rules.png"]},
  evidence_files:["logs/candidate.txt","logs/post-reboot.txt","logs/luci-apply.txt",
    "logs/rollback.txt","logs/tailscale.txt","logs/vm-final.txt"]
}' > "$EVIDENCE_DIR/qualification.json"

(cd "$EVIDENCE_DIR" &&
  find . -type f ! -name evidence-files-sha256sums -print | LC_ALL=C sort |
  while IFS= read -r file; do sha256sum "$file"; done > evidence-files-sha256sums)

EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_DIR="$RELEASE_DIR" \
  EXPECTED_SOURCE_SHA="$SOURCE_SHA" "$VALIDATOR" >/dev/null

ln -s logs/candidate.txt "$EVIDENCE_DIR/unexpected-link"
if EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_DIR="$RELEASE_DIR" \
  EXPECTED_SOURCE_SHA="$SOURCE_SHA" "$VALIDATOR" >/dev/null 2>&1; then
  printf 'Symlinked evidence unexpectedly passed the VirtualBox-only gate\n' >&2
  exit 1
fi
rm "$EVIDENCE_DIR/unexpected-link"

jq '.provider.qemu_used = true' "$EVIDENCE_DIR/qualification.json" \
  > "$EVIDENCE_DIR/qualification.json.new"
mv "$EVIDENCE_DIR/qualification.json.new" "$EVIDENCE_DIR/qualification.json"
(cd "$EVIDENCE_DIR" &&
  find . -type f ! -name evidence-files-sha256sums -print | LC_ALL=C sort |
  while IFS= read -r file; do sha256sum "$file"; done > evidence-files-sha256sums)
if EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_DIR="$RELEASE_DIR" \
  EXPECTED_SOURCE_SHA="$SOURCE_SHA" "$VALIDATOR" >/dev/null 2>&1; then
  printf 'QEMU-backed evidence unexpectedly passed the VirtualBox-only gate\n' >&2
  exit 1
fi

printf 'Mac Pro VirtualBox evidence contract and QEMU refusal tests passed\n'
