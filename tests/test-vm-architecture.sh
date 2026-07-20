#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CI="$ROOT_DIR/.github/workflows/ci.yml"
DIAGNOSTIC="$ROOT_DIR/.github/workflows/diagnose-router-ui-vm.yml"
BASELINES="$ROOT_DIR/.github/workflows/build-router-ui-legacy-baselines.yml"
CANDIDATE="$ROOT_DIR/.github/workflows/validate-router-ui-candidate.yml"
RELEASE="$ROOT_DIR/.github/workflows/release-vpn-panel.yml"
GATE="$ROOT_DIR/tests/vm/router-ui-vm-gate.sh"
RUNNER="$ROOT_DIR/tests/vm/fail-closed-runner.sh"
ARTIFACT_HELPER="$ROOT_DIR/tests/vm/download-immutable-actions-artifact.sh"
DIGEST="$ROOT_DIR/tests/vm/baseline-contract-digest.sh"
CONTENT_DESCRIPTOR="$ROOT_DIR/tests/vm/write-candidate-content-descriptor.sh"
LOCK="$ROOT_DIR/tests/vm/legacy-baseline-lock.json"
FIXTURE="$ROOT_DIR/tests/vm/fixtures/legacy-nonsecret"

fail() { printf 'VM-ARCHITECTURE-TEST: %s\n' "$*" >&2; exit 1; }

grep -q '^  push:' "$CI" || fail 'ordinary push CI is missing'
! grep -q 'production-candidate' "$CI" || fail 'push CI still invokes the protected candidate'
grep -q '^  workflow_dispatch:' "$DIAGNOSTIC" || fail 'diagnostic workflow is not manual'
! grep -q '^  push:' "$DIAGNOSTIC" || fail 'diagnostic workflow is still push-triggered'
grep -q '^  workflow_dispatch:' "$BASELINES" || fail 'baseline workflow is not manual'
! grep -q '^  push:' "$BASELINES" || fail 'baseline workflow is push-triggered'
grep -q '^  workflow_dispatch:' "$CANDIDATE" || fail 'protected candidate is not manually dispatched'
! grep -q '^  workflow_call:' "$CANDIDATE" || fail 'protected candidate can still be invoked automatically'
for workflow in "$CANDIDATE" "$RELEASE"; do
  for input in baseline_pack_artifact_id baseline_pack_artifact_zip_sha256; do
    grep -q "^      $input:" "$workflow" || fail "release gate lacks baseline identity input: $workflow $input"
  done
  for derived in baseline_pack_run_id baseline_pack_artifact_name baseline_pack_manifest_sha256; do
    ! grep -q "^      $derived:" "$workflow" || fail "release gate still asks operators for derived baseline identity: $workflow $derived"
  done
done
for input in candidate_artifact_id candidate_artifact_zip_sha256; do
  grep -q "^      $input:" "$RELEASE" || fail "tagged workflow lacks pre-tag candidate identity: $input"
done

for input in candidate_artifact_id candidate_artifact_zip_sha256 \
  baseline_pack_artifact_id baseline_pack_artifact_zip_sha256 \
  case source_version phase fault_boundary; do
  grep -q "^      $input:" "$DIAGNOSTIC" || fail "diagnostic input missing: $input"
done
for derived in harness_sha candidate_run_id candidate_run_number candidate_artifact_name \
  candidate_source_sha candidate_manifest_sha256 candidate_sha256sums_sha256 \
  synthetic_manifest_sha256 synthetic_sha256sums_sha256 baseline_pack_run_id \
  baseline_pack_artifact_name baseline_pack_manifest_sha256; do
  ! grep -q "^      $derived:" "$DIAGNOSTIC" || fail "diagnostic still asks operators for derived identity: $derived"
done
! grep -q '^      harness_sha:' "$BASELINES" || fail 'baseline builder still asks for a redundant harness SHA'
grep -q "timeout-minutes: \${{ inputs.case == 'full' && 360 || 90 }}" "$DIAGNOSTIC" ||
  fail 'targeted diagnostics retain the full-matrix hang window'
grep -q "timeout-minutes: \${{ inputs.selector == 'all' && 360 || 90 }}" "$BASELINES" ||
  fail 'single baseline validation retains the complete-pack hang window'
for workflow in "$DIAGNOSTIC" "$CANDIDATE" "$RELEASE"; do
  grep -q 'download-immutable-actions-artifact.sh' "$workflow" ||
    fail "workflow does not derive immutable artifact descriptors: $workflow"
