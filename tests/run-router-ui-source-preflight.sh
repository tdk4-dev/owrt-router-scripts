#!/bin/sh
set -u
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
EXPECTED_SOURCE_SHA="${EXPECTED_SOURCE_SHA:?EXPECTED_SOURCE_SHA is required}"
ACTUAL_SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
ACTUAL_SOURCE_TREE="$(git -C "$ROOT_DIR" rev-parse 'HEAD^{tree}')"
EXPECTED_SOURCE_TREE="${EXPECTED_SOURCE_TREE:-$ACTUAL_SOURCE_TREE}"
REPORT_PATH="${TIER0_REPORT_PATH:-${TMPDIR:-/tmp}/router-ui-tier0-$ACTUAL_SOURCE_SHA.json}"
RAW_EVIDENCE_DIR="${TIER0_RAW_EVIDENCE_DIR:-}"
TIER0_PARENT="${TIER0_TEMP_ROOT:-${TMPDIR:-/tmp}}"
WORK_ROOT="$(mktemp -d "$TIER0_PARENT/router-ui-tier0.XXXXXX")"
CONTROLLED_TMP="$WORK_ROOT/tmp"
RESULTS="$WORK_ROOT/results.ndjson"
GUARD_LOG="$WORK_ROOT/guard.log"
GUARD_BIN="$WORK_ROOT/guard-bin"
ARTIFACTS_BEFORE="$WORK_ROOT/artifacts.before"
ARTIFACTS_AFTER="$WORK_ROOT/artifacts.after"
SUITE_OK=true
GUARDED_ENTRYPOINT_COUNT=25
: > "$RESULTS"
: > "$GUARD_LOG"
mkdir -p "$GUARD_BIN" "$CONTROLLED_TMP" "$(dirname "$REPORT_PATH")"
TMPDIR="$CONTROLLED_TMP"
export TMPDIR

cleanup() { rm -rf "$WORK_ROOT"; }
trap cleanup EXIT INT TERM

[ "$ACTUAL_SOURCE_SHA" = "$EXPECTED_SOURCE_SHA" ] || {
  printf 'ERROR: Tier 0 source mismatch: expected %s, checked out %s\n' \
    "$EXPECTED_SOURCE_SHA" "$ACTUAL_SOURCE_SHA" >&2
  exit 1
}
[ "$ACTUAL_SOURCE_TREE" = "$EXPECTED_SOURCE_TREE" ] || {
  printf 'ERROR: Tier 0 tree mismatch: expected %s, checked out %s\n' \
    "$EXPECTED_SOURCE_TREE" "$ACTUAL_SOURCE_TREE" >&2
  exit 1
}
[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ] || {
  printf 'ERROR: exact-SHA Tier 0 requires a clean checkout\n' >&2
  exit 1
}

cat > "$GUARD_BIN/router-ui-forbidden-command" <<'EOF'
#!/bin/sh
set -eu
name="${0##*/}"
case "$name" in
  cmake|make|ninja|gcc|g++|clang|clang++|cc|c++|meson|cargo|rustc|go)
    category=compiler ;;
  usign|gpg|minisign)
    category=signing ;;
  opkg|opkg-build|mksquashfs|mkfs.ext4|mkfs.ubifs|ubinize|mkimage|docker|podman)
    category=product-build ;;
  qemu-system-*|qemu-img|VBoxManage)
    category=vm-execution ;;
  *) category=forbidden-command ;;
esac
printf '%s:%s\n' "$category" "$name" >> "${ROUTER_UI_TIER0_GUARD_LOG:?}"
exit 97
EOF
chmod 755 "$GUARD_BIN/router-ui-forbidden-command"
for command in cmake make ninja gcc g++ clang clang++ cc c++ meson cargo rustc go \
  usign gpg minisign opkg opkg-build mksquashfs mkfs.ext4 mkfs.ubifs ubinize mkimage \
  docker podman qemu-system-x86_64 qemu-system-aarch64 qemu-img VBoxManage
do
  ln -s router-ui-forbidden-command "$GUARD_BIN/$command"
