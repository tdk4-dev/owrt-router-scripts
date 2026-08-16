#!/bin/ash
set -eu

OUT_DIR="${1:-/tmp/router-ui-runtime-census}"
RESULTS="$OUT_DIR/results.tsv"
SUMMARY="$OUT_DIR/summary.txt"
FAILED=0

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
printf 'status\tkind\tobject\tresolved\texpected_owner\tactual_owner\tnote\n' > "$RESULTS"

row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$RESULTS"; }
fail_row() { FAILED=$((FAILED + 1)); row FAIL "$@"; }

owners_for_path() {
  local target="$1" list package
  for list in /usr/lib/opkg/info/*.list; do
    [ -f "$list" ] || continue
    grep -qxF "$target" "$list" || continue
    package="${list##*/}"
    printf '%s\n' "${package%.list}"
  done | LC_ALL=C sort -u
}

check_path() {
  local kind="$1" target="$2" expected="$3" owners count
  if [ ! -e "$target" ]; then
    fail_row "$kind" "$target" missing "$expected" none 'required path is absent'
    return
  fi
  owners="$(owners_for_path "$target")"
  count="$(printf '%s\n' "$owners" | awk 'NF { count++ } END { print count+0 }')"
  if [ "$count" -ne 1 ]; then
    fail_row "$kind" "$target" "$target" "$expected" "${owners:-none}" 'path ownership is missing or ambiguous'
  elif [ "$owners" != "$expected" ]; then
    fail_row "$kind" "$target" "$target" "$expected" "$owners" 'path owner differs from the census contract'
  else
    row PASS "$kind" "$target" "$target" "$expected" "$owners" installed
  fi
}

check_command() {
  local name="$1" expected="$2" resolved canonical owners count
  resolved="$(command -v "$name" 2>/dev/null || true)"
  if [ -z "$resolved" ] || [ ! -x "$resolved" ]; then
    fail_row executable "$name" missing "$expected" none 'required executable is absent'
    return
  fi
  canonical="$(readlink -f "$resolved" 2>/dev/null || printf '%s' "$resolved")"
  owners="$(owners_for_path "$canonical")"
  count="$(printf '%s\n' "$owners" | awk 'NF { count++ } END { print count+0 }')"
  if [ "$count" -ne 1 ]; then
    fail_row executable "$name" "$resolved" "$expected" "${owners:-none}" 'resolved executable ownership is missing or ambiguous'
  elif [ "$owners" != "$expected" ]; then
    fail_row executable "$name" "$resolved" "$expected" "$owners" 'resolved executable owner differs from the census contract'
  else
    row PASS executable "$name" "$resolved -> $canonical" "$expected" "$owners" installed
  fi
}

check_package() {
  local package="$1"
  if opkg status "$package" 2>/dev/null | grep -Eq '^Status: install (user|ok) installed$'; then
    row PASS package "$package" installed "$package" "$package" installed
  else
    fail_row package "$package" missing "$package" none 'required package is not installed'
  fi
}

check_uci() {
  local object="$1" target="$2" expected="$3" owners count runtime_package
  if ! uci -q get "$object" >/dev/null 2>&1 && ! uci -q show "$object" >/dev/null 2>&1; then
    fail_row uci-object "$object" missing "$expected" none "required UCI object is absent from $target"
    return
  fi
  owners="$(owners_for_path "$target")"
  count="$(printf '%s\n' "$owners" | awk 'NF { count++ } END { print count+0 }')"
  case "$expected" in
    *:runtime)
      runtime_package="${expected%:runtime}"
      if [ "$count" -ne 0 ]; then
        fail_row uci-object "$object" "$target" "$expected" "$owners" 'runtime-generated UCI path also has a package file owner'
      elif ! opkg status "$runtime_package" 2>/dev/null | grep -Eq '^Status: install (user|ok) installed$'; then
        fail_row uci-object "$object" "$target" "$expected" none 'runtime owner package is not installed'
      else
        row PASS uci-object "$object" "$target" "$expected" "$expected" present
      fi
      return
      ;;
  esac
  if [ "$count" -ne 1 ]; then
    fail_row uci-object "$object" "$target" "$expected" "${owners:-none}" 'UCI configuration ownership is missing or ambiguous'
  elif [ "$owners" != "$expected" ]; then
    fail_row uci-object "$object" "$target" "$expected" "$owners" 'UCI configuration owner differs from the census contract'
  else
    row PASS uci-object "$object" "$target" "$expected" "$owners" present
  fi
}

check_runtime_path() {
  local kind="$1" target="$2" expected="$3" phase="$4"
  if [ -e "$target" ]; then
    row PASS "$kind" "$target" "$target" "$expected" "$expected" "$phase"
  else
    fail_row "$kind" "$target" missing "$expected" none "missing after $phase"
  fi
}

