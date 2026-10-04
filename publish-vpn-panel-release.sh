#!/usr/bin/env bash
set -euo pipefail
[ -z "${ROUTER_UI_TIER0_GUARD_LOG:-}" ] || { printf 'publisher:%s\n' "${0##*/}" >> "$ROUTER_UI_TIER0_GUARD_LOG"; exit 97; }
umask 077

ROOT_DIR="${RELEASE_ROOT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
GH_BIN="${GH_BIN:-gh}"
VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
TAG="${GITHUB_REF_NAME:-${1:-}}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/dist/release-v$VERSION}"
TITLE="Router UI $VERSION"
if [[ "$VERSION" =~ -rc\.([0-9]+)$ ]]; then
  TITLE="Router UI 0.7.11 RC${BASH_REMATCH[1]}"
  RELEASE_IS_PRERELEASE=1
else
  RELEASE_IS_PRERELEASE=0
fi
PUBLISH_VERIFIED_RELEASE="${PUBLISH_VERIFIED_RELEASE:-0}"
VALIDATE_STAGED_RELEASE="${VALIDATE_STAGED_RELEASE:-1}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "${VERSION%%-rc.*}" == 0.7.11 ]] || fail "publisher is scoped to Router UI 0.7.11"
[[ "$TAG" == "vpn-panel-v$VERSION" ]] || fail "tag $TAG does not match VERSION $VERSION"
[[ -d "$RELEASE_DIR" ]] || fail "staged release directory is missing"
[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || fail "publisher refuses a dirty source tree"
[[ "$(git -C "$ROOT_DIR" cat-file -t "refs/tags/$TAG" 2>/dev/null || true)" == tag ]] ||
  fail "an existing annotated tag is required; the publisher never creates tags"
TAG_COMMIT="$(git -C "$ROOT_DIR" rev-parse "$TAG^{commit}")"
MANIFEST_COMMIT="$(jq -r .source_commit "$RELEASE_DIR/router-release-manifest.json")"
[[ "$TAG_COMMIT" == "$MANIFEST_COMMIT" ]] || fail "tag commit and signed manifest commit differ"
git -C "$ROOT_DIR" merge-base --is-ancestor "$TAG_COMMIT" origin/main ||
  fail "tag commit is not contained in origin/main"

if [[ "$VALIDATE_STAGED_RELEASE" == 1 ]]; then
  RELEASE_DIR="$RELEASE_DIR" STRICT_RELEASE=1 EXPECTED_SOURCE_COMMIT="$TAG_COMMIT" \
    "$ROOT_DIR/scripts/validate-staged-release.sh"
fi

ASSETS=()
while IFS= read -r asset; do ASSETS+=("$asset"); done < <(
  find "$RELEASE_DIR" -maxdepth 1 -type f -print | LC_ALL=C sort
)
(( ${#ASSETS[@]} > 0 )) || fail "staged release contains no assets"
printf '%s\n' "${ASSETS[@]}" | sed 's#^.*/##' | LC_ALL=C sort > "${TMPDIR:-/tmp}/router-ui-asset-names.$$"
[[ -z "$(uniq -d "${TMPDIR:-/tmp}/router-ui-asset-names.$$")" ]] || fail "duplicate flat asset name"

release_exists=0
if "$GH_BIN" release view "$TAG" >/dev/null 2>&1; then
  release_exists=1
  release_json="$("$GH_BIN" release view "$TAG" --json name,isDraft,tagName,targetCommitish)"
  [[ "$(jq -r .name <<<"$release_json")" == "$TITLE" ]] || fail "existing release title mismatch"
  [[ "$(jq -r .tagName <<<"$release_json")" == "$TAG" ]] || fail "existing release tag mismatch"
  [[ "$(jq -r .isDraft <<<"$release_json")" == true ]] || fail "existing release is not a draft"
fi

if (( release_exists == 0 )); then
  create_args=(release create "$TAG" "${ASSETS[@]}" --draft --verify-tag --latest=false
    --title "$TITLE" --notes-file "$ROOT_DIR/luci-vpn-ui/RELEASE_NOTES.md")
  (( RELEASE_IS_PRERELEASE == 0 )) || create_args+=(--prerelease)
  "$GH_BIN" "${create_args[@]}"
fi

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-draft.XXXXXX")"
cleanup() { rm -rf "$VERIFY_DIR"; }
trap cleanup EXIT INT TERM
"$GH_BIN" release download "$TAG" --dir "$VERIFY_DIR"
DOWNLOADED=()
while IFS= read -r asset; do DOWNLOADED+=("$asset"); done < <(
  find "$VERIFY_DIR" -maxdepth 1 -type f -print | LC_ALL=C sort
)
[[ "${#DOWNLOADED[@]}" == "${#ASSETS[@]}" ]] || fail "draft asset count mismatch"
for asset in "${ASSETS[@]}"; do
  name="$(basename "$asset")"
  [[ -f "$VERIFY_DIR/$name" ]] || fail "draft asset missing: $name"
  cmp -s "$asset" "$VERIFY_DIR/$name" || fail "draft asset differs: $name"
done
downloaded_names="${TMPDIR:-/tmp}/router-ui-downloaded-names.$$"
find "$VERIFY_DIR" -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort > "$downloaded_names"
cmp -s "${TMPDIR:-/tmp}/router-ui-asset-names.$$" "$downloaded_names" ||
  fail "draft contains unexpected asset names"
rm -f "${TMPDIR:-/tmp}/router-ui-asset-names.$$" "$downloaded_names"

if [[ "$VALIDATE_STAGED_RELEASE" == 1 ]]; then
  RELEASE_DIR="$VERIFY_DIR" STRICT_RELEASE=1 EXPECTED_SOURCE_COMMIT="$TAG_COMMIT" \
    "$ROOT_DIR/scripts/validate-staged-release.sh"
fi

if [[ "$PUBLISH_VERIFIED_RELEASE" == 1 ]]; then
  if (( RELEASE_IS_PRERELEASE == 1 )); then
    "$GH_BIN" release edit "$TAG" --draft=false --prerelease --latest=false
  else
    "$GH_BIN" release edit "$TAG" --draft=false --latest=false
  fi
  printf 'Published verified release %s after exact draft round-trip.\n' "$TAG"
else
  printf 'Verified draft release %s; publication remains gated.\n' "$TAG"
fi
