#!/bin/sh
set -eu
umask 077

REPO="${ROUTER_UI_REPO:-tdk4-dev/owrt-router-scripts}"
REQUESTED_VERSION="${ROUTER_UI_VERSION:-}"
DISCOVERY_BASE="${ROUTER_UI_DISCOVERY_BASE:-https://github.com/$REPO/releases/latest/download}"
WORK_DIR="$(mktemp -d /tmp/router-ui-package-install.XXXXXX)"
TRUSTED_KEY_ID='test-21ff375c021d4c72'
TRUSTED_KEY_COMMENT='untrusted comment: DEVELOPMENT ONLY Router UI 0.7.11 test key'
TRUSTED_KEY_DATA='RWQh/zdcAh1Mcj/PUhA2hZ1LsFkip+XD1Z/dNfSM0FiTFhGV4c1vRDml'
PUBLIC_KEY="$WORK_DIR/release.pub"
OPENWRT_RELEASE_FILE="${ROUTER_UI_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}
cleanup() {
  case "$WORK_DIR" in /tmp/router-ui-package-install.*) rm -rf "$WORK_DIR" ;; esac
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
for tool in jsonfilter usign sha256sum tar mktemp; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
printf '%s\n%s\n' "$TRUSTED_KEY_COMMENT" "$TRUSTED_KEY_DATA" > "$PUBLIC_KEY"
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
  POINTER="$WORK_DIR/stable-channel.json"
  POINTER_SIG="$WORK_DIR/stable-channel.json.sig"
  if [ -n "$REQUESTED_VERSION" ]; then
    printf '%s' "$REQUESTED_VERSION" |
      grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(RC[0-9]+)?$' ||
      die "requested version is malformed"
    TAG="vpn-panel-v$REQUESTED_VERSION"
  else
    fetch "$DISCOVERY_BASE/stable-channel.json" "$POINTER" ||
      die "could not download the stable-channel pointer"
    fetch "$DISCOVERY_BASE/stable-channel.json.sig" "$POINTER_SIG" ||
      die "could not download the stable-channel signature"
    usign -q -V -p "$PUBLIC_KEY" -m "$POINTER" -x "$POINTER_SIG" ||
      die "stable-channel signature verification failed"
    [ "$(jget "$POINTER" '@.schema_version')" = 1 ] ||
      die "unsupported stable-channel schema"
    [ "$(jget "$POINTER" '@.channel')" = stable ] ||
      die "stable-channel metadata names another channel"
    [ "$(jget "$POINTER" '@.signing_key_id')" = "$TRUSTED_KEY_ID" ] ||
      die "stable-channel signing key ID mismatch"
    TAG="$(jget "$POINTER" '@.release_tag')"
    REQUESTED_VERSION="$(jget "$POINTER" '@.target_version')"
    [ "$TAG" = "vpn-panel-v$REQUESTED_VERSION" ] ||
      die "stable-channel tag/version mismatch"
  fi

  RELEASE_BASE="https://github.com/$REPO/releases/download/$TAG"
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
sh -n "$SUPERVISOR" || die "transaction supervisor shell syntax is invalid"
sh -n "$UPDATE_LIB" || die "update library shell syntax is invalid"
chmod 700 "$SUPERVISOR" "$UPDATE_LIB"
printf '%s\n' "$TRUSTED_KEY_ID" > "$WORK_DIR/release-key-id"

VPN_UI_UPDATE_LIB="$UPDATE_LIB" \
VPN_UI_UPDATE_SELF="$SUPERVISOR" \
VPN_UI_RELEASE_PUBLIC_KEY="$PUBLIC_KEY" \
VPN_UI_RELEASE_KEY_ID_FILE="$WORK_DIR/release-key-id" \
VPN_UI_EXISTING_CONFIG_RECOVERY="${ROUTER_UI_EXISTING_CONFIG_RECOVERY:-}" \
  "$SUPERVISOR" apply-local "$ASSET_DIR" "$MANIFEST" "$SIGNATURE" standalone no

printf 'Router UI %s installed through updater protocol v2.\n' \
  "$(jget "$MANIFEST" '@.app_version')"
