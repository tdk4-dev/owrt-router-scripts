#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION")"
PKG_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/PACKAGE_VERSION")"
USIGN_BIN="${TEST_USIGN_BIN:-$(command -v usign || true)}"
[ -x "$USIGN_BIN" ] || { printf 'usign is required for release-v2 tests\n' >&2; exit 1; }
export USIGN_BIN
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-v2-test.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_DATE_EPOCH="$(git -C "$ROOT_DIR" show -s --format=%ct HEAD)"
SECRET="$TMP_ROOT/test.sec"
PUBLIC="$TMP_ROOT/test.pub"
"$USIGN_BIN" -G -s "$SECRET" -p "$PUBLIC" -c 'Router UI protocol v2 ephemeral test key'
KEY_ID="test-$($USIGN_BIN -F -p "$PUBLIC")"
TRUST_ROOT="$TMP_ROOT/trust-root"
TRUST_REGISTRY="$TRUST_ROOT/keys/release/trusted-keys.json"
mkdir -p "$TRUST_ROOT/keys/release"
cp "$PUBLIC" "$TRUST_ROOT/keys/release/test.pub"
jq -n --arg key_id "$KEY_ID" --arg fingerprint "$($USIGN_BIN -F -p "$PUBLIC")" \
  '{schema_version:1,active_key_id:$key_id,keys:[{
    key_id:$key_id,fingerprint:$fingerprint,status:"active",
    creation_date:"2026-07-21",public_key_path:"keys/release/test.pub"}]}' \
  > "$TRUST_REGISTRY"
ROUTER_UI_TRUSTED_KEYS_FILE="$TRUST_REGISTRY"
ROUTER_UI_TRUST_ROOT="$TRUST_ROOT"
ROUTER_UI_SIGNING_KEY_ID="$KEY_ID"
ROUTER_UI_SIGNING_KEY="$SECRET"
export ROUTER_UI_TRUSTED_KEYS_FILE ROUTER_UI_TRUST_ROOT
export ROUTER_UI_SIGNING_KEY_ID ROUTER_UI_SIGNING_KEY

