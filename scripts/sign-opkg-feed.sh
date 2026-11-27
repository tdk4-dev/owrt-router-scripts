#!/bin/sh
set -eu
[ -z "${ROUTER_UI_TIER0_GUARD_LOG:-}" ] || { printf 'signing:%s\n' "${0##*/}" >> "$ROUTER_UI_TIER0_GUARD_LOG"; exit 97; }
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
PKG_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/PACKAGE_VERSION" | tr -d '\r\n')"
case "$APP_VERSION" in *-rc.*) RELEASE_CHANNEL=candidate ;; *) RELEASE_CHANNEL=stable ;; esac
IPK_DIR="${IPK_DIR:?IPK_DIR is required}"
FEED_DIR="${FEED_DIR:?FEED_DIR is required}"
SOURCE_COMMIT="${SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
SOURCE_DIRTY="${SOURCE_DIRTY:-}"
STRICT_RELEASE="${STRICT_RELEASE:-0}"
PROJECT_PACKAGES="premier-router-core luci-app-premier-router premier-router-setup"
ROUTER_UI_RELEASE_ROOT="$ROOT_DIR"
export ROUTER_UI_RELEASE_ROOT
. "$ROOT_DIR/scripts/release-key-lib.sh"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "${APP_VERSION%%-rc.*}" = 0.7.11 ] || fail "feed signing is scoped to 0.7.11"
if [ -n "$(git -C "$ROOT_DIR" status --short)" ]; then actual_source_dirty=true; else actual_source_dirty=false; fi
if [ "$STRICT_RELEASE" = 1 ] && [ -n "$SOURCE_DIRTY" ] && [ "$SOURCE_DIRTY" != "$actual_source_dirty" ]; then
  fail "SOURCE_DIRTY disagrees with the checkout state"
fi
SOURCE_DIRTY="${SOURCE_DIRTY:-$actual_source_dirty}"
[ "$STRICT_RELEASE" != 1 ] || [ "$SOURCE_DIRTY" = false ] || fail "strict feed signing refuses dirty source"
case "$IPK_DIR:$FEED_DIR" in /*:/*) ;; *) fail "IPK_DIR and FEED_DIR must be absolute" ;; esac
pr_require_active_signing_key || exit 1
for tool in awk cmp gzip jq sha256sum tar; do command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"; done
[ -s "$FEED_DIR/Packages" ] && [ -s "$FEED_DIR/Packages.gz" ] || fail "unsigned feed indexes are missing"
gzip -dc "$FEED_DIR/Packages.gz" | cmp -s - "$FEED_DIR/Packages" || fail "Packages.gz differs from Packages"

packages='[]'
for package in $PROJECT_PACKAGES; do
  filename="${package}_${PKG_VERSION}_all.ipk"
  canonical="$IPK_DIR/$filename"
  feed="$FEED_DIR/$filename"
  [ -s "$canonical" ] && [ -s "$feed" ] || fail "missing canonical/feed package: $filename"
  cmp -s "$canonical" "$feed" || fail "feed package differs from canonical bytes: $filename"
  sha="$(sha256sum "$canonical" | awk '{print $1}')"
  size="$(wc -c < "$canonical" | tr -d ' ')"
  awk -v package="$package" -v version="$PKG_VERSION" -v filename="$filename" \
    -v sha="$sha" -v size="$size" '
      BEGIN { RS=""; FS="\n"; found=0 }
      {
        p=v=f=s=h=""
        for (i=1; i<=NF; i++) {
          if ($i ~ /^Package: /) p=substr($i,10)
          if ($i ~ /^Version: /) v=substr($i,10)
          if ($i ~ /^Filename: /) f=substr($i,11)
          if ($i ~ /^Size: /) s=substr($i,7)
          if ($i ~ /^SHA256sum: /) h=substr($i,12)
        }
        if (p==package && v==version && f==filename && s==size && h==sha) found++
      }
      END { exit found == 1 ? 0 : 1 }
    ' "$FEED_DIR/Packages" || fail "feed index metadata mismatch: $filename"
  object="$(jq -n --arg name "$package" --arg filename "$filename" \
    --arg version "$PKG_VERSION" --arg sha256 "$sha" --argjson size "$size" \
    '{name:$name,filename:$filename,version:$version,size:$size,sha256:$sha256}')"
  packages="$(printf '%s' "$packages" | jq --argjson object "$object" '. + [$object]')"
done

rm -f "$FEED_DIR/Packages.sig" "$FEED_DIR/feed-provenance.json" \
  "$FEED_DIR/feed-provenance.json.sig" "$FEED_DIR/SHA256SUMS"
"$USIGN_BIN" -S -m "$FEED_DIR/Packages" -s "$SIGNING_KEY" -x "$FEED_DIR/Packages.sig"
jq -n --arg version "$APP_VERSION" --arg package_version "$PKG_VERSION" \
  --arg source_commit "$SOURCE_COMMIT" --arg signing_key_id "$RELEASE_KEY_ID" \
  --arg signing_key_fingerprint "$RELEASE_KEY_FINGERPRINT" --arg channel "$RELEASE_CHANNEL" \
  --argjson source_dirty "$SOURCE_DIRTY" --argjson packages "$packages" \
  '{schema_version:1,kind:"opkg-feed",channel:$channel,app_version:$version,
    package_version:$package_version,source_commit:$source_commit,source_dirty:$source_dirty,
    signing_key_id:$signing_key_id,signing_key_fingerprint:$signing_key_fingerprint,
    packages:$packages}' | jq -S . > "$FEED_DIR/feed-provenance.json"
"$USIGN_BIN" -S -m "$FEED_DIR/feed-provenance.json" -s "$SIGNING_KEY" \
  -x "$FEED_DIR/feed-provenance.json.sig"
(
  cd "$FEED_DIR"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -print | LC_ALL=C sort | sed 's#^./##' |
    while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS
  sha256sum -c SHA256SUMS >/dev/null
)
printf 'Signed %s opkg feed with key %s (%s)\n' "$RELEASE_CHANNEL" "$RELEASE_KEY_ID" "$RELEASE_KEY_FINGERPRINT"