transparent_kernel_state_present() {
  nft list table inet xray_transparent >/dev/null 2>&1 &&
    nft list set inet xray_transparent bypass4 >/dev/null 2>&1 &&
    nft list set inet xray_transparent vpn_ui_device_bypass4 >/dev/null 2>&1 &&
    nft list chain inet xray_transparent dns_prerouting 2>/dev/null |
      grep -q 'redirect to :53' &&
    [ "$(nft list chain inet xray_transparent tproxy_prerouting 2>/dev/null |
      grep -c 'tproxy.*:12345')" -ge 2 ] &&
    ip -4 rule show 2>/dev/null |
      grep -Eq 'fwmark (0x0*1|1)(/0xffffffff)? .*lookup 100' &&
    ip -4 route show table 100 2>/dev/null |
      grep -Eq '^local (default|0\.0\.0\.0/0) dev lo( |$)'
}

for package in premier-router-core luci-app-premier-router premier-router-setup; do check_package "$package"; done

while IFS='|' read -r kind target expected; do
  [ -n "$kind" ] || continue
  check_path "$kind" "$target" "$expected"
done <<'EOF'
executable|/usr/sbin/vpn-ui|premier-router-core
executable|/usr/sbin/vpn-ui-readonly|premier-router-core
executable|/usr/sbin/vpn-ui-update|premier-router-core
executable|/usr/libexec/premier-router/update-lib.sh|premier-router-core
executable|/usr/libexec/premier-router/candidate-validator|premier-router-core
executable|/usr/libexec/premier-router/xray-overlay.uc|premier-router-core
init-service|/etc/init.d/premier-router-update-recovery|premier-router-core
init-service|/etc/init.d/xray-transparent|premier-router-core
configuration|/etc/vpn-ui-update.conf|premier-router-core
configuration|/etc/config/premier_router|premier-router-core
configuration|/usr/share/vpn-ui/version|premier-router-core
configuration|/usr/share/premier-router/build-info|premier-router-core
configuration|/usr/share/premier-router/keys/release.pub|premier-router-core
configuration|/usr/share/premier-router/keys/release-key-id|premier-router-core
configuration|/usr/share/premier-router/keys/trusted-keys.json|premier-router-core
configuration|/usr/share/luci/menu.d/luci-app-vpn-ui.json|luci-app-premier-router
configuration|/usr/share/rpcd/acl.d/luci-app-vpn-ui.json|luci-app-premier-router
asset|/www/luci-static/resources/view/network/vpn.js|luci-app-premier-router
asset|/www/luci-static/resources/view/network/tailscale.js|luci-app-premier-router
asset|/www/luci-static/resources/view/system/update.js|luci-app-premier-router
asset|/www/luci-static/resources/view/status/include/35_vpn.js|luci-app-premier-router
executable|/www/cgi-bin/firstboot-setup|premier-router-setup
asset|/www/setup/index.html|premier-router-setup
asset|/www/setup/styles.css|premier-router-setup
asset|/www/setup/app.js|premier-router-setup
init-service|/etc/init.d/xray|xray-core
configuration|/etc/config/xray|xray-core
init-service|/etc/init.d/tailscale|tailscale
configuration|/etc/config/tailscale|tailscale
configuration|/etc/ssl/certs/ca-certificates.crt|ca-bundle
asset|/www/luci-static/resources/luci.js|luci-base
executable|/usr/libexec/cgi-io|cgi-io
init-service|/etc/init.d/cron|busybox
init-service|/etc/init.d/rpcd|rpcd
init-service|/etc/init.d/uhttpd|uhttpd
init-service|/etc/init.d/dropbear|dropbear
init-service|/etc/init.d/dnsmasq|dnsmasq-full
init-service|/etc/init.d/firewall|firewall4
EOF

while IFS='|' read -r name expected; do
  [ -n "$name" ] || continue
  check_command "$name" "$expected"
done <<'EOF'
xray|xray-core
tailscale|tailscale
nft|nftables-json
ip|ip-full
conntrack|conntrack
curl|curl
jsonfilter|jsonfilter
usign|usign
ucode|ucode
base64|coreutils-base64
nohup|coreutils-nohup
socat|socat
ubus|ubus
opkg|opkg
tar|busybox
gzip|busybox
sha256sum|busybox
nslookup|busybox
EOF

check_package kmod-nft-tproxy
if find /lib/modules -type f \( -name '*nft*tproxy*.ko' -o -name '*nft*tproxy*.ko.gz' \) 2>/dev/null | grep -q .; then
  row PASS kernel-capability nft-tproxy /lib/modules kmod-nft-tproxy kmod-nft-tproxy module-present
else
  fail_row kernel-capability nft-tproxy missing kmod-nft-tproxy none 'TPROXY kernel module is absent'
fi

