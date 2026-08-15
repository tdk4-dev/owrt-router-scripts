#!/bin/sh
set -eu
umask 077

REPO="${ROUTER_UI_REPO:-tdk4-dev/owrt-router-scripts}"
TARGET_VERSION=0.7.11-rc.13
TARGET_TAG="vpn-panel-v$TARGET_VERSION"
RELEASE_BASE="${ROUTER_UI_RELEASE_BASE:-https://github.com/$REPO/releases/download/$TARGET_TAG}"
VERSION_FILE="${ROUTER_UI_VERSION_FILE:-/usr/share/vpn-ui/version}"
WORK_DIR="$(mktemp -d /tmp/router-ui-rescue.XXXXXX)"
TRUSTED_KEY_ID='UNRENDERED-PRODUCTION-KEY-ID'
TRUSTED_KEY_FINGERPRINT='UNRENDERED-PRODUCTION-FINGERPRINT'
TRUSTED_KEY_COMMENT='UNRENDERED-PRODUCTION-PUBLIC-KEY'
TRUSTED_KEY_DATA=''
PUBLIC_KEY="$WORK_DIR/release.pub"
OPENWRT_RELEASE_FILE="${ROUTER_UI_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
OPKG_BIN="${ROUTER_UI_OPKG_BIN:-opkg}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
  case "$WORK_DIR" in /tmp/router-ui-rescue.*) rm -rf "$WORK_DIR" ;; esac
}
trap cleanup EXIT INT TERM
fetch() {
  local url="$1" dst="$2" attempt=1
  case "$url" in https://*) ;; *) return 1 ;; esac
  while [ "$attempt" -le 3 ]; do
    rm -f "$dst"
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
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
  return 1
}
jget() { jsonfilter -i "$1" -e "$2" | sed -n '1p'; }
filesystem_free_kib() {
  df -Pk "$1" 2>/dev/null | awk 'NR > 1 && $4 ~ /^[0-9]+$/ { print $4; exit }'
}
bridge_state_kib() {
  for path in /etc/config /etc/xray /etc/vpn-ui-update.conf /etc/crontabs/root \
    /usr/lib/opkg/status; do
    [ ! -e "$path" ] || du -sk "$path" 2>/dev/null || return 1
  done | awk '{ total += $1 } END { print total + 0 }'
}
ensure_worker_prerequisite() {
  local index=0 size package_bytes=0 package_kib state_kib
  local persistent_probe persistent_free temporary_free persistent_required temporary_required

  command -v nohup >/dev/null 2>&1 && return 0
  while [ "$index" -lt 3 ]; do
    size="$(jget "$MANIFEST" "@.packages[$index].size")"
    printf '%s' "$size" | grep -Eq '^[1-9][0-9]*$' ||
      die "manifest package size is malformed"
    package_bytes=$((package_bytes + size))
    index=$((index + 1))
  done
  [ -z "$(jget "$MANIFEST" '@.packages[3].name')" ] ||
    die "manifest contains an unexpected package"
  package_kib=$(((package_bytes + 1023) / 1024))
  state_kib="$(bridge_state_kib)" || die "could not measure the existing router state"
  persistent_required=$((32768 + (package_kib * 4) + state_kib))
  temporary_required=$((16384 + (package_kib * 2) + state_kib))
  persistent_probe=/overlay
  [ -d "$persistent_probe" ] || persistent_probe=/
  persistent_free="$(filesystem_free_kib "$persistent_probe")"
  temporary_free="$(filesystem_free_kib /tmp)"
  printf '%s' "$persistent_free" | grep -Eq '^[0-9]+$' ||
    die "could not determine persistent free space before prerequisite repair"
  printf '%s' "$temporary_free" | grep -Eq '^[0-9]+$' ||
    die "could not determine temporary free space before prerequisite repair"
  [ "$persistent_free" -ge "$persistent_required" ] ||
    die "insufficient persistent space before prerequisite repair: need ${persistent_required} KiB, have ${persistent_free} KiB"
  [ "$temporary_free" -ge "$temporary_required" ] ||
    die "insufficient /tmp space before prerequisite repair: need ${temporary_required} KiB, have ${temporary_free} KiB"

  printf 'Installing the signed-feed coreutils-nohup prerequisite for legacy Router UI %s.\n' \
    "$SOURCE_VERSION"
  "$OPKG_BIN" update || die "signed OpenWrt package index update failed"
  "$OPKG_BIN" install coreutils-nohup || die "coreutils-nohup prerequisite installation failed"
  command -v nohup >/dev/null 2>&1 || die "coreutils-nohup did not provide nohup"
}

