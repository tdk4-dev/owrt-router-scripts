#!/bin/sh
set -eu
umask 077

TARGET_APP_VERSION='UNRENDERED-APP-VERSION'
TARGET_PACKAGE_VERSION='UNRENDERED-PACKAGE-VERSION'
TRUSTED_KEY_ID='UNRENDERED-PRODUCTION-KEY-ID'
TRUSTED_KEY_FINGERPRINT='UNRENDERED-PRODUCTION-FINGERPRINT'
TRUSTED_KEY_COMMENT='UNRENDERED-PRODUCTION-PUBLIC-KEY'
TRUSTED_KEY_DATA=''
SUPPORTED_OPENWRT_MIN='24.10.0'
SUPPORTED_OPENWRT_MAX='24.10.99'
SUPPORTED_TARGETS='x86/64 mediatek/filogic'
ROOT_PREFIX="${ROUTER_UI_ROOT_PREFIX:-}"
ASSET_DIR="${ROUTER_UI_ASSET_DIR:-${1:-/tmp}}"
OPKG_BIN="${ROUTER_UI_OPKG_BIN:-opkg}"
SYSUPGRADE_BIN="${ROUTER_UI_SYSUPGRADE_BIN:-sysupgrade}"
WORK_DIR="$(mktemp -d /tmp/router-ui-ipk-bootstrap.XXXXXX)"
PUBLIC_KEY="$WORK_DIR/release.pub"
PROJECT_PACKAGES='premier-router-core luci-app-premier-router premier-router-setup'
MANIFEST="$ASSET_DIR/installed-manifest.json"
SIGNATURE="$ASSET_DIR/installed-manifest.json.sig"
VALIDATOR="$ASSET_DIR/router-candidate-validator"
INSTALLED_DIR="$ROOT_PREFIX/etc/premier-router"
FIRSTBOOT_STATE_DIR="$ROOT_PREFIX/etc/firstboot-wizard"
FIRSTBOOT_COMPLETE_FILE="$FIRSTBOOT_STATE_DIR/complete"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
  case "$WORK_DIR" in /tmp/router-ui-ipk-bootstrap.*) rm -rf "$WORK_DIR" ;; esac
}
trap cleanup EXIT INT TERM
jget() { jsonfilter -i "$1" -e "$2" | sed -n '1p'; }
version_le() {
  awk -v left="$1" -v right="$2" 'BEGIN {
    ln = split(left, l, "."); rn = split(right, r, "."); n = ln > rn ? ln : rn
    for (i = 1; i <= n; i++) {
      lv = (i <= ln ? l[i] + 0 : 0); rv = (i <= rn ? r[i] + 0 : 0)
      if (lv < rv) exit 0
      if (lv > rv) exit 1
    }
    exit 0
  }'
}
filesystem_free_kib() {
  df -Pk "$1" 2>/dev/null | awk 'NR > 1 && $4 ~ /^[0-9]+$/ { print $4; exit }'
}
safe_name() {
  [ -n "$1" ] || return 1
  case "$1" in /*|.|..|*/*|*\\*) return 1 ;; esac
  LC_ALL=C printf '%s' "$1" | grep -q '[[:cntrl:]]' && return 1
  return 0
}
seal_existing_router_setup() {
  [ ! -L "$FIRSTBOOT_STATE_DIR" ] ||
    die 'refusing symlinked first-boot state directory'
  if [ -e "$FIRSTBOOT_STATE_DIR" ] && [ ! -d "$FIRSTBOOT_STATE_DIR" ]; then
    die 'refusing non-directory first-boot state path'
  fi
  mkdir -p "$FIRSTBOOT_STATE_DIR"
  chmod 700 "$FIRSTBOOT_STATE_DIR"

  [ ! -L "$FIRSTBOOT_COMPLETE_FILE" ] ||
    die 'refusing symlinked first-boot completion marker'
  if [ -e "$FIRSTBOOT_COMPLETE_FILE" ] && [ ! -f "$FIRSTBOOT_COMPLETE_FILE" ]; then
    die 'refusing non-file first-boot completion marker'
  fi
  if [ ! -f "$FIRSTBOOT_COMPLETE_FILE" ]; then
    firstboot_temporary="$FIRSTBOOT_STATE_DIR/.complete.$$"
    rm -f "$firstboot_temporary"
    : > "$firstboot_temporary"
    chmod 600 "$firstboot_temporary"
    mv "$firstboot_temporary" "$FIRSTBOOT_COMPLETE_FILE"
  fi
  chmod 600 "$FIRSTBOOT_COMPLETE_FILE"
}

