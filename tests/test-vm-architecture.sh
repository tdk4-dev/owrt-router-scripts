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
AGGREGATOR="$ROOT_DIR/tests/vm/aggregate-candidate-evidence.sh"
PREIMAGE_RESCUE="$ROOT_DIR/tests/vm/run-preimage-rescue-smoke.sh"
LOCK="$ROOT_DIR/tests/vm/legacy-baseline-lock.json"
LEGACY_CANDIDATES="$ROOT_DIR/tests/vm/legacy-diagnostic-candidates.json"
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
for workflow in "$BASELINES" "$DIAGNOSTIC" "$CANDIDATE" "$RELEASE"; do
  grep -q 'group: router-ui-project-vm-global' "$workflow" ||
    fail "VM workflow does not share the no-overlap concurrency group: $workflow"
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
grep -q 'vm_work_root="$RUNNER_TEMP/baseline-pack-work"' "$DIAGNOSTIC" ||
  fail 'diagnostic baseline consumer does not preserve the relocatable overlay layout'
grep -q 'export TMPDIR="$vm_work_root/overlays"' "$DIAGNOSTIC" ||
  fail 'diagnostic VM work directory is not rooted beside the baseline bases directory'
for workflow in "$CANDIDATE" "$RELEASE"; do
  grep -q 'local vm_work_root="$RUNNER_TEMP/vm-work-$label"' "$workflow" ||
    fail "sharded baseline consumer does not preserve a per-case relocatable layout: $workflow"
  grep -q 'TMPDIR="$vm_work_root/overlays"' "$workflow" ||
    fail "sharded VM work directory is not rooted beside the baseline bases directory: $workflow"
done
[ -s "$ARTIFACT_HELPER" ] || fail 'immutable artifact descriptor verifier is missing'
[ -x "$ARTIFACT_HELPER" ] || fail 'immutable artifact descriptor verifier is not executable'
grep -q 'ROUTER_UI_ALLOW_LEGACY_DIAGNOSTIC_CANDIDATE: "1"' "$DIAGNOSTIC" ||
  fail 'diagnostic workflow cannot consume the exact locked legacy candidate'
grep -q 'ROUTER_UI_ALLOW_FAILED_PROTECTED_CANDIDATE: "1"' "$DIAGNOSTIC" ||
  fail 'diagnostic workflow cannot consume failed protected candidate bytes'
for workflow in "$CANDIDATE" "$RELEASE"; do
  ! grep -q 'ROUTER_UI_ALLOW_LEGACY_DIAGNOSTIC_CANDIDATE' "$workflow" ||
    fail "release-authorizing workflow enables legacy diagnostic provenance: $workflow"
done
grep -q 'locked-legacy-diagnostic-candidate' "$ARTIFACT_HELPER" ||
  fail 'immutable artifact helper does not label legacy candidate provenance'
grep -q 'release_evidence_eligible=false' "$ARTIFACT_HELPER" ||
  fail 'legacy candidate is not explicitly ineligible as release evidence'
grep -q 'failed-protected-diagnostic-candidate' "$ARTIFACT_HELPER" ||
  fail 'failed protected candidates are not explicitly diagnostic-only'
grep -q 'candidate_scope=transition-only' "$ARTIFACT_HELPER" ||
  fail 'transition-only failed candidates are not scoped fail closed'
grep -q '^  rescue-0-7-0:' "$CANDIDATE" ||
  fail 'protected candidate lacks the earliest rescue-0.7.0 gate'
grep -Fq 'needs: [canonical-ipks, sign-installed-package-set, rescue-0-7-0]' "$CANDIDATE" ||
  fail 'image builds do not wait for rescue-0.7.0'
grep -q 'pretag-router-ui-transition-candidate-' "$CANDIDATE" ||
  fail 'protected workflow does not preserve reusable signed transition bytes'
