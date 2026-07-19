#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UPDATER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
UPDATE_LIB="$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh"
VALIDATOR="$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/candidate-validator"
RECOVERY="$ROOT_DIR/luci-vpn-ui/files/etc/init.d/premier-router-update-recovery"
BUILDER="$ROOT_DIR/scripts/build-openwrt-ipks.sh"

# Release discovery is signed-pointer -> exact tagged manifest. The unsigned
# legacy version/changelog/date triplet must never influence update authority.
grep -q 'DISCOVERY_BASE=.*releases/latest/download' "$UPDATER"
grep -q 'stable-channel.json' "$UPDATER"
grep -q 'router-release-manifest.json.sig' "$UPDATER"
grep -q 'releases/download/\$tag' "$UPDATER"
! grep -q 'vpn-ui-version.txt' "$UPDATER"
! grep -q 'vpn-ui-changelog.txt' "$UPDATER"
! grep -q 'vpn-ui-release-date.txt' "$UPDATER"

pointer_verify="$(grep -n 'pr_verify_signature "$pointer"' "$UPDATER" | sed -n '1s/:.*//p')"
pointer_read="$(grep -n 'tag="$(pr_json_get "$pointer"' "$UPDATER" | sed -n '2s/:.*//p')"
manifest_hash="$(grep -n 'pr_sha256 "$manifest"' "$UPDATER" | sed -n '1s/:.*//p')"
manifest_verify="$(grep -n 'pr_verify_signature "$manifest"' "$UPDATER" | sed -n '1s/:.*//p')"
manifest_validate="$(grep -n 'pr_manifest_validate "$manifest"' "$UPDATER" | sed -n '1s/:.*//p')"
[ -n "$pointer_verify" ] && [ -n "$pointer_read" ] &&
  [ "$pointer_verify" -lt "$pointer_read" ]
[ -n "$manifest_hash" ] && [ -n "$manifest_verify" ] && [ -n "$manifest_validate" ] &&
  [ "$manifest_hash" -lt "$manifest_verify" ] &&
  [ "$manifest_verify" -lt "$manifest_validate" ]

# RC and four-component comparisons are part of the signed compatibility
# contract used by both the bridge release and later mainline releases.
PREMIER_ROUTER_HOST_TEST=1 sh -c '
  . "$1"
  pr_version_newer 0.8.0 0.8.0RC2
  ! pr_version_newer 0.8.0RC2 0.8.0
  pr_version_newer 0.8.0RC3 0.8.0RC2
  pr_version_newer 0.8.0.1 0.8.0
  pr_version_valid 24.10.5
  pr_version_valid 0.8.0RC2
  ! pr_version_valid 0.8
  ! pr_version_valid 0.8.0-rc2
  pr_safe_asset_name premier-router-core_0.8.0RC2-1_all.ipk
  ! pr_safe_asset_name ../escape.ipk
' sh "$UPDATE_LIB"

grep -q '^UPDATER_PROTOCOL=2$' "$BUILDER"
grep -q '"curl, jsonfilter, usign,' "$BUILDER"
grep -q 'premier-router-update-recovery enable' "$BUILDER"
grep -q 'PERSIST_ROOT=.*premier-router-updates' "$UPDATER"
grep -q 'state.json' "$UPDATER"
grep -q 'rollback_failed\|recovery_required' "$UPDATER"
grep -q '^START=5$' "$RECOVERY"
grep -q 'vpn-ui-update recover' "$RECOVERY"

# The mainline target validator retains the 0.8-only features while accepting
# input solely through protocol-v2 package metadata.
grep -q 'view/network/adguard.js' "$VALIDATOR"
grep -q 'view/system/reset.js' "$VALIDATOR"
grep -q 'tools/router_footer.js' "$VALIDATOR"
grep -q 'updater protocol v2 is not installed' "$VALIDATOR"

printf 'Signed updater-v2 mainline compatibility checks passed\n'
