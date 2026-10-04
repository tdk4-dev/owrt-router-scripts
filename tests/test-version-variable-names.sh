#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

for file in \
  "$ROOT_DIR/build-openwrt-custom-image-linux.sh" \
  "$ROOT_DIR/scripts/stage-router-release.sh" \
  "$ROOT_DIR/scripts/build-openwrt-ipks.sh"
do
  grep -q 'APP_VERSION' "$file" || {
    printf '%s does not use APP_VERSION explicitly\n' "$file" >&2
    exit 1
  }
done

for file in \
  "$ROOT_DIR/build-openwrt-custom-image-linux.sh" \
  "$ROOT_DIR/scripts/stage-router-release.sh"
do
  grep -q 'OPENWRT_VERSION' "$file" || {
    printf '%s does not use OPENWRT_VERSION explicitly\n' "$file" >&2
    exit 1
  }
  if grep -Eq '(^|[^A-Z_])VERSION=' "$file"; then
    printf '%s uses ambiguous VERSION= assignment\n' "$file" >&2
    exit 1
  fi
  if grep -Eq '\$VERSION(\W|$)|\${VERSION' "$file"; then
    printf '%s references ambiguous VERSION variable\n' "$file" >&2
    exit 1
  fi
done

# The x86 compatibility entrypoint intentionally delegates identity handling to
# the generic builder. Preserve the naming guard at the implementation boundary
# without duplicating version parsing in the wrapper.
grep -Fq 'exec "$ROOT_DIR/build-openwrt-custom-image-linux.sh"' \
  "$ROOT_DIR/build-openwrt-x86-fin0-image-linux.sh" || {
  printf 'x86 compatibility entrypoint does not delegate to the guarded generic builder\n' >&2
  exit 1
}

log="$(mktemp "${TMPDIR:-/tmp}/version-name-test.XXXXXX")"
trap 'rm -f "$log"' EXIT INT TERM
if grep -RE '(^|[^A-Z_])VERSION=24\.10\.5' "$ROOT_DIR/README.md" "$ROOT_DIR/docs" "$ROOT_DIR/.github/workflows" >"$log" 2>&1; then
  cat "$log" >&2
  printf 'OpenWrt examples must use OPENWRT_VERSION=24.10.5\n' >&2
  exit 1
fi

printf 'version variable naming guard passed\n'