[ "${ROUTER_UI_TARGET_VERSION:-$TARGET_VERSION}" = "$TARGET_VERSION" ] ||
  die "direct rescue is pinned to Router UI $TARGET_VERSION; another target is refused"

if [ "$(id -u)" != 0 ] && [ "${PREMIER_ROUTER_HOST_TEST:-0}" != 1 ]; then
  die "run this rescue as root on OpenWrt"
fi
[ -f "$OPENWRT_RELEASE_FILE" ] || die "this does not appear to be OpenWrt"
[ -s "$VERSION_FILE" ] || die "Router UI version metadata is missing"

SOURCE_VERSION="$(sed -n '1p' "$VERSION_FILE" | tr -d '\r\n')"
case "$SOURCE_VERSION" in
  0.7.0|0.7.1|0.7.2|0.7.3|0.7.4|0.7.5|0.7.6|0.7.8|0.7.9|0.7.10)
    ;;
  0.7.7)
    die "Router UI 0.7.7 is tag-only and has no published installation artifact; automatic rescue is refused"
    ;;
  "$TARGET_VERSION")
    if [ -x /usr/sbin/vpn-ui-update ] &&
      grep -qx 'UPDATER_PROTOCOL=2' /usr/share/premier-router/build-info 2>/dev/null &&
      /usr/sbin/vpn-ui-update status >/dev/null; then
      printf 'Router UI %s and updater protocol v2 are already installed.\n' "$TARGET_VERSION"
      exit 0
    fi
    die "$TARGET_VERSION metadata exists but protocol-v2 validation failed"
    ;;
  *RC*|*-rc.*|*dev*|*dirty*|development|'')
    die "development or malformed source version is refused: ${SOURCE_VERSION:-missing}"
    ;;
  *)
    die "source version is not in the explicit rescue matrix: $SOURCE_VERSION"
    ;;
esac

if [ "${PREMIER_ROUTER_HOST_TEST:-0}" = 1 ] &&
  [ "${ROUTER_UI_TEST_VALIDATE_SOURCE_ONLY:-0}" = 1 ]; then
  printf 'Recognized rescue source: %s\n' "$SOURCE_VERSION"
  exit 0
fi
case "$TRUSTED_KEY_ID:$TRUSTED_KEY_FINGERPRINT:$TRUSTED_KEY_COMMENT:$TRUSTED_KEY_DATA" in
  *UNRENDERED*|*:|*test-*|*dev-*)
    die "this source-tree rescue is unrendered and contains no trusted production key; use the signed release asset"
    ;;
esac
for tool in jsonfilter usign sha256sum tar mktemp awk df du "$OPKG_BIN"; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

printf '%s\n%s\n' "$TRUSTED_KEY_COMMENT" "$TRUSTED_KEY_DATA" > "$PUBLIC_KEY"
[ "$(usign -F -p "$PUBLIC_KEY")" = "$TRUSTED_KEY_FINGERPRINT" ] ||
  die "embedded release public-key fingerprint mismatch"
MANIFEST="$WORK_DIR/router-release-manifest.json"
SIGNATURE="$WORK_DIR/router-release-manifest.json.sig"
fetch "$RELEASE_BASE/router-release-manifest.json" "$MANIFEST" ||
  die "could not download the exact $TARGET_VERSION manifest"
fetch "$RELEASE_BASE/router-release-manifest.json.sig" "$SIGNATURE" ||
  die "could not download the exact $TARGET_VERSION manifest signature"
usign -q -V -p "$PUBLIC_KEY" -m "$MANIFEST" -x "$SIGNATURE" ||
  die "$TARGET_VERSION manifest signature verification failed"
[ "$(jget "$MANIFEST" '@.schema_version')" = 2 ] ||
  die "unsupported release manifest schema"
[ "$(jget "$MANIFEST" '@.update_protocol')" = 2 ] ||
  die "target does not install updater protocol v2"
[ "$(jget "$MANIFEST" '@.app_version')" = "$TARGET_VERSION" ] ||
  die "manifest target version mismatch"
