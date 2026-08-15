#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
UPDATER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
UPDATE_LIB="$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh"
UPDATE_VIEW="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/system/update.js"
VIEW="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/network/vpn.js"
SETUP_CGI="$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"
SETUP_APP="$ROOT_DIR/firstboot-wizard/www/app.js"
SETUP_SERVER="$ROOT_DIR/firstboot-wizard/server.mjs"
RELEASE_INSTALLER="$ROOT_DIR/install-router-ui-release.sh"
STAGED_VALIDATOR="$ROOT_DIR/scripts/validate-staged-release.sh"
VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION")"
PACKAGE_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/PACKAGE_VERSION")"
INSTALLED_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/files/usr/share/vpn-ui/version")"

[ "$VERSION" = "0.7.11-rc.12" ]
[ "$PACKAGE_VERSION" = "0.7.11~rc12-1" ]
[ "$INSTALLED_VERSION" = "$VERSION" ]

. "$UPDATE_LIB"
pr_version_newer 0.7.11 0.7.10
! pr_version_newer 0.7.11 0.7.11
pr_version_newer 0.7.11 0.7.11-rc.12
pr_version_newer 0.7.11-rc.12 0.7.11-rc.6
pr_version_newer 0.7.11-rc.12 0.7.11-rc.8
pr_version_newer 0.7.11-rc.12 0.7.11-rc.10
pr_version_newer 0.7.11-rc.12 0.7.11-rc.11
pr_version_newer 0.7.11-rc.12 0.7.11-rc.5
! pr_version_newer 0.7.11-rc.12 0.7.11
! pr_version_newer 0.7.11-rc.6 0.7.11-rc.12
! pr_version_newer 0.7.11-rc.8 0.7.11-rc.12
! pr_version_newer 0.7.11-rc.10 0.7.11-rc.12
! pr_version_newer 0.7.11-rc.11 0.7.11-rc.12
! pr_version_newer 0.7.11-rc.12 0.7.11-rc.12
pr_version_newer 0.8.0 0.8.0RC2
! pr_version_newer 0.8.0RC2 0.8.0
pr_version_newer 0.8.0RC3 0.8.0RC2
pr_version_valid 0.7.9.1
pr_version_valid 0.7.11-rc.12
pr_package_version_matches_app 0.7.11-rc.12 0.7.11~rc12-1
pr_package_version_matches_app 0.7.11 0.7.11-1
! pr_package_version_matches_app 0.7.11-rc.12 0.7.11-1
! pr_version_valid 0.7
! pr_version_valid 0.8.0-RC2

STATUS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-rc-status.XXXXXX")"
trap 'rm -rf "$STATUS_ROOT"' EXIT INT TERM
mkdir -p "$STATUS_ROOT/usr/share/vpn-ui" "$STATUS_ROOT/etc/premier-router/update-cache" \
  "$STATUS_ROOT/etc" "$STATUS_ROOT/root/premier-router-updates/quarantine"
printf '%s\n' "$VERSION" > "$STATUS_ROOT/usr/share/vpn-ui/version"
printf "AUTO_UPDATE='0'\nAUTO_SCHEDULE='Sunday 04:17'\n" > "$STATUS_ROOT/etc/vpn-ui-update.conf"
printf '%s\n' '{"target_version":"0.7.11"}' > \
  "$STATUS_ROOT/etc/premier-router/update-cache/stable-channel.json"
STATUS_JSON="$(PREMIER_ROUTER_HOST_TEST=1 VPN_UI_ROOT_PREFIX="$STATUS_ROOT" \
  VPN_UI_UPDATE_LIB="$UPDATE_LIB" VPN_UI_UPDATE_SOURCE_ONLY=1 \
  sh -c '. "$1"; status_json' sh "$UPDATER")"
printf '%s\n' "$STATUS_JSON" | jq -e '
  .current == "0.7.11-rc.12" and .current_channel == "candidate" and
  .latest == "0.7.11" and .available == true
' >/dev/null

jq -e '
  .target == "0.7.11-rc.12" and .package_version == "0.7.11~rc12-1" and
  any(.baselines[]; .version == "0.7.11-rc.5" and
    .tag_commit == "d02b3bcd187a44d366469ed1f37bb1b273e60529") and
  any(.baselines[]; .version == "0.7.11-rc.6" and
    .tag_commit == "68976508e231cf8ab6fb441f8587de03c1903a3b" and
    .tree == "b8362d85404f47a07abd6f556fbe55f998de68e8" and
    .signed_manifest_sha256 == null) and
  any(.baselines[]; .version == "0.7.11-rc.6" and
    .tag_commit == "f1c8bf0eb81a663340351276f3cafd3fdeab53f5" and
    .tree == "c976abd2e4c47853f330dda500400d2f17bbacc7" and
    .signed_manifest_sha256 == "3c1e3159fd208dac77689fb997f10d98bd5847f0db274903510726d7232e3c32") and
  any(.baselines[]; .version == "0.7.11-rc.7" and
    .tag_commit == "97da893062ebed1e27e9b35dbf0b68f248c12dd7" and
    .tree == "db5e610c25eeda74f0ec0c931145249669eced69") and
  any(.baselines[]; .version == "0.7.11-rc.8" and
    .tag_commit == "ded0d472efb2452ba40dd2847912f0230e899bb5" and
    .tree == "5db998924088f2b8aa1e95c70baf797f10830557" and
    .support == "unsupported" and .evidence == "source-only-no-package-set") and
  any(.baselines[]; .version == "0.7.11-rc.9" and
    .tag_commit == "890ce802a2e2dd104eb907867c0779b59a65feac" and
    .tree == "52c544b0c36ff2e9716396541ec3ac46eaf875ed" and
    .evidence == "invalidated-exact-byte-checkpoint") and
  any(.baselines[]; .version == "0.7.11-rc.10" and
    .tag_commit == "9c6e0c631dbba4e6c7b736769f23005e50b4d4c4" and
    .tree == "6b5c8534c02f16c4025fcc56a14b4f0d951a7528" and
    .evidence == "invalidated-protected-state-exit-40") and
  any(.baselines[]; .version == "0.7.11-rc.11" and
    .tag_commit == "32d9a07cc5412ea785af092558f85ad69d066cf7" and
    .tree == "13805a2079b5a1b14d8fae7f1e14367bdac2b6bf" and
    .evidence == "invalidated-real-browser-xray-toggle")
