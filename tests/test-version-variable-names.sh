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
  if grep -Eq '\\$VERSION(\\W|$)|\\${VERSION' "$file"; then
    printf '%s references ambiguous VERSION variable\n' "$file" >&2
    exit 1
  fi
done

# The x86 entrypoint is intentionally a thin compatibility wrapper. Version
# handling belongs to the generic target builder it delegates to.
grep -Fq 'exec "$ROOT_DIR/build-openwrt-custom-image-linux.sh"' \
  "$ROOT_DIR/build-openwrt-x86-fin0-image-linux.sh"
if grep -Eq '(^|[^A-Z_])VERSION=' "$ROOT_DIR/build-openwrt-x86-fin0-image-linux.sh"; then
  printf 'x86 compatibility wrapper uses ambiguous VERSION= assignment\n' >&2
  exit 1
fi

if grep -RE '(^|[^A-Z_])VERSION=24\.10\.5' "$ROOT_DIR/README.md" "$ROOT_DIR/docs" "$ROOT_DIR/.github/workflows" >/tmp/version-name-test.log 2>&1; then
  cat /tmp/version-name-test.log >&2
  printf 'OpenWrt examples must use OPENWRT_VERSION=24.10.5\n' >&2
  exit 1
fi

printf 'version variable naming guard passed\n'
