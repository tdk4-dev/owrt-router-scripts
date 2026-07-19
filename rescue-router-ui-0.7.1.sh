#!/bin/ash
set -eu

# Narrow recovery path for legacy Router UI 0.7.1 installations whose LuCI
# update controls cannot start a fresh check or install.
#
# Run on the router as root. With no version set, the script accepts the latest
# published stable release only when it is 0.7.9 or 0.7.10:
#
#   sh rescue-router-ui-0.7.1.sh
#
# Pin the currently published recovery target explicitly:
#
#   ROUTER_UI_VERSION=0.7.9 sh rescue-router-ui-0.7.1.sh
#
# The downloaded standalone installer creates and validates a full OpenWrt
# backup and uses the release's normal transactional install/rollback path.

REPO="${ROUTER_UI_REPO:-tdk4-dev/owrt-router-scripts}"
RELEASE_ORIGIN="${ROUTER_UI_RESCUE_RELEASE_ORIGIN:-https://github.com}"
VERSION_FILE="${ROUTER_UI_VERSION_FILE:-/usr/share/vpn-ui/version}"
OPENWRT_RELEASE_FILE="${ROUTER_UI_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
REQUESTED_VERSION="${ROUTER_UI_VERSION:-${1:-}}"
WORK_DIR=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  case "$WORK_DIR" in
    /tmp/router-ui-0.7.1-rescue.*)
      rm -f \
        "$WORK_DIR/latest-version" \
        "$WORK_DIR/release-version" \
        "$WORK_DIR/install-router-ui-release.sh" \
        "$WORK_DIR/install-router-ui-release.sh.sha256" 2>/dev/null || true
      rmdir "$WORK_DIR" 2>/dev/null || true
      ;;
  esac
}

fetch() {
  local url="$1"
  local dst="$2"
  local attempt=1

  while [ "$attempt" -le 3 ]; do
    if command -v curl >/dev/null 2>&1; then
      curl -4 -fsSL --proto '=https' --connect-timeout 10 --max-time 120 \
        "$url" -o "$dst" && return 0
    elif command -v wget >/dev/null 2>&1; then
      wget -T 120 -qO "$dst" "$url" && return 0
    elif command -v uclient-fetch >/dev/null 2>&1; then
      uclient-fetch -T 120 -q -O "$dst" "$url" && return 0
    else
      die "curl, wget, or uclient-fetch is required"
    fi
    rm -f "$dst"
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
  return 1
}

read_version() {
  sed -n '1p' "$1" | tr -d '\r\n'
}

version_is_allowed() {
  case "$1" in
    0.7.9|0.7.10) return 0 ;;
    *) return 1 ;;
  esac
}

[ "$#" -le 1 ] || die "usage: ROUTER_UI_VERSION=0.7.9 sh $0"
[ "$(id -u)" = "0" ] || die "run this script as root on OpenWrt"
[ -f "$OPENWRT_RELEASE_FILE" ] || die "this does not appear to be OpenWrt"
[ -f "$VERSION_FILE" ] || die "Router UI version file is missing: $VERSION_FILE"
command -v mktemp >/dev/null 2>&1 || die "mktemp is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

CURRENT_VERSION="$(read_version "$VERSION_FILE")"
case "$CURRENT_VERSION" in
  0.7.1|0.7.9|0.7.10) ;;
  *)
    die "this rescue is limited to Router UI 0.7.1, 0.7.9, or 0.7.10; installed version is $CURRENT_VERSION"
    ;;
esac

WORK_DIR="$(mktemp -d /tmp/router-ui-0.7.1-rescue.XXXXXX)" ||
  die "could not create a temporary directory"
trap cleanup EXIT INT TERM
chmod 700 "$WORK_DIR"

if [ -n "$REQUESTED_VERSION" ]; then
  TARGET_VERSION="$REQUESTED_VERSION"
else
  LATEST_BASE="$RELEASE_ORIGIN/$REPO/releases/latest/download"
  printf 'Resolving the latest published Router UI release...\n'
  fetch "$LATEST_BASE/vpn-ui-version.txt" "$WORK_DIR/latest-version" ||
    die "could not download latest release metadata"
  TARGET_VERSION="$(read_version "$WORK_DIR/latest-version")"
fi

version_is_allowed "$TARGET_VERSION" ||
  die "refusing target $TARGET_VERSION; this rescue allows only 0.7.9 or 0.7.10"

if [ "$CURRENT_VERSION" = "$TARGET_VERSION" ]; then
  printf 'Router UI %s is already installed; no rescue is needed.\n' "$CURRENT_VERSION"
  exit 0
fi
if [ "$CURRENT_VERSION" = "0.7.10" ] && [ "$TARGET_VERSION" = "0.7.9" ]; then
  die "refusing to downgrade Router UI 0.7.10 to 0.7.9"
fi

RELEASE_BASE="$RELEASE_ORIGIN/$REPO/releases/download/vpn-panel-v$TARGET_VERSION"
INSTALLER="$WORK_DIR/install-router-ui-release.sh"
CHECKSUM="$WORK_DIR/install-router-ui-release.sh.sha256"

printf 'Reading exact Router UI %s release metadata...\n' "$TARGET_VERSION"
fetch "$RELEASE_BASE/vpn-ui-version.txt" "$WORK_DIR/release-version" ||
  die "Router UI $TARGET_VERSION is not published or its metadata is unavailable"
[ "$(read_version "$WORK_DIR/release-version")" = "$TARGET_VERSION" ] ||
  die "exact release metadata does not match target $TARGET_VERSION"

printf 'Downloading the checksum-verified standalone installer...\n'
fetch "$RELEASE_BASE/install-router-ui-release.sh" "$INSTALLER" ||
  die "could not download the Router UI $TARGET_VERSION installer"
fetch "$RELEASE_BASE/install-router-ui-release.sh.sha256" "$CHECKSUM" ||
  die "could not download the Router UI $TARGET_VERSION installer checksum"

EXPECTED_SUM="$(awk 'NR == 1 { print $1 }' "$CHECKSUM")"
CHECKSUM_NAME="$(awk 'NR == 1 { print $2 }' "$CHECKSUM")"
printf '%s' "$EXPECTED_SUM" | grep -Eq '^[0-9a-f]{64}$' ||
  die "installer checksum metadata is malformed"
[ "$CHECKSUM_NAME" = "install-router-ui-release.sh" ] ||
  die "installer checksum names an unexpected file"
ACTUAL_SUM="$(sha256sum "$INSTALLER" | awk '{ print $1 }')"
[ "$ACTUAL_SUM" = "$EXPECTED_SUM" ] ||
  die "installer checksum verification failed"
sh -n "$INSTALLER" || die "downloaded installer has invalid shell syntax"
chmod 700 "$INSTALLER"

printf '\nLaunching the normal Router UI %s backup/install/rollback transaction.\n' \
  "$TARGET_VERSION"
ROUTER_UI_VERSION="$TARGET_VERSION" ROUTER_UI_REPO="$REPO" \
  sh "$INSTALLER"

INSTALLED_VERSION="$(read_version "$VERSION_FILE")"
[ "$INSTALLED_VERSION" = "$TARGET_VERSION" ] ||
  die "installer returned success but the installed version is $INSTALLED_VERSION"

printf '\nRouter UI %s is installed. Reload LuCI and open System > Update.\n' \
  "$TARGET_VERSION"
