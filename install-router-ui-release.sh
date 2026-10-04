#!/bin/sh
set -eu
umask 077

REPO="${ROUTER_UI_REPO:-tdk4-dev/owrt-router-scripts}"
REQUESTED_VERSION="${ROUTER_UI_VERSION:-}"
DISCOVERY_BASE="${ROUTER_UI_DISCOVERY_BASE:-https://github.com/$REPO/releases/latest/download}"
RELEASE_CHANNEL="${ROUTER_UI_RELEASE_CHANNEL:-stable}"
case "$RELEASE_CHANNEL" in stable|candidate) ;; *)
  printf 'ERROR: unsupported release channel: %s\n' "$RELEASE_CHANNEL" >&2
  exit 64
esac
POINTER_NAME="$RELEASE_CHANNEL-channel.json"
WORK_DIR="$(mktemp -d /tmp/router-ui-package-install.XXXXXX)"
TRUSTED_KEY_ID='UNRENDERED-PRODUCTION-KEY-ID'
TRUSTED_KEY_FINGERPRINT='UNRENDERED-PRODUCTION-FINGERPRINT'
TRUSTED_KEY_COMMENT='UNRENDERED-PRODUCTION-PUBLIC-KEY'
TRUSTED_KEY_DATA=''
PUBLIC_KEY="$WORK_DIR/release.pub"
OPENWRT_RELEASE_FILE="${ROUTER_UI_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}
version_valid() {
  printf '%s' "$1" |
    grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(RC[0-9]+|-rc\.[0-9]+|-test[0-9]+)?$'
}
cleanup() {
  case "$WORK_DIR" in /tmp/router-ui-package-install.*) rm -rf "$WORK_DIR" ;; esac
}
trap cleanup EXIT INT TERM

if [ "${PREMIER_ROUTER_HOST_TEST:-0}" = 1 ] &&
  [ "${ROUTER_UI_TEST_VALIDATE_REQUESTED_VERSION_ONLY:-0}" = 1 ]; then
  [ -n "$REQUESTED_VERSION" ] && version_valid "$REQUESTED_VERSION" ||
    die "requested version is malformed"
  printf 'Recognized requested version: %s\n' "$REQUESTED_VERSION"
  exit 0