for workflow in "$CANDIDATE" "$DIAGNOSTIC"; do
  grep -q 'run-preimage-rescue-smoke.sh' "$workflow" ||
    fail "image-free transition diagnostic does not use the scoped smoke wrapper: $workflow"
done
[ -x "$PREIMAGE_RESCUE" ] || fail 'pre-image rescue wrapper is not executable'
grep -q 'diagnostic_geometry_only:true' "$PREIMAGE_RESCUE" ||
  fail 'pre-image geometry does not identify itself as diagnostic-only'
grep -q 'ROUTER_UI_VM_CASE:-.*= rescue' "$PREIMAGE_RESCUE" ||
  fail 'pre-image geometry is not restricted to the rescue selector'
grep -q 'ROUTER_UI_VM_SOURCE_VERSION:-.*= 0.7.0' "$PREIMAGE_RESCUE" ||
  fail 'pre-image geometry is not restricted to source 0.7.0'
grep -q 'mktemp -d "$RUNNER_TEMP/' "$PREIMAGE_RESCUE" ||
  fail 'pre-image geometry can escape RUNNER_TEMP'
grep -q 'cp -Rp "$IMMUTABLE_RELEASE_DIR/." "$gate_input/"' "$PREIMAGE_RESCUE" ||
  fail 'pre-image smoke does not isolate immutable candidate bytes from gate input'
grep -q 'diagnostic geometry-only archive is not a release image' \
  "$ROOT_DIR/scripts/validate-staged-release.sh" ||
  fail 'strict staged-release validation can mistake geometry shims for real images'
grep -q 'release validation accepted a diagnostic geometry-only image shim' \
  "$ROOT_DIR/tests/test-router-ui-release-v2.sh" ||
  fail 'release contract tests do not prove diagnostic geometry shim rejection'
grep -q 'compare with the tested transition bytes' "$CANDIDATE" ||
  fail 'final assembly does not compare against early tested transition bytes'
grep -q 'max-parallel: 2' "$CANDIDATE" ||
  fail 'candidate VM shards are not capped at two parallel jobs'
for shard in legacy protocol-concurrency-storage faults-a faults-b; do
  grep -q "$shard" "$CANDIDATE" || fail "candidate VM shard is missing: $shard"
done
grep -q '^  aggregate-vm-evidence:' "$CANDIDATE" ||
  fail 'candidate has no mandatory evidence aggregation job'
grep -q 'Aggregate mandatory VM evidence' "$CANDIDATE" ||
  fail 'candidate aggregation job is not an explicit authorization boundary'
grep -q 'aggregate-candidate-evidence.sh' "$CANDIDATE" ||
  fail 'candidate aggregation job does not run the completeness validator'
grep -q '^  rd23-stock-image:' "$CANDIDATE" &&
  grep -q '^  rd23-ubootmod-image:' "$CANDIDATE" ||
  fail 'RD23 stock and ubootmod are not independent concurrent jobs'
[ "$(grep -Fc 'needs: [canonical-ipks, sign-installed-package-set, rescue-0-7-0]' "$CANDIDATE")" -ge 3 ] ||
  fail 'all three image jobs do not start in parallel after fail-fast rescue'
grep -q '.storage_profiles\["rd23-stock"\].writable_backing_kib' "$CANDIDATE" ||
  fail 'x86 does not derive its exact writable extent from the verified baseline lock'
grep -q 'max-parallel: 2' "$RELEASE" ||
  fail 'tagged VM shards are not capped at two parallel jobs'
for shard in legacy protocol-concurrency-storage faults-a faults-b; do
  grep -q "$shard" "$RELEASE" || fail "tagged VM shard is missing: $shard"
done
grep -q '^  aggregate-tagged-vm-evidence:' "$RELEASE" ||
  fail 'tagged release has no mandatory evidence aggregation job'
grep -q 'aggregate-candidate-evidence.sh' "$RELEASE" ||
  fail 'tagged aggregation job does not run the completeness validator'