done
PATH="$GUARD_BIN:$PATH"
ROUTER_UI_TIER0_GUARD_LOG="$GUARD_LOG"
export PATH ROUTER_UI_TIER0_GUARD_LOG

artifact_inventory() {
  for inventory_root in "$ROOT_DIR" "$CONTROLLED_TMP"; do
    find "$inventory_root" -path "$ROOT_DIR/.git" -prune -o -type f \( \
      -name '*.ipk' -o -name '*.img' -o -name '*.img.gz' -o -name '*.bin' \
      -o -name '*.trx' -o -name '*.ubi' -o -name '*.itb' -o -name '*.iso' \
      -o -name '*.o' -o -name '*.a' -o -name '*.so' -o -name '*.pyc' -o -name '*.pdf' \
      -o -name '*.tar.gz' -o -name '*.sig' -o -name 'Packages' \
      -o -name 'Packages.gz' -o -name 'SHA256SUMS' \
      -o -name 'router-release-manifest.json' -o -name 'installed-manifest.json' \
    \) -print |
    LC_ALL=C sort | while IFS= read -r file; do
      printf '%s  %s\n' "$(sha256sum "$file" | awk '{print $1}')" "$file"
    done
  done | LC_ALL=C sort
}

record_result() {
  name="$1" status="$2" code="$3" duration="$4"
  jq -nc --arg name "$name" --arg status "$status" \
    --argjson exit_code "$code" --argjson duration_seconds "$duration" \
    '{name:$name,status:$status,exit_code:$exit_code,duration_seconds:$duration_seconds}' \
    >> "$RESULTS"
}

run_test() {
  name="$1"
  shift
  printf 'Tier 0: %s\n' "$name"
  started="$(date +%s)"
  if "$@"; then
    code=0
    status=passed
  else
    code=$?
    status=failed
    SUITE_OK=false
  fi
  finished="$(date +%s)"
  record_result "$name" "$status" "$code" "$((finished - started))"
  [ "$code" -eq 0 ]
}

write_report() {
  artifact_new="$1"
  product_count="$(grep -Ec '^(product-build|package-integration-test|canonical-release-test):' "$GUARD_LOG" 2>/dev/null || true)"
  image_count="$(grep -Ec '^image-build:' "$GUARD_LOG" 2>/dev/null || true)"
  compiler_count="$(grep -Ec '^compiler:' "$GUARD_LOG" 2>/dev/null || true)"
  signing_count="$(grep -Ec '^(signing|staging):' "$GUARD_LOG" 2>/dev/null || true)"
  publication_count="$(grep -Ec '^publisher:' "$GUARD_LOG" 2>/dev/null || true)"
  tool_install_count="$(grep -Ec '^tool-install:' "$GUARD_LOG" 2>/dev/null || true)"
  vm_count="$(grep -Ec '^vm-execution:' "$GUARD_LOG" 2>/dev/null || true)"
  guard_count="$(awk 'NF { count++ } END { print count + 0 }' "$GUARD_LOG")"
  jq -s \
    --argjson ok "$SUITE_OK" \
    --arg source_sha "$ACTUAL_SOURCE_SHA" \
    --arg source_tree "$ACTUAL_SOURCE_TREE" \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson product_build_invocations "$product_count" \
    --argjson image_build_invocations "$image_count" \
    --argjson compiler_invocations "$compiler_count" \
    --argjson signing_or_staging_invocations "$signing_count" \
    --argjson release_publication_invocations "$publication_count" \
    --argjson tool_install_invocations "$tool_install_count" \
    --argjson vm_execution_invocations "$vm_count" \
    --argjson guarded_entrypoint_count "$GUARDED_ENTRYPOINT_COUNT" \
    --arg controlled_tmp "$CONTROLLED_TMP" \
    --arg package_root "$ROOT_DIR/.package-build" \
    --arg output_root "$ROOT_DIR/output" \
    --arg repo_tmp_root "$ROOT_DIR/tmp" \
    --argjson forbidden_invocations "$guard_count" \
    --argjson package_image_release_artifacts_generated "$artifact_new" \
    '{schema_version:2,kind:"router-ui-tier0-source-preflight",ok:$ok,
      source_sha:$source_sha,source_tree:$source_tree,generated_at:$generated_at,
      product_build_invocations:$product_build_invocations,
      image_build_invocations:$image_build_invocations,
      compiler_invocations:$compiler_invocations,
      signing_or_staging_invocations:$signing_or_staging_invocations,
      release_publication_invocations:$release_publication_invocations,
      tool_install_invocations:$tool_install_invocations,
      vm_execution_invocations:$vm_execution_invocations,
      forbidden_invocations:$forbidden_invocations,
      guarded_entrypoint_count:$guarded_entrypoint_count,
      declared_temporary_and_output_roots:[$controlled_tmp,$package_root,$output_root,$repo_tmp_root],
      package_image_release_artifacts_generated:$package_image_release_artifacts_generated,
      tests:.}' "$RESULTS" > "$REPORT_PATH.new"
  mv "$REPORT_PATH.new" "$REPORT_PATH"
}