[ "$(jget "$MANIFEST" '@.release_tag')" = "$TARGET_TAG" ] ||
  die "manifest tag mismatch"
[ "$(jget "$MANIFEST" '@.signing_key_id')" = "$TRUSTED_KEY_ID" ] ||
  die "manifest signing key ID mismatch"
[ "$(jget "$MANIFEST" '@.signing_key_fingerprint')" = "$TRUSTED_KEY_FINGERPRINT" ] ||
  die "manifest signing key fingerprint mismatch"
[ "$(jget "$MANIFEST" '@.source_dirty')" = false ] ||
  die "dirty target provenance is refused"
TARGET_CHANNEL="$(jget "$MANIFEST" '@.channel')"
TARGET_PACKAGE_VERSION="$(jget "$MANIFEST" '@.package_version')"
case "$TARGET_CHANNEL" in stable|candidate) ;; *)
  die "unsupported target release channel: $TARGET_CHANNEL"
esac

INSTALLER_NAME="$(jget "$MANIFEST" '@.standalone_installer.filename')"
INSTALLER_SIZE="$(jget "$MANIFEST" '@.standalone_installer.size')"
INSTALLER_SHA="$(jget "$MANIFEST" '@.standalone_installer.sha256')"
[ "$INSTALLER_NAME" = install-router-ui-release.sh ] ||
  die "manifest names an unexpected standalone installer"
printf '%s' "$INSTALLER_SHA" | grep -Eq '^[0-9a-f]{64}$' ||
  die "installer hash metadata is malformed"
fetch "$RELEASE_BASE/$INSTALLER_NAME" "$WORK_DIR/$INSTALLER_NAME" ||
  die "could not download the exact standalone installer"
[ "$(wc -c < "$WORK_DIR/$INSTALLER_NAME" | tr -d ' ')" = "$INSTALLER_SIZE" ] &&
  [ "$(sha256sum "$WORK_DIR/$INSTALLER_NAME" | awk '{print $1}')" = "$INSTALLER_SHA" ] ||
  die "standalone installer verification failed"
sh -n "$WORK_DIR/$INSTALLER_NAME" ||
  die "standalone installer shell syntax is invalid"
chmod 700 "$WORK_DIR/$INSTALLER_NAME"

ensure_worker_prerequisite
printf 'Installing the exact Router UI %s bridge from recognized source %s.\n' \
  "$TARGET_VERSION" "$SOURCE_VERSION"
ROUTER_UI_VERSION="$TARGET_VERSION" ROUTER_UI_REPO="$REPO" \
  ROUTER_UI_RELEASE_CHANNEL="$TARGET_CHANNEL" \
  ROUTER_UI_EXACT_RELEASE_BASE="$RELEASE_BASE" \
  sh "$WORK_DIR/$INSTALLER_NAME"

[ "$(sed -n '1p' "$VERSION_FILE" | tr -d '\r\n')" = "$TARGET_VERSION" ] ||
  die "installed app version is not $TARGET_VERSION"
grep -qx 'UPDATER_PROTOCOL=2' /usr/share/premier-router/build-info ||
  die "updater protocol v2 is not active"
for package in premier-router-core luci-app-premier-router premier-router-setup; do
  version="$(opkg status "$package" 2>/dev/null | sed -n 's/^Version: //p' | sed -n '1p')"
  [ "$version" = "$TARGET_PACKAGE_VERSION" ] ||
    die "$package is not installed at $TARGET_PACKAGE_VERSION"
done
/usr/sbin/vpn-ui-update status >/dev/null ||
  die "updater status validation failed"
TRANSACTION="$(sed -n '1p' /root/premier-router-updates/active-transaction 2>/dev/null)"
[ -n "$TRANSACTION" ] &&
  [ -x "/root/premier-router-updates/$TRANSACTION/rollback.sh" ] &&
  [ -s "/root/premier-router-updates/$TRANSACTION/openwrt-configuration-recovery.tar.gz" ] ||
  die "persistent rollback or configuration recovery material is missing"

printf 'Router UI %s is installed with updater protocol v2.\n' "$TARGET_VERSION"
printf 'Use System > Update or /usr/sbin/vpn-ui-update check-start for later stable releases.\n'
printf 'Exact rollback: sh /root/premier-router-updates/%s/rollback.sh\n' "$TRANSACTION"