grep -q '^  rd23-stock-image:' "$RELEASE" &&
  grep -q '^  rd23-ubootmod-image:' "$RELEASE" ||
  fail 'tagged RD23 stock and ubootmod are not independent concurrent jobs'
grep -Fq 'needs: [canonical-ipks, sign-installed-package-set, rd23-stock-image]' "$RELEASE" ||
  fail 'tagged x86 does not start from stock provenance independently of ubootmod completion'
[ -x "$AGGREGATOR" ] || fail 'candidate evidence aggregator is not executable'
grep -q 'maximum_parallel_vm_jobs:2' "$AGGREGATOR" ||
  fail 'aggregated evidence does not record the two-VM maximum'
grep -q 'individual_shards_authorize_release:false' "$AGGREGATOR" ||
  fail 'individual shard evidence can be mistaken for release authorization'
for workflow in "$CANDIDATE" "$RELEASE"; do
  grep -q 'write-candidate-content-descriptor.sh' "$workflow" ||
    fail "workflow does not persist a candidate content descriptor: $workflow"
done
[ -s "$CONTENT_DESCRIPTOR" ] || fail 'candidate content descriptor generator is missing'
[ -x "$CONTENT_DESCRIPTOR" ] || fail 'candidate content descriptor generator is not executable'
grep -A4 -F 'path: ${{ runner.temp }}/baseline-artifact/' "$BASELINES" |
  grep -q 'include-hidden-files: true' || fail 'baseline evidence upload omits hidden checksummed evidence'
grep -A4 -F 'path: ${{ runner.temp }}/diagnostic-evidence/' "$DIAGNOSTIC" |
  grep -q 'include-hidden-files: true' || fail 'diagnostic upload omits hidden checksummed evidence'
grep -A4 -F '${{ runner.temp }}/candidate-evidence/' "$CANDIDATE" |
  grep -q 'include-hidden-files: true' || fail 'candidate upload omits hidden checksummed evidence'
grep -A4 -F 'path: ${{ runner.temp }}/tagged-evidence/' "$RELEASE" |
  grep -q 'include-hidden-files: true' || fail 'tagged release upload omits hidden checksummed evidence'

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
grep -A3 '^setup_tls()' "$GATE" | grep -q "ssh-keygen -q -t ed25519 -N '' -f \"\$WORK/ssh-key\"" ||
  fail 'candidate consumers do not generate disposable runtime SSH credentials'
[ "$(grep -c "ssh-keygen -q -t ed25519 -N '' -f \"\$WORK/ssh-key\"" "$GATE")" -eq 1 ] ||
  fail 'runtime SSH credentials are generated outside the shared setup phase'
grep -q 'read_until_prompt' "$GATE" ||
  fail 'serial bootstrap is not synchronized to the disposable guest prompt'
grep -q 'prompt = re.compile' "$GATE" ||
  fail 'serial bootstrap is tied to a single guest hostname'
grep -Fq 'prompt = re.compile(rb"(?:^|\r?\n)root@[^\r\n]*:~# ")' "$GATE" ||
  fail 'serial bootstrap rejects a real prompt followed by asynchronous guest output'
! grep -Fq 'root@[^\r\n]*:~# $' "$GATE" ||
  fail 'serial bootstrap still requires the guest prompt at the end of a socket read'
grep -q 'chunk_size = 128' "$GATE" ||
  fail 'serial bootstrap does not split the test CA into bounded commands'
grep -q 'ROUTER_UI_CONSOLE_BOOTSTRAP_OK' "$GATE" ||
  fail 'serial bootstrap has no explicit completion marker'
grep -q 'marker.encode() not in \[line.strip() for line in normalized_lines\]' "$GATE" ||
  fail 'serial bootstrap accepts marker text without exact executed output'
grep -q 'guest SSH bootstrap key does not match the runtime key' "$GATE" ||
  fail 'guest runtime SSH key is not verified before candidate operations'
