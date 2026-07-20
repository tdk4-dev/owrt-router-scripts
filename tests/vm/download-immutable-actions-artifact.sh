#!/bin/bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KIND="${1:?usage: download-immutable-actions-artifact.sh KIND ARTIFACT_ID ZIP_SHA256 DESTINATION DESCRIPTOR}"
ARTIFACT_ID="${2:?artifact ID is required}"
ZIP_SHA256="${3:?artifact ZIP SHA-256 is required}"
DESTINATION="${4:?destination is required}"
DESCRIPTOR="${5:?descriptor output is required}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
LEGACY_DIAGNOSTIC_CANDIDATES="$ROOT_DIR/tests/vm/legacy-diagnostic-candidates.json"

fail() { printf 'IMMUTABLE-ARTIFACT-ERROR: %s\n' "$*" >&2; exit 1; }
for tool in cmp find gh jq sha256sum sort unzip; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing dependency: $tool"
done
[[ "$KIND" != candidate ]] || command -v usign >/dev/null 2>&1 || fail "missing dependency: usign"
case "$KIND" in candidate|baseline) ;; *) fail "unsupported artifact kind: $KIND" ;; esac
[[ "$ARTIFACT_ID" =~ ^[1-9][0-9]*$ ]] || fail "artifact ID is not numeric"
[[ "$ZIP_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "artifact ZIP SHA-256 is malformed"
[[ ! -e "$DESTINATION" ]] || fail "destination must not already exist"
mkdir -p "$DESTINATION" "$(dirname "$DESCRIPTOR")"

artifact_json="$(mktemp "${RUNNER_TEMP:-/tmp}/router-ui-artifact.XXXXXX.json")"
run_json="$(mktemp "${RUNNER_TEMP:-/tmp}/router-ui-run.XXXXXX.json")"
jobs_json="$(mktemp "${RUNNER_TEMP:-/tmp}/router-ui-jobs.XXXXXX.json")"
archive="$(mktemp "${RUNNER_TEMP:-/tmp}/router-ui-artifact.XXXXXX.zip")"
cleanup() { rm -f "$artifact_json" "$run_json" "$jobs_json" "$archive"; }
trap cleanup EXIT INT TERM

verify_inventory() {
  local directory="$1" depth="$2" actual expected
  actual="$(mktemp "${RUNNER_TEMP:-/tmp}/router-ui-files.actual.XXXXXX")"
  expected="$(mktemp "${RUNNER_TEMP:-/tmp}/router-ui-files.expected.XXXXXX")"
  (cd "$directory" && find . $depth -type f ! -name SHA256SUMS -print | LC_ALL=C sort) > "$actual"
  (cd "$directory" && awk '{name=$2; sub(/^\*/, "", name); print "./" name}' SHA256SUMS | LC_ALL=C sort) > "$expected"
  cmp -s "$actual" "$expected" || fail "artifact contains unmanifested or missing files: $directory"
  rm -f "$actual" "$expected"
}

gh api "/repos/$GITHUB_REPOSITORY/actions/artifacts/$ARTIFACT_ID" > "$artifact_json"
artifact_name="$(jq -er '.name' "$artifact_json")"
run_id="$(jq -er '.workflow_run.id' "$artifact_json")"
jq -e --argjson id "$ARTIFACT_ID" --arg digest "sha256:$ZIP_SHA256" '
  .id == $id and .expired == false and .digest == $digest and
  (.workflow_run.id | type == "number")
' "$artifact_json" >/dev/null || fail "GitHub artifact metadata does not match the supplied immutable identity"

gh api "/repos/$GITHUB_REPOSITORY/actions/runs/$run_id" > "$run_json"
jq -e --argjson id "$run_id" '
  .id == $id and .status == "completed" and
  (.head_sha | test("^[0-9a-f]{40}$"))
' "$run_json" >/dev/null || fail "artifact-producing workflow run is not a completed immutable source"
run_number="$(jq -er '.run_number' "$run_json")"
run_head_sha="$(jq -er '.head_sha' "$run_json")"
workflow_path="$(jq -er '.path' "$run_json")"
workflow_conclusion="$(jq -er '.conclusion' "$run_json")"
provenance_mode=""
release_evidence_eligible=false
producer_jobs_api_sha256=""

case "$KIND" in
  candidate)
    if [[ "$workflow_path" = .github/workflows/validate-router-ui-candidate.yml &&
          "$workflow_conclusion" = success ]]; then
      provenance_mode=successful-manual-candidate
      release_evidence_eligible=true
    elif [[ "${ROUTER_UI_ALLOW_LEGACY_DIAGNOSTIC_CANDIDATE:-0}" = 1 ]]; then
      [[ -s "$LEGACY_DIAGNOSTIC_CANDIDATES" ]] || fail "legacy diagnostic candidate lock is missing"
      jq -e --argjson artifact_id "$ARTIFACT_ID" --arg artifact_name "$artifact_name" \
        --arg zip "$ZIP_SHA256" --argjson run_id "$run_id" --argjson run_number "$run_number" \
        --arg path "$workflow_path" --arg conclusion "$workflow_conclusion" \
        --arg source "$run_head_sha" '
          .schema_version == 1 and any(.candidates[];
            .artifact_id == $artifact_id and .artifact_name == $artifact_name and
            .artifact_zip_sha256 == $zip and .workflow_run_id == $run_id and
            .workflow_run_number == $run_number and .workflow_path == $path and
            .workflow_conclusion == $conclusion and .product_source_sha == $source and
            .diagnostic_only == true and .release_evidence_eligible == false)
        ' "$LEGACY_DIAGNOSTIC_CANDIDATES" >/dev/null ||
        fail "candidate does not match the exact diagnostic-only legacy provenance lock"
      gh api --paginate "/repos/$GITHUB_REPOSITORY/actions/runs/$run_id/jobs?per_page=100" \
        --jq '.jobs[]' | jq -s '{jobs:.}' > "$jobs_json"
      jq -e --argjson artifact_id "$ARTIFACT_ID" --slurpfile actual "$jobs_json" '
        (.candidates[] | select(.artifact_id == $artifact_id)) as $lock |
        ($actual[0].jobs) as $jobs |
        all($lock.required_success_job_names[]; . as $name |
          any($jobs[]; .name == $name and .status == "completed" and .conclusion == "success")) and
        all($lock.required_success_job_prefixes[]; . as $prefix |
          any($jobs[]; (.name | startswith($prefix)) and .status == "completed" and .conclusion == "success")) and
        all($lock.required_failure_job_names[]; . as $name |
          any($jobs[]; .name == $name and .status == "completed" and .conclusion == "failure"))
      ' "$LEGACY_DIAGNOSTIC_CANDIDATES" >/dev/null ||
        fail "legacy diagnostic candidate producer job conclusions do not match the provenance lock"
      provenance_mode=locked-legacy-diagnostic-candidate
      release_evidence_eligible=false
      producer_jobs_api_sha256="$(sha256sum "$jobs_json" | awk '{print $1}')"
    else
      fail "candidate artifact is not from a successful manual candidate workflow"
    fi
    ;;
  baseline)
    [[ "$workflow_path" = .github/workflows/build-router-ui-legacy-baselines.yml &&
        "$workflow_conclusion" = success ]] ||
      fail "baseline artifact is not from a successful baseline workflow"
    provenance_mode=successful-manual-baseline
    ;;
