#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VALIDATOR="$ROOT_DIR/tests/integration/validate-rc15-virtualbox-evidence.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rc15-virtualbox-evidence.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
RELEASE_DIR="$TMP_ROOT/release"
EVIDENCE_DIR="$TMP_ROOT/evidence"
mkdir -p "$RELEASE_DIR" "$EVIDENCE_DIR/screenshots" "$EVIDENCE_DIR/logs" \
  "$EVIDENCE_DIR/observations"

jq -n --arg source "$SOURCE_SHA" '{
  source_commit:$source,
  signing_key_fingerprint:"d055711acf1d9a5b"
}' > "$RELEASE_DIR/router-release-manifest.json"
manifest_sha="$(sha256sum "$RELEASE_DIR/router-release-manifest.json" | awk '{print $1}')"

printf 'sanitized controller transcript\n' > "$EVIDENCE_DIR/logs/controller.log"
printf 'name="RouterUI-RC15-Valera-test"\nVMState="poweroff"\n' \
  > "$EVIDENCE_DIR/logs/vbox-showvminfo.txt"
python3 - "$EVIDENCE_DIR/screenshots/update.png" "$EVIDENCE_DIR/screenshots/vpn-rules.png" <<'PY'
import binascii, struct, sys, zlib
def chunk(name, payload):
    return struct.pack(">I", len(payload)) + name + payload + struct.pack(">I", binascii.crc32(name + payload) & 0xffffffff)
def write(path, rgb):
    w, h = 1280, 720
    row = b"\0" + bytes(rgb) * w
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(row * h, 1)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)
write(sys.argv[1], (32, 48, 64))
write(sys.argv[2], (48, 64, 32))
PY

jq -n --arg source "$SOURCE_SHA" --arg manifest "$manifest_sha" '{
  schema_version:1,source_sha:$source,release_manifest_sha256:$manifest,
  host_os:"Darwin",virtualbox_version:"6.1.50r161033",
  base_vm:"RouterUI-RC5-X86-d02b3bcd",base_snapshot:"exact-image-preboot",
  base_archive_sha256:"a3ac22e653fc8b0fa818163a4ae04b0693bf6a8bcf2e968feb4fdc791f3f5ad4",
  base_vdi_sha256:"54e37fdc012cb9d905219aeaf6c04e5da650b49bebfe5d6dfa8765fb3fb6614d",
  base_vm_uuid:"11111111-1111-4111-8111-111111111111",
  clone_name:"RouterUI-RC15-Valera-test",clone_uuid:"22222222-2222-4222-8222-222222222222",
  nic2:"none",final_power_state:"poweroff",qemu_processes_started:0
}' > "$EVIDENCE_DIR/observations/vm.json"

jq -n '{schema_version:1,
  source:{app_version:"0.7.11-rc.5",package_version:"0.7.11~rc5-1",protocol:2,
    source_commit:"d02b3bcd187a44d366469ed1f37bb1b273e60529"},
  target:{app_version:"0.7.11-rc.15",package_version:"0.7.11~rc15-1",protocol:2},
  boot_id_before:"11111111-2222-4333-8444-555555555555",
  boot_id_after:"66666666-7777-4888-8999-aaaaaaaaaaaa",
  candidate_state:"committed_pending_reboot_validation",post_reboot_state:"committed",
  ownership_before:"absent",ownership_after:"adopted-overlay",
  config_sha256_before:("a"*64),config_sha256_after_candidate:("a"*64),
  config_sha256_after_adoption:("a"*64),exact_rc5_rollback:true,rc15_reapplied:true,
  packages:[
    {name:"premier-router-core",version:"0.7.11~rc15-1",sha256:("b"*64)},
    {name:"luci-app-premier-router",version:"0.7.11~rc15-1",sha256:("c"*64)},
    {name:"premier-router-setup",version:"0.7.11~rc15-1",sha256:("d"*64)}]
}' > "$EVIDENCE_DIR/observations/transition.json"

jq -n '{schema_version:1,enrolled_test_identity:true,sample_count:120,failed_samples:0,
  pid_before:101,pid_after:101,identity_sha256:("e"*64),route_sha256_before:("f"*64),
  route_sha256_after:("f"*64),service_restarts:0,admin_path_interruptions:0
}' > "$EVIDENCE_DIR/observations/tailscale.json"

