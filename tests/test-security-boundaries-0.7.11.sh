#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SETUP_CGI="$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"
ACL="$ROOT_DIR/luci-vpn-ui/files/usr/share/rpcd/acl.d/luci-app-vpn-ui.json"
READONLY="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-readonly"
HELPER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
UPDATER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
VPN_VIEW="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/network/vpn.js"
TAILSCALE_VIEW="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/network/tailscale.js"
UPDATE_VIEW="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/system/update.js"
STATUS_INCLUDE="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/status/include/35_vpn.js"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vpn-ui-security-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

jq -e '
  .["luci-app-vpn-ui"] as $acl |
  ($acl.read.file["/usr/sbin/vpn-ui-readonly"] == ["exec"]) and
  (($acl.read.file | has("/usr/sbin/vpn-ui")) | not) and
  ($acl.write.file["/usr/sbin/vpn-ui"] == ["exec"])
' "$ACL" >/dev/null

cp "$READONLY" "$TMP_ROOT/vpn-ui-readonly"
cat > "$TMP_ROOT/vpn-ui" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP_ROOT/invocations"
printf '{"ok":true,"command":"%s"}\n' "\$1"
EOF
chmod 755 "$TMP_ROOT/vpn-ui"
sed -i.bak "s|HELPER=\"/usr/sbin/vpn-ui\"|HELPER=\"$TMP_ROOT/vpn-ui\"|" \
  "$TMP_ROOT/vpn-ui-readonly"
rm -f "$TMP_ROOT/vpn-ui-readonly.bak"

for command in status vpn-summary tailscale-status update-status adoption-preview; do
  sh "$TMP_ROOT/vpn-ui-readonly" "$command" |
    grep -Fq '"ok":true'
done
sh "$TMP_ROOT/vpn-ui-readonly" tailscale-ping 100.64.0.1 |
  grep -Fq '"ok":true'
sh "$TMP_ROOT/vpn-ui-readonly" test-domain example.com |
  grep -Fq '"ok":true'
[ "$(wc -l < "$TMP_ROOT/invocations" | tr -d ' ')" = 7 ]

for command in init refresh-pings add select delete adoption-confirm overlay-recover apply-rules check device xray \
  subscription-add subscription-sync subscription-delete subscription-preview \
  validate-vless auto-config auto-tick tailscale-up tailscale-logout \
  tailscale-restart tailscale-stop update-check-start update-apply-start update-auto
do
  before="$(wc -l < "$TMP_ROOT/invocations" | tr -d ' ')"
  sh "$TMP_ROOT/vpn-ui-readonly" "$command" injected |
    grep -Fq '"ok":false'
  after="$(wc -l < "$TMP_ROOT/invocations" | tr -d ' ')"
  [ "$before" = "$after" ]
done

grep -Fq 'adoption-confirm' "$HELPER"
grep -Fq 'adoption-preview' "$HELPER"
grep -Fq 'profile changes are disabled in adopted-overlay mode' "$HELPER"
sed -n '/^cmd_xray()/,/^}/p' "$HELPER" | grep -Fq 'require_managed_ownership'
sed -n '/^cmd_device()/,/^}/p' "$HELPER" | grep -Fq 'require_managed_ownership'
! sed -n '/^cmd_check()/,/^}/p' "$HELPER" | grep -Fq 'init_state'
sed -n '/^cmd_auto_tick()/,/^}/p' "$HELPER" | grep -Fq 'update_mutation_status || exit 0'
sed -n '/^cmd_auto_tick()/,/^}/p' "$HELPER" | grep -Fq 'require_adopted_ownership'
sed -n '/^cmd_auto_tick()/,/^}/p' "$HELPER" | grep -Fq 'apply_adopted_rules'
sed -n '/^case "${1:-status}" in/,/^[[:space:]]*status)/p' "$HELPER" |
  grep -Fq 'require_native_ownership'
grep -Fq "'disabled': isReadonlyView || mutationDisabled" "$VPN_VIEW"
! grep -Fq '"protocol": ["bittorrent"]' "$HELPER"
! grep -Fq '"port": "8080"' "$HELPER"

grep -Fq "var readonlyHelper = '/usr/sbin/vpn-ui-readonly';" "$VPN_VIEW"
grep -Fq "var readonlyHelper = '/usr/sbin/vpn-ui-readonly';" "$TAILSCALE_VIEW"
grep -Fq "var readonlyHelper = '/usr/sbin/vpn-ui-readonly';" "$UPDATE_VIEW"
grep -Fq "var helper = '/usr/sbin/vpn-ui-readonly';" "$STATUS_INCLUDE"
grep -Fq 'if (!isReadonlyView && !data.checked_at' "$UPDATE_VIEW"
sed -n '/^status_json()/,/^}/p' "$HELPER" | grep -Fq 'read_state'
! sed -n '/^status_json()/,/^}/p' "$HELPER" | grep -Fq 'init_state'
sed -n '/^vpn_summary_json()/,/^}/p' "$HELPER" | grep -Fq 'read_state'
! sed -n '/^vpn_summary_json()/,/^}/p' "$HELPER" | grep -Fq 'init_state'
! sed -n '/^dhcp_devices_json()/,/^}/p' "$HELPER" | grep -Fq 'ensure_device_bypass_nft'
sed -n '/^status_json()/,/^}/p' "$UPDATER" | grep -Fq 'load_config_readonly'
! sed -n '/^status_json()/,/^}/p' "$UPDATER" |
  grep -Eq '^[[:space:]]*load_config[[:space:]]*$'

cp "$SETUP_CGI" "$TMP_ROOT/firstboot-setup"
mkdir -p "$TMP_ROOT/state"
touch "$TMP_ROOT/state/complete"
sed -i.bak \
  -e "s|STATE_DIR=\"/etc/firstboot-wizard\"|STATE_DIR=\"$TMP_ROOT/state\"|" \
  -e "s|PAYLOAD=\"/tmp/firstboot-setup\\.\\$\\$\\.json\"|PAYLOAD=\"$TMP_ROOT/payload.json\"|" \
  -e "s|FILTERS_FILE=\"/tmp/firstboot-adguard-filters\\.\\$\\$\"|FILTERS_FILE=\"$TMP_ROOT/filters\"|" \
  -e 's|^  configure_account |  : > "$STATE_DIR/MUTATION_REACHED"; configure_account |' \
  "$TMP_ROOT/firstboot-setup"
rm -f "$TMP_ROOT/firstboot-setup.bak"

QUERY_STRING='action=apply' CONTENT_LENGTH=0 sh "$TMP_ROOT/firstboot-setup" \
  > "$TMP_ROOT/completed-response"
grep -Fq '"ok":false' "$TMP_ROOT/completed-response"
grep -Fq 'Initial setup is already complete' "$TMP_ROOT/completed-response"
[ ! -e "$TMP_ROOT/state/MUTATION_REACHED" ]
[ ! -e "$TMP_ROOT/state/apply.lock" ]

rm -f "$TMP_ROOT/state/complete"
mkdir "$TMP_ROOT/state/apply.lock"
QUERY_STRING='action=apply' CONTENT_LENGTH=0 sh "$TMP_ROOT/firstboot-setup" \
  > "$TMP_ROOT/concurrent-response"
grep -Fq '"ok":false' "$TMP_ROOT/concurrent-response"
grep -Fq 'another setup request is in progress' "$TMP_ROOT/concurrent-response"
[ ! -e "$TMP_ROOT/state/MUTATION_REACHED" ]

printf 'Router UI 0.7.11 setup and read-only ACL security checks passed\n'