check_uci xray /etc/config/xray xray-core
check_uci premier_router.router /etc/config/premier_router premier-router-core
check_uci 'tailscale.@settings[0]' /etc/config/tailscale tailscale
check_uci 'system.@system[0]' /etc/config/system base-files:runtime
check_uci network.lan /etc/config/network netifd:runtime
check_uci dhcp.lan /etc/config/dhcp dnsmasq-full
check_uci 'firewall.@defaults[0]' /etc/config/firewall firewall4

xray_reported=false
xray_process=false
/etc/init.d/xray running >/dev/null 2>&1 && xray_reported=true
pidof xray >/dev/null 2>&1 && xray_process=true
if [ "$xray_reported" = "$xray_process" ]; then
  row PASS init-postcondition xray-running "$xray_reported" xray-core xray-core matches-daemon-process
else
  fail_row init-postcondition xray-running "$xray_reported" xray-core "$xray_process" 'init running result does not match the daemon process'
fi

transparent_reported=false
transparent_actual=false
/etc/init.d/xray-transparent running >/dev/null 2>&1 && transparent_reported=true
transparent_kernel_state_present && transparent_actual=true
if [ "$transparent_reported" = "$transparent_actual" ]; then
  row PASS init-postcondition xray-transparent-running "$transparent_reported" premier-router-core premier-router-core matches-kernel-state
else
  fail_row init-postcondition xray-transparent-running "$transparent_reported" premier-router-core "$transparent_actual" 'init running result does not match complete nftables and policy-routing state'
fi

if ubus -S list file 2>/dev/null | grep -Fxq file; then
  row PASS ubus-object file file rpcd-mod-file rpcd-mod-file present
else
  fail_row ubus-object file missing rpcd-mod-file none 'rpcd file object is absent'
fi

check_runtime_path configuration /etc/crontabs/root premier-router-core:runtime post-install
check_runtime_path runtime-state /etc/firstboot-wizard premier-router-setup:runtime post-install
check_runtime_path configuration /etc/firstboot-wizard/complete premier-router-setup:runtime post-install
check_runtime_path runtime-state /tmp/dhcp.leases dnsmasq-full:runtime post-service-start
check_runtime_path runtime-state /etc/xray xray-core dependency-install

if [ -e /etc/premier-router/installed-manifest.json ] ||
  [ -e /etc/premier-router/installed-manifest.json.sig ]; then
  check_runtime_path configuration /etc/premier-router/installed-manifest.json premier-router-installer:runtime post-canonical-installer
  check_runtime_path configuration /etc/premier-router/installed-manifest.json.sig premier-router-installer:runtime post-canonical-installer
else
  row PASS lifecycle-boundary installed-manifest not-created premier-router-installer:runtime none post-canonical-installer-only
fi

INIT_RESULT="$OUT_DIR/backend-init.json"
/usr/sbin/vpn-ui init > "$INIT_RESULT" 2>&1 || true
if grep -Fq '"ok":true' "$INIT_RESULT"; then
  row PASS backend-init '/usr/sbin/vpn-ui init' "$INIT_RESULT" premier-router-core premier-router-core non-activating
else
  fail_row backend-init '/usr/sbin/vpn-ui init' "$INIT_RESULT" premier-router-core premier-router-core 'backend initialization did not succeed'
fi
for target in /etc/xray/exit-st-cf.json /etc/xray/vless-profiles.d /etc/xray/subscriptions.d \
  /etc/xray/vless-selected \
  /etc/xray/direct-domains.txt /etc/xray/direct-ips.txt \
  /etc/xray/vpn-ui-device-bypass-macs.txt /etc/xray/vpn-ui-auto.conf \
  /etc/xray/vpn-ui-auto-pool.txt; do
  check_runtime_path runtime-state "$target" premier-router-core:runtime backend-init
done

if [ -e /etc/init.d/adguardhome ] || command -v AdGuardHome >/dev/null 2>&1; then
  if [ -x /etc/init.d/adguardhome ] && command -v AdGuardHome >/dev/null 2>&1; then
    row PASS conditional-runtime adguard available adguardhome adguardhome visible-controls-enabled
  else
    fail_row conditional-runtime adguard partial adguardhome ambiguous 'AdGuard visibility dependencies are only partially installed'
  fi
else
  row PASS conditional-runtime adguard hidden adguardhome none guarded-unavailable-notice
fi

if [ "$FAILED" -eq 0 ]; then
  printf 'STATUS=PASS\nFAILED=0\nRESULTS=%s\n' "$RESULTS" > "$SUMMARY"
  cat "$SUMMARY"
  exit 0
fi
printf 'STATUS=FAIL\nFAILED=%s\nRESULTS=%s\n' "$FAILED" "$RESULTS" > "$SUMMARY"
cat "$SUMMARY"
exit 1