finish() {
  requested_exit="$1"
  artifact_inventory > "$ARTIFACTS_AFTER"
  artifact_new="$(comm -13 "$ARTIFACTS_BEFORE" "$ARTIFACTS_AFTER" | awk 'NF { count++ } END { print count + 0 }')"
  [ ! -s "$GUARD_LOG" ] || SUITE_OK=false
  [ "$artifact_new" -eq 0 ] || SUITE_OK=false
  write_report "$artifact_new"
  if [ -n "$RAW_EVIDENCE_DIR" ]; then
    case "$RAW_EVIDENCE_DIR" in
      /*) ;;
      *) printf 'TIER0_RAW_EVIDENCE_DIR must be absolute\n' >&2; exit 1 ;;
    esac
    case "$RAW_EVIDENCE_DIR" in
      "$ROOT_DIR"|"$ROOT_DIR"/*|"$CONTROLLED_TMP"|"$CONTROLLED_TMP"/*)
        printf 'TIER0_RAW_EVIDENCE_DIR must be outside inventoried roots\n' >&2
        exit 1 ;;
    esac
    mkdir -p "$RAW_EVIDENCE_DIR"
    cp "$GUARD_LOG" "$RAW_EVIDENCE_DIR/guard.log"
    cp "$ARTIFACTS_BEFORE" "$RAW_EVIDENCE_DIR/artifacts.before"
    cp "$ARTIFACTS_AFTER" "$RAW_EVIDENCE_DIR/artifacts.after"
    cp "$RESULTS" "$RAW_EVIDENCE_DIR/results.ndjson"
    cp "$REPORT_PATH" "$RAW_EVIDENCE_DIR/report.json"
  fi
  if [ "$SUITE_OK" != true ] || [ "$requested_exit" -ne 0 ]; then
    [ ! -s "$GUARD_LOG" ] || { printf 'Forbidden Tier 0 invocation(s):\n' >&2; cat "$GUARD_LOG" >&2; }
    [ "$artifact_new" -eq 0 ] || printf 'Tier 0 generated %s forbidden artifact(s)\n' "$artifact_new" >&2
    printf 'Tier 0 source preflight failed; report: %s\n' "$REPORT_PATH" >&2
    exit 1
  fi
  printf 'Router UI Tier 0 source preflight passed: %s tree %s\n' \
    "$ACTUAL_SOURCE_SHA" "$ACTUAL_SOURCE_TREE"
  printf 'Machine-readable result: %s\n' "$REPORT_PATH"
  exit 0
}

artifact_inventory > "$ARTIFACTS_BEFORE"
cd "$ROOT_DIR"

run_test shell-syntax sh -c '
  root="$1"
  git -C "$root" ls-files "*.sh" | while IFS= read -r file; do
    first="$(sed -n "1p" "$root/$file")"
    case "$first" in *bash*) bash -n "$root/$file" ;; *) sh -n "$root/$file" ;; esac
  done
' sh "$ROOT_DIR" || finish 1
run_test javascript-syntax sh -c '
  root="$1"
  git -C "$root" ls-files "*.js" "*.mjs" | while IFS= read -r file; do
    node --check "$root/$file" >/dev/null
  done
' sh "$ROOT_DIR" || finish 1
run_test python-syntax python3 -c '
import ast, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
for relative in subprocess.check_output(["git", "-C", str(root), "ls-files", "*.py"], text=True).splitlines():
    ast.parse((root / relative).read_text(encoding="utf-8"), filename=relative)
' "$ROOT_DIR" || finish 1
run_test json-syntax sh -c '
  root="$1"
  git -C "$root" ls-files "*.json" | while IFS= read -r file; do jq empty "$root/$file"; done
' sh "$ROOT_DIR" || finish 1
run_test git-diff-check sh -c 'git diff --check 18562f49bcac914acf3b07749f5b8863d8016e00 HEAD' || finish 1
run_test scope-ledger sh -c '
  out="$1/scope-ledger.json"
  root="$2"
  node "$root/scripts/generate-router-ui-rc9-scope-ledger.mjs" --output "$out" >/dev/null
  cmp -s "$out" "$root/docs/evidence/router-ui-0.7.11-rc9-scope-ledger.json"
' sh "$WORK_ROOT" "$ROOT_DIR" || finish 1

run_test tier0-zero-build-contracts sh tests/test-tier0-zero-build-contracts.sh || finish 1
run_test tier0-renderer-guard python3 tests/test-tier0-renderer-guard.py || finish 1
run_test control-census node tests/test-router-ui-control-census.mjs || finish 1
run_test runtime-ownership-census node tests/test-router-ui-runtime-ownership.mjs || finish 1
run_test seven-state-rendering node tests/test-router-ui-state-rendering.mjs || finish 1
run_test update-operation-ui node tests/test-update-operation-ui.mjs || finish 1
run_test tailscale-ping-ui node tests/test-tailscale-ping-ui.mjs || finish 1
run_test tailscale-convergence-ui node tests/test-tailscale-convergence-ui.mjs || finish 1
run_test adopted-luci-rpc-rollback node tests/test-vpn-luci-adopted-apply.mjs || finish 1
run_test adopted-source-contracts node tests/test-xray-adopted-source-contracts.mjs || finish 1
run_test xray-service-toggle sh tests/test-xray-service-toggle.sh || finish 1
run_test xray-native-apply sh tests/test-xray-native-apply.sh || finish 1
run_test xray-transparent-init sh tests/test-xray-transparent-init.sh || finish 1
run_test xray-mutation-callpaths sh tests/test-xray-mutation-callpaths.sh || finish 1
run_test security-acl-boundaries sh tests/test-security-boundaries-0.7.11.sh || finish 1
run_test async-success-contracts sh tests/test-async-success-contracts.sh || finish 1
run_test updater-identity-contracts sh tests/test-vpn-hotfixes.sh || finish 1
run_test updater-source-transactions sh tests/test-updater-source-contracts.sh || finish 1
run_test updater-worker-locking sh tests/test-updater-worker-start.sh || finish 1
run_test updater-operation-jobs sh tests/test-updater-operation-jobs.sh || finish 1
run_test tailscale-registration sh tests/test-tailscale-registration.sh || finish 1
run_test tailscale-convergence sh tests/test-tailscale-convergence.sh || finish 1
run_test tailscale-stopped-status sh tests/test-tailscale-stopped-status.sh || finish 1
run_test firstboot-optional-services sh tests/test-firstboot-optional-services.sh || finish 1
run_test router-metadata sh tests/test-router-metadata.sh || finish 1
run_test package-source-contracts sh tests/test-package-source-contracts.sh || finish 1
run_test rd23-package-boundary sh tests/test-rd23-profile.sh || finish 1
run_test version-variable-boundary sh tests/test-version-variable-names.sh || finish 1
run_test stable-luci-assets sh tests/test-luci-stable-assets.sh || finish 1
run_test rescue-support-matrix sh tests/test-rescue-support-matrix.sh || finish 1
run_test workflow-dependencies node tests/test-phase1-workflow-dependencies.mjs || finish 1
run_test collateral-contracts python3 tests/test-router-ui-collateral.py || finish 1
run_test vm-methodology-contracts sh tests/test-vm-architecture.sh || finish 1
run_test tracked-secret-scan sh tests/test-source-secret-boundaries.sh || finish 1

finish 0
