#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESET_VIEW="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/system/reset.js"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/state" "$TMP_DIR/www/cgi-bin" "$TMP_DIR/www/setup"
touch "$TMP_DIR/state/complete" "$TMP_DIR/www/setup/index.html"
cat > "$TMP_DIR/www/cgi-bin/firstboot-setup" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP_DIR/www/cgi-bin/firstboot-setup"

VPN_UI_RESET_DRY_RUN=1 \
FIRSTBOOT_STATE_DIR="$TMP_DIR/state" \
FIRSTBOOT_SETUP_CGI="$TMP_DIR/www/cgi-bin/firstboot-setup" \
FIRSTBOOT_SETUP_INDEX="$TMP_DIR/www/setup/index.html" \
  sh "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui" reset-status |
  grep -q '"supported":true'

VPN_UI_RESET_DRY_RUN=1 \
FIRSTBOOT_STATE_DIR="$TMP_DIR/state" \
FIRSTBOOT_SETUP_CGI="$TMP_DIR/www/cgi-bin/firstboot-setup" \
FIRSTBOOT_SETUP_INDEX="$TMP_DIR/www/setup/index.html" \
  sh "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui" reset-status |
  grep -q '"progress_url":"/setup/?reset=1"'

VPN_UI_RESET_DRY_RUN=1 \
FIRSTBOOT_STATE_DIR="$TMP_DIR/state" \
FIRSTBOOT_SETUP_CGI="$TMP_DIR/www/cgi-bin/firstboot-setup" \
FIRSTBOOT_SETUP_INDEX="$TMP_DIR/www/setup/index.html" \
  sh "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui" reset-to-setup RESET |
  grep -q '"dry_run":true'

grep -q '"admin/system/router-reset"' "$ROOT_DIR/luci-vpn-ui/files/usr/share/luci/menu.d/luci-app-vpn-ui.json"
grep -q 'rm -rf /etc/firstboot-wizard/phases' "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
grep -q 'copy_tree_file_modes.*luci-vpn-ui/files/www' "$ROOT_DIR/scripts/build-openwrt-ipks.sh"
! grep -q 'system/reset' "$ROOT_DIR/luci-vpn-ui/install.sh"
grep -q 'system/reset' "$ROOT_DIR/install-openwrt-vpn-ui.sh"
grep -q 'system/reset' "$ROOT_DIR/install-friend-vpn-panel.sh"
grep -q 'System -> Reset' "$ROOT_DIR/firstboot-wizard/www/app.js"
grep -q "window.location.replace(result.progress_url" "$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/system/reset.js"
grep -q "resetRecoveryMode" "$ROOT_DIR/firstboot-wizard/www/app.js"
grep -q "This page is safe to reload" "$ROOT_DIR/firstboot-wizard/www/app.js"
grep -q "/setup/?v=0.8.0RC2-ux-health-4" "$ROOT_DIR/firstboot-wizard/www/app.js"
grep -q "/setup/?v=0.8.0RC2-ux-health-4" "$ROOT_DIR/image-overlay/www/premier-router-index.html"
grep -q 'handoffTimer = window.setTimeout' "$RESET_VIEW"
grep -q 'window.location.replace(progressUrl)' "$RESET_VIEW"
grep -q "ROUTER_RESET_STATE" "$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"
grep -q "reset_rc" "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
grep -q 'ROOT_FS_TYPE.*proc/mounts' "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
grep -q 'explicit-ext4' "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
grep -q "phase === 'idle'" "$ROOT_DIR/firstboot-wizard/www/app.js"
