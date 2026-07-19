#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE_BUILDER="$ROOT_DIR/build-openwrt-custom-image-linux.sh"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
RELEASE_DIR="$ROOT_DIR/dist/release-v$APP_VERSION"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/router-release-staging-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

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
grep -Fq 'sha256sum "$archive_name" > "$archive_name.sha256"' "$IMAGE_BUILDER"
grep -Fq 'rm -rf "$TARGET_OUT"' "$IMAGE_BUILDER"
grep -Fq 'cd "$PROJECT_PACKAGE_DIR"' "$IMAGE_BUILDER"
grep -Fq "sed 's#  \\./#  #'" "$IMAGE_BUILDER"
grep -Fq 'find . -maxdepth 1 -type f ! -name sha256sums -print' "$IMAGE_BUILDER"

grep -q '/usr/sbin/vpn-ui status' "$RELEASE_DIR/install-router-ui-release.sh"
! grep -q '/usr/sbin/vpn-ui check' "$RELEASE_DIR/install-router-ui-release.sh"
! grep -q '/usr/sbin/vpn-ui vpn-summary' "$RELEASE_DIR/install-router-ui-release.sh"
grep -q '^/www/luci-static/resources/view/network/vpn.js$' "$RELEASE_DIR/install-router-ui-release.sh"
grep -q '^/www/luci-static/resources/view/status/include/_35_vpn.js$' "$RELEASE_DIR/install-router-ui-release.sh"
grep -q '^/www/cgi-bin/firstboot-setup$' "$RELEASE_DIR/install-router-ui-release.sh"
grep -q '^/www/prepare/app.js"$' "$RELEASE_DIR/install-router-ui-release.sh"

for pkg in premier-router-core luci-app-premier-router premier-router-setup; do
  ls "$RELEASE_DIR/packages/${pkg}_${APP_VERSION}-1_all.ipk" >/dev/null
  ls "$RELEASE_DIR/opkg-feed/${pkg}_${APP_VERSION}-1_all.ipk" >/dev/null
  grep -q "$pkg $APP_VERSION-1 all" "$RELEASE_DIR/router-ui-packages.txt"
  grep -q "Package: $pkg" "$RELEASE_DIR/opkg-feed/Packages"
done

grep -q "\"version\": \"$APP_VERSION\"" "$RELEASE_DIR/router-release-manifest.json"
grep -q "\"package_version\": \"$APP_VERSION-1\"" "$RELEASE_DIR/router-release-manifest.json"
grep -q "\"openwrt_version\": \"$OPENWRT_VERSION\"" "$RELEASE_DIR/router-release-manifest.json"
grep -Eq '"generated_at": "[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$RELEASE_DIR/router-release-manifest.json"
grep -q '"artifact_type":"package"' "$RELEASE_DIR/router-release-manifest.json"
grep -q '"artifact_type":"installer"' "$RELEASE_DIR/router-release-manifest.json"
grep -q 'installed-manifest.json' "$RELEASE_DIR/install-router-ui-release.sh"
grep -q 'metadata-installed.*package-first-staged\|INSTALL_SOURCE=package-first-staged' "$RELEASE_DIR/install-router-ui-release.sh"

(
  cd "$RELEASE_DIR"
  sha256sum -c SHA256SUMS >/tmp/router-release-sha256-test.log
)

RELEASE_DIR="$RELEASE_DIR" "$ROOT_DIR/scripts/validate-staged-release.sh" >/tmp/router-release-validator-test.log

CUSTOM_OUT="$TMP_DIR/custom-output"
BUILD_DIR="$TMP_DIR/build" \
OUT_DIR="$CUSTOM_OUT/ipk" \
FEED_DIR="$CUSTOM_OUT/opkg-feed" \
SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567 \
SOURCE_DIRTY=0 \
  "$ROOT_DIR/scripts/build-openwrt-ipks.sh" >/tmp/router-release-custom-build-test.log
OUT_ROOT="$CUSTOM_OUT" \
RELEASE_DIR="$CUSTOM_OUT/release-v$APP_VERSION" \
SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567 \
SOURCE_DIRTY=false \
  "$ROOT_DIR/scripts/stage-router-release.sh" >/tmp/router-release-custom-stage-test.log
RELEASE_DIR="$CUSTOM_OUT/release-v$APP_VERSION" \
STRICT_RELEASE=1 \
  "$ROOT_DIR/scripts/validate-staged-release.sh" >/tmp/router-release-custom-validate-test.log
grep -q 'SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567' \
  "$TMP_DIR/build/premier-router-core/root/usr/share/vpn-ui/build-info"

if find "$RELEASE_DIR" -type f | grep -E '/(\.DS_Store|id_rsa|\.env|\.pcap|luci-vpn-ui\.tar\.gz)$'; then
  printf 'release directory contains forbidden local or legacy tarball artifacts\n' >&2
  exit 1
fi

printf 'Package-first release staging validation passed\n'
