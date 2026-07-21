#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
PKG_VERSION="$APP_VERSION-${PKG_RELEASE:-1}"
IPK_DIR="${IPK_DIR:?IPK_DIR is required}"
OUT_DIR="${OUT_DIR:?OUT_DIR is required}"
USIGN_BIN="${USIGN_BIN:-usign}"
SOURCE_COMMIT="${SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT_DIR" show -s --format=%ct "$SOURCE_COMMIT")}"
PROJECT_PACKAGES="premier-router-core luci-app-premier-router premier-router-setup"
ROUTER_UI_RELEASE_ROOT="$ROOT_DIR"
export ROUTER_UI_RELEASE_ROOT
. "$ROOT_DIR/scripts/release-key-lib.sh"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$APP_VERSION" = 0.7.11 ] || fail "installed package-set staging is scoped to 0.7.11"
pr_require_active_signing_key || exit 1
mkdir -p "$OUT_DIR"

index=0
packages='[]'
for package in $PROJECT_PACKAGES; do
  file="$IPK_DIR/${package}_${PKG_VERSION}_all.ipk"
  [ -s "$file" ] || fail "missing canonical package: $package"
  order=$((index + 1))
  object="$(jq -n --arg name "$package" --arg filename "$(basename "$file")" \
    --arg version "$PKG_VERSION" --arg architecture all --argjson install_order "$order" \
    --argjson size "$(wc -c < "$file" | tr -d ' ')" \
    --arg sha256 "$(sha256sum "$file" | awk '{print $1}')" \
    '{name:$name,filename:$filename,version:$version,architecture:$architecture,
      install_order:$install_order,size:$size,sha256:$sha256}')"
  packages="$(printf '%s' "$packages" | jq --argjson object "$object" '. + [$object]')"
  index=$((index + 1))
done
[ "$index" = 3 ] || fail "installed package set is incomplete"

manifest="$OUT_DIR/installed-manifest.json"
jq -n --arg app_version "$APP_VERSION" --arg package_version "$PKG_VERSION" \
  --arg source_commit "$SOURCE_COMMIT" --argjson source_date_epoch "$SOURCE_DATE_EPOCH" \
  --arg signing_key_id "$RELEASE_KEY_ID" \
  --arg signing_key_fingerprint "$RELEASE_KEY_FINGERPRINT" \
  --argjson packages "$packages" \
  '{schema_version:1,kind:"installed-package-set",app_version:$app_version,
    package_version:$package_version,source_commit:$source_commit,source_dirty:false,
    source_date_epoch:$source_date_epoch,signing_key_id:$signing_key_id,
    signing_key_fingerprint:$signing_key_fingerprint,packages:$packages}' |
  jq -S . > "$manifest"
"$USIGN_BIN" -S -m "$manifest" -s "$SIGNING_KEY" -x "$OUT_DIR/installed-manifest.json.sig"
cp "$RELEASE_PUBLIC_KEY" "$OUT_DIR/release.pub"
printf '%s\n' "$RELEASE_KEY_ID" > "$OUT_DIR/release-key-id"
for package in $PROJECT_PACKAGES; do cp "$IPK_DIR/${package}_${PKG_VERSION}_all.ipk" "$OUT_DIR/"; done
tar -xzOf "$IPK_DIR/premier-router-core_${PKG_VERSION}_all.ipk" ./data.tar.gz |
  tar -xzOf - ./usr/libexec/premier-router/candidate-validator > "$OUT_DIR/router-candidate-validator"
chmod 755 "$OUT_DIR/router-candidate-validator"
(
  cd "$OUT_DIR"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -print | LC_ALL=C sort | sed 's#^\./##' |
    while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS
  sha256sum -c SHA256SUMS >/dev/null
)
