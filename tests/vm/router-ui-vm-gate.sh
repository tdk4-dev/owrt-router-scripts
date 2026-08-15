#!/bin/bash
set -Eeuo pipefail
[ -z "${ROUTER_UI_TIER0_GUARD_LOG:-}" ] || { printf 'vm-execution:%s\n' "${0##*/}" >> "$ROUTER_UI_TIER0_GUARD_LOG"; exit 97; }
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/tests/vm/fail-closed-runner.sh"
source "$ROOT_DIR/tests/vm/recovery-readiness.sh"

VM_MODE="${ROUTER_UI_VM_MODE:-candidate}"
RELEASE_DIR="${RELEASE_DIR:-}"
X86_IMAGE_ARCHIVE="${X86_IMAGE_ARCHIVE:-}"
SYNTHETIC_DIR="${SYNTHETIC_DIR:-}"
EVIDENCE_DIR="${EVIDENCE_DIR:?EVIDENCE_DIR is required}"
VM_CASE="${ROUTER_UI_VM_CASE:-${ROUTER_UI_VM_DIAGNOSTIC_CASE:-full}}"
DIAGNOSTIC_CASE="$VM_CASE"
DIAGNOSTIC_RUN="${ROUTER_UI_VM_DIAGNOSTIC:-0}"
VM_ONLY="${ROUTER_UI_VM_ONLY:-0}"
ALLOW_LEGACY_CONTRACT="${ROUTER_UI_VM_ALLOW_LEGACY_CONTRACT:-0}"
HARNESS_SOURCE_SHA="${ROUTER_UI_VM_HARNESS_SHA:-}"
VM_SOURCE_VERSION="${ROUTER_UI_VM_SOURCE_VERSION:-}"
VM_ACTIVE_VERSION=""
VM_PHASE_SELECTOR="${ROUTER_UI_VM_PHASE:-all}"
VM_FAULT_BOUNDARY="${ROUTER_UI_VM_FAULT_BOUNDARY:-}"
VM_RECOVERY_TIMEOUT_SECONDS="${ROUTER_UI_VM_RECOVERY_TIMEOUT_SECONDS:-600}"
BASELINE_PACK_DIR="${ROUTER_UI_BASELINE_PACK_DIR:-}"
BASELINE_OUTPUT_DIR="${ROUTER_UI_BASELINE_OUTPUT_DIR:-}"
BASELINE_PACK_DIGEST="${ROUTER_UI_BASELINE_PACK_DIGEST:-}"
BASELINE_SELECTOR="${ROUTER_UI_BASELINE_SELECTOR:-all}"
BASELINE_ASSET_CACHE_DIR="${ROUTER_UI_BASELINE_ASSET_CACHE_DIR:-}"
BASELINE_LOCK="$ROOT_DIR/tests/vm/legacy-baseline-lock.json"
BASELINE_CONTRACT_DIGEST_SCRIPT="$ROOT_DIR/tests/vm/baseline-contract-digest.sh"
BASELINE_CONTRACT_DIGEST=""
FIXTURE_DIR="$ROOT_DIR/tests/vm/fixtures/legacy-nonsecret"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
SERVER_PORT="${ROUTER_UI_VM_HTTPS_PORT:-18443}"
SSH_PORT="${ROUTER_UI_VM_SSH_PORT:-22220}"
HTTP_PORT="${ROUTER_UI_VM_HTTP_PORT:-18080}"
SERIAL_PORT="${ROUTER_UI_VM_SERIAL_PORT:-22330}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-vm-gate.XXXXXX")"
ORIGIN="https://10.0.2.2:$SERVER_PORT"
HOST_ORIGIN="https://127.0.0.1:$SERVER_PORT"
BASELINE_VERSIONS=(0.5.1 0.5.2 0.6.0 0.7.0 0.7.1 0.7.2 0.7.3 0.7.4 0.7.5 0.7.6 0.7.8 0.7.9 0.7.10)
FLEET_BASELINE_VERSIONS=(0.7.1 0.7.9 0.7.10)
CANDIDATE_APP_VERSION=""
CANDIDATE_PACKAGE_VERSION=""
CANDIDATE_RELEASE_TAG=""
CANDIDATE_KEY_ID=""
CANDIDATE_KEY_FINGERPRINT=""
SUCCESSOR_APP_VERSION=""
SUCCESSOR_PACKAGE_VERSION=""
SUCCESSOR_RELEASE_TAG=""
CANDIDATE_CONTRACT_MODE=""
DUAL_DAEMON_SAMPLES="${ROUTER_UI_VM_DUAL_DAEMON_SAMPLES:-15}"
DUAL_DAEMON_INTERVAL_SECONDS="${ROUTER_UI_VM_DUAL_DAEMON_INTERVAL_SECONDS:-2}"
FAULT_BOUNDARIES=(before-mutation snapshot_ready applying after-premier-router-core after-luci-app-premier-router after-premier-router-setup validating committing rollback_pending rolling_back rollback-after-premier-router-core rollback-after-luci-app-premier-router rollback-after-premier-router-setup compatibility-cleanup post-reboot-validation)
CURRENT_PID=""
SERVER_PID=""
STOCK_WRITABLE_KIB=0
STOCK_UBIFS_DF_KIB=0
UBOOTMOD_WRITABLE_KIB=0
UBOOTMOD_UBIFS_DF_KIB=0

cleanup() {
  status=$?
  trap - EXIT INT TERM
  set +e
  if [[ -n "${VM_PHASE_EXECUTOR_PID:-}" ]]; then
    kill "$VM_PHASE_EXECUTOR_PID" 2>/dev/null
    wait "$VM_PHASE_EXECUTOR_PID" 2>/dev/null
    VM_PHASE_EXECUTOR_PID=""
  fi
  if [[ -n "${VM_PHASE_TEE_PID:-}" ]]; then
    kill "$VM_PHASE_TEE_PID" 2>/dev/null
    wait "$VM_PHASE_TEE_PID" 2>/dev/null
    VM_PHASE_TEE_PID=""
  fi
  if [[ -n "$CURRENT_PID" ]]; then
    if kill -0 "$CURRENT_PID" 2>/dev/null && declare -F capture_guest_state >/dev/null; then
      capture_guest_state "cleanup-failure" >/dev/null 2>&1 || true
    fi
    kill -9 "$CURRENT_PID" 2>/dev/null
    wait "$CURRENT_PID" 2>/dev/null
    CURRENT_PID=""
  fi
  rm -f "$EVIDENCE_DIR/current-qemu.pid"
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=""
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() { printf 'VM-GATE-ERROR: %s\n' "$*" >&2; return 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing host dependency: $1"; }
[[ "$VM_RECOVERY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  fail "invalid recovery timeout: $VM_RECOVERY_TIMEOUT_SECONDS"
(( VM_RECOVERY_TIMEOUT_SECONDS < VM_PHASE_TIMEOUT_SECONDS )) ||
  fail "recovery timeout must be lower than the phase timeout"
case "$VM_MODE" in
  candidate|baseline-pack) ;;
  *) fail "unsupported VM gate mode: $VM_MODE" ;;
esac
case "$VM_CASE" in
  full|old-worker|rescue|protocol-v2|clean-image|dual-daemon|concurrency|storage|fault) ;;
  baseline-validation) [[ "$VM_MODE" = baseline-pack ]] || fail "baseline-validation is pack-build only" ;;
  *) fail "unsupported VM gate case selector: $VM_CASE" ;;
esac
case "$DIAGNOSTIC_RUN" in 0|1) ;; *) fail "ROUTER_UI_VM_DIAGNOSTIC must be 0 or 1" ;; esac
case "$VM_ONLY" in 0|1) ;; *) fail "ROUTER_UI_VM_ONLY must be 0 or 1" ;; esac
case "$ALLOW_LEGACY_CONTRACT" in 0|1) ;;
  *) fail "ROUTER_UI_VM_ALLOW_LEGACY_CONTRACT must be 0 or 1" ;;
esac
if [[ "$ALLOW_LEGACY_CONTRACT" = 1 && "$DIAGNOSTIC_RUN" != 1 ]]; then
  fail "the locked legacy candidate contract is diagnostic-only"
fi
if [[ "$VM_ONLY" = 1 && "$VM_MODE" != candidate ]]; then
  fail "ROUTER_UI_VM_ONLY is valid only for candidate validation"