build_once() {
  label="$1"
  SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    BUILD_DIR="$TMP_ROOT/build-$label" OUT_DIR="$TMP_ROOT/ipk-$label" \
    FEED_DIR="$TMP_ROOT/feed-$label" "$ROOT_DIR/scripts/build-openwrt-ipks.sh" >/dev/null
}
build_once a
build_once b
diff -u "$TMP_ROOT/ipk-a/router-ui-packages.txt" "$TMP_ROOT/ipk-b/router-ui-packages.txt"
for file in "$TMP_ROOT/ipk-a"/*.ipk; do
  cmp -s "$file" "$TMP_ROOT/ipk-b/$(basename "$file")" || {
    printf 'nondeterministic IPK: %s\n' "$(basename "$file")" >&2
    exit 1
  }
done

IPK_DIR="$TMP_ROOT/ipk-a" FEED_DIR="$TMP_ROOT/feed-a" \
  SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false USIGN_BIN="$USIGN_BIN" \
  "$ROOT_DIR/scripts/sign-opkg-feed.sh" >/dev/null
IPK_DIR="$TMP_ROOT/ipk-a" OUT_DIR="$TMP_ROOT/installed-set" \
  SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  USIGN_BIN="$USIGN_BIN" "$ROOT_DIR/scripts/stage-installed-package-set.sh"

OUT_ROOT="$TMP_ROOT/stage-root" IPK_DIR="$TMP_ROOT/ipk-a" \
  FEED_DIR="$TMP_ROOT/feed-a" INSTALLED_SET_DIR="$TMP_ROOT/installed-set" \
  RELEASE_DIR="$TMP_ROOT/release" SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false \
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" USIGN_BIN="$USIGN_BIN" \
  "$ROOT_DIR/scripts/stage-router-release.sh" >/dev/null
jq -e '
  .app_version == "0.7.11-rc.6" and .package_version == "0.7.11~rc6-1" and
  any(.transitions[]; .source_version == "0.7.11-rc.5" and
    .source_protocol == 2 and .mode == "package-v2-rc") and
  any(.transitions[]; .source_version == "0.7.11-rc.6" and
    .source_protocol == 2 and .mode == "package-v2-rc") and
  (any(.transitions[]; .source_version == "0.7.11-rc.4" and
    .source_protocol == 2) | not)
' "$TMP_ROOT/release/router-release-manifest.json" >/dev/null

# A caller may itself be a strict candidate job. The deliberately
# version-mutated synthetic successor must remain a bounded disposable VM
# fixture instead of inheriting strict candidate staging policy.
STRICT_RELEASE=1 OUTPUT_DIR="$TMP_ROOT/synthetic-next" \
  SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  "$ROOT_DIR/tests/vm/build-synthetic-next.sh" >/dev/null
jq -e --arg source "$SOURCE_COMMIT" '
  .app_version == "0.7.11" and .package_version == "0.7.11-1" and
  .source_commit == $source and .source_dirty == false and
  any(.transitions[]; .source_version == "0.7.11-rc.6" and
    .source_protocol == 2 and .mode == "package-v2-rc")
' "$TMP_ROOT/synthetic-next/router-release-manifest.json" >/dev/null

RELEASE_DIR="$TMP_ROOT/release" \
  EXPECTED_RELEASE_KEY_ID="$KEY_ID" EXPECTED_SOURCE_COMMIT="$SOURCE_COMMIT" \
  USIGN_BIN="$USIGN_BIN" "$ROOT_DIR/scripts/validate-staged-release.sh" >/dev/null
cmp -s "$TMP_ROOT/release/rd23-storage-geometry.json" \
  "$ROOT_DIR/release/rd23-storage-geometry.json"
jq -e --arg sha "$(sha256sum "$TMP_ROOT/release/rd23-storage-geometry.json" | awk '{print $1}')" \
  '.rd23_storage_geometry.filename == "rd23-storage-geometry.json" and
    .rd23_storage_geometry.sha256 == $sha' \
  "$TMP_ROOT/release/router-release-manifest.json" >/dev/null

mkdir -p "$TMP_ROOT/bootstrap-root/etc" "$TMP_ROOT/bootstrap-bin"
printf "DISTRIB_RELEASE='24.10.5'\nDISTRIB_TARGET='x86/64'\n" > \
  "$TMP_ROOT/bootstrap-root/etc/openwrt_release"
cat > "$TMP_ROOT/bootstrap-bin/jsonfilter" <<'EOF'
#!/bin/sh
set -eu
file= expression=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -i) file="$2"; shift 2 ;;
    -e) expression="$2"; shift 2 ;;
    *) exit 2 ;;
  esac
done
query="$(printf '%s' "$expression" | sed 's/^@//')"
jq -r "$query | if . == null then empty else . end" "$file"
EOF
cat > "$TMP_ROOT/bootstrap-bin/opkg" <<'EOF'
#!/bin/sh
case "${1:-}" in
  status)
    if [ -n "${FAKE_OPKG_INSTALLED_PACKAGE:-}" ] &&
      [ "${2:-}" = "$FAKE_OPKG_INSTALLED_PACKAGE" ]; then
      printf 'Package: %s\nVersion: %s\nStatus: install user installed\n' \
        "$2" "${FAKE_OPKG_VERSION:-$BOOTSTRAP_TEST_PKG_VERSION}"
    fi
    exit 0
    ;;
  *) exit 2 ;;
esac
EOF
cat > "$TMP_ROOT/bootstrap-bin/sysupgrade" <<'EOF'
#!/bin/sh
set -eu
if [ "${BOOTSTRAP_TEST_SYSUPGRADE_MODE:-fail}" = backup ]; then
  [ "${1:-}" = -b ] && [ -n "${2:-}" ]
  tar -czf "$2" -C "$BOOTSTRAP_TEST_ROOT" etc/firstboot-wizard/complete
  exit 0
fi
exit 2
EOF
chmod 755 "$TMP_ROOT/bootstrap-bin/jsonfilter" "$TMP_ROOT/bootstrap-bin/opkg" \
  "$TMP_ROOT/bootstrap-bin/sysupgrade"
run_bootstrap_assets() {
  PATH="$TMP_ROOT/bootstrap-bin:$(dirname "$USIGN_BIN"):$PATH" \
    PREMIER_ROUTER_HOST_TEST=1 ROUTER_UI_TEST_VALIDATE_ASSETS_ONLY=1 \
    ROUTER_UI_TEST_PERSISTENT_FREE_KIB="${TEST_BOOTSTRAP_PERSISTENT_FREE_KIB:-999999}" \
    ROUTER_UI_TEST_TMP_FREE_KIB="${TEST_BOOTSTRAP_TMP_FREE_KIB:-999999}" \
    BOOTSTRAP_TEST_PKG_VERSION="$PKG_VERSION" \
    ROUTER_UI_ROOT_PREFIX="$TMP_ROOT/bootstrap-root" \
    ROUTER_UI_ASSET_DIR="$TMP_ROOT/release" \
    ROUTER_UI_OPKG_BIN="$TMP_ROOT/bootstrap-bin/opkg" \
    ROUTER_UI_SYSUPGRADE_BIN="$TMP_ROOT/bootstrap-bin/sysupgrade" \
    "$TMP_ROOT/release/bootstrap-router-ui-ipk-install.sh"
}
run_bootstrap_assets >/dev/null
[ ! -e "$TMP_ROOT/bootstrap-root/etc/firstboot-wizard" ]

run_bootstrap_until_update_failure() {
  PATH="$TMP_ROOT/bootstrap-bin:$(dirname "$USIGN_BIN"):$PATH" \
    PREMIER_ROUTER_HOST_TEST=1 \
    ROUTER_UI_TEST_PERSISTENT_FREE_KIB=999999 \
    ROUTER_UI_TEST_TMP_FREE_KIB=999999 \
    BOOTSTRAP_TEST_PKG_VERSION="$PKG_VERSION" \
    BOOTSTRAP_TEST_SYSUPGRADE_MODE=backup \
    BOOTSTRAP_TEST_ROOT="$TMP_ROOT/bootstrap-root" \
    ROUTER_UI_ROOT_PREFIX="$TMP_ROOT/bootstrap-root" \
    ROUTER_UI_ASSET_DIR="$TMP_ROOT/release" \
    ROUTER_UI_OPKG_BIN="$TMP_ROOT/bootstrap-bin/opkg" \
    ROUTER_UI_SYSUPGRADE_BIN="$TMP_ROOT/bootstrap-bin/sysupgrade" \
    "$TMP_ROOT/release/bootstrap-router-ui-ipk-install.sh"
}
if run_bootstrap_until_update_failure > "$TMP_ROOT/bootstrap-update-failure.log" 2>&1; then
  printf 'initial-install bootstrap unexpectedly passed the forced opkg update failure\n' >&2
  exit 1
fi
grep -q 'package index update failed' "$TMP_ROOT/bootstrap-update-failure.log"
[ -f "$TMP_ROOT/bootstrap-root/etc/firstboot-wizard/complete" ]
bootstrap_state_mode="$(stat -c '%a' "$TMP_ROOT/bootstrap-root/etc/firstboot-wizard" \
  2>/dev/null || stat -f '%Lp' "$TMP_ROOT/bootstrap-root/etc/firstboot-wizard")"
bootstrap_complete_mode="$(stat -c '%a' \
  "$TMP_ROOT/bootstrap-root/etc/firstboot-wizard/complete" 2>/dev/null ||
  stat -f '%Lp' "$TMP_ROOT/bootstrap-root/etc/firstboot-wizard/complete")"
[ "$bootstrap_state_mode" = 700 ]
[ "$bootstrap_complete_mode" = 600 ]
bootstrap_backup="$TMP_ROOT/bootstrap-root/root/premier-router-updates/initial-ipk-install-$APP_VERSION/openwrt-configuration-recovery.tar.gz"
tar -tzf "$bootstrap_backup" | grep -Fqx 'etc/firstboot-wizard/complete'
known_good_dir="$TMP_ROOT/bootstrap-root/root/premier-router-updates/known-good/$(sha256sum \
  "$TMP_ROOT/release/installed-manifest.json" | awk '{print $1}')"
[ -f "$known_good_dir/bootstrap-incomplete" ]
[ ! -e "$TMP_ROOT/bootstrap-root/etc/premier-router/installed-manifest.json" ]

rm -rf "$TMP_ROOT/bootstrap-root/etc/firstboot-wizard" \
  "$TMP_ROOT/bootstrap-root/root/premier-router-updates"

cp "$TMP_ROOT/bootstrap-root/etc/openwrt_release" "$TMP_ROOT/openwrt_release.good"
printf "DISTRIB_RELEASE='23.05.5'\nDISTRIB_TARGET='x86/64'\n" > \
  "$TMP_ROOT/bootstrap-root/etc/openwrt_release"
if run_bootstrap_assets >"$TMP_ROOT/bootstrap-old-openwrt.log" 2>&1; then
  printf 'initial-install bootstrap accepted unsupported OpenWrt 23.05\n' >&2
  exit 1
fi
grep -q 'outside supported range' "$TMP_ROOT/bootstrap-old-openwrt.log"

printf "DISTRIB_RELEASE='24.10.5'\nDISTRIB_TARGET='ath79/generic'\n" > \
  "$TMP_ROOT/bootstrap-root/etc/openwrt_release"
if run_bootstrap_assets >"$TMP_ROOT/bootstrap-target.log" 2>&1; then
  printf 'initial-install bootstrap accepted an unsupported target\n' >&2
  exit 1
fi
grep -q 'unsupported OpenWrt target' "$TMP_ROOT/bootstrap-target.log"
cp "$TMP_ROOT/openwrt_release.good" "$TMP_ROOT/bootstrap-root/etc/openwrt_release"

if TEST_BOOTSTRAP_PERSISTENT_FREE_KIB=1 run_bootstrap_assets \
  >"$TMP_ROOT/bootstrap-space.log" 2>&1; then
  printf 'initial-install bootstrap accepted insufficient persistent space\n' >&2
  exit 1
fi
unset TEST_BOOTSTRAP_PERSISTENT_FREE_KIB
grep -q 'insufficient persistent space' "$TMP_ROOT/bootstrap-space.log"

FAKE_OPKG_INSTALLED_PACKAGE=premier-router-core run_bootstrap_assets >/dev/null
if FAKE_OPKG_INSTALLED_PACKAGE=premier-router-core FAKE_OPKG_VERSION=0.7.10-1 \
  run_bootstrap_assets >"$TMP_ROOT/bootstrap-version.log" 2>&1; then
  printf 'initial-install bootstrap accepted a conflicting installed package\n' >&2
  exit 1
fi
grep -q 'different version' "$TMP_ROOT/bootstrap-version.log"

refresh_release_sums() {
  (
    cd "$TMP_ROOT/release"
    find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name SHA256SUMS.sig -print |
      sed 's#^\./##' | LC_ALL=C sort |
      while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS
  )
  rm -f "$TMP_ROOT/release/SHA256SUMS.sig"
  "$USIGN_BIN" -S -m "$TMP_ROOT/release/SHA256SUMS" -s "$SECRET" \
    -x "$TMP_ROOT/release/SHA256SUMS.sig"
}

shim_name="premier-router-$APP_VERSION-openwrt-24.10.5-xiaomi-ax3000t-stock.tar.gz"
shim="$TMP_ROOT/release/$shim_name"
mkdir -p "$TMP_ROOT/diagnostic-shim/router-ui-rd23-stock"
printf '%s\n' '{"schema_version":1,"diagnostic_geometry_only":true}' \
  > "$TMP_ROOT/diagnostic-shim/router-ui-rd23-stock/image-provenance.json"
tar -czf "$shim" -C "$TMP_ROOT/diagnostic-shim" router-ui-rd23-stock
refresh_release_sums
if RELEASE_DIR="$TMP_ROOT/release" \
  EXPECTED_RELEASE_KEY_ID="$KEY_ID" EXPECTED_SOURCE_COMMIT="$SOURCE_COMMIT" \
  USIGN_BIN="$USIGN_BIN" "$ROOT_DIR/scripts/validate-staged-release.sh" \
  >"$TMP_ROOT/diagnostic-shim.log" 2>&1; then
  printf 'release validation accepted a diagnostic geometry-only image shim\n' >&2
  exit 1
fi
grep -q 'diagnostic geometry-only archive is not a release image' \
  "$TMP_ROOT/diagnostic-shim.log"
rm -f "$shim"
refresh_release_sums

cp "$TMP_ROOT/release/rd23-storage-geometry.json" "$TMP_ROOT/storage-geometry.good"
printf 'corruption\n' >> "$TMP_ROOT/release/rd23-storage-geometry.json"
if RELEASE_DIR="$TMP_ROOT/release" \
  EXPECTED_RELEASE_KEY_ID="$KEY_ID" EXPECTED_SOURCE_COMMIT="$SOURCE_COMMIT" \
  USIGN_BIN="$USIGN_BIN" "$ROOT_DIR/scripts/validate-staged-release.sh" \
  >"$TMP_ROOT/storage-geometry.log" 2>&1; then
  printf 'release validation accepted corrupted RD23 storage geometry\n' >&2
  exit 1
fi
grep -Eq 'SHA256SUMS validation failed|manifest RD23 storage geometry hash mismatch' \
  "$TMP_ROOT/storage-geometry.log"
mv "$TMP_ROOT/storage-geometry.good" "$TMP_ROOT/release/rd23-storage-geometry.json"

if RELEASE_DIR="$TMP_ROOT/release" \
  EXPECTED_RELEASE_KEY_ID="$KEY_ID" EXPECTED_SOURCE_COMMIT="$SOURCE_COMMIT" \
  STRICT_RELEASE=1 USIGN_BIN="$USIGN_BIN" "$ROOT_DIR/scripts/validate-staged-release.sh" \
  >"$TMP_ROOT/strict.log" 2>&1; then
  printf 'strict validation accepted an ephemeral test key\n' >&2
  exit 1
fi
grep -q 'strict release refuses a development key ID' "$TMP_ROOT/strict.log"

MANIFEST="$TMP_ROOT/release/router-release-manifest.json"
SIGNATURE="$TMP_ROOT/release/router-release-manifest.json.sig"
OPENWRT_RELEASE="$TMP_ROOT/openwrt_release"
printf "DISTRIB_RELEASE='24.10.5'\nDISTRIB_TARGET='x86/64'\n" > "$OPENWRT_RELEASE"
validate_manifest() {
  PREMIER_ROUTER_HOST_TEST=1 PR_OPENWRT_RELEASE_FILE="$OPENWRT_RELEASE" \
    sh -c '. "$1"; pr_manifest_validate "$2" "$3" 0.7.10 1 "$4"' sh \
    "$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" "$1" \
    "$KEY_ID" "$($USIGN_BIN -F -p "$PUBLIC")"
}
reject_filter() {
  name="$1"
  filter="$2"
  jq "$filter" "$MANIFEST" > "$TMP_ROOT/reject.json"
  if validate_manifest "$TMP_ROOT/reject.json" >/dev/null 2>&1; then
    printf 'manifest mutation was accepted: %s\n' "$name" >&2
    exit 1
  fi
}
validate_manifest "$MANIFEST" >/dev/null
reject_filter malformed-version '.app_version="0.7"'
reject_filter unsupported-schema '.schema_version=99'
reject_filter unsupported-protocol '.update_protocol=3'
reject_filter dirty-provenance '.source_dirty=true'
reject_filter signing-fingerprint '.signing_key_fingerprint="0000000000000000"'
reject_filter missing-package '.packages=.packages[0:2]'
reject_filter extra-package '.packages += [.packages[0]]'
reject_filter duplicate-package '.packages[1]=.packages[0]'
reject_filter unsafe-filename '.packages[0].filename="../evil.ipk"'
reject_filter absolute-filename '.packages[0].filename="/tmp/evil.ipk"'
reject_filter architecture '.packages[0].architecture="mips"'
reject_filter unsupported-source '.transitions |= map(select(.source_version != "0.7.10"))'
reject_filter target-mismatch '.supported_targets=["mediatek/filogic"]'

"$USIGN_BIN" -q -V -p "$PUBLIC" -m "$MANIFEST" -x "$SIGNATURE"
cp "$SIGNATURE" "$TMP_ROOT/bad.sig"
printf 'x' >> "$TMP_ROOT/bad.sig"
if "$USIGN_BIN" -q -V -p "$PUBLIC" -m "$MANIFEST" -x "$TMP_ROOT/bad.sig"; then
  printf 'usign accepted a corrupted signature\n' >&2
  exit 1
fi
"$USIGN_BIN" -G -s "$TMP_ROOT/wrong.sec" -p "$TMP_ROOT/wrong.pub" -c 'wrong key'
if "$USIGN_BIN" -q -V -p "$TMP_ROOT/wrong.pub" -m "$MANIFEST" -x "$SIGNATURE"; then
  printf 'usign accepted a wrong key\n' >&2
  exit 1
fi

VPN_UI_UPDATE_SOURCE_ONLY=1 VPN_UI_UPDATE_LIB="$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" \
  PREMIER_ROUTER_HOST_TEST=1 sh -c '. "$1"; validate_asset_set "$2" "$3"' sh \
  "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update" "$TMP_ROOT/release" "$MANIFEST"
cp "$TMP_ROOT/release/premier-router-core_${PKG_VERSION}_all.ipk" "$TMP_ROOT/core.good"
printf 'corruption' >> "$TMP_ROOT/release/premier-router-core_${PKG_VERSION}_all.ipk"
if VPN_UI_UPDATE_SOURCE_ONLY=1 \
  VPN_UI_UPDATE_LIB="$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" \
  PREMIER_ROUTER_HOST_TEST=1 sh -c '. "$1"; validate_asset_set "$2" "$3"' sh \
  "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update" "$TMP_ROOT/release" "$MANIFEST"; then
  printf 'asset validation accepted a wrong hash/size\n' >&2
  exit 1
fi
mv "$TMP_ROOT/core.good" "$TMP_ROOT/release/premier-router-core_${PKG_VERSION}_all.ipk"

validator_root="$TMP_ROOT/installed-validator-root"
validator_bin="$TMP_ROOT/installed-validator-bin"
validator_log="$TMP_ROOT/installed-validator-vpn-ui.log"
mkdir -p "$validator_root" "$validator_root/etc/premier-router" "$validator_bin"
for ipk in "$TMP_ROOT/ipk-a"/*.ipk; do
  tar -xzOf "$ipk" ./data.tar.gz | tar -xzf - -C "$validator_root"
done
cp "$TMP_ROOT/installed-set/installed-manifest.json" \
  "$validator_root/etc/premier-router/installed-manifest.json"
cat > "$validator_bin/opkg" <<'EOF'
#!/bin/sh
set -eu
case "${1:-}" in
  status)
    case "${2:-}" in
      premier-router-core|luci-app-premier-router|premier-router-setup)
        printf 'Package: %s\nVersion: %s\nStatus: install user installed\n' \
          "$2" "$VALIDATOR_TEST_PKG_VERSION"
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
cat > "$validator_bin/vpn-ui" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "${1:-}" >> "$VALIDATOR_VPN_UI_LOG"
case "${1:-}" in
  vpn-summary) printf '%s\n' '{"ok":true}' ;;
  check) exit 99 ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$validator_bin/opkg" "$validator_bin/vpn-ui"
PATH="$TMP_ROOT/bootstrap-bin:$PATH" \
  PREMIER_ROUTER_HOST_TEST=1 \
  PREMIER_ROUTER_ROOT="$validator_root" \
  PREMIER_ROUTER_UPDATE_LIB="$validator_root/usr/libexec/premier-router/update-lib.sh" \
  PREMIER_ROUTER_OPKG_BIN="$validator_bin/opkg" \
  PREMIER_ROUTER_VPN_UI_BIN="$validator_bin/vpn-ui" \
  PREMIER_ROUTER_INSTALLED_MANIFEST="$validator_root/etc/premier-router/installed-manifest.json" \
  PREMIER_ROUTER_BUILD_INFO="$validator_root/usr/share/premier-router/build-info" \
  VALIDATOR_TEST_PKG_VERSION="$PKG_VERSION" \
  VALIDATOR_VPN_UI_LOG="$validator_log" \
  "$validator_root/usr/libexec/premier-router/candidate-validator" \
    --manifest "$validator_root/etc/premier-router/installed-manifest.json" \
    --source-version "$APP_VERSION" --phase installed >/dev/null
grep -Fqx 'vpn-summary' "$validator_log"
! grep -Fqx 'check' "$validator_log"

owned_index=0
for ipk in "$TMP_ROOT/ipk-a"/*.ipk; do
  owned_index=$((owned_index + 1))
  owned_root="$TMP_ROOT/owned-$owned_index"
  mkdir -p "$owned_root"
  tar -xzOf "$ipk" ./data.tar.gz | tar -xzf - -C "$owned_root"
  (cd "$owned_root" && find . \( -type f -o -type l \) -print | LC_ALL=C sort)
done | LC_ALL=C sort | uniq -d > "$TMP_ROOT/duplicate-owned-paths"
[ ! -s "$TMP_ROOT/duplicate-owned-paths" ] || {
  cat "$TMP_ROOT/duplicate-owned-paths" >&2
  printf 'project IPKs overlap ownership\n' >&2
  exit 1
}
tar -xzOf "$TMP_ROOT/ipk-a/premier-router-core_${PKG_VERSION}_all.ipk" ./control.tar.gz |
  tar -xzOf - ./conffiles > "$TMP_ROOT/conffiles"
[ "$(cat "$TMP_ROOT/conffiles")" = /etc/vpn-ui-update.conf ] || exit 1
tar -xzOf "$TMP_ROOT/ipk-a/premier-router-core_${PKG_VERSION}_all.ipk" ./control.tar.gz |
  tar -xzOf - ./control > "$TMP_ROOT/core-control"
grep -Fqx "Version: $PKG_VERSION" "$TMP_ROOT/core-control"
grep -Fqx "X-Premier-App-Version: $APP_VERSION" "$TMP_ROOT/core-control"
grep -Fqx 'X-Premier-Release-Channel: candidate' "$TMP_ROOT/core-control"
grep -Eq '^Depends: .*coreutils-nohup' "$TMP_ROOT/core-control"
grep -Eq '^Depends: .*ucode-mod-fs' "$TMP_ROOT/core-control"
grep -Eq '^Depends: .*ucode' "$TMP_ROOT/core-control"
tar -xzOf "$TMP_ROOT/ipk-a/premier-router-core_${PKG_VERSION}_all.ipk" ./data.tar.gz |
  tar -tzf - | grep -Fq './usr/libexec/premier-router/xray-overlay.uc'
tar -xzOf "$TMP_ROOT/ipk-a/premier-router-setup_${PKG_VERSION}_all.ipk" ./control.tar.gz |
  tar -xzOf - ./preinst > "$TMP_ROOT/setup-preinst"
grep -Fq '[ -n "${IPKG_INSTROOT:-}" ] && exit 0' "$TMP_ROOT/setup-preinst"
grep -Fq 'STATE_DIR=/etc/firstboot-wizard' "$TMP_ROOT/setup-preinst"
sed "s|STATE_DIR=/etc/firstboot-wizard|STATE_DIR='$TMP_ROOT/setup-state'|" \
  "$TMP_ROOT/setup-preinst" > "$TMP_ROOT/setup-preinst-test"
chmod 755 "$TMP_ROOT/setup-preinst-test"
IPKG_INSTROOT="$TMP_ROOT/image-root" sh "$TMP_ROOT/setup-preinst-test"
[ ! -e "$TMP_ROOT/setup-state" ]
mkdir -p "$TMP_ROOT/setup-state-target"
ln -s "$TMP_ROOT/setup-state-target" "$TMP_ROOT/setup-state"
if sh "$TMP_ROOT/setup-preinst-test" > "$TMP_ROOT/setup-preinst-symlink.log" 2>&1; then
  printf 'setup preinst accepted a symlinked first-boot state directory\n' >&2
  exit 1
fi
grep -q 'refusing symlinked first-boot state directory' \
  "$TMP_ROOT/setup-preinst-symlink.log"
rm -f "$TMP_ROOT/setup-state"
sh "$TMP_ROOT/setup-preinst-test"
[ -f "$TMP_ROOT/setup-state/complete" ]
setup_state_mode="$(stat -c '%a' "$TMP_ROOT/setup-state" 2>/dev/null ||
  stat -f '%Lp' "$TMP_ROOT/setup-state")"
setup_complete_mode="$(stat -c '%a' "$TMP_ROOT/setup-state/complete" 2>/dev/null ||
  stat -f '%Lp' "$TMP_ROOT/setup-state/complete")"
[ "$setup_state_mode" = 700 ]
[ "$setup_complete_mode" = 600 ]
tar -xzOf "$TMP_ROOT/ipk-a/premier-router-core_${PKG_VERSION}_all.ipk" ./data.tar.gz |
  tar -xzOf - ./usr/share/premier-router/build-info > "$TMP_ROOT/build-info"
grep -Fqx "APP_VERSION=$APP_VERSION" "$TMP_ROOT/build-info"
grep -Fqx "PACKAGE_VERSION=$PKG_VERSION" "$TMP_ROOT/build-info"
grep -Fqx 'RELEASE_CHANNEL=candidate' "$TMP_ROOT/build-info"
! tar -xzOf "$TMP_ROOT/ipk-a/luci-app-premier-router_${PKG_VERSION}_all.ipk" ./data.tar.gz |
  tar -tzf - | grep -q '/_35_vpn.js$'

grep -q 'candidate_validate' "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
grep -Fq 'VALIDATOR="$ASSET_DIR/$(jget "$MANIFEST" '\''@.candidate_validator.filename'\'')"' \
  "$ROOT_DIR/install-router-ui-release.sh"
grep -Fq 'chmod 700 "$SUPERVISOR" "$UPDATE_LIB" "$VALIDATOR"' \
  "$ROOT_DIR/install-router-ui-release.sh"
! grep -Eq 'curl -k|wget .*--no-check-certificate|opkg upgrade' \
  "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update" \
  "$ROOT_DIR/install-router-ui-release.sh" "$ROOT_DIR/rescue-router-ui.sh"

printf 'Router UI release-v2 package, signature, manifest, and asset tests passed\n'
