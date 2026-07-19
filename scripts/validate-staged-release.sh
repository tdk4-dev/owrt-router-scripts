#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/dist/release-v$APP_VERSION}"
STRICT_RELEASE="${STRICT_RELEASE:-0}"
REQUIRE_IMAGES="${REQUIRE_IMAGES:-0}"
PROJECT_PACKAGES="premier-router-core luci-app-premier-router premier-router-setup"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[ -d "$RELEASE_DIR" ] || fail "missing release directory: $RELEASE_DIR"
[ -f "$RELEASE_DIR/router-release-manifest.json" ] || fail "missing router-release-manifest.json"
[ -f "$RELEASE_DIR/SHA256SUMS" ] || fail "missing SHA256SUMS"
[ -f "$RELEASE_DIR/router-ui-packages.txt" ] || fail "missing router-ui-packages.txt"

(
  cd "$RELEASE_DIR"
  sha256sum -c SHA256SUMS >/tmp/router-release-validate-sha256.log
) || {
  cat /tmp/router-release-validate-sha256.log >&2
  fail "SHA256SUMS validation failed"
}

grep -q "\"version\": \"$APP_VERSION\"" "$RELEASE_DIR/router-release-manifest.json" ||
  fail "manifest app version does not match $APP_VERSION"
grep -q "\"package_version\": \"$APP_VERSION-1\"" "$RELEASE_DIR/router-release-manifest.json" ||
  fail "manifest package version does not match $APP_VERSION-1"
grep -q "\"openwrt_version\": \"$OPENWRT_VERSION\"" "$RELEASE_DIR/router-release-manifest.json" ||
  fail "manifest OpenWrt version does not match $OPENWRT_VERSION"
grep -q '"source_commit": "' "$RELEASE_DIR/router-release-manifest.json" ||
  fail "manifest source commit field is absent"

if [ "$STRICT_RELEASE" = "1" ]; then
  grep -q '"source_commit": "[0-9a-f]' "$RELEASE_DIR/router-release-manifest.json" ||
    fail "strict release validation refuses absent source commit"
  grep -q '"source_dirty": false' "$RELEASE_DIR/router-release-manifest.json" ||
    fail "strict release validation refuses source_dirty=true"
fi

for pkg in $PROJECT_PACKAGES; do
  ipk="$RELEASE_DIR/packages/${pkg}_${APP_VERSION}-1_all.ipk"
  feed_ipk="$RELEASE_DIR/opkg-feed/${pkg}_${APP_VERSION}-1_all.ipk"
  [ -f "$ipk" ] || fail "missing package asset: $ipk"
  [ -f "$feed_ipk" ] || fail "missing feed package asset: $feed_ipk"
  cmp -s "$ipk" "$feed_ipk" || fail "standalone and feed IPKs differ for $pkg"
  grep -q "$pkg $APP_VERSION-1 all" "$RELEASE_DIR/router-ui-packages.txt" ||
    fail "router-ui-packages.txt missing $pkg $APP_VERSION-1"
  grep -q "Package: $pkg" "$RELEASE_DIR/opkg-feed/Packages" ||
    fail "opkg feed index missing $pkg"
  grep -q "$(basename "$ipk")" "$RELEASE_DIR/router-release-manifest.json" ||
    fail "manifest missing $pkg asset"
done

image_count="$(find "$RELEASE_DIR" -maxdepth 1 -type f -name "premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-*.tar.gz" | wc -l | tr -d ' ')"
if [ "$REQUIRE_IMAGES" = "1" ] && [ "$image_count" -lt 3 ]; then
  fail "strict release validation requires x86, RD23 stock, and RD23 ubootmod image archives"
fi

find "$RELEASE_DIR" -maxdepth 1 -type f -name "premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-*.tar.gz" |
  while IFS= read -r archive; do
    hashes="/tmp/router-image-ipk-sha256sums.$$"
    rm -f "$hashes"
    member="$(tar -tzf "$archive" | grep '/project-ipk-sha256sums$' | sed -n '1p')"
    [ -n "$member" ] || fail "image archive lacks project-ipk-sha256sums: $archive"
    tar -xOzf "$archive" "$member" > "$hashes" ||
      fail "could not inspect image archive metadata: $archive"
    while read -r sha file; do
      [ -n "${sha:-}" ] || continue
      base="$(basename "$file")"
      release_file="$RELEASE_DIR/packages/$base"
      [ -f "$release_file" ] || fail "image used IPK not found in release packages: $base"
      actual="$(sha256sum "$release_file" | awk '{ print $1 }')"
      [ "$actual" = "$sha" ] || fail "image IPK hash drift for $base"
    done < "$hashes"
    rm -f "$hashes"
  done

printf 'staged release validation passed: %s\n' "$RELEASE_DIR"