fi

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
jget() {
  jsonfilter -i "$1" -e "$2" | sed -n '1p'
}
safe_name() {
  [ -n "$1" ] || return 1
  case "$1" in /*|.|..|*\\*) return 1 ;; esac
  ! printf '%s' "$1" | grep -q '/'
}
verify_file() {
  local file="$1" size="$2" sha="$3"
  [ -s "$file" ] &&
    [ "$(wc -c < "$file" | tr -d ' ')" = "$size" ] &&
    [ "$(sha256sum "$file" | awk '{print $1}')" = "$sha" ]
}
download_manifest_asset() {
  local base="$1" manifest="$2" object="$3"
  local name size sha
  name="$(jget "$manifest" "@.$object.filename")"
  size="$(jget "$manifest" "@.$object.size")"
  sha="$(jget "$manifest" "@.$object.sha256")"
  safe_name "$name" || die "unsafe asset name in $object"
  fetch "$base/$name" "$WORK_DIR/assets/$name" ||
    die "could not download $name"
  verify_file "$WORK_DIR/assets/$name" "$size" "$sha" ||
    die "asset verification failed: $name"
  printf '%s\n' "$name"
}

if [ "$(id -u)" != 0 ] && [ "${PREMIER_ROUTER_HOST_TEST:-0}" != 1 ]; then
  die "run this installer as root on OpenWrt"
fi
[ -f "$OPENWRT_RELEASE_FILE" ] || die "this does not appear to be OpenWrt"
case "$TRUSTED_KEY_ID:$TRUSTED_KEY_FINGERPRINT:$TRUSTED_KEY_COMMENT:$TRUSTED_KEY_DATA" in
  *UNRENDERED*|*:|*test-*|*dev-*)
    die "this source-tree installer is unrendered and contains no trusted production key; use the signed release asset"
    ;;
esac
for tool in jsonfilter usign sha256sum tar mktemp; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
printf '%s\n%s\n' "$TRUSTED_KEY_COMMENT" "$TRUSTED_KEY_DATA" > "$PUBLIC_KEY"
[ "$(usign -F -p "$PUBLIC_KEY")" = "$TRUSTED_KEY_FINGERPRINT" ] ||
  die "embedded release public-key fingerprint mismatch"
mkdir -p "$WORK_DIR/assets"

if [ -n "${ROUTER_UI_ASSET_DIR:-}" ]; then
  [ -s "${ROUTER_UI_VERIFIED_MANIFEST:-}" ] &&
    [ -s "${ROUTER_UI_VERIFIED_MANIFEST_SIGNATURE:-}" ] ||
    die "verified local mode requires a manifest and signature"
  ASSET_DIR="$ROUTER_UI_ASSET_DIR"
  MANIFEST="$ROUTER_UI_VERIFIED_MANIFEST"
  SIGNATURE="$ROUTER_UI_VERIFIED_MANIFEST_SIGNATURE"
  SUPERVISOR="$ASSET_DIR/$(jget "$MANIFEST" '@.transaction_supervisor.filename')"
  UPDATE_LIB="$ASSET_DIR/$(jget "$MANIFEST" '@.update_library.filename')"
else
  POINTER="$WORK_DIR/$POINTER_NAME"
  POINTER_SIG="$WORK_DIR/$POINTER_NAME.sig"
  if [ -n "$REQUESTED_VERSION" ]; then
    version_valid "$REQUESTED_VERSION" ||
      die "requested version is malformed"
    TAG="vpn-panel-v$REQUESTED_VERSION"
  else
    fetch "$DISCOVERY_BASE/$POINTER_NAME" "$POINTER" ||
      die "could not download the $RELEASE_CHANNEL-channel pointer"
    fetch "$DISCOVERY_BASE/$POINTER_NAME.sig" "$POINTER_SIG" ||
      die "could not download the $RELEASE_CHANNEL-channel signature"
    usign -q -V -p "$PUBLIC_KEY" -m "$POINTER" -x "$POINTER_SIG" ||
      die "$RELEASE_CHANNEL-channel signature verification failed"
    [ "$(jget "$POINTER" '@.schema_version')" = 1 ] ||
      die "unsupported $RELEASE_CHANNEL-channel schema"
    [ "$(jget "$POINTER" '@.channel')" = "$RELEASE_CHANNEL" ] ||
      die "$RELEASE_CHANNEL-channel metadata names another channel"
    [ "$(jget "$POINTER" '@.signing_key_id')" = "$TRUSTED_KEY_ID" ] ||
      die "$RELEASE_CHANNEL-channel signing key ID mismatch"
    TAG="$(jget "$POINTER" '@.release_tag')"
    REQUESTED_VERSION="$(jget "$POINTER" '@.target_version')"
    [ "$TAG" = "vpn-panel-v$REQUESTED_VERSION" ] ||
      die "$RELEASE_CHANNEL-channel tag/version mismatch"
  fi

  RELEASE_BASE="${ROUTER_UI_EXACT_RELEASE_BASE:-https://github.com/$REPO/releases/download/$TAG}"
  MANIFEST="$WORK_DIR/router-release-manifest.json"
  SIGNATURE="$WORK_DIR/router-release-manifest.json.sig"
  fetch "$RELEASE_BASE/router-release-manifest.json" "$MANIFEST" ||
    die "could not download the exact release manifest"
  fetch "$RELEASE_BASE/router-release-manifest.json.sig" "$SIGNATURE" ||
    die "could not download the exact release signature"
  usign -q -V -p "$PUBLIC_KEY" -m "$MANIFEST" -x "$SIGNATURE" ||
    die "release manifest signature verification failed"
  [ "$(jget "$MANIFEST" '@.release_tag')" = "$TAG" ] ||
    die "manifest release tag mismatch"
  [ "$(jget "$MANIFEST" '@.app_version')" = "$REQUESTED_VERSION" ] ||
    die "manifest version mismatch"
  [ "$(jget "$MANIFEST" '@.signing_key_id')" = "$TRUSTED_KEY_ID" ] ||
    die "manifest signing key ID mismatch"
  [ "$(jget "$MANIFEST" '@.signing_key_fingerprint')" = "$TRUSTED_KEY_FINGERPRINT" ] ||
    die "manifest signing key fingerprint mismatch"
  [ "$(jget "$MANIFEST" '@.channel')" = "$RELEASE_CHANNEL" ] ||
    die "manifest release channel mismatch"

  index=0
  while [ "$index" -lt 16 ]; do
    name="$(jget "$MANIFEST" "@.packages[$index].filename")"
    [ -n "$name" ] || break
    size="$(jget "$MANIFEST" "@.packages[$index].size")"
    sha="$(jget "$MANIFEST" "@.packages[$index].sha256")"
    safe_name "$name" || die "unsafe package filename"
    fetch "$RELEASE_BASE/$name" "$WORK_DIR/assets/$name" ||
      die "could not download package $name"
    verify_file "$WORK_DIR/assets/$name" "$size" "$sha" ||
      die "package verification failed: $name"
    index=$((index + 1))
  done
  [ "$index" = 3 ] || die "manifest does not contain the exact package set"
  download_manifest_asset "$RELEASE_BASE" "$MANIFEST" candidate_validator >/dev/null
  download_manifest_asset "$RELEASE_BASE" "$MANIFEST" transaction_supervisor >/dev/null
  download_manifest_asset "$RELEASE_BASE" "$MANIFEST" update_library >/dev/null
  download_manifest_asset "$RELEASE_BASE" "$MANIFEST" compatibility.status_0_7_9 >/dev/null
  cp "$MANIFEST" "$WORK_DIR/assets/router-release-manifest.json"
  cp "$SIGNATURE" "$WORK_DIR/assets/router-release-manifest.json.sig"
  ASSET_DIR="$WORK_DIR/assets"
  SUPERVISOR="$ASSET_DIR/$(jget "$MANIFEST" '@.transaction_supervisor.filename')"
  UPDATE_LIB="$ASSET_DIR/$(jget "$MANIFEST" '@.update_library.filename')"
fi

[ -s "$SUPERVISOR" ] && [ -s "$UPDATE_LIB" ] || die "verified supervisor assets are missing"
VALIDATOR="$ASSET_DIR/$(jget "$MANIFEST" '@.candidate_validator.filename')"
[ -s "$VALIDATOR" ] || die "verified candidate validator asset is missing"
sh -n "$SUPERVISOR" || die "transaction supervisor shell syntax is invalid"
sh -n "$UPDATE_LIB" || die "update library shell syntax is invalid"
sh -n "$VALIDATOR" || die "candidate validator shell syntax is invalid"
chmod 700 "$SUPERVISOR" "$UPDATE_LIB" "$VALIDATOR"
printf '%s\n' "$TRUSTED_KEY_ID" > "$WORK_DIR/release-key-id"

VPN_UI_UPDATE_LIB="$UPDATE_LIB" \
VPN_UI_UPDATE_SELF="$SUPERVISOR" \
VPN_UI_RELEASE_PUBLIC_KEY="$PUBLIC_KEY" \
VPN_UI_RELEASE_KEY_ID_FILE="$WORK_DIR/release-key-id" \
VPN_UI_EXISTING_CONFIG_RECOVERY="${ROUTER_UI_EXISTING_CONFIG_RECOVERY:-}" \
  "$SUPERVISOR" apply-local "$ASSET_DIR" "$MANIFEST" "$SIGNATURE" standalone no

printf 'Router UI %s installed through updater protocol v2.\n' \
  "$(jget "$MANIFEST" '@.app_version')"
