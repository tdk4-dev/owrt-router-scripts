#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
RELEASE_DIR="$ROOT_DIR/dist/release-v$APP_VERSION"

"$ROOT_DIR/scripts/stage-router-release.sh" >/tmp/router-release-stage-test.log

[ -d "$RELEASE_DIR" ]
[ -f "$RELEASE_DIR/router-release-manifest.json" ]
[ -f "$RELEASE_DIR/SHA256SUMS" ]
[ -f "$RELEASE_DIR/router-ui-packages.txt" ]
[ -f "$RELEASE_DIR/vpn-ui-version.txt" ]
[ -f "$RELEASE_DIR/vpn-ui-changelog.txt" ]
[ -f "$RELEASE_DIR/vpn-ui-release-date.txt" ]
[ -x "$RELEASE_DIR/install-router-ui-release.sh" ]
[ -f "$RELEASE_DIR/opkg-feed/Packages" ]
[ -f "$RELEASE_DIR/opkg-feed/Packages.gz" ]

grep -q '/usr/sbin/vpn-ui status' "$RELEASE_DIR/install-router-ui-release.sh"
! grep -q '/usr/sbin/vpn-ui check' "$RELEASE_DIR/install-router-ui-release.sh"

for pkg in premier-router-core luci-app-premier-router premier-router-setup; do
  ls "$RELEASE_DIR/packages/${pkg}_${APP_VERSION}-1_all.ipk" >/dev/null
  ls "$RELEASE_DIR/opkg-feed/${pkg}_${APP_VERSION}-1_all.ipk" >/dev/null
  grep -q "$pkg $APP_VERSION-1 all" "$RELEASE_DIR/router-ui-packages.txt"
  grep -q "Package: $pkg" "$RELEASE_DIR/opkg-feed/Packages"
done

grep -q "\"version\": \"$APP_VERSION\"" "$RELEASE_DIR/router-release-manifest.json"
grep -q "\"package_version\": \"$APP_VERSION-1\"" "$RELEASE_DIR/router-release-manifest.json"
grep -q "\"openwrt_version\": \"$OPENWRT_VERSION\"" "$RELEASE_DIR/router-release-manifest.json"
grep -q '"artifact_type":"package"' "$RELEASE_DIR/router-release-manifest.json"
grep -q '"artifact_type":"installer"' "$RELEASE_DIR/router-release-manifest.json"

(
  cd "$RELEASE_DIR"
  sha256sum -c SHA256SUMS >/tmp/router-release-sha256-test.log
)

RELEASE_DIR="$RELEASE_DIR" "$ROOT_DIR/scripts/validate-staged-release.sh" >/tmp/router-release-validator-test.log

if find "$RELEASE_DIR" -type f | grep -E '/(\.DS_Store|id_rsa|\.env|\.pcap|luci-vpn-ui\.tar\.gz)$'; then
  printf 'release directory contains forbidden local or legacy tarball artifacts\n' >&2
  exit 1
fi

printf 'Package-first release staging validation passed\n'
