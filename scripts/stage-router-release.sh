#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
PKG_RELEASE="${PKG_RELEASE:-1}"
PKG_VERSION="$APP_VERSION-$PKG_RELEASE"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/dist}"
RELEASE_DIR="${RELEASE_DIR:-$OUT_ROOT/release-v$APP_VERSION}"
SOURCE_COMMIT="${SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)}"
SOURCE_DIRTY="false"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

for tool in awk cp date find mkdir sed sha256sum sort wc; do
  need "$tool"
done

have_project_ipks() {
  [ -f "$OUT_ROOT/ipk/router-ui-packages.txt" ] || return 1
  for pkg in premier-router-core luci-app-premier-router premier-router-setup; do
    [ -f "$OUT_ROOT/ipk/${pkg}_${PKG_VERSION}_all.ipk" ] || return 1
  done
  [ -f "$OUT_ROOT/opkg-feed/Packages" ] || return 1
  [ -f "$OUT_ROOT/opkg-feed/Packages.gz" ] || return 1
  return 0
}

if [ -n "$(git -C "$ROOT_DIR" status --short 2>/dev/null)" ]; then
  SOURCE_DIRTY="true"
fi

if have_project_ipks; then
  printf 'Using existing project IPKs from %s/ipk\n' "$OUT_ROOT"
else
  "$ROOT_DIR/scripts/build-openwrt-ipks.sh"
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR/packages" "$RELEASE_DIR/opkg-feed"

cp "$ROOT_DIR"/dist/ipk/*.ipk "$RELEASE_DIR/packages/"
cp "$ROOT_DIR/dist/ipk/router-ui-packages.txt" "$RELEASE_DIR/router-ui-packages.txt"
cp "$ROOT_DIR/dist/opkg-feed/Packages" "$RELEASE_DIR/opkg-feed/Packages"
cp "$ROOT_DIR/dist/opkg-feed/Packages.gz" "$RELEASE_DIR/opkg-feed/Packages.gz"
cp "$ROOT_DIR"/dist/opkg-feed/*.ipk "$RELEASE_DIR/opkg-feed/"
cp "$ROOT_DIR/install-router-ui-release.sh" "$RELEASE_DIR/install-router-ui-release.sh"
chmod 755 "$RELEASE_DIR/install-router-ui-release.sh"
printf '%s\n' "$APP_VERSION" > "$RELEASE_DIR/vpn-ui-version.txt"
cp "$ROOT_DIR/luci-vpn-ui/RELEASE_NOTES.md" "$RELEASE_DIR/vpn-ui-changelog.txt"
date -u '+%B %d, %Y' > "$RELEASE_DIR/vpn-ui-release-date.txt"

find "$OUT_ROOT" -maxdepth 1 -type f -name "premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-*.tar.gz" |
  sort |
  while IFS= read -r image; do
    cp "$image" "$RELEASE_DIR/"
  done

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

asset_type() {
  case "$1" in
    *.ipk) printf 'package' ;;
    Packages|Packages.gz) printf 'opkg-feed-index' ;;
    *.tar.gz) printf 'image-archive' ;;
    install-router-ui-release.sh) printf 'installer' ;;
    router-ui-packages.txt|vpn-ui-version.txt|vpn-ui-changelog.txt|vpn-ui-release-date.txt) printf 'metadata' ;;
    *) printf 'metadata' ;;
  esac
}

target_from_name() {
  case "$1" in
    *x86-64*) printf 'x86/64 generic' ;;
    *xiaomi-ax3000t-stock*) printf 'mediatek/filogic xiaomi_mi-router-ax3000t-stock' ;;
    *xiaomi-ax3000t-ubootmod*) printf 'mediatek/filogic xiaomi_mi-router-ax3000t-ubootmod' ;;
    *) printf '' ;;
  esac
}

manifest="$RELEASE_DIR/router-release-manifest.json"
{
  printf '{\n'
  printf '  "project": "premier-router",\n'
  printf '  "version": "%s",\n' "$APP_VERSION"
  printf '  "package_version": "%s",\n' "$PKG_VERSION"
  printf '  "openwrt_version": "%s",\n' "$OPENWRT_VERSION"
  printf '  "source_commit": "%s",\n' "$SOURCE_COMMIT"
  printf '  "source_dirty": %s,\n' "$SOURCE_DIRTY"
  printf '  "generated_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '  "minimum_upgrade_version": "0.7.5",\n'
  printf '  "assets": [\n'
  first=1
  find "$RELEASE_DIR" -type f ! -name 'router-release-manifest.json' ! -name 'SHA256SUMS' |
    sort |
    while IFS= read -r path; do
      rel="${path#$RELEASE_DIR/}"
      name="$(basename "$path")"
      sha="$(sha256sum "$path" | awk '{ print $1 }')"
      size="$(wc -c < "$path" | tr -d ' ')"
      type="$(asset_type "$name")"
      target="$(target_from_name "$name")"
      if [ "$first" = "1" ]; then
        first=0
      else
        printf ',\n'
      fi
      printf '    {"filename":"'
      printf '%s' "$rel" | json_escape
      printf '","artifact_type":"%s","project_version":"%s","openwrt_version":"%s","target":"%s","sha256":"%s","size":%s,"source_commit":"%s"}' \
        "$type" "$APP_VERSION" "$OPENWRT_VERSION" "$target" "$sha" "$size" "$SOURCE_COMMIT"
    done
  printf '\n  ]\n'
  printf '}\n'
} > "$manifest"

(
  cd "$RELEASE_DIR"
  find . -type f ! -name SHA256SUMS -print | sort | sed 's#^\./##' |
    while IFS= read -r file; do
      sha256sum "$file"
    done > SHA256SUMS
)

printf 'Staged package-first release directory: %s\n' "$RELEASE_DIR"