case "$ROOT_PREFIX" in ''|/*) ;; *) die 'ROUTER_UI_ROOT_PREFIX must be empty or absolute' ;; esac
case "$ROOT_PREFIX" in *'/../'*|*/..|../*) die 'ROUTER_UI_ROOT_PREFIX may not traverse parents' ;; esac
case "$ASSET_DIR" in /*) ;; *) die 'the verified asset directory must be absolute' ;; esac
case "$TARGET_APP_VERSION:$TARGET_PACKAGE_VERSION:$TRUSTED_KEY_ID:$TRUSTED_KEY_FINGERPRINT:$TRUSTED_KEY_COMMENT:$TRUSTED_KEY_DATA" in
  *UNRENDERED*|*:)
    die 'this source-tree bootstrap is unrendered; use the signed release asset'
    ;;
esac
case "$TRUSTED_KEY_ID" in test-*|dev-*)
  [ "${PREMIER_ROUTER_HOST_TEST:-0}" = 1 ] ||
    die 'development signing keys are refused on a router'
  ;;
esac
if [ "$(id -u)" != 0 ] && [ "${PREMIER_ROUTER_HOST_TEST:-0}" != 1 ]; then
  die 'run this bootstrap as root on OpenWrt'
fi
[ -f "$ROOT_PREFIX/etc/openwrt_release" ] || die 'this does not appear to be OpenWrt'
for tool in jsonfilter usign sha256sum tar mktemp awk df cmp "$OPKG_BIN" "$SYSUPGRADE_BIN"; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required command: $tool"
done

DISTRIB_RELEASE= DISTRIB_TARGET=
# This root-owned OpenWrt identity file contains simple shell assignments.
# shellcheck disable=SC1090
. "$ROOT_PREFIX/etc/openwrt_release"
OPENWRT_RELEASE="${DISTRIB_RELEASE:-}"
OPENWRT_TARGET="${DISTRIB_TARGET:-}"
printf '%s' "$OPENWRT_RELEASE" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
  die "unsupported OpenWrt version identity: ${OPENWRT_RELEASE:-unknown}"
version_le "$SUPPORTED_OPENWRT_MIN" "$OPENWRT_RELEASE" &&
  version_le "$OPENWRT_RELEASE" "$SUPPORTED_OPENWRT_MAX" ||
  die "OpenWrt $OPENWRT_RELEASE is outside supported range $SUPPORTED_OPENWRT_MIN..$SUPPORTED_OPENWRT_MAX"
case " $SUPPORTED_TARGETS " in
  *" $OPENWRT_TARGET "*) ;;
  *) die "unsupported OpenWrt target: ${OPENWRT_TARGET:-unknown}" ;;
esac

printf '%s\n%s\n' "$TRUSTED_KEY_COMMENT" "$TRUSTED_KEY_DATA" > "$PUBLIC_KEY"
[ "$(usign -F -p "$PUBLIC_KEY")" = "$TRUSTED_KEY_FINGERPRINT" ] ||
  die 'embedded release public-key fingerprint mismatch'
[ -s "$MANIFEST" ] && [ -s "$SIGNATURE" ] && [ -s "$VALIDATOR" ] ||
  die 'signed installed-package-set assets are incomplete'
usign -q -V -p "$PUBLIC_KEY" -m "$MANIFEST" -x "$SIGNATURE" ||
  die 'installed package manifest signature verification failed'

[ "$(jget "$MANIFEST" '@.schema_version')" = 1 ] || die 'unsupported installed manifest schema'
[ "$(jget "$MANIFEST" '@.kind')" = installed-package-set ] || die 'unexpected installed manifest kind'
[ "$(jget "$MANIFEST" '@.app_version')" = "$TARGET_APP_VERSION" ] || die 'installed manifest app version mismatch'
[ "$(jget "$MANIFEST" '@.package_version')" = "$TARGET_PACKAGE_VERSION" ] || die 'installed manifest package version mismatch'
[ "$(jget "$MANIFEST" '@.source_dirty')" = false ] || die 'dirty installed-package provenance is refused'
[ "$(jget "$MANIFEST" '@.signing_key_id')" = "$TRUSTED_KEY_ID" ] || die 'installed manifest signing key mismatch'
[ "$(jget "$MANIFEST" '@.signing_key_fingerprint')" = "$TRUSTED_KEY_FINGERPRINT" ] ||
  die 'installed manifest signing fingerprint mismatch'

index=0
PACKAGE_BYTES=0
for expected_package in $PROJECT_PACKAGES; do
  package="$(jget "$MANIFEST" "@.packages[$index].name")"
  filename="$(jget "$MANIFEST" "@.packages[$index].filename")"
  version="$(jget "$MANIFEST" "@.packages[$index].version")"
  architecture="$(jget "$MANIFEST" "@.packages[$index].architecture")"
  order="$(jget "$MANIFEST" "@.packages[$index].install_order")"
  size="$(jget "$MANIFEST" "@.packages[$index].size")"
  sha="$(jget "$MANIFEST" "@.packages[$index].sha256")"
  [ "$package" = "$expected_package" ] && [ "$version" = "$TARGET_PACKAGE_VERSION" ] &&
    [ "$architecture" = all ] && [ "$order" = "$((index + 1))" ] ||
    die "installed manifest package identity mismatch: $expected_package"
  safe_name "$filename" || die "unsafe package filename: $filename"
  [ -s "$ASSET_DIR/$filename" ] || die "missing package asset: $filename"
  [ "$(wc -c < "$ASSET_DIR/$filename" | tr -d ' ')" = "$size" ] &&
    [ "$(sha256sum "$ASSET_DIR/$filename" | awk '{print $1}')" = "$sha" ] ||
    die "package hash or size mismatch: $filename"
  case "$index" in
    0) IPK_0="$ASSET_DIR/$filename" ;;
    1) IPK_1="$ASSET_DIR/$filename" ;;
    2) IPK_2="$ASSET_DIR/$filename" ;;
  esac
  PACKAGE_BYTES=$((PACKAGE_BYTES + size))
  index=$((index + 1))
done
[ -z "$(jget "$MANIFEST" '@.packages[3].name')" ] || die 'installed manifest contains extra packages'

[ ! -s "$INSTALLED_DIR/installed-manifest.json" ] ||
  die 'an installed Router UI manifest already exists; use the transactional release installer'
INSTALLED_COUNT=0
for package in $PROJECT_PACKAGES; do
  package_status="$("$OPKG_BIN" status "$package" 2>/dev/null || true)"
  if printf '%s\n' "$package_status" | grep -q '^Status: .* installed'; then
    installed_version="$(printf '%s\n' "$package_status" | sed -n 's/^Version: //p' | sed -n '1p')"
    [ "$installed_version" = "$TARGET_PACKAGE_VERSION" ] ||
      die "existing Router UI package has a different version: $package ${installed_version:-unknown}"
    INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
  fi
done

PACKAGE_KIB=$(((PACKAGE_BYTES + 1023) / 1024))
PERSISTENT_REQUIRED_KIB=$((32768 + (PACKAGE_KIB * 4)))
TEMPORARY_REQUIRED_KIB=$((16384 + (PACKAGE_KIB * 2)))
if [ -n "${ROUTER_UI_TEST_PERSISTENT_FREE_KIB:-}" ]; then
  PERSISTENT_FREE_KIB="$ROUTER_UI_TEST_PERSISTENT_FREE_KIB"
else
  PERSIST_PROBE="$ROOT_PREFIX/overlay"
  [ -d "$PERSIST_PROBE" ] || PERSIST_PROBE="${ROOT_PREFIX:-/}"
  PERSISTENT_FREE_KIB="$(filesystem_free_kib "$PERSIST_PROBE")"
fi
if [ -n "${ROUTER_UI_TEST_TMP_FREE_KIB:-}" ]; then
  TEMPORARY_FREE_KIB="$ROUTER_UI_TEST_TMP_FREE_KIB"
else
  TEMPORARY_FREE_KIB="$(filesystem_free_kib "$ROOT_PREFIX/tmp")"
fi
printf '%s' "$PERSISTENT_FREE_KIB" | grep -Eq '^[0-9]+$' ||
  die 'could not determine persistent free space'
printf '%s' "$TEMPORARY_FREE_KIB" | grep -Eq '^[0-9]+$' ||
  die 'could not determine /tmp free space'
[ "$PERSISTENT_FREE_KIB" -ge "$PERSISTENT_REQUIRED_KIB" ] ||
  die "insufficient persistent space: need ${PERSISTENT_REQUIRED_KIB} KiB, have ${PERSISTENT_FREE_KIB} KiB"
[ "$TEMPORARY_FREE_KIB" -ge "$TEMPORARY_REQUIRED_KIB" ] ||
  die "insufficient /tmp space: need ${TEMPORARY_REQUIRED_KIB} KiB, have ${TEMPORARY_FREE_KIB} KiB"

if [ "${ROUTER_UI_TEST_VALIDATE_ASSETS_ONLY:-0}" = 1 ]; then
  printf 'Verified initial-install assets for Router UI %s (%s), OpenWrt %s on %s.\n' \
    "$TARGET_APP_VERSION" "$TARGET_PACKAGE_VERSION" "$OPENWRT_RELEASE" "$OPENWRT_TARGET"
  exit 0
fi

seal_existing_router_setup

BACKUP_DIR="$ROOT_PREFIX/root/premier-router-updates/initial-ipk-install-$TARGET_APP_VERSION"
BACKUP="$BACKUP_DIR/openwrt-configuration-recovery.tar.gz"
mkdir -p "$BACKUP_DIR"
if [ ! -s "$BACKUP" ]; then
  "$SYSUPGRADE_BIN" -b "$BACKUP"
fi
[ -s "$BACKUP" ] && tar -tzf "$BACKUP" >/dev/null 2>&1 || die 'OpenWrt configuration backup failed'

KNOWN_HASH="$(sha256sum "$MANIFEST" | awk '{print $1}')"
KNOWN_PARENT="$ROOT_PREFIX/root/premier-router-updates/known-good"
KNOWN_DIR="$KNOWN_PARENT/$KNOWN_HASH"
KNOWN_NEW="$KNOWN_PARENT/.${KNOWN_HASH}.$$"
rm -rf "$KNOWN_NEW"
mkdir -p "$KNOWN_NEW"
cp "$IPK_0" "$IPK_1" "$IPK_2" "$KNOWN_NEW/"
cp "$VALIDATOR" "$KNOWN_NEW/router-candidate-validator"
cp "$MANIFEST" "$KNOWN_NEW/router-release-manifest.json"
cp "$SIGNATURE" "$KNOWN_NEW/router-release-manifest.json.sig"
chmod 700 "$KNOWN_NEW/router-candidate-validator"
printf '%s\n' "$TARGET_APP_VERSION" > "$KNOWN_NEW/bootstrap-incomplete"
if [ -d "$KNOWN_DIR" ]; then
  for staged in "$IPK_0" "$IPK_1" "$IPK_2"; do
    cmp -s "$staged" "$KNOWN_DIR/$(basename "$staged")" ||
      die "existing recovery seed differs: $(basename "$staged")"
  done
  cmp -s "$VALIDATOR" "$KNOWN_DIR/router-candidate-validator" &&
    cmp -s "$MANIFEST" "$KNOWN_DIR/router-release-manifest.json" &&
    cmp -s "$SIGNATURE" "$KNOWN_DIR/router-release-manifest.json.sig" ||
    die 'existing recovery seed metadata differs'
  rm -rf "$KNOWN_NEW"
else
  mv "$KNOWN_NEW" "$KNOWN_DIR"
fi

"$OPKG_BIN" update || die "package index update failed; rerun this bootstrap; recovery seed: $KNOWN_DIR"
"$OPKG_BIN" install "$KNOWN_DIR/$(basename "$IPK_0")" \
  "$KNOWN_DIR/$(basename "$IPK_1")" "$KNOWN_DIR/$(basename "$IPK_2")" ||
  die "package installation failed; rerun this bootstrap; configuration backup: $BACKUP"

if ! PREMIER_ROUTER_ROOT="$ROOT_PREFIX" \
  PREMIER_ROUTER_UPDATE_LIB="$ROOT_PREFIX/usr/libexec/premier-router/update-lib.sh" \
  PREMIER_ROUTER_OPKG_BIN="$OPKG_BIN" \
  PREMIER_ROUTER_VPN_UI_BIN="$ROOT_PREFIX/usr/sbin/vpn-ui" \
  PREMIER_ROUTER_INSTALLED_MANIFEST="$KNOWN_DIR/router-release-manifest.json" \
  PREMIER_ROUTER_BUILD_INFO="$ROOT_PREFIX/usr/share/premier-router/build-info" \
  "$KNOWN_DIR/router-candidate-validator" --manifest "$KNOWN_DIR/router-release-manifest.json" \
    --source-version "$TARGET_APP_VERSION" --phase installed; then
  die "installed package validation failed; rerun after diagnosis; recovery seed: $KNOWN_DIR; backup: $BACKUP"
fi

mkdir -p "$INSTALLED_DIR"
cp "$MANIFEST" "$INSTALLED_DIR/installed-manifest.json.new"
cp "$SIGNATURE" "$INSTALLED_DIR/installed-manifest.json.sig.new"
mv "$INSTALLED_DIR/installed-manifest.json.new" "$INSTALLED_DIR/installed-manifest.json"
mv "$INSTALLED_DIR/installed-manifest.json.sig.new" "$INSTALLED_DIR/installed-manifest.json.sig"
rm -f "$KNOWN_DIR/bootstrap-incomplete"

printf 'Router UI %s (%s) installed and seeded for signed rollback/update.\n' \
  "$TARGET_APP_VERSION" "$TARGET_PACKAGE_VERSION"
if [ "$INSTALLED_COUNT" -gt 0 ]; then
  printf 'Resumed and completed a matching partial installation (%s package(s) were already present).\n' \
    "$INSTALLED_COUNT"
fi
printf 'Configuration backup: %s\n' "$BACKUP"