done
[ -s "$ARTIFACT_HELPER" ] || fail 'immutable artifact descriptor verifier is missing'
[ -x "$ARTIFACT_HELPER" ] || fail 'immutable artifact descriptor verifier is not executable'
for workflow in "$CANDIDATE" "$RELEASE"; do
  grep -q 'write-candidate-content-descriptor.sh' "$workflow" ||
    fail "workflow does not persist a candidate content descriptor: $workflow"
done
[ -s "$CONTENT_DESCRIPTOR" ] || fail 'candidate content descriptor generator is missing'
[ -x "$CONTENT_DESCRIPTOR" ] || fail 'candidate content descriptor generator is not executable'

for selector in old-worker rescue protocol-v2 clean-image concurrency storage fault full; do
  grep -q "$selector" "$GATE" || fail "harness selector missing: $selector"
done
! grep -Eq 'pgrep|pkill|killall|ps[[:space:]].*qemu|semaphore|third-VM' "$GATE" ||
  fail 'harness scans or coordinates unrelated QEMU processes'
grep -q -- '-m 256' "$GATE" || fail 'guest RAM is not exactly 256 MiB'
grep -q 'CURRENT_PID=\$!' "$GATE" || fail 'harness does not track its exact QEMU child PID'
grep -q 'wait "\$CURRENT_PID"' "$GATE" || fail 'harness does not wait for its exact QEMU child PID'
grep -q 'ROUTER_UI_VM_PHASE_TIMEOUT_SECONDS' "$RUNNER" || fail 'phase runner has no enforced deadline'
grep -q 'raise SystemExit(124)' "$RUNNER" || fail 'phase timeout does not preserve exit 124'
grep -q 'qemu-timeout.json' "$RUNNER" || fail 'phase timeout does not preserve exact QEMU evidence'
grep -q 'run_vm_phase "baseline-validation-\$version"' "$GATE" ||
  fail 'legacy baselines do not have independent phase deadlines'
grep -q 'run_vm_phase "fault-\$boundary"' "$GATE" ||
  fail 'fault boundaries do not have independent phase deadlines'

for input in tests/vm/legacy-baseline-lock.json tests/vm/router-ui-vm-gate.sh \
  tests/vm/router-ui-vm-guest.sh tests/vm/fail-closed-runner.sh \
  image/openwrt-fin0-packages.txt release/rd23-storage-geometry.json \
  scripts/patch-openwrt-x86-writable-extent.sh; do
  grep -q "emit $input" "$DIGEST" || fail "baseline content digest omits $input"
done
! grep -Eq 'git|HEAD|rev-parse' "$DIGEST" || fail 'baseline content digest is tied to commit identity'
contract_digest="$(sh "$DIGEST")"
printf '%s' "$contract_digest" | grep -Eq '^[0-9a-f]{64}$' || fail 'baseline content digest is malformed'
grep -q 'baseline_contract_digest' "$GATE" || fail 'baseline manifest omits content compatibility digest'
grep -q 'builder_commit' "$GATE" || fail 'baseline builder commit provenance is missing'
grep -q 'xray-ipk/xray' "$GATE" || fail 'expected Xray binary hash is not derived from the locked IPK'
grep -q 'installed Xray binary differs from the exact locked IPK' "$ROOT_DIR/tests/vm/router-ui-vm-guest.sh" ||
  fail 'guest does not enforce the derived Xray binary hash'

jq -e '.schema_version == 1 and (.baselines | length) == 13 and
  .openwrt.version == "24.10.5" and
  .openwrt.imagebuilder_sha256 == "78ce7cda0409e4afad9226c3018c8827264790ae198118dfc735339d8211fc61" and
  .xray.version == "25.1.30-r1" and
  .xray.package_sha256 == "fb7a8aef5e4d61f2ef6bb37e5506e3bde4a2f342ad1ba707bd68203bf6317d2d" and
  .storage_profiles["rd23-stock"].writable_backing_kib == 54436 and
  .storage_profiles["rd23-ubootmod"].writable_backing_kib == 80352 and
  all(.baselines[]; (.release_sha256 | test("^[0-9a-f]{64}$")) and
    (.worker_sha256 | test("^[0-9a-f]{64}$")) and
    (.validator_sha256 | test("^[0-9a-f]{64}$")))' "$LOCK" >/dev/null ||
  fail 'legacy baseline input lock is incomplete'