esac
cp "$artifact_json" "${DESCRIPTOR%.json}.artifact-api.json"
cp "$run_json" "${DESCRIPTOR%.json}.workflow-run-api.json"
[[ ! -s "$jobs_json" ]] || cp "$jobs_json" "${DESCRIPTOR%.json}.producer-jobs-api.json"

gh api "/repos/$GITHUB_REPOSITORY/actions/artifacts/$ARTIFACT_ID/zip" > "$archive"
printf '%s  %s\n' "$ZIP_SHA256" "$archive" | sha256sum -c -
unzip -q "$archive" -d "$DESTINATION"

case "$KIND" in
  candidate)
    release="$DESTINATION/release-v0.7.11"
    synthetic="$DESTINATION/synthetic-next"
    [[ -d "$release" && -d "$synthetic" ]] || fail "candidate payload directories are incomplete"
    for directory in "$release" "$synthetic"; do
      (cd "$directory" && sha256sum -c SHA256SUMS)
      verify_inventory "$directory" "-maxdepth 1"
      for signed in router-release-manifest.json stable-channel.json release-provenance.json; do
        usign -q -V -p "$ROOT_DIR/release/keys/router-ui-production.pub" \
          -m "$directory/$signed" -x "$directory/$signed.sig"
      done
    done
    source_sha="$(jq -er '.source_commit' "$release/router-release-manifest.json")"
    key_id="$(sed -n '1p' "$ROOT_DIR/release/keys/router-ui-production.key-id")"
    key_fingerprint="$(usign -F -p "$ROOT_DIR/release/keys/router-ui-production.pub")"
    [[ "$source_sha" = "$run_head_sha" ]] || fail "candidate source SHA differs from workflow head"
    [[ "$artifact_name" = "pretag-router-ui-candidate-$source_sha" ]] ||
      fail "candidate artifact name is not bound to its product source SHA"
    [[ "$key_id" = router-ui-prod-5b001ed1f9e63c96 ]] || fail "unexpected production key ID"
    [[ "$key_fingerprint" = 5b001ed1f9e63c96 ]] || fail "unexpected production key fingerprint"
    jq -e --arg sha "$source_sha" --arg key "$key_id" '
      .source_commit == $sha and .source_dirty == false and .app_version == "0.7.11" and
      .signing_key_id == $key
    ' "$release/router-release-manifest.json" >/dev/null || fail "candidate signed manifest contract failed"
    jq -e --arg sha "$source_sha" --arg key "$key_id" '
      .source_commit == $sha and .source_dirty == false and .app_version == "0.7.12" and
      .signing_key_id == $key
    ' "$synthetic/router-release-manifest.json" >/dev/null || fail "synthetic signed manifest contract failed"
    RELEASE_DIR="$release" RELEASE_PUBLIC_KEY="$ROOT_DIR/release/keys/router-ui-production.pub" \
      STRICT_RELEASE=1 REQUIRE_IMAGES=1 REQUIRE_MAIN_ANCESTRY=0 \
      EXPECTED_SOURCE_COMMIT="$source_sha" USIGN_BIN=usign \
      "$ROOT_DIR/scripts/validate-staged-release.sh"
    jq -n --argjson artifact_id "$ARTIFACT_ID" --arg artifact_name "$artifact_name" \
      --arg artifact_digest "sha256:$ZIP_SHA256" --argjson workflow_run_id "$run_id" \
      --argjson workflow_run_number "$run_number" --arg workflow_path "$workflow_path" \
      --arg workflow_conclusion "$workflow_conclusion" --arg provenance_mode "$provenance_mode" \
      --argjson release_evidence_eligible "$release_evidence_eligible" \
      --arg producer_jobs_api_sha256 "$producer_jobs_api_sha256" \
      --arg product_source_sha "$source_sha" --arg production_key_id "$key_id" \
      --arg production_key_fingerprint "$key_fingerprint" \
      --arg release_manifest_sha256 "$(sha256sum "$release/router-release-manifest.json" | awk '{print $1}')" \
      --arg release_sha256sums_sha256 "$(sha256sum "$release/SHA256SUMS" | awk '{print $1}')" \
      --arg synthetic_manifest_sha256 "$(sha256sum "$synthetic/router-release-manifest.json" | awk '{print $1}')" \
      --arg synthetic_sha256sums_sha256 "$(sha256sum "$synthetic/SHA256SUMS" | awk '{print $1}')" '
        {schema_version:1,kind:"router-ui-production-candidate",immutable:true,
         artifact_id:$artifact_id,artifact_name:$artifact_name,artifact_digest:$artifact_digest,
         workflow_run_id:$workflow_run_id,workflow_run_number:$workflow_run_number,
         workflow_path:$workflow_path,workflow_conclusion:$workflow_conclusion,
         provenance_mode:$provenance_mode,release_evidence_eligible:$release_evidence_eligible,
         producer_jobs_api_sha256:(if ($producer_jobs_api_sha256 | length) > 0
           then $producer_jobs_api_sha256 else null end),
         product_source_sha:$product_source_sha,
         production_key_id:$production_key_id,
         production_key_fingerprint:$production_key_fingerprint,
         release_manifest_sha256:$release_manifest_sha256,
         release_sha256sums_sha256:$release_sha256sums_sha256,
         synthetic_manifest_sha256:$synthetic_manifest_sha256,
         synthetic_sha256sums_sha256:$synthetic_sha256sums_sha256,
         signatures_verified:true,strict_release_validation_passed:true}
      ' > "$DESCRIPTOR"
    ;;
  baseline)
    pack="$DESTINATION/legacy-baseline-pack"
    [[ -d "$pack" ]] || fail "baseline artifact lacks legacy-baseline-pack"
    (cd "$pack" && sha256sum -c SHA256SUMS)
    verify_inventory "$pack" ""
    internal_descriptor="$pack/baseline-pack-descriptor.json"
    manifest="$pack/baseline-pack-manifest.json"
    [[ -s "$internal_descriptor" && -s "$manifest" ]] || fail "baseline descriptor or manifest is missing"
    contract_digest="$(sh "$ROOT_DIR/tests/vm/baseline-contract-digest.sh")"
    manifest_sha256="$(sha256sum "$manifest" | awk '{print $1}')"
    selector="$(jq -er '.selector' "$internal_descriptor")"
    jq -e --arg builder "$run_head_sha" --arg contract "$contract_digest" \
      --arg manifest "$manifest_sha256" '
        .schema_version == 1 and .immutable == true and
        .builder_commit == $builder and .baseline_contract_digest == $contract and
        .manifest_sha256 == $manifest
      ' "$internal_descriptor" >/dev/null || fail "baseline immutable descriptor contract failed"
    jq -e --arg builder "$run_head_sha" --arg contract "$contract_digest" '
      . as $root |
      .schema_version == 1 and .verified == true and .builder_commit == $builder and
      .baseline_contract_digest == $contract and
      (.expected_xray_binary_sha256 | test("^[0-9a-f]{64}$")) and
      all(.baselines[]; .self_validation.ok == true and
        .xray_package_version == $root.xray.version and
        .xray_binary_sha256 == $root.expected_xray_binary_sha256)
    ' "$manifest" >/dev/null || fail "baseline manifest content contract failed"
    [[ "$artifact_name" = "router-ui-legacy-baselines-$run_head_sha-$selector" ]] ||
      fail "baseline artifact name is not bound to builder provenance and selector"
    jq -n --argjson artifact_id "$ARTIFACT_ID" --arg artifact_name "$artifact_name" \
      --arg artifact_digest "sha256:$ZIP_SHA256" --argjson workflow_run_id "$run_id" \
      --argjson workflow_run_number "$run_number" --arg workflow_path "$workflow_path" \
      --arg builder_commit "$run_head_sha" --arg selector "$selector" \
      --arg baseline_contract_digest "$contract_digest" --arg manifest_sha256 "$manifest_sha256" '
        {schema_version:1,kind:"router-ui-legacy-baseline-pack-artifact",immutable:true,
         artifact_id:$artifact_id,artifact_name:$artifact_name,artifact_digest:$artifact_digest,
         workflow_run_id:$workflow_run_id,workflow_run_number:$workflow_run_number,
         workflow_path:$workflow_path,builder_commit:$builder_commit,selector:$selector,
         baseline_contract_digest:$baseline_contract_digest,
         manifest_sha256:$manifest_sha256,verified:true}
      ' > "$DESCRIPTOR"
    ;;
esac