fi
if [[ "$VM_MODE" = candidate ]]; then
  [[ -d "$RELEASE_DIR" ]] || fail "RELEASE_DIR is required in candidate mode"
  [[ -f "$X86_IMAGE_ARCHIVE" ]] || fail "X86_IMAGE_ARCHIVE is required in candidate mode"
  [[ -d "$SYNTHETIC_DIR" ]] || fail "SYNTHETIC_DIR is required in candidate mode"
  [[ -d "$BASELINE_PACK_DIR" ]] || fail "ROUTER_UI_BASELINE_PACK_DIR is required in candidate mode"
  [[ "$BASELINE_PACK_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "candidate mode requires the verified baseline artifact digest"
else
  [[ -n "$BASELINE_OUTPUT_DIR" ]] || fail "baseline-pack mode requires ROUTER_UI_BASELINE_OUTPUT_DIR"
  if [[ -n "$BASELINE_ASSET_CACHE_DIR" ]]; then
    [[ -d "$BASELINE_ASSET_CACHE_DIR" ]] ||
      fail "baseline asset cache directory does not exist: $BASELINE_ASSET_CACHE_DIR"
  fi
fi
if [[ "$DIAGNOSTIC_RUN" = 1 || "$VM_MODE" = baseline-pack ]]; then
  [[ "$HARNESS_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] ||
    fail "VM diagnostics require an exact harness source SHA"
else
  [[ "$VM_CASE" = full ]] || fail "targeted cases are diagnostic-only"
fi
for tool in awk curl gzip jq make node openssl python3 qemu-img qemu-system-x86_64 sed sha256sum ssh ssh-keygen stat tar tee timeout zstd; do need "$tool"; done
[[ "$DUAL_DAEMON_SAMPLES" =~ ^[1-9][0-9]*$ ]] && (( DUAL_DAEMON_SAMPLES <= 60 )) ||
  fail "dual-daemon sample count must be between 1 and 60"
[[ "$DUAL_DAEMON_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] &&
  (( DUAL_DAEMON_INTERVAL_SECONDS <= 10 )) ||
  fail "dual-daemon sample interval must be between 1 and 10 seconds"
[[ -s "$BASELINE_LOCK" ]] || fail "missing legacy baseline input lock"
[[ "$(jq -r .openwrt.version "$BASELINE_LOCK")" = "$OPENWRT_VERSION" ]] ||
  fail "OpenWrt version differs from the baseline lock"
[[ "$(sha256sum "$ROOT_DIR/release/rd23-storage-geometry.json" | awk '{print $1}')" = "$(jq -r .storage_profiles.geometry_sha256 "$BASELINE_LOCK")" ]] ||
  fail "RD23 geometry differs from the baseline lock"
BASELINE_CONTRACT_DIGEST="$(sh "$BASELINE_CONTRACT_DIGEST_SCRIPT")"
[[ "$BASELINE_CONTRACT_DIGEST" =~ ^[0-9a-f]{64}$ ]] || fail "invalid baseline-contract content digest"
mkdir -p "$EVIDENCE_DIR" "$WORK/server/releases/latest/download" \
  "$WORK/server/releases/download" "$WORK/server/baselines" \
  "$WORK/server/fixtures" "$WORK/server/vm"
: > "$EVIDENCE_DIR/vm-measurements.jsonl"
: > "$EVIDENCE_DIR/transition-results.jsonl"
: > "$EVIDENCE_DIR/fault-results.jsonl"
: > "$EVIDENCE_DIR/storage-results.jsonl"
: > "$EVIDENCE_DIR/published-baselines.jsonl"
: > "$EVIDENCE_DIR/reboot-recovery.jsonl"

record_result() {
  file="$1" kind="$2" name="$3" status="$4"
  if [[ $# -ge 5 ]]; then details="$5"; else details='{}'; fi
  jq -cn --arg kind "$kind" --arg name "$name" --arg status "$status" \
    --argjson details "$details" '{kind:$kind,name:$name,status:$status,details:$details}' >> "$file"
}

load_release_contracts() {
  local candidate_manifest="$RELEASE_DIR/router-release-manifest.json"
  local successor_manifest="$SYNTHETIC_DIR/router-release-manifest.json"
  local manifest_source selected_key selected_fingerprint selected_status candidate_channel_expected
  [[ -s "$candidate_manifest" && -s "$RELEASE_DIR/router-release-manifest.json.sig" ]] ||
    fail "candidate signed manifest is missing"
  [[ -s "$successor_manifest" && -s "$SYNTHETIC_DIR/router-release-manifest.json.sig" ]] ||
    fail "successor signed manifest is missing"

  CANDIDATE_APP_VERSION="$(jq -er '.app_version | select(type == "string" and length > 0)' "$candidate_manifest")"
  CANDIDATE_PACKAGE_VERSION="$(jq -er '.package_version | select(type == "string" and length > 0)' "$candidate_manifest")"
  CANDIDATE_RELEASE_TAG="$(jq -er '.release_tag | select(type == "string" and length > 0)' "$candidate_manifest")"
  CANDIDATE_KEY_ID="$(jq -er '.signing_key_id | select(type == "string" and length > 0)' "$candidate_manifest")"
  CANDIDATE_KEY_FINGERPRINT="$(jq -er '.signing_key_fingerprint | select(type == "string" and length > 0)' "$candidate_manifest")"
  SUCCESSOR_APP_VERSION="$(jq -er '.app_version | select(type == "string" and length > 0)' "$successor_manifest")"
  SUCCESSOR_PACKAGE_VERSION="$(jq -er '.package_version | select(type == "string" and length > 0)' "$successor_manifest")"
  SUCCESSOR_RELEASE_TAG="$(jq -er '.release_tag | select(type == "string" and length > 0)' "$successor_manifest")"

  if [[ "$ALLOW_LEGACY_CONTRACT" = 1 ]]; then
    CANDIDATE_CONTRACT_MODE=locked-legacy-diagnostic
    [[ "$CANDIDATE_APP_VERSION" = 0.7.11 &&
      "$CANDIDATE_PACKAGE_VERSION" = 0.7.11-1 ]] ||
      fail "legacy candidate manifest is not the locked 0.7.11 contract"
    [[ "$SUCCESSOR_APP_VERSION" = 0.7.12 &&
      "$SUCCESSOR_PACKAGE_VERSION" = 0.7.12-1 ]] ||
      fail "legacy successor manifest is not the locked 0.7.12 contract"
    selected_key=router-ui-prod-5b001ed1f9e63c96
    selected_status=previous
    candidate_channel_expected=stable
  else
    CANDIDATE_CONTRACT_MODE=rc11-active-key
    [[ "$CANDIDATE_APP_VERSION" = 0.7.11-rc.11 ]] ||
      fail "candidate app version is not the RC11 contract: $CANDIDATE_APP_VERSION"
    [[ "$CANDIDATE_PACKAGE_VERSION" = '0.7.11~rc11-1' ]] ||
      fail "candidate package version is not the opkg-safe RC11 contract: $CANDIDATE_PACKAGE_VERSION"
    [[ "$SUCCESSOR_APP_VERSION" = 0.7.11 &&
      "$SUCCESSOR_PACKAGE_VERSION" = 0.7.11-1 ]] ||
      fail "synthetic successor is not stable 0.7.11"
    selected_key="$(jq -er .active_key_id "$ROOT_DIR/release/keys/trusted-keys.json")"
    selected_status=active
    candidate_channel_expected=candidate
  fi
  [[ "$CANDIDATE_RELEASE_TAG" = "vpn-panel-v$CANDIDATE_APP_VERSION" ]] ||
    fail "candidate manifest release tag does not match its app version"
  [[ "$SUCCESSOR_RELEASE_TAG" = "vpn-panel-v$SUCCESSOR_APP_VERSION" ]] ||
    fail "successor manifest release tag does not match its app version"
  [[ "$CANDIDATE_RELEASE_TAG" =~ ^[A-Za-z0-9._-]+$ &&
    "$SUCCESSOR_RELEASE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] ||
    fail "manifest release tag is not path-safe"

  manifest_source="$(jq -er '.source_commit | select(test("^[0-9a-f]{40}$"))' "$candidate_manifest")"
  [[ "$manifest_source" = "$(jq -er .source_commit "$successor_manifest")" ]] ||
    fail "candidate and stable successor do not share one source commit"
  if [[ -n "${CANDIDATE_SOURCE_SHA:-}" && "$CANDIDATE_SOURCE_SHA" != "$manifest_source" ]]; then
    fail "candidate manifest source differs from the requested source SHA"
  fi
  CANDIDATE_SOURCE_SHA="$manifest_source"

  selected_fingerprint="$(jq -er --arg key "$selected_key" --arg status "$selected_status" \
    '.keys[] | select(.key_id == $key and .status == $status) | .fingerprint' \
    "$ROOT_DIR/release/keys/trusted-keys.json")"
  [[ "$CANDIDATE_KEY_ID" = "$selected_key" &&
    "$CANDIDATE_KEY_FINGERPRINT" = "$selected_fingerprint" ]] ||
    fail "candidate manifest is not bound to the selected committed release key"
  jq -e --arg source "$manifest_source" --arg key "$selected_key" \
    --arg fingerprint "$selected_fingerprint" \
    --arg channel "$candidate_channel_expected" '
      .source_commit == $source and .source_dirty == false and
      .channel == $channel and .signing_key_id == $key and
      .signing_key_fingerprint == $fingerprint
    ' "$candidate_manifest" >/dev/null || fail "candidate manifest contract failed"
  jq -e --arg source "$manifest_source" --arg key "$selected_key" \
    --arg fingerprint "$selected_fingerprint" '
      .source_commit == $source and .source_dirty == false and
      .channel == "stable" and .signing_key_id == $key and
      .signing_key_fingerprint == $fingerprint
    ' "$successor_manifest" >/dev/null || fail "stable successor manifest contract failed"

  jq -n --arg candidate_app_version "$CANDIDATE_APP_VERSION" \
    --arg candidate_package_version "$CANDIDATE_PACKAGE_VERSION" \
    --arg candidate_release_tag "$CANDIDATE_RELEASE_TAG" \
    --arg successor_app_version "$SUCCESSOR_APP_VERSION" \
    --arg successor_package_version "$SUCCESSOR_PACKAGE_VERSION" \
    --arg successor_release_tag "$SUCCESSOR_RELEASE_TAG" \
    --arg signing_key_id "$CANDIDATE_KEY_ID" \
    --arg signing_key_fingerprint "$CANDIDATE_KEY_FINGERPRINT" \
    --arg source_commit "$manifest_source" \
    --arg contract_mode "$CANDIDATE_CONTRACT_MODE" \
    --arg candidate_manifest_sha256 "$(sha256sum "$candidate_manifest" | awk '{print $1}')" \
    --arg successor_manifest_sha256 "$(sha256sum "$successor_manifest" | awk '{print $1}')" \
    '{schema_version:1,source_commit:$source_commit,contract_mode:$contract_mode,
      candidate:{app_version:$candidate_app_version,package_version:$candidate_package_version,
        release_tag:$candidate_release_tag,manifest_sha256:$candidate_manifest_sha256},
      successor:{app_version:$successor_app_version,package_version:$successor_package_version,
        release_tag:$successor_release_tag,manifest_sha256:$successor_manifest_sha256},
      signing_key_id:$signing_key_id,signing_key_fingerprint:$signing_key_fingerprint,
      manifest_signature_files_present:true,signatures_verified_by_harness:false,
      hardware_verified:false}' \
    > "$EVIDENCE_DIR/release-contract.json"
}

load_storage_profiles() {
  local profile pattern archive member provenance
  if [[ "$VM_MODE" = baseline-pack || "$VM_ONLY" = 1 ]]; then
    STOCK_WRITABLE_KIB="$(jq -r '.storage_profiles["rd23-stock"].writable_backing_kib' "$BASELINE_LOCK")"
    STOCK_UBIFS_DF_KIB="$(jq -r '.storage_profiles["rd23-stock"].expected_ubifs_df_total_kib' "$BASELINE_LOCK")"
    UBOOTMOD_WRITABLE_KIB="$(jq -r '.storage_profiles["rd23-ubootmod"].writable_backing_kib' "$BASELINE_LOCK")"
    UBOOTMOD_UBIFS_DF_KIB="$(jq -r '.storage_profiles["rd23-ubootmod"].expected_ubifs_df_total_kib' "$BASELINE_LOCK")"
    return
  fi
  for profile in rd23-stock rd23-ubootmod; do
    case "$profile" in
      rd23-stock) pattern='*xiaomi-ax3000t-stock.tar.gz' ;;
      rd23-ubootmod) pattern='*xiaomi-ax3000t-ubootmod.tar.gz' ;;
    esac
    archive="$(find "$RELEASE_DIR" -maxdepth 1 -type f -name "$pattern" | sed -n '1p')"
    [[ -n "$archive" ]] || fail "release set lacks $profile image archive"
    member="$(tar -tzf "$archive" | awk '/\/image-provenance\.json$/ && !found {print; found=1}')"
    [[ -n "$member" ]] || fail "$profile archive lacks image provenance"
    provenance="$WORK/$profile.provenance.json"
    tar -xOzf "$archive" "$member" > "$provenance"
    jq -e --arg profile "$profile" '.storage_profile == $profile and
      .writable_backing_kib > 0 and .expected_ubifs_df_total_kib > 0 and
      .writable_backing_kib == .rd23_storage_layout.rootfs_data_volume_kib' \
      "$provenance" >/dev/null || fail "$profile storage provenance is incomplete"
    case "$profile" in
      rd23-stock)
        STOCK_WRITABLE_KIB="$(jq -r '.writable_backing_kib' "$provenance")"
        STOCK_UBIFS_DF_KIB="$(jq -r '.expected_ubifs_df_total_kib' "$provenance")"
        ;;
      rd23-ubootmod)
        UBOOTMOD_WRITABLE_KIB="$(jq -r '.writable_backing_kib' "$provenance")"
        UBOOTMOD_UBIFS_DF_KIB="$(jq -r '.expected_ubifs_df_total_kib' "$provenance")"
        ;;
    esac
  done
  [[ "$STOCK_WRITABLE_KIB" = "$(jq -r '.storage_profiles["rd23-stock"].writable_backing_kib' "$BASELINE_LOCK")" ]] ||
    fail "candidate stock writable geometry does not match the verified baseline pack contract"
  [[ "$UBOOTMOD_WRITABLE_KIB" = "$(jq -r '.storage_profiles["rd23-ubootmod"].writable_backing_kib' "$BASELINE_LOCK")" ]] ||
    fail "candidate ubootmod writable geometry does not match the verified baseline pack contract"
}

extract_openwrt_gzip_image() {
  local source="$1" destination="$2" log="$3" status=0 lines
  if gzip -dc "$source" > "$destination" 2> "$log"; then
    :
  else
    status=$?
    lines="$(awk 'NF { count++ } END { print count + 0 }' "$log")"
    if [[ "$status" -ne 2 ]] || [[ "$lines" -ne 1 ]] ||
      ! grep -Eq '^gzip: .*: decompression OK, trailing garbage ignored$' "$log"; then
      cat "$log" >&2
      fail "OpenWrt image decompression failed: $(basename "$source")"
    fi
  fi
  [[ -s "$destination" ]] || fail "OpenWrt image decompressed to an empty file: $(basename "$source")"
  qemu-img info --output=json "$destination" |
    jq -e '.format == "raw" and .["virtual-size"] > 0' >/dev/null ||
    fail "OpenWrt image is not a nonempty raw disk: $(basename "$source")"
}

setup_tls() {
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/ssh-key"
  openssl genrsa -out "$WORK/ca.key" 2048 >/dev/null 2>&1
  openssl req -x509 -new -key "$WORK/ca.key" -sha256 -days 2 \
    -subj '/CN=Router UI disposable VM test CA' -out "$WORK/ca.crt" >/dev/null 2>&1
  openssl genrsa -out "$WORK/server.key" 2048 >/dev/null 2>&1
  openssl req -new -key "$WORK/server.key" -subj '/CN=10.0.2.2' -out "$WORK/server.csr" >/dev/null 2>&1
  printf 'subjectAltName=IP:10.0.2.2,IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n' > "$WORK/server.ext"
  openssl x509 -req -in "$WORK/server.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
    -CAcreateserial -out "$WORK/server.crt" -days 2 -sha256 -extfile "$WORK/server.ext" >/dev/null 2>&1
}

prepare_server() {
  local file version base versions release_sha actual_sha fixture_sha
  if [[ "$VM_MODE" = candidate ]]; then
    mkdir -p "$WORK/server/releases/download/$CANDIDATE_RELEASE_TAG" \
      "$WORK/server/releases/download/$SUCCESSOR_RELEASE_TAG"
    for file in "$RELEASE_DIR"/*; do
      [[ -f "$file" ]] || continue
      ln "$file" "$WORK/server/releases/latest/download/$(basename "$file")"
      ln "$file" "$WORK/server/releases/download/$CANDIDATE_RELEASE_TAG/$(basename "$file")"
    done
    for file in "$SYNTHETIC_DIR"/*; do
      [[ -f "$file" ]] || continue
      ln "$file" "$WORK/server/releases/download/$SUCCESSOR_RELEASE_TAG/$(basename "$file")"
    done
    printf 'router-ui-dual-daemon-ok\n' > "$WORK/server/vm/dual-daemon-probe.txt"
  fi
  cp "$ROOT_DIR/tests/vm/router-ui-vm-guest.sh" "$WORK/server/vm/"
  cp -R "$FIXTURE_DIR" "$WORK/server/fixtures/legacy-nonsecret"
  fixture_sha="$(cd "$WORK/server/fixtures/legacy-nonsecret" &&
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
  [[ "$fixture_sha" = "$(jq -r .fixture.tree_sha256 "$BASELINE_LOCK")" ]] ||
    fail "deterministic fixture differs from its input lock"
  if [[ "$VM_MODE" = baseline-pack ]]; then
    case "$BASELINE_SELECTOR" in
      all) versions=("${BASELINE_VERSIONS[@]}") ;;
      fleet) versions=("${FLEET_BASELINE_VERSIONS[@]}") ;;
      *) versions=("$BASELINE_SELECTOR") ;;
    esac
    for version in "${versions[@]}"; do
      base="$(jq -r --arg version "$version" '.baselines[] | select(.version == $version) | .release_url' "$BASELINE_LOCK")"
      release_sha="$(jq -r --arg version "$version" '.baselines[] | select(.version == $version) | .release_sha256' "$BASELINE_LOCK")"
      [[ -n "$base" && "$base" != null && "$release_sha" =~ ^[0-9a-f]{64}$ ]] ||
        fail "baseline selector is not present in the lock: $version"
      mkdir -p "$WORK/server/baselines/$version"
      if [[ -n "$BASELINE_ASSET_CACHE_DIR" &&
        -f "$BASELINE_ASSET_CACHE_DIR/$version/luci-vpn-ui.tar.gz" ]]; then
        cp "$BASELINE_ASSET_CACHE_DIR/$version/luci-vpn-ui.tar.gz" \
          "$WORK/server/baselines/$version/luci-vpn-ui.tar.gz"
      else
        curl -fL --retry 3 "$base" -o "$WORK/server/baselines/$version/luci-vpn-ui.tar.gz"
      fi
      actual_sha="$(sha256sum "$WORK/server/baselines/$version/luci-vpn-ui.tar.gz" | awk '{print $1}')"
      [[ "$actual_sha" = "$release_sha" ]] || fail "published baseline hash mismatch: $version"
      printf '%s  luci-vpn-ui.tar.gz\n' "$release_sha" > "$WORK/server/baselines/$version/luci-vpn-ui.tar.gz.sha256"
      jq -cn --arg version "$version" --arg url "$base" --arg sha256 "$release_sha" \
        --argjson size "$(wc -c < "$WORK/server/baselines/$version/luci-vpn-ui.tar.gz" | tr -d ' ')" \
        '{version:$version,asset:"luci-vpn-ui.tar.gz",url:$url,sha256:$sha256,size:$size,
          source:"exact-published-release",input_lock_verified:true}' \
        >> "$EVIDENCE_DIR/published-baselines.jsonl"
    done
  fi
  python3 "$ROOT_DIR/tests/vm/https-artifact-server.py" --root "$WORK/server" \
    --cert "$WORK/server.crt" --key "$WORK/server.key" --port "$SERVER_PORT" \
    >"$EVIDENCE_DIR/https-server.log" 2>&1 &
  SERVER_PID=$!
  for _ in {1..30}; do
    curl -fsS --connect-timeout 1 --max-time 5 --cacert "$WORK/ca.crt" \
      "$HOST_ORIGIN/vm/router-ui-vm-guest.sh" >/dev/null && return
    sleep 1
  done
  fail "local TLS-valid artifact server did not start"
}

build_vm_base() {
  local ib_name="openwrt-imagebuilder-$OPENWRT_VERSION-x86-64.Linux-x86_64"
  local archive="$WORK/$ib_name.tar.zst" ib="$WORK/$ib_name" packages overlay="$WORK/base-overlay"
  local host_bin="$WORK/host-bin" expected_ib_sha expected_xray_sha xray_url
  local published_base="$WORK/openwrt-published-base.img.gz" expected_base_sha
  cp "$FIXTURE_DIR/fixture-contract.json" "$EVIDENCE_DIR/vm-test-profile.json"
  mkdir -p "$host_bin"
  cat > "$host_bin/sha256" <<'EOF'
#!/bin/sh
sha256sum "$@" | awk '{print $1}'
EOF
  chmod 755 "$host_bin/sha256"
  PATH="$host_bin:$PATH"
  export PATH
  expected_base_sha="$(jq -r .openwrt.published_base_image_sha256 "$BASELINE_LOCK")"
  curl -fL --retry 3 "$(jq -r .openwrt.published_base_image_url "$BASELINE_LOCK")" -o "$published_base"
  [[ "$(sha256sum "$published_base" | awk '{print $1}')" = "$expected_base_sha" ]] ||
    fail "published OpenWrt base image differs from the baseline input lock"
  expected_ib_sha="$(jq -r .openwrt.imagebuilder_sha256 "$BASELINE_LOCK")"
  curl -fL --retry 3 "$(jq -r .openwrt.imagebuilder_url "$BASELINE_LOCK")" -o "$archive"
  [[ "$(sha256sum "$archive" | awk '{print $1}')" = "$expected_ib_sha" ]] ||
    fail "OpenWrt ImageBuilder differs from the baseline input lock"
  tar --use-compress-program=unzstd -xf "$archive" -C "$WORK"
  xray_url="$(jq -r .xray.package_url "$BASELINE_LOCK")"
  expected_xray_sha="$(jq -r .xray.package_sha256 "$BASELINE_LOCK")"
  mkdir -p "$ib/packages"
  curl -fL --retry 3 "$xray_url" -o "$ib/packages/xray-core_25.1.30-r1_x86_64.ipk"
  [[ "$(sha256sum "$ib/packages/xray-core_25.1.30-r1_x86_64.ipk" | awk '{print $1}')" = "$expected_xray_sha" ]] ||
    fail "Xray package differs from the baseline input lock"
  mkdir -p "$WORK/xray-ipk"
  tar -xOzf "$ib/packages/xray-core_25.1.30-r1_x86_64.ipk" ./data.tar.gz > "$WORK/xray-ipk/data.tar.gz"
  tar -xOzf "$WORK/xray-ipk/data.tar.gz" ./usr/bin/xray > "$WORK/xray-ipk/xray"
  sha256sum "$WORK/xray-ipk/xray" | awk '{print $1}' > "$WORK/xray-binary.sha256"
  [[ "$(sed -n '1p' "$WORK/xray-binary.sha256")" =~ ^[0-9a-f]{64}$ ]] ||
    fail "could not derive the installed Xray binary hash from the locked IPK"
  "$ROOT_DIR/scripts/patch-openwrt-x86-writable-extent.sh" \
    "$ib/scripts/gen_image_generic.sh"
  grep -q ROOTFS_SIZE_SPEC "$ib/scripts/gen_image_generic.sh" ||
    fail "VM ImageBuilder lacks exact writable-extent support"
  sed -i 's/^CONFIG_TARGET_ROOTFS_EXT4FS=y$/# CONFIG_TARGET_ROOTFS_EXT4FS is not set/' "$ib/.config"
  grep -q '^# CONFIG_TARGET_ROOTFS_EXT4FS is not set$' "$ib/.config" ||
    fail "could not disable the unused VM ext4 image variant"
  mkdir -p "$overlay/etc/config" "$overlay/etc/dropbear" "$overlay/etc/ssl/certs"
  cp "$WORK/ssh-key.pub" "$overlay/etc/dropbear/authorized_keys"
  cp "$WORK/ca.crt" "$overlay/etc/ssl/certs/router-ui-vm-ca.pem"
  cat > "$overlay/etc/config/network" <<'EOF'
config interface 'loopback'
  option device 'lo'
  option proto 'static'
  option ipaddr '127.0.0.1'
  option netmask '255.0.0.0'
config interface 'lan'
  option device 'eth0'
  option proto 'dhcp'
EOF
  # The harness itself is deliberately umask 077, but ImageBuilder preserves
  # FILES directory modes.  An unreadable /etc tree prevents ubusd from
  # starting and leaves the guest stuck at "procd: - ubus -".
  chmod 755 "$overlay" "$overlay/etc" "$overlay/etc/config" \
    "$overlay/etc/dropbear" "$overlay/etc/ssl" "$overlay/etc/ssl/certs"
  chmod 600 "$overlay/etc/dropbear/authorized_keys"
  chmod 644 "$overlay/etc/config/network" \
    "$overlay/etc/ssl/certs/router-ui-vm-ca.pem"
  for path in "$overlay" "$overlay/etc" "$overlay/etc/config" \
    "$overlay/etc/dropbear" "$overlay/etc/ssl" "$overlay/etc/ssl/certs"; do
    [[ "$(stat -c '%a' "$path")" = 755 ]] ||
      fail "unsafe ImageBuilder overlay directory mode: $path"
  done
  [[ "$(stat -c '%a' "$overlay/etc/dropbear/authorized_keys")" = 600 ]] ||
    fail "unsafe VM authorized-keys mode"
  [[ "$(stat -c '%a' "$overlay/etc/config/network")" = 644 ]] ||
    fail "unsafe VM network-config mode"
  [[ "$(stat -c '%a' "$overlay/etc/ssl/certs/router-ui-vm-ca.pem")" = 644 ]] ||
    fail "unsafe VM test-CA mode"
  packages="$(awk 'NF && $1 !~ /^#/ {printf "%s ",$1}' "$ROOT_DIR/image/openwrt-fin0-packages.txt") dropbear ca-bundle usign"
  local profile budget profiles
  if [[ "$BASELINE_SELECTOR" != all ]]; then
    profiles=(rd23-stock)
  else
    profiles=(rd23-stock rd23-ubootmod)
  fi
  for profile in "${profiles[@]}"; do
    case "$profile" in
      rd23-stock) budget="$STOCK_WRITABLE_KIB" ;;
      rd23-ubootmod) budget="$UBOOTMOD_WRITABLE_KIB" ;;
    esac
    rm -rf "$ib/bin/targets/x86/64"
    if ! (umask 022 && ROOTFS_WRITABLE_KIB="$budget" make -C "$ib" image \
      PROFILE=generic PACKAGES="$packages" FILES="$overlay" ROOTFS_PARTSIZE=128) \
      > "$EVIDENCE_DIR/vm-base-$profile-build.log" 2>&1; then
      cat "$EVIDENCE_DIR/vm-base-$profile-build.log" >&2
      fail "VM base build failed for the $profile exact writable extent"
    fi
    base_gz="$(find "$ib/bin/targets/x86/64" -maxdepth 1 -type f -name '*squashfs-combined.img.gz' | sed -n '1p')"
    [[ -n "$base_gz" ]] || fail "VM base build did not produce the $profile combined squashfs image"
    extract_openwrt_gzip_image "$base_gz" "$WORK/vm-base-$profile.img" \
      "$EVIDENCE_DIR/vm-base-$profile-gzip.log"
  done
  ln -s "$WORK/vm-base-rd23-stock.img" "$WORK/vm-base.img"
}

extract_candidate_image() {
  mkdir -p "$WORK/candidate-archive"
  tar -xzf "$X86_IMAGE_ARCHIVE" -C "$WORK/candidate-archive"
  candidate_gz="$(find "$WORK/candidate-archive" -type f -name '*squashfs-combined.img.gz' | sed -n '1p')"
  [[ -n "$candidate_gz" ]] || fail "candidate archive lacks x86 combined squashfs image"
  extract_openwrt_gzip_image "$candidate_gz" "$WORK/candidate.img" \
    "$EVIDENCE_DIR/candidate-image-gzip.log"
}

verify_baseline_pack() {
  local manifest="$BASELINE_PACK_DIR/baseline-pack-manifest.json"
  local descriptor="$BASELINE_PACK_DIR/baseline-pack-descriptor.json"
  local lock_sha version overlay backing expected_backing expected_ubootmod manifest_sha
  [[ -s "$manifest" && -s "$descriptor" && -s "$BASELINE_PACK_DIR/SHA256SUMS" ]] ||
    fail "baseline pack is missing its descriptor, manifest, or checksum inventory"
  (cd "$BASELINE_PACK_DIR" && sha256sum -c SHA256SUMS)
  lock_sha="$(sha256sum "$BASELINE_LOCK" | awk '{print $1}')"
  manifest_sha="$(sha256sum "$manifest" | awk '{print $1}')"
  jq -e --arg contract "$BASELINE_CONTRACT_DIGEST" --arg manifest "$manifest_sha" '
    .schema_version == 1 and .immutable == true and
    .baseline_contract_digest == $contract and .manifest_sha256 == $manifest and
    (.builder_commit | test("^[0-9a-f]{40}$"))
  ' "$descriptor" >/dev/null || fail "baseline pack immutable descriptor failed"
  jq -e --arg lock "$lock_sha" --arg contract "$BASELINE_CONTRACT_DIGEST" '
    . as $root |
    .schema_version == 1 and .verified == true and
    .input_lock_sha256 == $lock and
    .baseline_contract_digest == $contract and
    (.builder_commit | test("^[0-9a-f]{40}$")) and
    (.expected_xray_binary_sha256 | test("^[0-9a-f]{64}$")) and
    (.baselines | length) > 0 and
    all(.baselines[]; .self_validation.ok == true and
      .xray_package_version == $root.xray.version and
      .xray_binary_sha256 == $root.expected_xray_binary_sha256)
  ' "$manifest" >/dev/null || fail "baseline pack manifest contract failed"
  for version in $(jq -r '.baselines[] | select(.storage_profile == "rd23-stock") | .version' "$manifest"); do
    overlay="$BASELINE_PACK_DIR/overlays/rd23-stock/baseline-$version.qcow2"
    [[ -s "$overlay" ]] || fail "baseline pack lacks stock overlay: $version"
    backing="$(qemu-img info --output=json "$overlay" | jq -r '.["backing-filename"]')"
    [[ "$backing" = ../../bases/rd23-stock.img ]] ||
      fail "baseline overlay has a non-relocatable backing path: $version"
    ln -s "$overlay" "$WORK/baseline-$version.qcow2"
  done
  if [[ -s "$BASELINE_PACK_DIR/overlays/rd23-ubootmod/baseline-0.7.10.qcow2" ]]; then
    ln -s "$BASELINE_PACK_DIR/overlays/rd23-ubootmod/baseline-0.7.10.qcow2" \
      "$WORK/baseline-0.7.10-ubootmod.qcow2"
  fi
  expected_backing="$(jq -r '.storage_profiles["rd23-stock"].writable_backing_kib' "$manifest")"
  [[ "$expected_backing" = "$STOCK_WRITABLE_KIB" ]] ||
    fail "baseline pack stock geometry differs from the candidate"
  expected_ubootmod="$(jq -r '.storage_profiles["rd23-ubootmod"].writable_backing_kib' "$manifest")"
  [[ "$expected_ubootmod" = "$UBOOTMOD_WRITABLE_KIB" ]] ||
    fail "baseline pack ubootmod geometry differs from the candidate"
  cp "$manifest" "$EVIDENCE_DIR/baseline-pack-manifest.json"
  jq -n --arg artifact_digest "$BASELINE_PACK_DIGEST" \
    --arg manifest_sha256 "$(sha256sum "$manifest" | awk '{print $1}')" \
    --arg input_lock_sha256 "$lock_sha" \
    '{artifact_digest:$artifact_digest,manifest_sha256:$manifest_sha256,
      input_lock_sha256:$input_lock_sha256,identity_verified:true}' \
    > "$EVIDENCE_DIR/baseline-pack-identity.json"
}

clone_disk() {
  backing="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  qemu-img create -q -f qcow2 -F "${3:-raw}" -b "$backing" "$2"
}

start_vm() {
  disk="$1" name="$2"
  [[ -z "$CURRENT_PID" ]] || fail "serial harness attempted to overlap project VMs"
  qemu-system-x86_64 -name "router-ui-vm-$name" -machine pc,accel=tcg -cpu qemu64 \
    -m 256 -smp 1 -drive "file=$disk,if=ide,format=qcow2" \
    -nic "user,model=e1000,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$HTTP_PORT-:80" \
    -chardev "socket,id=serial0,host=127.0.0.1,port=$SERIAL_PORT,server=on,wait=off,logfile=$EVIDENCE_DIR/$name.serial.log" \
    -serial chardev:serial0 -display none \
    >"$EVIDENCE_DIR/$name.qemu.log" 2>&1 &
  CURRENT_PID=$!
  printf '%s\n' "$CURRENT_PID" > "$EVIDENCE_DIR/current-qemu.pid"
  sleep 1
  kill -0 "$CURRENT_PID" 2>/dev/null || {
    cat "$EVIDENCE_DIR/$name.qemu.log" >&2
    cat "$EVIDENCE_DIR/$name.serial.log" >&2
    wait "$CURRENT_PID" 2>/dev/null || true
    CURRENT_PID=""
    fail "QEMU process exited before readiness: $name"
  }
}

ssh_base=(ssh -i "$WORK/ssh-key" -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 root@127.0.0.1)
console_bootstrap_key() {
  local serial_log="$1"
  [[ -s "$WORK/ssh-key" && -s "$WORK/ssh-key.pub" && -s "$WORK/ca.crt" ]] ||
    fail "runtime VM bootstrap credentials are missing"
  ROUTER_UI_VM_PUBLIC_KEY="$(cat "$WORK/ssh-key.pub")" \
  ROUTER_UI_VM_CA_B64="$(base64 < "$WORK/ca.crt" | tr -d '\n')" \
    python3 - "$SERIAL_PORT" <<'PY'
import os, re, socket, sys, time
sock = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=2)
sock.settimeout(0.2)
prompt = re.compile(rb"(?:^|\r?\n)root@[^\r\n]*:~# ")

def send(payload):
    deadline = time.monotonic() + 20
    for offset in range(0, len(payload), 32):
        sock.sendall(payload[offset:offset + 32])
        if time.monotonic() >= deadline:
            raise TimeoutError("serial console bootstrap write timed out")
        time.sleep(0.003)

def read_until_prompt(label):
    output = bytearray()
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            chunk = sock.recv(65536)
            if not chunk:
                raise RuntimeError("serial console closed during " + label)
            output.extend(chunk)
            if prompt.search(output):
                return bytes(output)
        except socket.timeout:
            pass
    raise TimeoutError("serial console prompt timed out during " + label)

def run_command(command, label):
    send(command.encode() + b"\n")
    return read_until_prompt(label)

key = os.environ["ROUTER_UI_VM_PUBLIC_KEY"]
ca = os.environ["ROUTER_UI_VM_CA_B64"]
marker = "ROUTER_UI_CONSOLE_BOOTSTRAP_OK"
send(b"\n")
read_until_prompt("console activation")
run_command("mkdir -p /etc/dropbear /etc/ssl/certs", "credential directories")
run_command("printf '%s\\n' '" + key + "' > /etc/dropbear/authorized_keys",
            "runtime public key")
run_command(": > /tmp/router-ui-vm-ca.b64", "test CA staging")
chunk_size = 128
for offset in range(0, len(ca), chunk_size):
    chunk = ca[offset:offset + chunk_size]
    run_command("printf '%s' '" + chunk + "' >> /tmp/router-ui-vm-ca.b64",
                "test CA chunk")
run_command(
    "base64 -d /tmp/router-ui-vm-ca.b64 > /etc/ssl/certs/router-ui-vm-ca.pem; "
    "rm -f /tmp/router-ui-vm-ca.b64; chmod 600 /etc/dropbear/authorized_keys",
    "credential installation")
run_command(
    "uci -q set network.lan.proto='dhcp'; "
    "uci -q delete network.lan.ipaddr; uci -q delete network.lan.netmask; "
    "uci -q delete network.lan.gateway; uci -q delete network.lan.dns; "
    "uci commit network; /etc/init.d/network restart; /etc/init.d/dropbear restart",
    "network and SSH restart")
marker_output = run_command("echo " + marker, "completion marker")
normalized_lines = marker_output.replace(b"\r\n", b"\n").replace(b"\r", b"\n").splitlines()
if marker.encode() not in [line.strip() for line in normalized_lines]:
    raise RuntimeError("serial credential bootstrap marker was not executed")
sock.close()
PY
  kill -0 "$CURRENT_PID" 2>/dev/null || fail "VM exited during serial credential bootstrap"
  grep -q 'ROUTER_UI_CONSOLE_BOOTSTRAP_OK' "$serial_log" ||
    fail "serial credential bootstrap evidence marker is missing"
}
wait_serial_console() {
  local serial_log="$1"
  for _ in {1..120}; do
    grep -q 'Please press Enter to activate this console' "$serial_log" && return
    kill -0 "$CURRENT_PID" 2>/dev/null || fail "VM exited before its serial console became ready"
    sleep 1
  done
  fail "VM serial console did not become ready"
}
wait_ssh() {
  for _ in {1..120}; do
    "${ssh_base[@]}" true >/dev/null 2>&1 && return
    sleep 1
  done
  fail "VM SSH did not become ready"
}
wait_reboot_ssh() {
  local previous_boot_id="$1" boot_id
  for _ in {1..180}; do
    boot_id="$("${ssh_base[@]}" cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    if [[ -n "$boot_id" && "$boot_id" != "$previous_boot_id" ]] &&
      "${ssh_base[@]}" true >/dev/null 2>&1; then
      printf '%s\n' "$boot_id"
      return 0
    fi
    sleep 1
  done
  return 1
}
start_candidate_vm() {
  local disk="$1" name="$2"
  local expected_key actual_key expected_key_sha actual_key_sha expected_ca actual_ca
  start_vm "$disk" "$name"
  wait_serial_console "$EVIDENCE_DIR/$name.serial.log"
  console_bootstrap_key "$EVIDENCE_DIR/$name.serial.log"
  wait_ssh
  expected_key="$(sed -n '1p' "$WORK/ssh-key.pub")"
  actual_key="$("${ssh_base[@]}" sed -n '1p' /etc/dropbear/authorized_keys)"
  [[ "$actual_key" = "$expected_key" ]] || fail "guest SSH bootstrap key does not match the runtime key"
  expected_key_sha="$(sha256sum "$WORK/ssh-key.pub" | awk '{print $1}')"
  actual_key_sha="$(printf '%s\n' "$actual_key" | sha256sum | awk '{print $1}')"
  expected_ca="$(sha256sum "$WORK/ca.crt" | awk '{print $1}')"
  actual_ca="$("${ssh_base[@]}" sha256sum /etc/ssl/certs/router-ui-vm-ca.pem | awk '{print $1}')"
  [[ "$actual_ca" = "$expected_ca" ]] || fail "guest test CA does not match the runtime artifact server CA"
  jq -n --arg ssh_public_key_sha256 "$expected_key_sha" \
    --arg guest_ssh_public_key_sha256 "$actual_key_sha" \
    --arg test_ca_sha256 "$expected_ca" --arg guest_test_ca_sha256 "$actual_ca" \
    '{ssh_public_key_sha256:$ssh_public_key_sha256,
      guest_ssh_public_key_sha256:$guest_ssh_public_key_sha256,
      test_ca_sha256:$test_ca_sha256,guest_test_ca_sha256:$guest_test_ca_sha256,
      exact_runtime_credentials_verified:true}' \
    > "$EVIDENCE_DIR/$name.credential-bootstrap.json"
}
start_baseline_vm() {
  start_candidate_vm "$@"
}
guest() {
  local command="" arg
  for arg in "$@"; do printf -v quoted '%q' "$arg"; command+=" $quoted"; done
  "${ssh_base[@]}" "SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem curl -fsSL --proto '=https' '$ORIGIN/vm/router-ui-vm-guest.sh' -o /tmp/router-ui-vm-guest.sh && chmod 700 /tmp/router-ui-vm-guest.sh && /tmp/router-ui-vm-guest.sh$command"
}
vm_candidate_mutation_began() {
  local transaction state
  [[ "$VM_MODE" = candidate ]] || { printf 'false\n'; return; }
  [[ -n "$CURRENT_PID" ]] && kill -0 "$CURRENT_PID" 2>/dev/null || {
    printf 'false\n'
    return
  }
  transaction="$(timeout 5 "${ssh_base[@]}" sed -n '1p' \
    /root/premier-router-updates/active-transaction 2>/dev/null || true)"
  [[ -n "$transaction" ]] || { printf 'false\n'; return; }
  state="$(timeout 5 "${ssh_base[@]}" "jsonfilter -i '/root/premier-router-updates/$transaction/state.json' -e '@.state'" \
    2>/dev/null || true)"
  case "$state" in
    ''|checking|check_complete|snapshot_ready|failed_before_mutation) printf 'false\n' ;;
    *) printf 'true\n' ;;
  esac
}
capture_guest_state() {
  local name="$1" out="$EVIDENCE_DIR/$1"
  [[ -n "$CURRENT_PID" ]] && kill -0 "$CURRENT_PID" 2>/dev/null || return 0
  timeout 20 "${ssh_base[@]}" '
    echo "== version =="
    sed -n "1p" /usr/share/vpn-ui/version 2>/dev/null || true
    echo "== updater status =="
    /usr/sbin/vpn-ui-update status 2>/dev/null || true
    echo "== project opkg status =="
    for package in premier-router-core luci-app-premier-router premier-router-setup; do
      opkg status "$package" 2>/dev/null || true
    done
    echo "== filesystems =="
    df -Pk / /overlay /tmp 2>/dev/null || true
    echo "== memory =="
    sed -n "/^MemTotal:/p;/^MemAvailable:/p;/^Shmem:/p" /proc/meminfo
    echo "== Xray and Tailscale processes =="
    for process in tailscaled xray xray-latest; do
      for pid in $(pidof "$process" 2>/dev/null || true); do
        printf "process=%s pid=%s\n" "$process" "$pid"
        sed -n "/^Name:/p;/^State:/p;/^VmRSS:/p;/^VmSize:/p;/^Threads:/p" "/proc/$pid/status" 2>/dev/null || true
      done
    done
    echo "== OOM scan =="
    dmesg 2>/dev/null | grep -Ei "out of memory|oom-killer|killed process" || true
    logread 2>/dev/null | grep -Ei "out of memory|oom-killer|killed process" || true
    echo "== protected filesystem hashes =="
    for path in /etc/config /etc/xray /etc/vpn-ui-update.conf /etc/crontabs/root; do
      if [ -f "$path" ]; then sha256sum "$path"; fi
      if [ -d "$path" ]; then find "$path" -type f -exec sha256sum {} \; | sort; fi
    done
    echo "== updater evidence hashes =="
    find /root/premier-router-updates -maxdepth 4 -type f -exec sha256sum {} \; 2>/dev/null | sort
    echo "== updater service state =="
    /etc/init.d/premier-router-update-recovery enabled 2>/dev/null; echo "enabled_rc=$?"
    /etc/init.d/premier-router-update-recovery running 2>/dev/null; echo "running_rc=$?"
  ' > "$out.filesystem.txt" 2>&1 || true
  timeout 20 "${ssh_base[@]}" '
    find /root/premier-router-updates -maxdepth 4 -type f \
      \( -name "*.json" -o -name "*.log" -o -name "*.txt" \) -print 2>/dev/null | sort |
    while IFS= read -r file; do
      echo "===== $file ====="
      sed -n "1,800p" "$file"
    done
  ' > "$out.transaction-evidence.txt" 2>&1 || true
  timeout 20 "${ssh_base[@]}" logread > "$out.logread.txt" 2>&1 || true
  timeout 20 "${ssh_base[@]}" '
    find /tmp -maxdepth 1 -type f \
      \( -name "vpn-ui*.log" -o -name "vpn-ui*.json" \) -print 2>/dev/null | sort |
    while IFS= read -r file; do
      echo "===== $file ====="
      sed -n "1,800p" "$file"
    done
  ' > "$out.guest-bootstrap-and-validator.txt" 2>&1 || true
}
record_measurement() {
  name="$1" profile="${2:-rd23-stock}"
  case "$profile" in
    rd23-stock) measurement="$(guest measure "$profile" "$STOCK_WRITABLE_KIB" "$STOCK_UBIFS_DF_KIB")" ;;
    rd23-ubootmod) measurement="$(guest measure "$profile" "$UBOOTMOD_WRITABLE_KIB" "$UBOOTMOD_UBIFS_DF_KIB")" ;;
    *) fail "unknown measurement profile: $profile" ;;
  esac
  jq -cn --arg name "$name" --argjson measurement "$measurement" '$measurement + {case:$name}' >> "$EVIDENCE_DIR/vm-measurements.jsonl"
}
measure_stock() { guest measure rd23-stock "$STOCK_WRITABLE_KIB" "$STOCK_UBIFS_DF_KIB"; }
measure_ubootmod() { guest measure rd23-ubootmod "$UBOOTMOD_WRITABLE_KIB" "$UBOOTMOD_UBIFS_DF_KIB"; }
shutdown_vm() {
  [[ -n "$CURRENT_PID" ]] || fail "shutdown requested without an owned VM PID"
  set +e
  "${ssh_base[@]}" 'sync; poweroff' >/dev/null 2>&1
  for _ in {1..30}; do kill -0 "$CURRENT_PID" 2>/dev/null || break; sleep 1; done
  kill "$CURRENT_PID" 2>/dev/null || true
  wait "$CURRENT_PID" 2>/dev/null
  set -e
  CURRENT_PID=""
  rm -f "$EVIDENCE_DIR/current-qemu.pid"
}
hard_poweroff_vm() {
  [[ -n "$CURRENT_PID" ]] || fail "power-off requested without an owned VM PID"
  kill -9 "$CURRENT_PID" 2>/dev/null || true
  wait "$CURRENT_PID" 2>/dev/null || true
  CURRENT_PID=""
  rm -f "$EVIDENCE_DIR/current-qemu.pid"
}
normal_reboot() {
  local before after transaction pre_state expected_state rc=0
  transaction="$("${ssh_base[@]}" sed -n '1p' \
    /root/premier-router-updates/active-transaction 2>/dev/null || true)"
  if [[ -n "$transaction" ]]; then
    pre_state="$("${ssh_base[@]}" \
      "jsonfilter -i '/root/premier-router-updates/$transaction/state.json' -e '@.state'" \
      2>/dev/null || true)"
    case "$pre_state" in
      committed_pending_reboot_validation) expected_state=committed ;;
      committed|rolled_back|failed_before_mutation) expected_state="$pre_state" ;;
      *) fail "unexpected pre-reboot transaction state: ${pre_state:-missing}" ;;
    esac
  else
    pre_state=none
    expected_state=none
  fi
  before="$("${ssh_base[@]}" cat /proc/sys/kernel/random/boot_id)"
  "${ssh_base[@]}" 'sync; reboot' >/dev/null 2>&1 || true
  after="$(wait_reboot_ssh "$before")" ||
    fail "VM SSH did not become ready on a new boot ID"

  vm_wait_for_recovery "$EVIDENCE_DIR/reboot-recovery.jsonl" \
    "$VM_RECOVERY_TIMEOUT_SECONDS" "$transaction" "$expected_state" "$before" "$after" || rc=$?
  case "$rc" in
    0) ;;
    86) fail "post-reboot recovery reached unsafe state" ;;
    87) fail "post-reboot recovery reached an unexpected terminal state" ;;
    124) return 124 ;;
    *) fail "post-reboot recovery observation failed with exit $rc" ;;
  esac
}

vm_recovery_observe() {
  local transaction="$1" state=none lock_present=false
  if [[ -n "$transaction" ]]; then
    state="$("${ssh_base[@]}" \
      "jsonfilter -i '/root/premier-router-updates/$transaction/state.json' -e '@.state'" \
      2>/dev/null || true)"
  fi
  if "${ssh_base[@]}" test -d /root/premier-router-updates/update.lock 2>/dev/null; then
    lock_present=true
  fi
  printf '%s\t%s\n' "${state:-missing}" "$lock_present"
}

initialize_baseline_pack() {
  mkdir -p "$BASELINE_OUTPUT_DIR/bases" "$BASELINE_OUTPUT_DIR/overlays/rd23-stock" \
    "$BASELINE_OUTPUT_DIR/overlays/rd23-ubootmod"
  : > "$EVIDENCE_DIR/baseline-validation-results.jsonl"
}

prepare_baseline_version() {
  local version="$1" profile="$2" validation expected_worker expected_validator
  local expected_xray_version expected_xray_binary disk base_disk overlay
  VM_ACTIVE_VERSION="$version"
  case "$profile" in
    rd23-stock)
      base_disk="$WORK/vm-base.img"
      overlay="$BASELINE_OUTPUT_DIR/overlays/rd23-stock/baseline-$version.qcow2"
      ;;
    rd23-ubootmod)
      [[ "$version" = 0.7.10 ]] || fail "ubootmod baseline is only required for 0.7.10"
      base_disk="$WORK/vm-base-rd23-ubootmod.img"
      overlay="$BASELINE_OUTPUT_DIR/overlays/rd23-ubootmod/baseline-$version.qcow2"
      ;;
    *) fail "unsupported baseline storage profile: $profile" ;;
  esac
  VM_PHASE_COMMAND="guest install-baseline $version $ORIGIN/baselines"
  disk="$WORK/baseline-$version-$profile.qcow2"
  clone_disk "$base_disk" "$disk" raw
  start_vm "$disk" "prepare-$version-$profile"; wait_ssh
  record_measurement "prepare-$version-$profile" "$profile"
  guest install-baseline "$version" "$ORIGIN/baselines"
  expected_worker="$(jq -r --arg version "$version" \
    '.baselines[] | select(.version == $version) | .worker_sha256' "$BASELINE_LOCK")"
  expected_validator="$(jq -r --arg version "$version" \
    '.baselines[] | select(.version == $version) | .validator_sha256' "$BASELINE_LOCK")"
  expected_xray_binary="$(sed -n '1p' "$WORK/xray-binary.sha256")"
  expected_xray_version="$(jq -r .xray.version "$BASELINE_LOCK")"
  VM_PHASE_COMMAND="guest validate-baseline $version $expected_worker $expected_validator $expected_xray_version $expected_xray_binary"
  validation="$(guest validate-baseline "$version" "$expected_worker" \
    "$expected_validator" "$expected_xray_version" "$expected_xray_binary" | tail -n 1)"
  jq -e '.self_validation.ok == true' <<<"$validation" >/dev/null ||
    fail "baseline self-validation result is not truthful: $version ($profile)"
  jq -cn --argjson validation "$validation" \
    --arg version "$version" --arg profile "$profile" \
    '$validation + {version:$version,storage_profile:$profile}' \
    >> "$EVIDENCE_DIR/baseline-validation-results.jsonl"
  capture_guest_state "prepare-$version-$profile-complete"
  shutdown_vm
  mv "$disk" "$overlay"
}

assemble_baseline_pack() {
  local versions version overlay_dir lock_sha manifest_tmp overlay overlay_sha
  case "$BASELINE_SELECTOR" in
    all) versions=("${BASELINE_VERSIONS[@]}") ;;
    fleet) versions=("${FLEET_BASELINE_VERSIONS[@]}") ;;
    *) versions=("$BASELINE_SELECTOR") ;;
  esac
  mv "$WORK/vm-base-rd23-stock.img" "$BASELINE_OUTPUT_DIR/bases/rd23-stock.img"
  rm -f "$WORK/vm-base.img"
  for version in "${versions[@]}"; do
    overlay_dir="$BASELINE_OUTPUT_DIR/overlays/rd23-stock"
    (cd "$overlay_dir" && qemu-img rebase -u -f qcow2 -F raw \
      -b ../../bases/rd23-stock.img "baseline-$version.qcow2")
  done

  if [[ "$BASELINE_SELECTOR" = all ]]; then
    mv "$WORK/vm-base-rd23-ubootmod.img" "$BASELINE_OUTPUT_DIR/bases/rd23-ubootmod.img"
    (cd "$BASELINE_OUTPUT_DIR/overlays/rd23-ubootmod" &&
      qemu-img rebase -u -f qcow2 -F raw -b ../../bases/rd23-ubootmod.img baseline-0.7.10.qcow2)
  fi

  lock_sha="$(sha256sum "$BASELINE_LOCK" | awk '{print $1}')"
  manifest_tmp="$WORK/baseline-pack-manifest.json"
  jq -s --slurpfile lock "$BASELINE_LOCK" \
    --arg builder_commit "$HARNESS_SOURCE_SHA" --arg input_lock_sha256 "$lock_sha" \
    --arg baseline_contract_digest "$BASELINE_CONTRACT_DIGEST" \
    --arg expected_xray_binary_sha256 "$(sed -n '1p' "$WORK/xray-binary.sha256")" \
    --arg fixture_sha256 "$(jq -r .fixture.tree_sha256 "$BASELINE_LOCK")" \
    --arg stock_base_sha256 "$(sha256sum "$BASELINE_OUTPUT_DIR/bases/rd23-stock.img" | awk '{print $1}')" \
    --arg ubootmod_base_sha256 "$([[ -s "$BASELINE_OUTPUT_DIR/bases/rd23-ubootmod.img" ]] && sha256sum "$BASELINE_OUTPUT_DIR/bases/rd23-ubootmod.img" | awk '{print $1}' || true)" '
      {schema_version:1,verified:true,builder_commit:$builder_commit,
       baseline_contract_digest:$baseline_contract_digest,
       input_lock_sha256:$input_lock_sha256,openwrt:$lock[0].openwrt,xray:$lock[0].xray,
       expected_xray_binary_sha256:$expected_xray_binary_sha256,
       fixture:($lock[0].fixture + {verified_tree_sha256:$fixture_sha256}),
       storage_profiles:$lock[0].storage_profiles,
       base_disks:{"rd23-stock":{path:"bases/rd23-stock.img",sha256:$stock_base_sha256},
         "rd23-ubootmod":(if $ubootmod_base_sha256 == "" then null else
           {path:"bases/rd23-ubootmod.img",sha256:$ubootmod_base_sha256} end)},
       baselines:map(. as $result | ($lock[0].baselines[] | select(.version == $result.version)) +
         $result + {overlay_path:("overlays/" + $result.storage_profile + "/baseline-" + $result.version + ".qcow2")})}
    ' "$EVIDENCE_DIR/baseline-validation-results.jsonl" > "$manifest_tmp"
  while IFS= read -r overlay; do
    overlay_sha="$(sha256sum "$BASELINE_OUTPUT_DIR/$overlay" | awk '{print $1}')"
    jq --arg path "$overlay" --arg sha "$overlay_sha" \
      '(.baselines[] | select(.overlay_path == $path)).overlay_sha256 = $sha' \
      "$manifest_tmp" > "$manifest_tmp.next"
    mv "$manifest_tmp.next" "$manifest_tmp"
  done < <(jq -r '.baselines[].overlay_path' "$manifest_tmp")
  mv "$manifest_tmp" "$BASELINE_OUTPUT_DIR/baseline-pack-manifest.json"
  jq -n --arg builder_commit "$HARNESS_SOURCE_SHA" \
    --arg selector "$BASELINE_SELECTOR" \
    --arg baseline_contract_digest "$BASELINE_CONTRACT_DIGEST" \
    --arg manifest_sha256 "$(sha256sum "$BASELINE_OUTPUT_DIR/baseline-pack-manifest.json" | awk '{print $1}')" \
    --arg input_lock_sha256 "$lock_sha" \
    '{schema_version:1,kind:"router-ui-legacy-baseline-pack",immutable:true,
      builder_commit:$builder_commit,selector:$selector,
      baseline_contract_digest:$baseline_contract_digest,
      manifest_sha256:$manifest_sha256,input_lock_sha256:$input_lock_sha256}' \
    > "$BASELINE_OUTPUT_DIR/baseline-pack-descriptor.json"
  (cd "$BASELINE_OUTPUT_DIR" &&
    find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | sed 's#^./##' |
    while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS)
  cp "$BASELINE_OUTPUT_DIR/baseline-pack-manifest.json" "$EVIDENCE_DIR/"
}

prepare_baseline_pack() {
  local versions version
  run_vm_phase initialize-baseline-pack initialize_baseline_pack
  case "$BASELINE_SELECTOR" in
    all) versions=("${BASELINE_VERSIONS[@]}") ;;
    fleet) versions=("${FLEET_BASELINE_VERSIONS[@]}") ;;
    *) versions=("$BASELINE_SELECTOR") ;;
  esac
  for version in "${versions[@]}"; do
    run_vm_phase "baseline-validation-$version" \
      prepare_baseline_version "$version" rd23-stock
  done
  if [[ "$BASELINE_SELECTOR" = all ]]; then
    run_vm_phase baseline-validation-0.7.10-ubootmod \
      prepare_baseline_version 0.7.10 rd23-ubootmod
  fi
  run_vm_phase assemble-baseline-pack assemble_baseline_pack
}

run_old_worker_version() {
  local version="$1"
  VM_ACTIVE_VERSION="$version"
  case "$version" in 0.7.9|0.7.10) ;; *) fail "old-worker requires source 0.7.9 or 0.7.10" ;; esac
    disk="$WORK/old-worker-$version.qcow2"
    clone_disk "$WORK/baseline-$version.qcow2" "$disk" qcow2
    start_baseline_vm "$disk" "old-worker-$version"; record_measurement "old-worker-$version"
    before="$(guest protected-hash)"; usage_before="$(measure_stock)"
    transaction="$(guest old-worker "$ORIGIN" "$version" "$CANDIDATE_APP_VERSION" | tail -n 1)"
    usage_candidate="$(measure_stock)"
    guest verify-target "$CANDIDATE_APP_VERSION" "$CANDIDATE_PACKAGE_VERSION" "$version" pending
    node "$ROOT_DIR/tests/vm/check-status-card.cjs" \
      "http://127.0.0.1:$HTTP_PORT/cgi-bin/luci/admin/status/overview" \
      > "$EVIDENCE_DIR/old-worker-$version-visible-card.json"
    normal_reboot
    guest verify-target "$CANDIDATE_APP_VERSION" "$CANDIDATE_PACKAGE_VERSION" "$version" post-reboot
    usage_committed="$(measure_stock)"
    [[ "$(guest protected-hash)" = "$before" ]] || fail "protected hash drift after old-worker reboot"
    guest rollback "$transaction" "$version"; usage_rolled_back="$(measure_stock)"; normal_reboot
    [[ "$(sed -n '1p' < <("${ssh_base[@]}" cat /usr/share/vpn-ui/version))" = "$version" ]] || fail "old-worker rollback did not persist"
    usage_after="$(measure_stock)"
    details="$(jq -cn --arg transaction "$transaction" --argjson before "$usage_before" \
      --argjson candidate "$usage_candidate" --argjson committed "$usage_committed" \
      --argjson rolled_back "$usage_rolled_back" --argjson after "$usage_after" \
      '{transaction:$transaction,disk_before:$before,disk_candidate:$candidate,
        disk_committed:$committed,disk_rolled_back:$rolled_back,disk_after_reboot:$after}')"
    record_result "$EVIDENCE_DIR/transition-results.jsonl" old-worker \
      "$version->$CANDIDATE_APP_VERSION->rollback" pass "$details"
    shutdown_vm; rm -f "$disk"
}
run_old_worker_matrix() {
  local version versions
  if [[ -n "$VM_SOURCE_VERSION" ]]; then versions=("$VM_SOURCE_VERSION"); else versions=(0.7.9 0.7.10); fi
  for version in "${versions[@]}"; do
    run_vm_phase "old-worker-$version" run_old_worker_version "$version"
  done
}

run_rescue_version() {
    local version="$1" rescue_log
    VM_ACTIVE_VERSION="$version"
    disk="$WORK/rescue-$version.qcow2"
    clone_disk "$WORK/baseline-$version.qcow2" "$disk" qcow2
    start_baseline_vm "$disk" "rescue-$version"; record_measurement "rescue-$version"
    before="$(guest protected-hash)"; usage_before="$(measure_stock)"
    rescue_log="$EVIDENCE_DIR/rescue-$version.guest-validator.log"
    guest rescue "$ORIGIN" "$version" "$CANDIDATE_APP_VERSION" \
      "$CANDIDATE_RELEASE_TAG" 2>&1 | tee "$rescue_log"
    transaction="$(tail -n 1 "$rescue_log")"
    usage_candidate="$(measure_stock)"
    guest verify-target "$CANDIDATE_APP_VERSION" "$CANDIDATE_PACKAGE_VERSION" "$version" pending
    capture_guest_state "rescue-$version-pending-reboot"
    normal_reboot
    guest verify-target "$CANDIDATE_APP_VERSION" "$CANDIDATE_PACKAGE_VERSION" "$version" post-reboot
    usage_committed="$(measure_stock)"
    capture_guest_state "rescue-$version-committed"
    guest rollback "$transaction" "$version"
    usage_rolled_back="$(measure_stock)"
    capture_guest_state "rescue-$version-rolled-back"
    normal_reboot
    usage_final="$(measure_stock)"
    [[ "$("${ssh_base[@]}" sed -n '1p' /usr/share/vpn-ui/version)" = "$version" ]] || fail "rescue rollback did not persist: $version"
    [[ "$(guest protected-hash)" = "$before" ]] || fail "rescue protected hash drift: $version"
    details="$(jq -cn --arg transaction "$transaction" --argjson before "$usage_before" \
      --argjson candidate "$usage_candidate" --argjson committed "$usage_committed" \
      --argjson rolled_back "$usage_rolled_back" --argjson final "$usage_final" \
      '{transaction:$transaction,disk_before:$before,disk_candidate:$candidate,
        disk_committed:$committed,disk_rolled_back:$rolled_back,disk_after_rollback_reboot:$final}')"
    record_result "$EVIDENCE_DIR/transition-results.jsonl" rescue \
      "$version->$CANDIDATE_APP_VERSION->rollback" pass "$details"
    shutdown_vm; rm -f "$disk"
}
run_rescue_matrix() {
  local versions version
  if [[ -n "$VM_SOURCE_VERSION" ]]; then versions=("$VM_SOURCE_VERSION"); else versions=("${BASELINE_VERSIONS[@]}"); fi
  for version in "${versions[@]}"; do
    run_vm_phase "rescue-$version" run_rescue_version "$version"
  done
}

run_refusals() {
  VM_ACTIVE_VERSION=0.7.10
  local values=(0.7.7 unknown 0.7 development 0.7.11RC1 0.8.0)
  local candidate_base="$ORIGIN/releases/download/$CANDIDATE_RELEASE_TAG"
  for value in "${values[@]}"; do
    disk="$WORK/refuse-${value//[^A-Za-z0-9]/_}.qcow2"
    clone_disk "$WORK/baseline-0.7.10.qcow2" "$disk" qcow2
    start_baseline_vm "$disk" "refuse-${value//[^A-Za-z0-9]/_}"; record_measurement "refuse-$value"
    "${ssh_base[@]}" "printf '%s\\n' '$value' > /usr/share/vpn-ui/version; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem curl -fsSL --proto '=https' '$candidate_base/rescue-router-ui.sh' -o /tmp/rescue; chmod 700 /tmp/rescue; ! SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem ROUTER_UI_RELEASE_BASE='$candidate_base' sh /tmp/rescue" >/dev/null
    record_result "$EVIDENCE_DIR/transition-results.jsonl" refusal "$value" pass '{}'
    shutdown_vm; rm -f "$disk"
  done
  disk="$WORK/refuse-target.qcow2"; clone_disk "$WORK/baseline-0.7.10.qcow2" "$disk" qcow2
  start_baseline_vm "$disk" refuse-other-target; record_measurement refuse-other-target
  "${ssh_base[@]}" "SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem curl -fsSL --proto '=https' '$candidate_base/rescue-router-ui.sh' -o /tmp/rescue; chmod 700 /tmp/rescue; ! SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem ROUTER_UI_TARGET_VERSION='$SUCCESSOR_APP_VERSION' ROUTER_UI_RELEASE_BASE='$candidate_base' sh /tmp/rescue" >/dev/null
  record_result "$EVIDENCE_DIR/transition-results.jsonl" refusal direct-other-target pass '{}'
  shutdown_vm; rm -f "$disk"
}

run_clean_image() {
  VM_ACTIVE_VERSION="$CANDIDATE_APP_VERSION"
  disk="$WORK/clean-image.qcow2"; clone_disk "$WORK/candidate.img" "$disk" raw
  start_candidate_vm "$disk" clean-image; record_measurement clean-image
  fingerprint="$(jq -er .signing_key_fingerprint "$RELEASE_DIR/router-release-manifest.json")"
  guest verify-clean-image "$fingerprint" "$CANDIDATE_APP_VERSION" "$CANDIDATE_PACKAGE_VERSION"
  normal_reboot
  guest verify-clean-image "$fingerprint" "$CANDIDATE_APP_VERSION" "$CANDIDATE_PACKAGE_VERSION"
  record_result "$EVIDENCE_DIR/transition-results.jsonl" image clean-x86-boot pass '{}'
  shutdown_vm; rm -f "$disk"
}

run_dual_daemon() {
  local disk sample pre_boot_id post_boot_id evidence details probe_url min_mem_available_kib
  local tailscale_backend_states
  VM_ACTIVE_VERSION="$CANDIDATE_APP_VERSION"
  evidence="$EVIDENCE_DIR/dual-daemon-evidence.jsonl"
  probe_url="$ORIGIN/vm/dual-daemon-probe.txt"
  : > "$evidence"
  disk="$WORK/dual-daemon.qcow2"
  clone_disk "$WORK/candidate.img" "$disk" raw
  start_candidate_vm "$disk" dual-daemon
  record_measurement dual-daemon-before-reboot
  guest dual-daemon-setup "$CANDIDATE_APP_VERSION" "$CANDIDATE_PACKAGE_VERSION"
  pre_boot_id="$("${ssh_base[@]}" cat /proc/sys/kernel/random/boot_id)"
  for ((sample = 1; sample <= DUAL_DAEMON_SAMPLES; sample++)); do
    guest dual-daemon-sample before-reboot "$CANDIDATE_APP_VERSION" \
      "$CANDIDATE_PACKAGE_VERSION" "$probe_url" >> "$evidence"
    (( sample == DUAL_DAEMON_SAMPLES )) || sleep "$DUAL_DAEMON_INTERVAL_SECONDS"
  done

  normal_reboot
  post_boot_id="$("${ssh_base[@]}" cat /proc/sys/kernel/random/boot_id)"
  [[ "$post_boot_id" != "$pre_boot_id" ]] || fail "dual-daemon reboot did not change boot ID"
  record_measurement dual-daemon-after-reboot
  for ((sample = 1; sample <= DUAL_DAEMON_SAMPLES; sample++)); do
    guest dual-daemon-sample after-reboot "$CANDIDATE_APP_VERSION" \
      "$CANDIDATE_PACKAGE_VERSION" "$probe_url" >> "$evidence"
    (( sample == DUAL_DAEMON_SAMPLES )) || sleep "$DUAL_DAEMON_INTERVAL_SECONDS"
  done
  capture_guest_state dual-daemon-final

  jq -s -e --arg app "$CANDIDATE_APP_VERSION" \
    --arg package "$CANDIDATE_PACKAGE_VERSION" \
    --arg before "$pre_boot_id" --arg after "$post_boot_id" \
    --argjson samples "$DUAL_DAEMON_SAMPLES" '
      length == ($samples * 2) and
      ([.[] | select(.phase == "before-reboot")] | length) == $samples and
      ([.[] | select(.phase == "after-reboot")] | length) == $samples and
      ([.[] | select(.phase == "before-reboot") | .tailscaled |
        [.pid,.starttime_ticks]] | unique | length) == 1 and
      ([.[] | select(.phase == "before-reboot") | .xray |
        [.pid,.starttime_ticks]] | unique | length) == 1 and
      ([.[] | select(.phase == "after-reboot") | .tailscaled |
        [.pid,.starttime_ticks]] | unique | length) == 1 and
      ([.[] | select(.phase == "after-reboot") | .xray |
        [.pid,.starttime_ticks]] | unique | length) == 1 and
      all(.[];
        .app_version == $app and .package_version == $package and
        .mem_total_kib >= 220000 and .mem_total_kib <= 262144 and
        .mem_available_kib >= 16384 and .tmp_free_kib > 0 and .overlay_free_kib > 0 and
        .tailscaled.running == true and .tailscaled.pid > 0 and
        .tailscaled.starttime_ticks > 0 and .tailscaled.rss_kib > 0 and
        .xray.running == true and .xray.pid > 0 and
        .xray.starttime_ticks > 0 and .xray.rss_kib > 0 and
        .xray.loopback_only == true and .xray.traffic_probe_ok == true and
        .router_ui_status_ok == true and .tailscale_local_api_ok == true and
        .tailscale_backend_state == "NeedsLogin" and
        .tailscale_ips_present == false and
        .tailscale_enrollment_observed == "not-enrolled" and
        .oom_detected == false and
        .hardware_verified == false) and
      all(.[] | select(.phase == "before-reboot"); .boot_id == $before) and
      all(.[] | select(.phase == "after-reboot"); .boot_id == $after) and
      $before != $after
    ' "$evidence" >/dev/null || fail "dual-daemon evidence contract failed"
  min_mem_available_kib="$(jq -s '[.[].mem_available_kib] | min' "$evidence")"
  tailscale_backend_states="$(jq -c -s '[.[].tailscale_backend_state] | unique' "$evidence")"
  details="$(jq -cn --arg app_version "$CANDIDATE_APP_VERSION" \
    --arg package_version "$CANDIDATE_PACKAGE_VERSION" \
    --arg before_boot_id "$pre_boot_id" --arg after_boot_id "$post_boot_id" \
    --argjson samples_per_boot "$DUAL_DAEMON_SAMPLES" \
    --argjson minimum_mem_available_kib "$min_mem_available_kib" \
    --argjson tailscale_backend_states "$tailscale_backend_states" \
    '{app_version:$app_version,package_version:$package_version,
      configured_ram_mib:256,samples_per_boot:$samples_per_boot,
      minimum_mem_available_kib:$minimum_mem_available_kib,
      before_boot_id:$before_boot_id,after_boot_id:$after_boot_id,
      boot_id_changed:($before_boot_id != $after_boot_id),
      release_package_set_persisted:true,tailscaled_real_process:true,
      tailscale_enrollment:"not-enrolled",tailscale_enrollment_observed:true,
      tailscale_backend_states:$tailscale_backend_states,tailscale_ips_present:false,
      xray_real_process:true,
      xray_scope:"non-secret-local-loopback-only",oom_detected:false,
      process_restart_detected:false,
      vm_verified:true,rd23_hardware_verified:false}')"
  record_result "$EVIDENCE_DIR/transition-results.jsonl" runtime \
    dual-daemon-256m pass "$details"
  shutdown_vm
  rm -f "$disk"
}

run_protocol_v2() {
  local poll state
  VM_ACTIVE_VERSION="$CANDIDATE_APP_VERSION"
  disk="$WORK/protocol-v2.qcow2"; clone_disk "$WORK/candidate.img" "$disk" raw
  start_candidate_vm "$disk" protocol-v2; record_measurement protocol-v2
  discovery="$ORIGIN/releases/download/$SUCCESSOR_RELEASE_TAG"
  protected_before="$(guest protected-hash)"; usage_before="$(measure_stock)"
  "${ssh_base[@]}" "SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_RELEASE_ORIGIN='$ORIGIN' VPN_UI_DISCOVERY_BASE='$discovery' /usr/sbin/vpn-ui-update check-start" \
    > "$EVIDENCE_DIR/protocol-v2-check-start.json"
  jq -e '.ok and .started and .job == "check"' \
    "$EVIDENCE_DIR/protocol-v2-check-start.json" >/dev/null || fail "detached update check did not start"
  state=waiting
  for poll in {1..120}; do
    if guest verify-update-available "$CANDIDATE_APP_VERSION" "$CANDIDATE_PACKAGE_VERSION" \
      "$SUCCESSOR_APP_VERSION" "$SUCCESSOR_PACKAGE_VERSION" >/dev/null 2>&1; then
      state=available
      break
    fi
    sleep 1
  done
  [[ "$state" = available ]] || fail "detached update check did not publish verified availability"
  "${ssh_base[@]}" "SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_RELEASE_ORIGIN='$ORIGIN' /usr/sbin/vpn-ui-update apply-start" \
    > "$EVIDENCE_DIR/protocol-v2-apply-start.json"
  jq -e '.ok and .started and .job == "apply"' \
    "$EVIDENCE_DIR/protocol-v2-apply-start.json" >/dev/null || fail "detached update apply did not start"
  transaction=""
  state=waiting
  for poll in {1..180}; do
    transaction="$("${ssh_base[@]}" sed -n '1p' /root/premier-router-updates/active-transaction 2>/dev/null || true)"
    if [[ "$transaction" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]]; then
      state="$("${ssh_base[@]}" "jsonfilter -i '/root/premier-router-updates/$transaction/state.json' -e '@.state'" 2>/dev/null || true)"
      if [[ "$state" = committed_pending_reboot_validation ]] &&
        ! "${ssh_base[@]}" test -d /root/premier-router-updates/update.lock 2>/dev/null; then
        break
      fi
      case "$state" in rollback_failed|recovery_required) fail "detached updater reached unsafe state: $state" ;; esac
    fi
    sleep 1
  done
  [[ "$state" = committed_pending_reboot_validation ]] ||
    fail "detached update apply did not reach a pending committed state"
  guest verify-target "$SUCCESSOR_APP_VERSION" "$SUCCESSOR_PACKAGE_VERSION" \
    "$CANDIDATE_APP_VERSION" pending
  usage_candidate_one="$(measure_stock)"
  normal_reboot
  guest verify-target "$SUCCESSOR_APP_VERSION" "$SUCCESSOR_PACKAGE_VERSION" \
    "$CANDIDATE_APP_VERSION" post-reboot
  usage_committed_one="$(measure_stock)"
  guest rollback "$transaction" "$CANDIDATE_APP_VERSION" "$CANDIDATE_PACKAGE_VERSION"
  usage_rollback_one="$(measure_stock)"; normal_reboot
  [[ "$(guest protected-hash)" = "$protected_before" ]] || fail "package rollback changed protected configuration"
  "${ssh_base[@]}" "mkdir -p /root/premier-router-updates/recovery-required-must-survive; printf '%s\\n' '{\"state\":\"recovery_required\"}' > /root/premier-router-updates/recovery-required-must-survive/state.json; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_RELEASE_ORIGIN='$ORIGIN' VPN_UI_DISCOVERY_BASE='$discovery' VPN_UI_SYNC_WORKER=1 /usr/sbin/vpn-ui-update check-start; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_RELEASE_ORIGIN='$ORIGIN' VPN_UI_SYNC_WORKER=1 /usr/sbin/vpn-ui-update apply-start" >/dev/null
  second_transaction="$("${ssh_base[@]}" sed -n '1p' /root/premier-router-updates/active-transaction)"
  normal_reboot
  guest verify-target "$SUCCESSOR_APP_VERSION" "$SUCCESSOR_PACKAGE_VERSION" \
    "$CANDIDATE_APP_VERSION" post-reboot
  usage_committed_two="$(measure_stock)"
  "${ssh_base[@]}" test -f /root/premier-router-updates/recovery-required-must-survive/state.json || fail "cleanup pruned recovery-required evidence"
  tx_count="$("${ssh_base[@]}" "find /root/premier-router-updates -mindepth 1 -maxdepth 1 -type d | wc -l")"
  [[ "$tx_count" -le 6 ]] || fail "successful transactions accumulated without bound"
  guest rollback "$second_transaction" "$CANDIDATE_APP_VERSION" "$CANDIDATE_PACKAGE_VERSION"
  normal_reboot
  [[ "$("${ssh_base[@]}" sed -n '1p' /usr/share/vpn-ui/version)" = "$CANDIDATE_APP_VERSION" ]] ||
    fail "retained exact rollback failed after cleanup"
  usage_final="$(measure_stock)"
  [[ "$(guest protected-hash)" = "$protected_before" ]] || fail "repeated package cycle changed protected configuration"
  record_result "$EVIDENCE_DIR/transition-results.jsonl" protocol-v2 \
    "$CANDIDATE_APP_VERSION->$SUCCESSOR_APP_VERSION->$CANDIDATE_APP_VERSION->$SUCCESSOR_APP_VERSION->$CANDIDATE_APP_VERSION" pass \
    "$(jq -cn --argjson retained "$tx_count" --argjson before "$usage_before" \
      --argjson candidate_one "$usage_candidate_one" --argjson committed_one "$usage_committed_one" \
      --argjson rollback_one "$usage_rollback_one" --argjson committed_two "$usage_committed_two" \
      --argjson final "$usage_final" \
      '{retained_directories:$retained,disk_before:$before,disk_candidate_one:$candidate_one,
        disk_committed_one:$committed_one,disk_rollback_one:$rollback_one,
        disk_committed_two:$committed_two,disk_final:$final,protected_state_matches:true}')"
  shutdown_vm; rm -f "$disk"
}

run_storage_pressure() {
  local selector="${1:-$VM_PHASE_SELECTOR}"
  local disk transaction required before after target state candidate_base
  VM_ACTIVE_VERSION=0.7.10

  if [[ "$selector" = all || "$selector" = normal ]]; then
  disk="$WORK/storage-normal.qcow2"; clone_disk "$WORK/baseline-0.7.10.qcow2" "$disk" qcow2
  start_baseline_vm "$disk" storage-normal; record_measurement storage-normal
  before="$(measure_stock)"
  transaction="$(guest rescue "$ORIGIN" 0.7.10 "$CANDIDATE_APP_VERSION" \
    "$CANDIDATE_RELEASE_TAG" | tail -n 1)"
  candidate="$(measure_stock)"; normal_reboot
  guest verify-target "$CANDIDATE_APP_VERSION" "$CANDIDATE_PACKAGE_VERSION" \
    0.7.10 post-reboot
  after="$(measure_stock)"
  record_result "$EVIDENCE_DIR/storage-results.jsonl" pressure normal-success pass \
    "$(jq -cn --argjson before "$before" --argjson candidate "$candidate" --argjson after "$after" \
      '{before:$before,candidate:$candidate,committed_after_reboot:$after}')"
  shutdown_vm; rm -f "$disk"
  fi

  if [[ "$selector" = all || "$selector" = near-reservation ]]; then
  disk="$WORK/storage-near.qcow2"; clone_disk "$WORK/baseline-0.7.10.qcow2" "$disk" qcow2
  start_baseline_vm "$disk" storage-near; record_measurement storage-near
  candidate_base="$ORIGIN/releases/download/$CANDIDATE_RELEASE_TAG"
  "${ssh_base[@]}" "touch /etc/premier-router/test-mode; printf '%s\\n' before-mutation > /etc/premier-router/test-mode.fail-after; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem curl -fsSL --proto '=https' '$candidate_base/rescue-router-ui.sh' -o /tmp/r; chmod 700 /tmp/r; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_TEST_FAIL_MODE=return ROUTER_UI_RELEASE_BASE='$candidate_base' sh /tmp/r" >/dev/null 2>&1 || true
  transaction="$("${ssh_base[@]}" sed -n '1p' /root/premier-router-updates/active-transaction)"
  required="$("${ssh_base[@]}" "jsonfilter -i /root/premier-router-updates/$transaction/reservation.json -e '@.persistent_required_kib'")"
  "${ssh_base[@]}" /usr/sbin/vpn-ui-update recover >/dev/null
  target=$((required + 1024)); guest fill-to-free "$target"
  transaction="$(guest rescue "$ORIGIN" 0.7.10 "$CANDIDATE_APP_VERSION" \
    "$CANDIDATE_RELEASE_TAG" | tail -n 1)"
  record_result "$EVIDENCE_DIR/storage-results.jsonl" pressure slightly-above-reservation pass \
    "$(jq -cn --argjson required "$required" --argjson target "$target" '{reservation_kib:$required,target_free_kib:$target}')"
  shutdown_vm; rm -f "$disk"
  fi

  if [[ "$selector" = all || "$selector" = below-reservation ]]; then
  disk="$WORK/storage-below.qcow2"; clone_disk "$WORK/baseline-0.7.10.qcow2" "$disk" qcow2
  start_baseline_vm "$disk" storage-below; record_measurement storage-below
  before="$(guest protected-hash)"
  candidate_base="$ORIGIN/releases/download/$CANDIDATE_RELEASE_TAG"
  "${ssh_base[@]}" "touch /etc/premier-router/test-mode; printf '%s\\n' before-mutation > /etc/premier-router/test-mode.fail-after; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem curl -fsSL --proto '=https' '$candidate_base/rescue-router-ui.sh' -o /tmp/r; chmod 700 /tmp/r; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_TEST_FAIL_MODE=return ROUTER_UI_RELEASE_BASE='$candidate_base' sh /tmp/r" >/dev/null 2>&1 || true
  transaction="$("${ssh_base[@]}" sed -n '1p' /root/premier-router-updates/active-transaction)"
  required="$("${ssh_base[@]}" "jsonfilter -i /root/premier-router-updates/$transaction/reservation.json -e '@.persistent_required_kib'")"
  "${ssh_base[@]}" /usr/sbin/vpn-ui-update recover >/dev/null
  target=$((required - 1024)); (( target > 0 )) || fail "invalid below-reservation target"
  guest fill-to-free "$target"
  "${ssh_base[@]}" "SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem curl -fsSL --proto '=https' '$candidate_base/rescue-router-ui.sh' -o /tmp/r2; chmod 700 /tmp/r2; ! SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem ROUTER_UI_RELEASE_BASE='$candidate_base' sh /tmp/r2" >/dev/null
  [[ "$(guest protected-hash)" = "$before" ]] || fail "below-reservation refusal changed protected source"
  [[ "$("${ssh_base[@]}" sed -n '1p' /usr/share/vpn-ui/version)" = 0.7.10 ]] || fail "below-reservation refusal mutated source version"
  state="$("${ssh_base[@]}" '/usr/sbin/vpn-ui-update status | jsonfilter -e "@.job.stage"')"
  [[ "$state" = failed_before_mutation ]] || fail "low-space refusal was not pre-mutation"
  record_result "$EVIDENCE_DIR/storage-results.jsonl" pressure below-reservation-refusal pass \
    "$(jq -cn --argjson required "$required" --argjson target "$target" '{reservation_kib:$required,target_free_kib:$target,source_unchanged:true}')"
  shutdown_vm; rm -f "$disk"
  fi
}

run_concurrency() {
  VM_ACTIVE_VERSION="$CANDIDATE_APP_VERSION"
  disk="$WORK/concurrency.qcow2"; clone_disk "$WORK/candidate.img" "$disk" raw
  start_candidate_vm "$disk" concurrency; record_measurement concurrency
  details="$(guest concurrency-race "$ORIGIN" \
    "$ORIGIN/releases/download/$SUCCESSOR_RELEASE_TAG")"
  record_result "$EVIDENCE_DIR/transition-results.jsonl" concurrency cli-rpc-cron pass "$details"
  shutdown_vm; rm -f "$disk"
}

run_fault_boundary_case() {
  local boundaries boundary valid_boundary candidate_base source_package_version actual_package_version
  candidate_base="$ORIGIN/releases/download/$CANDIDATE_RELEASE_TAG"
  if [[ -n "$VM_FAULT_BOUNDARY" ]]; then
    valid_boundary=false
    for boundary in "${FAULT_BOUNDARIES[@]}"; do
      [[ "$boundary" = "$VM_FAULT_BOUNDARY" ]] && valid_boundary=true
    done
    [[ "$valid_boundary" = true ]] || fail "unknown fault boundary: $VM_FAULT_BOUNDARY"
    boundaries=("$VM_FAULT_BOUNDARY")
  else
    boundaries=("${FAULT_BOUNDARIES[@]}")
  fi
  for boundary in "${boundaries[@]}"; do
    source_version=0.7.10
    source_package_version=""
    VM_ACTIVE_VERSION="$source_version"
    target_version="$CANDIDATE_APP_VERSION"
    target_package_version="$CANDIDATE_PACKAGE_VERSION"
    disk="$WORK/fault-${boundary}.qcow2"; clone_disk "$WORK/baseline-0.7.10.qcow2" "$disk" qcow2
    start_baseline_vm "$disk" "fault-$boundary"; record_measurement "fault-$boundary"
    before="$(guest protected-hash)"
    case "$boundary" in
      rolling_back)
        transaction="$(guest rescue "$ORIGIN" 0.7.10 "$CANDIDATE_APP_VERSION" \
          "$CANDIDATE_RELEASE_TAG" | tail -n 1)"
        "${ssh_base[@]}" "touch /etc/premier-router/test-mode; printf '%s\\n' '$boundary' > /etc/premier-router/test-mode.fail-after; sh /root/premier-router-updates/$transaction/rollback.sh" >/dev/null 2>&1 || true
        ;;
      rollback-after-*)
        shutdown_vm
        rm -f "$disk"; clone_disk "$WORK/candidate.img" "$disk" raw
        start_candidate_vm "$disk" "fault-$boundary"; record_measurement "fault-$boundary-ipk"
        source_version="$CANDIDATE_APP_VERSION"
        source_package_version="$CANDIDATE_PACKAGE_VERSION"
        VM_ACTIVE_VERSION="$source_version"
        target_version="$SUCCESSOR_APP_VERSION"
        target_package_version="$SUCCESSOR_PACKAGE_VERSION"
        before="$(guest protected-hash)"
        discovery="$ORIGIN/releases/download/$SUCCESSOR_RELEASE_TAG"
        "${ssh_base[@]}" "SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_RELEASE_ORIGIN='$ORIGIN' VPN_UI_DISCOVERY_BASE='$discovery' VPN_UI_SYNC_WORKER=1 /usr/sbin/vpn-ui-update check-start; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_RELEASE_ORIGIN='$ORIGIN' VPN_UI_SYNC_WORKER=1 /usr/sbin/vpn-ui-update apply-start" >/dev/null
        transaction="$("${ssh_base[@]}" sed -n '1p' /root/premier-router-updates/active-transaction)"
        normal_reboot
        guest verify-target "$SUCCESSOR_APP_VERSION" "$SUCCESSOR_PACKAGE_VERSION" \
          "$CANDIDATE_APP_VERSION" post-reboot
        "${ssh_base[@]}" "touch /etc/premier-router/test-mode; printf '%s\\n' '$boundary' > /etc/premier-router/test-mode.fail-after; sh /root/premier-router-updates/$transaction/rollback.sh" >/dev/null 2>&1 || true
        ;;
      compatibility-cleanup|post-reboot-validation)
        shutdown_vm
        rm -f "$disk"; clone_disk "$WORK/baseline-0.7.9.qcow2" "$disk" qcow2
        start_baseline_vm "$disk" "fault-$boundary"; record_measurement "fault-$boundary-079"
        source_version=0.7.9
        VM_ACTIVE_VERSION="$source_version"
        before="$(guest protected-hash)"
        guest rescue "$ORIGIN" 0.7.9 "$CANDIDATE_APP_VERSION" \
          "$CANDIDATE_RELEASE_TAG" >/dev/null
        "${ssh_base[@]}" "touch /etc/premier-router/test-mode; printf '%s\\n' '$boundary' > /etc/premier-router/test-mode.fail-after; reboot" >/dev/null 2>&1 || true
        sleep 5
        ;;
      rollback_pending)
        "${ssh_base[@]}" "touch /etc/premier-router/test-mode /etc/premier-router/test-mode.force-candidate-failure; printf '%s\\n' '$boundary' > /etc/premier-router/test-mode.fail-after; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem ROUTER_UI_RELEASE_BASE='$candidate_base' sh -c 'curl -fsSL --proto \"=https\" \"$candidate_base/rescue-router-ui.sh\" -o /tmp/r; sh /tmp/r'" >/dev/null 2>&1 || true
        ;;
      *)
        "${ssh_base[@]}" "touch /etc/premier-router/test-mode; printf '%s\\n' '$boundary' > /etc/premier-router/test-mode.fail-after; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem ROUTER_UI_RELEASE_BASE='$candidate_base' sh -c 'curl -fsSL --proto \"=https\" \"$candidate_base/rescue-router-ui.sh\" -o /tmp/r; sh /tmp/r'" >/dev/null 2>&1 || true
        ;;
    esac
    "${ssh_base[@]}" test ! -e /etc/premier-router/test-mode.fail-after ||
      fail "fault boundary was not reached: $boundary"
    hard_poweroff_vm
    start_baseline_vm "$disk" "recover-$boundary"; record_measurement "recover-$boundary"
    state=''
    for _ in {1..10}; do
      "${ssh_base[@]}" /etc/init.d/premier-router-update-recovery start >/dev/null 2>&1 || true
      state="$("${ssh_base[@]}" '/usr/sbin/vpn-ui-update status | jsonfilter -e "@.job.stage"' 2>/dev/null || true)"
      case "$state" in committed|rolled_back|failed_before_mutation) break ;; esac
      sleep 1
    done
    case "$state" in committed|rolled_back|failed_before_mutation) ;; *) fail "fault $boundary converged to unsafe state: $state" ;; esac
    [[ "$(guest protected-hash)" = "$before" ]] || fail "fault $boundary changed protected configuration"
    case "$state" in
      committed)
        guest verify-target "$target_version" "$target_package_version" \
          "$source_version" post-reboot
        ;;
      rolled_back|failed_before_mutation)
        [[ "$("${ssh_base[@]}" sed -n '1p' /usr/share/vpn-ui/version)" = "$source_version" ]] ||
          fail "fault $boundary did not restore exact source version"
        if [[ -n "$source_package_version" ]]; then
          for package in premier-router-core luci-app-premier-router premier-router-setup; do
            actual_package_version="$("${ssh_base[@]}" \
              "opkg status '$package' | sed -n 's/^Version: //p' | sed -n '1p'")"
            [[ "$actual_package_version" = "$source_package_version" ]] ||
              fail "fault $boundary did not restore exact source package version: $package"
          done
        fi
        ;;
    esac
    versions="$("${ssh_base[@]}" 'for p in premier-router-core luci-app-premier-router premier-router-setup; do opkg status "$p" | sed -n "s/^Version: //p" | sed -n 1p; done' | sed '/^$/d' | sort -u | wc -l)"
    [[ "$versions" -le 1 ]] || fail "fault $boundary left mixed project package versions"
    record_result "$EVIDENCE_DIR/fault-results.jsonl" power-loss "$boundary" pass \
      "$(jq -cn --arg final_state "$state" --arg source_version "$source_version" \
        '{final_state:$final_state,source_version:$source_version,injection_marker_consumed:true,protected_state_matches:true}')"
    shutdown_vm; rm -f "$disk"
  done
}

run_fault_boundary() {
  VM_FAULT_BOUNDARY="$1"
  run_fault_boundary_case
}

run_fault_matrix() {
  local boundaries boundary valid_boundary
  if [[ -n "$VM_FAULT_BOUNDARY" ]]; then
    valid_boundary=false
    for boundary in "${FAULT_BOUNDARIES[@]}"; do
      [[ "$boundary" = "$VM_FAULT_BOUNDARY" ]] && valid_boundary=true
    done
    [[ "$valid_boundary" = true ]] || fail "unknown fault boundary: $VM_FAULT_BOUNDARY"
    boundaries=("$VM_FAULT_BOUNDARY")
  else
    boundaries=("${FAULT_BOUNDARIES[@]}")
  fi
  for boundary in "${boundaries[@]}"; do
    run_vm_phase "fault-$boundary" run_fault_boundary "$boundary"
  done
}

run_storage_profiles() {
  VM_ACTIVE_VERSION=0.7.10
  profile=rd23-ubootmod
  disk="$WORK/storage-$profile.qcow2"
  clone_disk "$WORK/baseline-0.7.10-ubootmod.qcow2" "$disk" qcow2
  start_baseline_vm "$disk" "storage-$profile"
  record_measurement "storage-$profile" "$profile"
  before="$(measure_ubootmod)"
  transaction="$(guest rescue "$ORIGIN" 0.7.10 "$CANDIDATE_APP_VERSION" \
    "$CANDIDATE_RELEASE_TAG" | tail -n 1)"
  normal_reboot
  guest verify-target "$CANDIDATE_APP_VERSION" "$CANDIDATE_PACKAGE_VERSION" \
    0.7.10 post-reboot
  committed="$(measure_ubootmod)"
  guest rollback "$transaction" 0.7.10; normal_reboot
  restored="$(measure_ubootmod)"
  record_result "$EVIDENCE_DIR/storage-results.jsonl" target-layout "$profile" pass \
    "$(jq -cn --argjson before "$before" --argjson committed "$committed" --argjson restored "$restored" \
      '{before:$before,committed:$committed,restored:$restored,transition_and_rollback:true}')"
  shutdown_vm; rm -f "$disk"
}

finalize_evidence() {
  local candidate_source harness_source dual_daemon_passed=false
  candidate_source="$(jq -r .source_commit "$RELEASE_DIR/router-release-manifest.json")"
  harness_source="$HARNESS_SOURCE_SHA"
  [[ -n "$harness_source" ]] || harness_source="$candidate_source"
  jq -s '.' "$EVIDENCE_DIR/vm-measurements.jsonl" > "$EVIDENCE_DIR/vm-measurements.json"
  jq -s '.' "$EVIDENCE_DIR/transition-results.jsonl" > "$EVIDENCE_DIR/transition-results.json"
  jq -s '.' "$EVIDENCE_DIR/fault-results.jsonl" > "$EVIDENCE_DIR/fault-results.json"
  jq -s '.' "$EVIDENCE_DIR/storage-results.jsonl" > "$EVIDENCE_DIR/storage-results.json"
  jq -s '.' "$EVIDENCE_DIR/published-baselines.jsonl" > "$EVIDENCE_DIR/published-baselines.json"
  if jq -s -e 'any(.[]; .kind == "runtime" and .name == "dual-daemon-256m" and
    .status == "pass" and .details.vm_verified == true and
    .details.rd23_hardware_verified == false)' \
    "$EVIDENCE_DIR/transition-results.jsonl" >/dev/null; then
    dual_daemon_passed=true
  fi
  jq -n --argjson configured 256 \
    --argjson stock_backing "$STOCK_WRITABLE_KIB" \
    --argjson stock_ubifs_df "$STOCK_UBIFS_DF_KIB" \
    --argjson ubootmod_backing "$UBOOTMOD_WRITABLE_KIB" \
    --argjson ubootmod_ubifs_df "$UBOOTMOD_UBIFS_DF_KIB" \
    --arg source_commit "$candidate_source" \
    --arg harness_source_sha "$harness_source" \
    --arg diagnostic_case "$DIAGNOSTIC_CASE" \
    --arg diagnostic_run "$DIAGNOSTIC_RUN" \
    --arg vm_only "$VM_ONLY" \
    --arg baseline_pack_digest "$BASELINE_PACK_DIGEST" \
    --arg candidate_app_version "$CANDIDATE_APP_VERSION" \
    --arg candidate_package_version "$CANDIDATE_PACKAGE_VERSION" \
    --arg candidate_release_tag "$CANDIDATE_RELEASE_TAG" \
    --arg successor_app_version "$SUCCESSOR_APP_VERSION" \
    --arg successor_package_version "$SUCCESSOR_PACKAGE_VERSION" \
    --arg successor_release_tag "$SUCCESSOR_RELEASE_TAG" \
    --arg candidate_contract_mode "$CANDIDATE_CONTRACT_MODE" \
    --argjson dual_daemon_vm_verified "$dual_daemon_passed" \
    --argjson recovery_timeout_seconds "$VM_RECOVERY_TIMEOUT_SECONDS" \
    --arg key_fingerprint "$(jq -er .signing_key_fingerprint "$RELEASE_DIR/router-release-manifest.json")" \
    '{schema_version:1,candidate_source_sha:$source_commit,production_public_key_fingerprint:$key_fingerprint,
      harness_source_sha:$harness_source_sha,diagnostic_case:$diagnostic_case,
      baseline_pack_digest:$baseline_pack_digest,
      diagnostic:($diagnostic_run == "1" or $vm_only == "1"),
      release_evidence:($diagnostic_run != "1" and $vm_only != "1"),
      vm_only:($vm_only == "1"),
      candidate:{app_version:$candidate_app_version,package_version:$candidate_package_version,
        release_tag:$candidate_release_tag},
      successor:{app_version:$successor_app_version,package_version:$successor_package_version,
        release_tag:$successor_release_tag},
      candidate_contract_mode:$candidate_contract_mode,
      configured_ram_mib:$configured,vm_execution_mode:"strictly-serial-exact-child-pid",
      dual_daemon_vm_verified:$dual_daemon_vm_verified,
      dual_daemon_scope:"real-unenrolled-tailscaled-plus-local-only-xray",
      recovery_timeout_seconds:$recovery_timeout_seconds,
      storage_profiles:{"rd23-stock":{writable_backing_kib:$stock_backing,
        expected_ubifs_df_total_kib:$stock_ubifs_df},
        "rd23-ubootmod":{writable_backing_kib:$ubootmod_backing,
        expected_ubifs_df_total_kib:$ubootmod_ubifs_df}},
      storage_basis:(if $vm_only == "1" then
        "locked-RD23-storage-profile-applied-to-x86-QEMU-only"
        else "OpenWrt-v24.10.5-DTS-plus-exact-candidate-payload" end),
      physical_rd23_test:"pending-not-authorized",hardware_verified:false}' \
    > "$EVIDENCE_DIR/summary.json"
  (cd "$EVIDENCE_DIR" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print | sort | sed 's#^./##' |
    while read -r file; do sha256sum "$file"; done > SHA256SUMS)
}

finalize_baseline_evidence() {
  jq -s '.' "$EVIDENCE_DIR/vm-measurements.jsonl" > "$EVIDENCE_DIR/vm-measurements.json"
  jq -s '.' "$EVIDENCE_DIR/published-baselines.jsonl" > "$EVIDENCE_DIR/published-baselines.json"
  jq -s '.' "$EVIDENCE_DIR/baseline-validation-results.jsonl" > "$EVIDENCE_DIR/baseline-validation-results.json"
  jq -n --arg builder_commit "$HARNESS_SOURCE_SHA" --arg selector "$BASELINE_SELECTOR" \
    --arg baseline_contract_digest "$BASELINE_CONTRACT_DIGEST" \
    --arg manifest_sha256 "$(sha256sum "$BASELINE_OUTPUT_DIR/baseline-pack-manifest.json" | awk '{print $1}')" \
    --argjson configured_ram_mib 256 \
      '{schema_version:1,diagnostic:true,release_evidence:false,kind:"legacy-baseline-pack",
      builder_commit:$builder_commit,baseline_contract_digest:$baseline_contract_digest,
      selector:$selector,configured_ram_mib:$configured_ram_mib,
      vm_execution_mode:"strictly-serial-exact-child-pid",
      baseline_pack_manifest_sha256:$manifest_sha256,verified:true}' > "$EVIDENCE_DIR/summary.json"
  (cd "$EVIDENCE_DIR" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print |
    LC_ALL=C sort | sed 's#^./##' |
    while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS)
}

run_storage_case() {
  case "$VM_PHASE_SELECTOR" in
    all)
      run_vm_phase storage-normal run_storage_pressure normal
      run_vm_phase storage-near-reservation run_storage_pressure near-reservation
      run_vm_phase storage-below-reservation run_storage_pressure below-reservation
      run_vm_phase storage-rd23-ubootmod run_storage_profiles
      ;;
    normal|near-reservation|below-reservation)
      run_vm_phase "storage-$VM_PHASE_SELECTOR" run_storage_pressure "$VM_PHASE_SELECTOR"
      ;;
    rd23-ubootmod)
      run_vm_phase storage-rd23-ubootmod run_storage_profiles
      ;;
    *) fail "unsupported storage phase selector: $VM_PHASE_SELECTOR" ;;
  esac
}

run_candidate_cases() {
  case "$VM_CASE" in
    old-worker) run_old_worker_matrix ;;
    rescue)
      if [[ "$VM_PHASE_SELECTOR" = refusals ]]; then
        run_vm_phase rescue-refusals run_refusals
      else
        run_rescue_matrix
      fi
      ;;
    protocol-v2) run_vm_phase protocol-v2 run_protocol_v2 ;;
    clean-image) run_vm_phase clean-image run_clean_image ;;
    dual-daemon) run_vm_phase dual-daemon run_dual_daemon ;;
    concurrency) run_vm_phase concurrency run_concurrency ;;
    storage) run_storage_case ;;
    fault) run_fault_matrix ;;
    full)
      run_old_worker_matrix
      run_rescue_matrix
      run_vm_phase rescue-refusals run_refusals
      run_vm_phase clean-image run_clean_image
      run_vm_phase dual-daemon run_dual_daemon
      run_vm_phase protocol-v2 run_protocol_v2
      run_vm_phase concurrency run_concurrency
      run_fault_matrix
      run_storage_case
      ;;
    *) fail "case is not valid in candidate mode: $VM_CASE" ;;
  esac
}

if [[ "$VM_MODE" = candidate ]]; then
  run_vm_phase load-release-contracts load_release_contracts
fi
run_vm_phase setup-tls setup_tls
run_vm_phase prepare-server prepare_server
run_vm_phase load-storage-contract load_storage_profiles
if [[ "$VM_MODE" = baseline-pack ]]; then
  run_vm_phase build-openwrt-bases build_vm_base
  prepare_baseline_pack
  run_vm_phase finalize-baseline-evidence finalize_baseline_evidence
  printf 'Verified legacy baseline pack built (%s): %s\n' "$BASELINE_SELECTOR" "$BASELINE_OUTPUT_DIR"
else
  run_vm_phase verify-baseline-pack verify_baseline_pack
  case "$VM_CASE" in
    full|protocol-v2|clean-image|dual-daemon|concurrency|fault)
      run_vm_phase extract-candidate-image extract_candidate_image
      ;;
  esac
  run_candidate_cases
  run_vm_phase finalize-candidate-evidence finalize_evidence
  printf 'Constrained Router UI VM gate passed (%s); evidence: %s\n' "$VM_CASE" "$EVIDENCE_DIR"
fi