fixture_sha="$(cd "$FIXTURE" && find . -type f -print0 | LC_ALL=C sort -z |
  xargs -0 sha256sum | sha256sum | awk '{print $1}')"
[ "$fixture_sha" = "$(jq -r .fixture.tree_sha256 "$LOCK")" ] ||
  fail 'deterministic fixture tree hash drifted'

tmp="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-runner-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM
set +e
EVIDENCE_DIR="$tmp/evidence" CANDIDATE_SOURCE_SHA=373d88c3636340d1610187992ec256ecdf65e123 \
HARNESS_SOURCE_SHA=8980901fde2cbd02ce8816d20d06f0e125377cbe \
BASELINE_PACK_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
VM_CASE=rescue VM_SOURCE_VERSION=0.7.0 VM_PHASE_SELECTOR=transition \
bash -c 'set -Eeuo pipefail; source "$1"; mkdir -p "$EVIDENCE_DIR"; run_vm_phase validator sh -c "exit 37"' \
  router-ui-runner-test "$RUNNER"
runner_rc=$?
set -e
[ "$runner_rc" -eq 37 ] || fail "phase runner changed exit 37 to $runner_rc"
jq -e '.candidate_sha == "373d88c3636340d1610187992ec256ecdf65e123" and
  .harness_sha == "8980901fde2cbd02ce8816d20d06f0e125377cbe" and
  .baseline_pack_digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  .case == "rescue" and .version == "0.7.0" and .phase == "validator" and
  .command == "sh -c exit\\ 37" and .exit_code == 37 and
  .candidate_mutation_began == false' "$tmp/evidence/failure.json" >/dev/null ||
  fail 'failure.json did not preserve the exact failed command contract'

EVIDENCE_DIR="$tmp/state-evidence" \
bash -c '
  set -Eeuo pipefail
  source "$1"
  mkdir -p "$EVIDENCE_DIR"
  STOCK_WRITABLE_KIB=0
  persist_phase_state() { STOCK_WRITABLE_KIB=54436; }
  run_vm_phase state-handoff persist_phase_state
  test "$STOCK_WRITABLE_KIB" = 54436
' router-ui-state-test "$RUNNER" || fail 'deadline-owned phase did not return explicit runtime state'

set +e
EVIDENCE_DIR="$tmp/timeout-evidence" ROUTER_UI_VM_PHASE_TIMEOUT_SECONDS=1 \
CANDIDATE_SOURCE_SHA=373d88c3636340d1610187992ec256ecdf65e123 \
HARNESS_SOURCE_SHA=8980901fde2cbd02ce8816d20d06f0e125377cbe \
BASELINE_PACK_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
VM_CASE=baseline-validation VM_SOURCE_VERSION=0.7.0 \
bash -c '
  set -Eeuo pipefail
  timeout_probe() {
    sleep 30 &
    CURRENT_PID=$!
    printf "%s\\n" "$CURRENT_PID" > "$EVIDENCE_DIR/current-qemu.pid"
    printf "%s\\n" "$CURRENT_PID" > "$EVIDENCE_DIR/test-child.pid"
    wait "$CURRENT_PID"
  }
  source "$1"
  mkdir -p "$EVIDENCE_DIR"
  run_vm_phase timeout-probe timeout_probe
' router-ui-timeout-test "$RUNNER"
timeout_rc=$?
set -e
[ "$timeout_rc" -eq 124 ] || fail "phase timeout returned $timeout_rc instead of 124"
timeout_child="$(sed -n '1p' "$tmp/timeout-evidence/test-child.pid")"
! kill -0 "$timeout_child" 2>/dev/null || fail 'timed-out owned child survived cleanup'
jq -e '.exit_code == 124 and .timed_out == true and .timeout_seconds == 1 and
  .phase == "timeout-probe" and .command == "timeout_probe"' \
  "$tmp/timeout-evidence/failure.json" >/dev/null ||
  fail 'timeout failure.json is incomplete'
jq -e --argjson pid "$timeout_child" '.phase == "timeout-probe" and
  .qemu_pid == $pid and .alive_before_timeout_cleanup == true' \
  "$tmp/timeout-evidence/qemu-timeout.json" >/dev/null ||
  fail 'timeout did not preserve exact owned QEMU PID evidence'

printf 'VM architecture contract tests passed.\n'