' "$ROOT_DIR/release/transition-matrix.json" >/dev/null

grep -q 'flow_json=""' "$HELPER"
grep -q '"encryption": "none"\$flow_json' "$HELPER"
! grep -q 'P_FLOW="xtls-rprx-vision"' "$HELPER"
! grep -q '"port": "8080"' "$HELPER"
! grep -q '"protocol": \["bittorrent"\]' "$HELPER"
grep -q 'apply_adopted_rules' "$HELPER"
grep -q 'active_proxy_probe_ms' "$HELPER"
grep -q 'tcp %s\\n' "$HELPER"
grep -q 'direct_domain_rule_json=""' "$HELPER"
grep -q '\[ -n "$direct_domain_json" \]' "$HELPER"
grep -q 'XRAY_ACCESS_LOG_MAX_BYTES=1048576' "$HELPER"
grep -q 'cap_runtime_file "$XRAY_ACCESS_LOG"' "$HELPER"
grep -q 'harden_adguard_querylog' "$HELPER"
grep -q 'file_enabled: false' "$ROOT_DIR/setup-openwrt-x86-fin0.sh"
grep -q 'interval: 24h' "$ROOT_DIR/setup-openwrt-x86-fin0.sh"
grep -q 'file_enabled: false' "$SETUP_CGI"
grep -q 'interval: 24h' "$SETUP_CGI"
grep -q '"configured":false' "$HELPER"
grep -q 'configuration is not enabled' "$HELPER"
grep -q '"configured":true' "$HELPER"
grep -q 'router-release-manifest.json' "$RELEASE_INSTALLER"
grep -q 'usign -q -V' "$RELEASE_INSTALLER"
grep -q 'current_channel' "$UPDATER"
grep -q 'Release candidate' "$UPDATE_VIEW"
grep -q 'newer stable release will still be offered' "$UPDATE_VIEW"
grep -q 'Update failed safely: %s' "$UPDATE_VIEW"
! grep -q 'LuCI restarted during the update' "$UPDATE_VIEW"

STRICT_TRUST_FUNCTION="$STATUS_ROOT/strict-trust-function.sh"
sed -n '/^strict_trust_script_matches()/,/^}/p' "$STAGED_VALIDATOR" > \
  "$STRICT_TRUST_FUNCTION"
. "$STRICT_TRUST_FUNCTION"
EXPECTED_RELEASE_KEY_ID=production-fixture
RELEASE_KEY_FINGERPRINT=0123456789abcdef
STRICT_TRUST_FIXTURE="$STATUS_ROOT/rendered-bootstrap.sh"
cat > "$STRICT_TRUST_FIXTURE" <<'EOF'
TRUSTED_KEY_ID='production-fixture'
TRUSTED_KEY_FINGERPRINT='0123456789abcdef'
TRUSTED_KEY_COMMENT='untrusted comment: production fixture'
TRUSTED_KEY_DATA='RWfixture'
EOF
strict_trust_script_matches "$STRICT_TRUST_FIXTURE" \
  'untrusted comment: production fixture' 'RWfixture'
printf '%s\n' "TRUSTED_KEY_ID='attacker-override'" >> "$STRICT_TRUST_FIXTURE"
! strict_trust_script_matches "$STRICT_TRUST_FIXTURE" \
  'untrusted comment: production fixture' 'RWfixture'
grep -Fq 'bootstrap-router-ui-ipk-install.sh rescue-router-ui.sh' "$STAGED_VALIDATOR"

count="$(grep -c 'ui.addNotification' "$VIEW")"
[ "$count" -eq 1 ] || {
  printf 'expected one ui.addNotification call site, found %s\n' "$count" >&2
  exit 1
}
grep -q 'clearNotifications' "$VIEW"
grep -q "ping.indexOf('tcp ') == 0" "$VIEW"

grep -q 'vless://\*|https://\*' "$SETUP_CGI"
grep -q 'vpn-ui subscription-add' "$SETUP_CGI"
grep -q "startsWith('https://')" "$SETUP_APP"
grep -q "startsWith('https://')" "$SETUP_SERVER"

printf 'VPN 0.7.11 RC identity and updater-version checks passed\n'