grep -q 'guest test CA does not match the runtime artifact server CA' "$GATE" ||
  fail 'guest runtime test CA is not verified before candidate operations'
grep -q 'exact_runtime_credentials_verified:true' "$GATE" ||
  fail 'exact runtime credential verification is not preserved as VM evidence'

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
  .xray.package_url == "https://archive.openwrt.org/releases/24.10.5/packages/x86_64/packages/xray-core_25.1.30-r1_x86_64.ipk" and
  .xray.package_sha256 == "bd104b9badb83ee63e03e2abccc1b664f8994e00a0fc3e435af35d5e6fc864dc" and
  .storage_profiles["rd23-stock"].writable_backing_kib == 54436 and
  .storage_profiles["rd23-ubootmod"].writable_backing_kib == 80352 and
  all(.baselines[]; (.release_sha256 | test("^[0-9a-f]{64}$")) and
    (.worker_sha256 | test("^[0-9a-f]{64}$")) and
    (.validator_sha256 | test("^[0-9a-f]{64}$")))' "$LOCK" >/dev/null ||
  fail 'legacy baseline input lock is incomplete'

jq -e '.schema_version == 1 and (.candidates | length) == 1 and
  .candidates[0].artifact_id == 8473240890 and
  .candidates[0].artifact_name == "pretag-router-ui-candidate-373d88c3636340d1610187992ec256ecdf65e123" and
  .candidates[0].artifact_zip_sha256 == "1fea2b2e49d95ee544c70ff95db5698c51d7cc0cf3b8362e8c03281c0d64c6bb" and
  .candidates[0].workflow_run_id == 29770661240 and
  .candidates[0].workflow_run_number == 107 and
  .candidates[0].workflow_path == ".github/workflows/ci.yml" and
  .candidates[0].workflow_conclusion == "failure" and
  .candidates[0].product_source_sha == "373d88c3636340d1610187992ec256ecdf65e123" and
  .candidates[0].diagnostic_only == true and
  .candidates[0].release_evidence_eligible == false and
  .candidates[0].superseded == true and
  (.candidates[0].superseded_reason | contains("mode 0600")) and
  (.candidates[0].required_success_job_names | length) == 4 and
  (.candidates[0].required_success_job_prefixes | length) == 2 and
  .candidates[0].required_failure_job_names == ["production-candidate / constrained-vm-gate"]' \
  "$LEGACY_CANDIDATES" >/dev/null || fail 'legacy diagnostic candidate provenance lock is incomplete'

fixture_sha="$(cd "$FIXTURE" && find . -type f -print0 | LC_ALL=C sort -z |
  xargs -0 sha256sum | sha256sum | awk '{print $1}')"
[ "$fixture_sha" = "$(jq -r .fixture.tree_sha256 "$LOCK")" ] ||
  fail 'deterministic fixture tree hash drifted'

layout_tmp="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-baseline-layout.XXXXXX")"
mkdir -p "$layout_tmp/pack/bases" "$layout_tmp/pack/overlays/rd23-stock" \
  "$layout_tmp/consumer/overlays/router-ui-vm-gate.test"
: > "$layout_tmp/pack/bases/rd23-stock.img"
: > "$layout_tmp/pack/overlays/rd23-stock/baseline-0.7.0.qcow2"
ln -s "$layout_tmp/pack/bases" "$layout_tmp/consumer/bases"
ln -s "$layout_tmp/pack/overlays/rd23-stock/baseline-0.7.0.qcow2" \
  "$layout_tmp/consumer/overlays/router-ui-vm-gate.test/baseline-0.7.0.qcow2"
[ -e "$layout_tmp/consumer/overlays/router-ui-vm-gate.test/../../bases/rd23-stock.img" ] ||
  fail 'relocatable baseline backing path does not resolve from the VM work directory'
rm -rf "$layout_tmp"

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