jq -n '{schema_version:1,rpc_acl_write_path:true,sentinel_count_before:0,
  sentinel_count_after_apply:1,sentinel_count_after_remove:0,xray_pid_before:201,
  xray_pid_after_apply:202,config_sha256_before:("1"*64),
  config_sha256_after_remove:("1"*64),config_sha256_after_injected_failure:("1"*64),
  injected_restart_failure:true,rollback_verified:true
}' > "$EVIDENCE_DIR/observations/luci.json"

jq -n '{schema_version:1,host_os:"Darwin",same_workstation:true,browser:"Firefox",
  direct_localhost:true,update_url:"http://127.0.0.1:18076/cgi-bin/luci/admin/update",
  vpn_url:"http://127.0.0.1:18076/cgi-bin/luci/admin/network/vpn",
  update_page_rc_badge:"0.7.11-rc.15",vpn_page_mode:"adopted-overlay",console_errors:0
}' > "$EVIDENCE_DIR/observations/browser.json"

jq -n --arg source "$SOURCE_SHA" --arg manifest_sha "$manifest_sha" '{
  schema_version:1,
  result:"PASS",
  source_sha:$source,
  release_manifest_sha256:$manifest_sha,
  signing_key_fingerprint:"d055711acf1d9a5b",
  provider:{platform:"Mac Pro",hypervisor:"VirtualBox",qemu_used:false,supervised:true},
  vm:{disposable_clone:true,locally_recoverable:true,hardware_disconnected:true,
    final_power_state:"poweroff",clean_snapshot_restored:true},
  observations:{vm_file:"observations/vm.json",transition_file:"observations/transition.json",
    tailscale_file:"observations/tailscale.json",luci_file:"observations/luci.json",
    browser_file:"observations/browser.json"},
  transition:{
    source:{app_version:"0.7.11-rc.5",package_version:"0.7.11~rc5-1",protocol:2,
      source_commit:"d02b3bcd187a44d366469ed1f37bb1b273e60529"},
    target:{app_version:"0.7.11-rc.15",package_version:"0.7.11~rc15-1",protocol:2},
    candidate_validation:{adoption_preview_only:true,config_unchanged:true,ownership_absent:true},
    pending_state:"committed_pending_reboot_validation",pre_reboot_mutation_refused:true,
    boot_id_changed:true,post_reboot_state:"committed",adoption_after_commit:true,
    exact_rc5_rollback:true
  },
  luci_apply:{rpc_acl_write_path:true,structural_config_update:true,xray_restart:true,
    rule_removal:true,exact_failure_rollback:true,tailscale_continuously_unchanged:true},
  browser:{same_workstation:true,localhost_direct:true,
    screenshots:["screenshots/update.png","screenshots/vpn-rules.png"]},
  evidence_files:["observations/vm.json","observations/transition.json",
    "observations/tailscale.json","observations/luci.json","observations/browser.json",
    "logs/controller.log","logs/vbox-showvminfo.txt"]
}' > "$EVIDENCE_DIR/qualification.json"

(cd "$EVIDENCE_DIR" &&
  find . -type f ! -name evidence-files-sha256sums -print | LC_ALL=C sort |
  while IFS= read -r file; do sha256sum "$file"; done > evidence-files-sha256sums)

EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_DIR="$RELEASE_DIR" \
  EXPECTED_SOURCE_SHA="$SOURCE_SHA" "$VALIDATOR" >/dev/null

cp "$EVIDENCE_DIR/qualification.json" "$TMP_ROOT/qualification.valid.json"
jq '.transition.source.package_version = "0.7.11~rc5-2"' \
  "$EVIDENCE_DIR/qualification.json" > "$EVIDENCE_DIR/qualification.json.new"
mv "$EVIDENCE_DIR/qualification.json.new" "$EVIDENCE_DIR/qualification.json"
(cd "$EVIDENCE_DIR" &&
  find . -type f ! -name evidence-files-sha256sums -print | LC_ALL=C sort |
  while IFS= read -r file; do sha256sum "$file"; done > evidence-files-sha256sums)
if EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_DIR="$RELEASE_DIR" \
  EXPECTED_SOURCE_SHA="$SOURCE_SHA" "$VALIDATOR" >/dev/null 2>&1; then
  printf 'Evidence with the wrong RC5 package version unexpectedly passed\n' >&2
  exit 1
fi
cp "$TMP_ROOT/qualification.valid.json" "$EVIDENCE_DIR/qualification.json"
(cd "$EVIDENCE_DIR" &&
  find . -type f ! -name evidence-files-sha256sums -print | LC_ALL=C sort |
  while IFS= read -r file; do sha256sum "$file"; done > evidence-files-sha256sums)

jq '.transition.source.source_commit = "0000000000000000000000000000000000000000"' \
  "$EVIDENCE_DIR/qualification.json" > "$EVIDENCE_DIR/qualification.json.new"
mv "$EVIDENCE_DIR/qualification.json.new" "$EVIDENCE_DIR/qualification.json"
(cd "$EVIDENCE_DIR" &&
  find . -type f ! -name evidence-files-sha256sums -print | LC_ALL=C sort |
  while IFS= read -r file; do sha256sum "$file"; done > evidence-files-sha256sums)
if EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_DIR="$RELEASE_DIR" \
  EXPECTED_SOURCE_SHA="$SOURCE_SHA" "$VALIDATOR" >/dev/null 2>&1; then
  printf 'Evidence with the wrong RC5 source commit unexpectedly passed\n' >&2
  exit 1
fi
cp "$TMP_ROOT/qualification.valid.json" "$EVIDENCE_DIR/qualification.json"
(cd "$EVIDENCE_DIR" &&
  find . -type f ! -name evidence-files-sha256sums -print | LC_ALL=C sort |
  while IFS= read -r file; do sha256sum "$file"; done > evidence-files-sha256sums)

ln -s logs/candidate.txt "$EVIDENCE_DIR/unexpected-link"
if EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_DIR="$RELEASE_DIR" \
  EXPECTED_SOURCE_SHA="$SOURCE_SHA" "$VALIDATOR" >/dev/null 2>&1; then
  printf 'Symlinked evidence unexpectedly passed the VirtualBox-only gate\n' >&2
  exit 1
fi
rm "$EVIDENCE_DIR/unexpected-link"

cp "$EVIDENCE_DIR/screenshots/update.png" "$TMP_ROOT/update.valid.png"
printf 'not a png\n' > "$EVIDENCE_DIR/screenshots/update.png"
(cd "$EVIDENCE_DIR" &&
  find . -type f ! -name evidence-files-sha256sums -print | LC_ALL=C sort |
  while IFS= read -r file; do sha256sum "$file"; done > evidence-files-sha256sums)
if EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_DIR="$RELEASE_DIR" \
  EXPECTED_SOURCE_SHA="$SOURCE_SHA" "$VALIDATOR" >/dev/null 2>&1; then
  printf 'Text disguised as a PNG unexpectedly passed the VirtualBox-only gate\n' >&2
  exit 1
fi
cp "$TMP_ROOT/update.valid.png" "$EVIDENCE_DIR/screenshots/update.png"
(cd "$EVIDENCE_DIR" &&
  find . -type f ! -name evidence-files-sha256sums -print | LC_ALL=C sort |
  while IFS= read -r file; do sha256sum "$file"; done > evidence-files-sha256sums)

first_sum="$(sed -n '1p' "$EVIDENCE_DIR/evidence-files-sha256sums")"
printf '%s\n' "$first_sum" >> "$EVIDENCE_DIR/evidence-files-sha256sums"
if EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_DIR="$RELEASE_DIR" \
  EXPECTED_SOURCE_SHA="$SOURCE_SHA" "$VALIDATOR" >/dev/null 2>&1; then
  printf 'Duplicate checksum entry unexpectedly passed the VirtualBox-only gate\n' >&2
  exit 1
fi
(cd "$EVIDENCE_DIR" &&
  find . -type f ! -name evidence-files-sha256sums -print | LC_ALL=C sort |
  while IFS= read -r file; do sha256sum "$file"; done > evidence-files-sha256sums)

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
