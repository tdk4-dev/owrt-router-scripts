#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OVERLAY="$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/xray-overlay.uc"
VPN_UI="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
FIXTURE="$ROOT_DIR/tests/fixtures/xray/adopted-overlay.json"
VALERA_FIXTURE="$ROOT_DIR/tests/fixtures/xray/valera-manual-config.json"
UCODE_INSTALLER="$ROOT_DIR/scripts/install-ci-ucode.sh"
UCODE_REAL="${TEST_UCODE_BIN:-$(command -v ucode || true)}"
[ -x "$UCODE_REAL" ] || {
  printf 'ucode is required for adopted-overlay tests\n' >&2
  exit 1
}

grep -Fq 'UCODE_COMMIT=3f64c8089bf3ea4847c96b91df09fbfcaec19e1d' "$UCODE_INSTALLER"
grep -Fq 'UCODE_SOURCE_URL="${UCODE_SOURCE_URL:-https://github.com/jow-/ucode.git}"' \
  "$UCODE_INSTALLER"
grep -Fq 'export LD_LIBRARY_PATH=' "$UCODE_INSTALLER"
grep -Fq 'export DYLD_LIBRARY_PATH=' "$UCODE_INSTALLER"
! grep -Fq -- '-DIO_SUPPORT=OFF' "$UCODE_INSTALLER"
grep -Fq 'df -Pk "$(dirname "$actual")"' "$VPN_UI"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-adopted-overlay.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

UCODE="$TMP_ROOT/ucode"
cat > "$UCODE" <<'EOF'
#!/bin/sh
if [ -n "${TEST_UCODE_LIB:-}" ]; then
  exec "$TEST_UCODE_BIN" -L "$TEST_UCODE_LIB" "$@"
fi
exec "$TEST_UCODE_BIN" "$@"
EOF
chmod 755 "$UCODE"
export TEST_UCODE_BIN="$UCODE_REAL"

SOURCE="$TMP_ROOT/source.json"
CANDIDATE="$TMP_ROOT/candidate.json"
DOMAINS="$TMP_ROOT/domains.txt"
IPS="$TMP_ROOT/ips.txt"
cp "$FIXTURE" "$SOURCE"
SOURCE_HASH="$(sha256sum "$SOURCE" | awk '{print $1}')"

"$UCODE" "$OVERLAY" inspect "$SOURCE" > "$TMP_ROOT/inspect.json"
jq -e '
  .ok == true and .domain_rule_index == 3 and .ip_rule_index == 4 and
  .domain_count == 3 and .ip_count == 2 and
  (.warnings | index("routing.domainStrategy AsIs will be preserved") != null)
' "$TMP_ROOT/inspect.json" >/dev/null
"$UCODE" "$OVERLAY" extract "$SOURCE" 3 4 "$DOMAINS" "$IPS" >/dev/null
[ "$(sha256sum "$SOURCE" | awk '{print $1}')" = "$SOURCE_HASH" ]

VALERA_FULL="$TMP_ROOT/valera-full-panel.json"
PROFILE_INPUT="$TMP_ROOT/profile-input.json"
PROFILE_CANDIDATE="$TMP_ROOT/profile-candidate.json"
PROFILE_DOMAINS="$TMP_ROOT/profile-domains.txt"
PROFILE_IPS="$TMP_ROOT/profile-ips.txt"
jq '.routing.rules = [
  {
    "type":"field",
    "inboundTag":["socks-in","transparent-in"],
    "ip":["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","240.0.0.0/4","198.51.100.200/32"],
    "outboundTag":"direct"
  },
  .routing.rules[1],
  .routing.rules[0],
  .routing.rules[2]
]' "$VALERA_FIXTURE" > "$VALERA_FULL"
jq -r '.routing.rules[2].domain[]' "$VALERA_FULL" > "$PROFILE_DOMAINS"
jq -r '.routing.rules[1].ip[]' "$VALERA_FULL" > "$PROFILE_IPS"
cat > "$PROFILE_INPUT" <<'EOF'
{"address":"198.51.100.201","port":8443,"uuid":"00000000-0000-4000-8000-000000000007","flow":"","server_name":"next.example.invalid","fingerprint":"firefox","public_key":"next-sanitized-public-key","short_id":"fedcba9876543210","spider_x":"/next","old_vps_ip":"198.51.100.200","new_vps_ip":"198.51.100.201"}
EOF
"$UCODE" "$OVERLAY" patch-profile "$VALERA_FULL" 2 1 "$PROFILE_DOMAINS" "$PROFILE_IPS" \
  "$PROFILE_CANDIDATE" "$PROFILE_INPUT" > "$TMP_ROOT/profile-patch.json"
jq -e '.ok and .profile_updated and .non_managed_semantics_unchanged and
  .domain_rule_index == 2 and .ip_rule_index == 1 and .domain_count == 166 and .ip_count == 14' \
  "$TMP_ROOT/profile-patch.json" >/dev/null
jq -e '
  .outbounds[0].settings.vnext[0].address == "198.51.100.201" and
  .outbounds[0].settings.vnext[0].port == 8443 and
  .outbounds[0].settings.vnext[0].users[0].id == "00000000-0000-4000-8000-000000000007" and
  (.outbounds[0].settings.vnext[0].users[0] | has("flow") | not) and
  .outbounds[0].streamSettings.realitySettings.serverName == "next.example.invalid" and
  .routing.rules[0].ip[9] == "198.51.100.201/32" and
  (.routing.rules[1].ip | length) == 14 and (.routing.rules[2].domain | length) == 166 and
  .routing.domainStrategy == "AsIs" and (.inbounds | length) == 2 and (.routing.rules | length) == 4
' "$PROFILE_CANDIDATE" >/dev/null
jq -S '
  .outbounds[0].settings.vnext[0].address = "managed" |
  .outbounds[0].settings.vnext[0].port = 1 |
  .outbounds[0].settings.vnext[0].users[0] = {} |
  .outbounds[0].streamSettings.network = "managed" |
  .outbounds[0].streamSettings.security = "managed" |
  .outbounds[0].streamSettings.realitySettings = {} |
  .routing.rules[0].ip = ["managed"] |
  .routing.rules[1].ip = ["managed"] |
  .routing.rules[2].domain = ["managed"]
' "$VALERA_FULL" > "$TMP_ROOT/profile-source-unmanaged.json"
jq -S '
  .outbounds[0].settings.vnext[0].address = "managed" |
  .outbounds[0].settings.vnext[0].port = 1 |
  .outbounds[0].settings.vnext[0].users[0] = {} |
  .outbounds[0].streamSettings.network = "managed" |
  .outbounds[0].streamSettings.security = "managed" |
  .outbounds[0].streamSettings.realitySettings = {} |
  .routing.rules[0].ip = ["managed"] |
  .routing.rules[1].ip = ["managed"] |
  .routing.rules[2].domain = ["managed"]
' "$PROFILE_CANDIDATE" > "$TMP_ROOT/profile-candidate-unmanaged.json"
cmp -s "$TMP_ROOT/profile-source-unmanaged.json" "$TMP_ROOT/profile-candidate-unmanaged.json"

VALERA_SOURCE="$TMP_ROOT/valera-config.json"
VALERA_DOMAINS="$TMP_ROOT/valera-domains.txt"
VALERA_IPS="$TMP_ROOT/valera-ips.txt"
cp "$VALERA_FIXTURE" "$VALERA_SOURCE"
VALERA_HASH="$(sha256sum "$VALERA_SOURCE" | awk '{print $1}')"
"$UCODE" "$OVERLAY" inspect "$VALERA_SOURCE" > "$TMP_ROOT/valera-inspect.json"
jq -e '.domain_rule_index == 0 and .ip_rule_index == 1 and
  .domain_count == 166 and .ip_count == 14' "$TMP_ROOT/valera-inspect.json" >/dev/null
"$UCODE" "$OVERLAY" extract "$VALERA_SOURCE" 0 1 "$VALERA_DOMAINS" "$VALERA_IPS" >/dev/null
[ "$(wc -l < "$VALERA_DOMAINS" | tr -d ' ')" -eq 166 ]
[ "$(wc -l < "$VALERA_IPS" | tr -d ' ')" -eq 14 ]
[ "$(sha256sum "$VALERA_SOURCE" | awk '{print $1}')" = "$VALERA_HASH" ]
jq -e '(.inbounds | length) == 2 and (.routing.rules | length) == 3 and
  .routing.domainStrategy == "AsIs" and
  (any(.routing.rules[]; (.protocol // []) | index("bittorrent")) | not) and
  (any(.routing.rules[]; .port == "8080") | not)' "$VALERA_SOURCE" >/dev/null
[ "$(wc -l < "$DOMAINS" | tr -d ' ')" -eq 3 ]
[ "$(wc -l < "$IPS" | tr -d ' ')" -eq 2 ]

printf '%s\n' 'full:rc6-validation.invalid' 'domain:kept.example' > "$DOMAINS"
printf '%s\n' '198.51.100.0/25' > "$IPS"
"$UCODE" "$OVERLAY" patch "$SOURCE" 3 4 "$DOMAINS" "$IPS" "$CANDIDATE" > "$TMP_ROOT/patch.json"
jq -e '.ok and .non_managed_semantics_unchanged and .domain_count == 2 and .ip_count == 1' \
  "$TMP_ROOT/patch.json" >/dev/null
jq -S '(.routing.rules[3].domain) = ["managed"] | (.routing.rules[4].ip) = ["managed"]' \
  "$SOURCE" > "$TMP_ROOT/source-unmanaged.json"
jq -S '(.routing.rules[3].domain) = ["managed"] | (.routing.rules[4].ip) = ["managed"]' \
  "$CANDIDATE" > "$TMP_ROOT/candidate-unmanaged.json"
cmp -s "$TMP_ROOT/source-unmanaged.json" "$TMP_ROOT/candidate-unmanaged.json"
jq -e '
  .routing.domainStrategy == "AsIs" and
  .routing.rules[0].ip[3] == "203.0.113.10/32" and
  .routing.rules[1].protocol == ["bittorrent"] and
  .routing.rules[2].port == "8080" and
  .outbounds[0].settings.vnext[0].users[0].id == "00000000-0000-4000-8000-000000000006" and
  .routing.rules[3].domain == ["full:rc6-validation.invalid", "domain:kept.example"] and
  .routing.rules[4].ip == ["198.51.100.0/25"]
' "$CANDIDATE" >/dev/null
[ "$(sha256sum "$SOURCE" | awk '{print $1}')" = "$SOURCE_HASH" ]

jq '.routing.rules += [.routing.rules[3]]' "$SOURCE" > "$TMP_ROOT/ambiguous.json"
if "$UCODE" "$OVERLAY" inspect "$TMP_ROOT/ambiguous.json" > "$TMP_ROOT/ambiguous-result.json" 2>/dev/null; then
  printf 'ambiguous adopted layout unexpectedly passed\n' >&2
  exit 1
fi
jq -e '.ok == false and (.error | contains("exactly one isolated direct domain array"))' \
  "$TMP_ROOT/ambiguous-result.json" >/dev/null

printf '%s\n' '{not-json' > "$TMP_ROOT/invalid.json"
if "$UCODE" "$OVERLAY" inspect "$TMP_ROOT/invalid.json" > "$TMP_ROOT/invalid-result.json" 2>/dev/null; then
  printf 'invalid JSON unexpectedly passed structural inspection\n' >&2
  exit 1
fi
jq -e '.ok == false and (.error | contains("not valid JSON"))' \
  "$TMP_ROOT/invalid-result.json" >/dev/null

CLEAN_ROOT="$TMP_ROOT/clean-root"
mkdir -p "$CLEAN_ROOT/etc" "$CLEAN_ROOT/tmp"
PREMIER_ROUTER_HOST_TEST=1 VPN_UI_SOURCE_ONLY=1 VPN_UI_ROOT_PREFIX="$CLEAN_ROOT" \
  sh -c '. "$1"; ownership_status_json; require_native_ownership' sh "$VPN_UI" \
  > "$TMP_ROOT/clean-native.json"
jq -e '.mode == "native-generated" and .healthy == true and
  .adoption_required == false and .path == "/etc/xray/exit-st-cf.json"' \
  "$TMP_ROOT/clean-native.json" >/dev/null
printf '%s\n' 'full:native-managed.invalid' > "$TMP_ROOT/native-domains"
printf '%s\n' '198.51.100.0/24' > "$TMP_ROOT/native-ips"
PREMIER_ROUTER_HOST_TEST=1 VPN_UI_SOURCE_ONLY=1 VPN_UI_ROOT_PREFIX="$CLEAN_ROOT" \
  sh -c '. "$1"; P_HOST=198.51.100.6; P_SNI=example.invalid; P_FINGERPRINT=chrome;
    P_PUBLIC_KEY=public-key; P_SHORT_ID=0123456789abcdef; P_SPIDERX=/;
    P_UUID=00000000-0000-4000-8000-000000000006; P_PORT=443; P_FLOW="";
    P_VPS_IP=198.51.100.6; LAN_IP=192.0.2.1;
    render_xray_config "$2" "$3" "$4"' sh "$VPN_UI" "$TMP_ROOT/native.json" \
      "$TMP_ROOT/native-domains" "$TMP_ROOT/native-ips"
jq -e '
  any(.routing.rules[]; .domain == ["full:native-managed.invalid"] and .outboundTag == "direct") and
  any(.routing.rules[]; (.ip // []) | index("198.51.100.0/24")) and
  (any(.routing.rules[]; (.protocol // []) | index("bittorrent")) | not) and
  (any(.routing.rules[]; .port == "8080") | not)
' "$TMP_ROOT/native.json" >/dev/null

FAKE_ROOT="$TMP_ROOT/root"
mkdir -p "$FAKE_ROOT/etc/xray" "$FAKE_ROOT/etc/init.d" "$FAKE_ROOT/usr/local/bin" \
  "$FAKE_ROOT/usr/libexec/premier-router" "$FAKE_ROOT/tmp"
cp "$FIXTURE" "$FAKE_ROOT/etc/xray/config.json"
cp "$OVERLAY" "$FAKE_ROOT/usr/libexec/premier-router/xray-overlay.uc"
chmod 755 "$FAKE_ROOT/usr/libexec/premier-router/xray-overlay.uc"

cat > "$FAKE_ROOT/usr/local/bin/xray-latest" <<'EOF'
#!/bin/sh
[ "${VPN_UI_TEST_XRAY_VALIDATE_FAIL:-0}" != 1 ] || exit 42
[ "$1" = run ] && [ "$2" = -test ] && [ "$3" = -config ] && [ -s "$4" ] &&
  [ "${4##*.}" = json ] &&
  jq -e . "$4" >/dev/null 2>&1
EOF
cat > "$FAKE_ROOT/etc/init.d/xray" <<'EOF'
#!/bin/sh
case "${1:-}" in
  running) exit 0 ;;
  restart)
    if [ "${VPN_UI_TEST_XRAY_RESTART_FAIL_ONCE:-0}" = 1 ] &&
      [ ! -f "$VPN_UI_ROOT_PREFIX/tmp/restart-failed-once" ]; then
      : > "$VPN_UI_ROOT_PREFIX/tmp/restart-failed-once"
      exit 42
    fi
    exit 0
    ;;
  stop|start) exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$FAKE_ROOT/etc/init.d/xray-transparent" <<'EOF'
#!/bin/sh
case "${1:-}" in running|restart|stop|start) exit 0 ;; *) exit 1 ;; esac
EOF
chmod 755 "$FAKE_ROOT/usr/local/bin/xray-latest" "$FAKE_ROOT/etc/init.d/xray" \
  "$FAKE_ROOT/etc/init.d/xray-transparent"

tree_hash() {
  (
    cd "$1"
    find . -type f -print | LC_ALL=C sort | xargs sha256sum | sha256sum | awk '{print $1}'
  )
}

backend() {
  env \
    PREMIER_ROUTER_HOST_TEST=1 \
    VPN_UI_SOURCE_ONLY=1 \
    VPN_UI_ROOT_PREFIX="$FAKE_ROOT" \
    VPN_UI_TEST_ACTIVE_XRAY_CONFIG="${VPN_UI_TEST_ACTIVE_XRAY_CONFIG:-/etc/xray/config.json}" \
    VPN_UI_XRAY_BIN="$FAKE_ROOT/usr/local/bin/xray-latest" \
    VPN_UI_XRAY_OVERLAY_HELPER="$FAKE_ROOT/usr/libexec/premier-router/xray-overlay.uc" \
    VPN_UI_UCODE_BIN="$UCODE" \
    VPN_UI_UPDATE_PERSIST_ROOT="$FAKE_ROOT/root/premier-router-updates" \
    VPN_UI_TEST_TAILSCALE_SNAPSHOT='pid=606;enabled=true;backend=Running;ip4=100.64.0.6;route=unchanged' \
    VPN_UI_TEST_ADOPT_FREE_BYTES="${VPN_UI_TEST_ADOPT_FREE_BYTES:-10485760}" \
    VPN_UI_TEST_ADOPT_FAIL_AFTER="${VPN_UI_TEST_ADOPT_FAIL_AFTER:-}" \
    VPN_UI_TEST_ADOPT_INVALID_AFTER_CONFIG="${VPN_UI_TEST_ADOPT_INVALID_AFTER_CONFIG:-0}" \
    VPN_UI_TEST_ADOPT_JOURNAL_FAIL_STATE="${VPN_UI_TEST_ADOPT_JOURNAL_FAIL_STATE:-}" \
    VPN_UI_TEST_TAILSCALE_SNAPSHOT_AFTER="${VPN_UI_TEST_TAILSCALE_SNAPSHOT_AFTER:-}" \
    VPN_UI_TEST_XRAY_VALIDATE_FAIL="${VPN_UI_TEST_XRAY_VALIDATE_FAIL:-0}" \
    VPN_UI_TEST_XRAY_RESTART_FAIL_ONCE="${VPN_UI_TEST_XRAY_RESTART_FAIL_ONCE:-0}" \
    VPN_UI_TEST_ADOPT_CRASH_AFTER="${VPN_UI_TEST_ADOPT_CRASH_AFTER:-}" \
    VPN_UI_TEST_ADOPT_DRIFT_BEFORE="${VPN_UI_TEST_ADOPT_DRIFT_BEFORE:-}" \
    VPN_UI_TEST_ADOPT_DRIFT_FILE="${VPN_UI_TEST_ADOPT_DRIFT_FILE:-}" \
    VPN_UI_TEST_ADOPT_HOLD_AFTER_LOCK="${VPN_UI_TEST_ADOPT_HOLD_AFTER_LOCK:-}" \
    VPN_UI_XRAY_TXN_RETAIN="${VPN_UI_XRAY_TXN_RETAIN:-4}" \
    sh -c '. "$1"; shift; "$@"' sh "$VPN_UI" "$@"
}

CONFIG="$FAKE_ROOT/etc/xray/config.json"
CONFIG_PRE_ADOPT_HASH="$(sha256sum "$CONFIG" | awk '{print $1}')"
mv "$CONFIG" "$CONFIG.real"
ln -s config.real "$CONFIG"
backend cmd_adoption_preview > "$TMP_ROOT/symlink-preview.json"
jq -e '.ok == false and (.error | contains("symlinked"))' "$TMP_ROOT/symlink-preview.json" >/dev/null
rm "$CONFIG"
mv "$CONFIG.real" "$CONFIG"
backend cmd_adoption_preview > "$TMP_ROOT/preview.json"
jq -e '
  .ok and .adoption.path == "/etc/xray/config.json" and
  .adoption.analysis.domain_count == 3 and .adoption.analysis.ip_count == 2 and
  (.adoption.config_sha256 | test("^[0-9a-f]{64}$")) and
  (.adoption.domain_sha256 | test("^[0-9a-f]{64}$")) and
  (.adoption.ip_sha256 | test("^[0-9a-f]{64}$"))
' "$TMP_ROOT/preview.json" >/dev/null
! grep -Fq '00000000-0000-4000-8000-000000000006' "$TMP_ROOT/preview.json"
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$CONFIG_PRE_ADOPT_HASH" ]

preview_hash="$(jq -r .adoption.config_sha256 "$TMP_ROOT/preview.json")"
domain_index="$(jq -r .adoption.analysis.domain_rule_index "$TMP_ROOT/preview.json")"
ip_index="$(jq -r .adoption.analysis.ip_rule_index "$TMP_ROOT/preview.json")"
UPDATE_TRANSACTION=20260810T120000Z-0123456789abcdef
mkdir -p "$FAKE_ROOT/root/premier-router-updates/$UPDATE_TRANSACTION"
printf '%s\n' "$UPDATE_TRANSACTION" > "$FAKE_ROOT/root/premier-router-updates/active-transaction"
printf '{"state":"committed_pending_reboot_validation"}\n' \
  > "$FAKE_ROOT/root/premier-router-updates/$UPDATE_TRANSACTION/state.json"
PENDING_TREE_HASH="$(tree_hash "$FAKE_ROOT/etc")"
backend cmd_auto_tick
[ "$(tree_hash "$FAKE_ROOT/etc")" = "$PENDING_TREE_HASH" ]
backend cmd_adoption_confirm /etc/xray/config.json "$preview_hash" "$domain_index" "$ip_index" \
  > "$TMP_ROOT/pending-confirm.json"
jq -e '.ok == false and (.error | contains("supervised reboot validation"))' \
  "$TMP_ROOT/pending-confirm.json" >/dev/null
[ ! -e "$FAKE_ROOT/etc/premier-router/xray-ownership.json" ]
[ ! -e "$FAKE_ROOT/etc/xray/direct-domains.txt" ]
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$CONFIG_PRE_ADOPT_HASH" ]
backend ownership_status_json > "$TMP_ROOT/pending-status.json"
jq -e '.mutations_allowed == false and
  (.mutation_block_reason | contains("supervised reboot validation"))' \
  "$TMP_ROOT/pending-status.json" >/dev/null
printf '{"state":"committed"}\n' \
  > "$FAKE_ROOT/root/premier-router-updates/$UPDATE_TRANSACTION/state.json"
backend cmd_adoption_confirm /etc/xray/config.json "$preview_hash" "$domain_index" "$ip_index" \
  > "$TMP_ROOT/confirm.json"
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$CONFIG_PRE_ADOPT_HASH" ]
jq -e '.mode == "adopted-overlay" and .path == "/etc/xray/config.json" and .config_sha256 == $hash' \
  --arg hash "$CONFIG_PRE_ADOPT_HASH" "$FAKE_ROOT/etc/premier-router/xray-ownership.json" >/dev/null
[ "$(grep -cv '^#' "$FAKE_ROOT/etc/xray/direct-domains.txt")" -eq 3 ]
[ "$(grep -cv '^#' "$FAKE_ROOT/etc/xray/direct-ips.txt")" -eq 2 ]
backend cmd_device disable 02:00:00:00:00:06 192.0.2.6 > "$TMP_ROOT/adopted-device.json"
jq -e '.ok == true and .ownership.mode == "adopted-overlay" and .ownership.healthy == true' \
  "$TMP_ROOT/adopted-device.json" >/dev/null
grep -Fxq '02:00:00:00:00:06' "$FAKE_ROOT/etc/xray/vpn-ui-device-bypass-macs.txt"
backend cmd_device enable 02:00:00:00:00:06 192.0.2.6 > "$TMP_ROOT/adopted-device-enabled.json"
jq -e '.ok == true' "$TMP_ROOT/adopted-device-enabled.json" >/dev/null
! grep -Fxq '02:00:00:00:00:06' "$FAKE_ROOT/etc/xray/vpn-ui-device-bypass-macs.txt"
backend cmd_xray off > "$TMP_ROOT/adopted-xray-off.json"
jq -e '.ok == true and .ownership.mode == "adopted-overlay"' "$TMP_ROOT/adopted-xray-off.json" >/dev/null
backend cmd_xray on > "$TMP_ROOT/adopted-xray-on.json"
jq -e '.ok == true and .ownership.healthy == true' "$TMP_ROOT/adopted-xray-on.json" >/dev/null
backend cmd_refresh_pings > "$TMP_ROOT/adopted-refresh.json"
jq -e '.ok == true' "$TMP_ROOT/adopted-refresh.json" >/dev/null
backend cmd_auto_config 0 0 12 '' > "$TMP_ROOT/adopted-auto.json"
jq -e '.ok == true and .auto.failover == false and .auto.periodic == false' \
  "$TMP_ROOT/adopted-auto.json" >/dev/null

cp "$CONFIG" "$FAKE_ROOT/etc/xray/other.json"
VPN_UI_TEST_ACTIVE_XRAY_CONFIG=/etc/xray/other.json \
  backend ownership_status_json > "$TMP_ROOT/path-drift.json"
VPN_UI_TEST_ACTIVE_XRAY_CONFIG=
jq -e '.mode == "adopted-overlay" and .healthy == false and
  .active_path == "/etc/xray/other.json" and .selectors_match == false' \
  "$TMP_ROOT/path-drift.json" >/dev/null

printf '%s\n' 'full:rc6-validation.invalid' > "$TMP_ROOT/new-domains"
printf '%s\n' '198.51.100.128/25' > "$TMP_ROOT/new-ips"
backend apply_adopted_rules "$TMP_ROOT/new-domains" "$TMP_ROOT/new-ips"
jq -e '
  .routing.rules[3].domain == ["full:rc6-validation.invalid"] and
  .routing.rules[4].ip == ["198.51.100.128/25"] and
  .routing.rules[0].ip[3] == "203.0.113.10/32" and
  .routing.rules[1].protocol == ["bittorrent"] and .routing.rules[2].port == "8080" and
  .routing.domainStrategy == "AsIs"
' "$CONFIG" >/dev/null
jq -e --arg hash "$(sha256sum "$CONFIG" | awk '{print $1}')" '.config_sha256 == $hash' \
  "$FAKE_ROOT/etc/premier-router/xray-ownership.json" >/dev/null

VPN_UI_TEST_ADOPT_HOLD_AFTER_LOCK=2 \
  backend apply_adopted_rules "$TMP_ROOT/new-domains" "$TMP_ROOT/new-ips" \
    > "$TMP_ROOT/concurrent-first.json" &
concurrent_pid=$!
tries=0
while [ ! -f "$FAKE_ROOT/etc/premier-router/xray-transactions/lock/owner" ]; do
  tries=$((tries + 1))
  [ "$tries" -lt 50 ] || { printf 'overlay lock did not appear\n' >&2; exit 1; }
  sleep 0.1
done
backend apply_adopted_rules "$TMP_ROOT/new-domains" "$TMP_ROOT/new-ips" \
  > "$TMP_ROOT/concurrent-second.json"
jq -e '.ok == false and (.error | contains("another adopted-overlay transaction"))' \
  "$TMP_ROOT/concurrent-second.json" >/dev/null
wait "$concurrent_pid"
[ ! -d "$FAKE_ROOT/etc/premier-router/xray-transactions/lock" ]
! find "$FAKE_ROOT/etc/xray" -maxdepth 1 -name '.*.vpn-ui-candidate.*' -print | grep -q .

# An owner record is installed atomically. A second process must treat the
# brief ownerless directory window as active instead of stealing the lock.
mkdir "$FAKE_ROOT/etc/premier-router/xray-transactions/lock"
backend apply_adopted_rules "$TMP_ROOT/new-domains" "$TMP_ROOT/new-ips" \
  > "$TMP_ROOT/ownerless-lock.json"
jq -e '.ok == false and (.error | contains("another adopted-overlay transaction"))' \
  "$TMP_ROOT/ownerless-lock.json" >/dev/null
[ -d "$FAKE_ROOT/etc/premier-router/xray-transactions/lock" ]
rmdir "$FAKE_ROOT/etc/premier-router/xray-transactions/lock"

ROLLBACK_CONFIG_HASH="$(sha256sum "$CONFIG" | awk '{print $1}')"
ROLLBACK_DOMAIN_HASH="$(sha256sum "$FAKE_ROOT/etc/xray/direct-domains.txt" | awk '{print $1}')"
ROLLBACK_IP_HASH="$(sha256sum "$FAKE_ROOT/etc/xray/direct-ips.txt" | awk '{print $1}')"
ROLLBACK_STATE_HASH="$(sha256sum "$FAKE_ROOT/etc/premier-router/xray-ownership.json" | awk '{print $1}')"
printf '%s\n' 'full:must-roll-back.invalid' > "$TMP_ROOT/failing-domains"

cp "$CONFIG" "$TMP_ROOT/pre-toctou-config.json"
jq '.log.loglevel = "error"' "$CONFIG" > "$TMP_ROOT/external-drift.json"
EXTERNAL_DRIFT_HASH="$(sha256sum "$TMP_ROOT/external-drift.json" | awk '{print $1}')"
VPN_UI_TEST_ADOPT_DRIFT_BEFORE=config VPN_UI_TEST_ADOPT_DRIFT_FILE="$TMP_ROOT/external-drift.json" \
  backend apply_adopted_rules "$TMP_ROOT/failing-domains" "$TMP_ROOT/new-ips" \
    > "$TMP_ROOT/toctou-config.json"
VPN_UI_TEST_ADOPT_DRIFT_BEFORE=
VPN_UI_TEST_ADOPT_DRIFT_FILE=
jq -e '.ok == false and (.error | contains("immediately before live configuration commit")) and
  (.error | contains("external Xray bytes were preserved"))' "$TMP_ROOT/toctou-config.json" >/dev/null
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$EXTERNAL_DRIFT_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-domains.txt" | awk '{print $1}')" = "$ROLLBACK_DOMAIN_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-ips.txt" | awk '{print $1}')" = "$ROLLBACK_IP_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/premier-router/xray-ownership.json" | awk '{print $1}')" = "$ROLLBACK_STATE_HASH" ]
cp "$TMP_ROOT/pre-toctou-config.json" "$CONFIG"
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$ROLLBACK_CONFIG_HASH" ]

VPN_UI_TEST_ADOPT_DRIFT_BEFORE=config-final \
  VPN_UI_TEST_ADOPT_DRIFT_FILE="$TMP_ROOT/external-drift.json" \
  backend apply_adopted_rules "$TMP_ROOT/failing-domains" "$TMP_ROOT/new-ips" \
    > "$TMP_ROOT/toctou-config-final.json"
VPN_UI_TEST_ADOPT_DRIFT_BEFORE=
VPN_UI_TEST_ADOPT_DRIFT_FILE=
jq -e '.ok == false and (.error | contains("immediately before live configuration replacement")) and
  (.error | contains("external Xray bytes were preserved"))' \
  "$TMP_ROOT/toctou-config-final.json" >/dev/null
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$EXTERNAL_DRIFT_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-domains.txt" | awk '{print $1}')" = "$ROLLBACK_DOMAIN_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-ips.txt" | awk '{print $1}')" = "$ROLLBACK_IP_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/premier-router/xray-ownership.json" | awk '{print $1}')" = "$ROLLBACK_STATE_HASH" ]
cp "$TMP_ROOT/pre-toctou-config.json" "$CONFIG"
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$ROLLBACK_CONFIG_HASH" ]

if VPN_UI_TEST_ADOPT_CRASH_AFTER=rules \
  backend apply_adopted_rules "$TMP_ROOT/failing-domains" "$TMP_ROOT/new-ips" \
    > "$TMP_ROOT/crash-rules.json"; then
  printf 'rules-phase crash injection unexpectedly returned success\n' >&2
  exit 1
else
  [ "$?" -eq 99 ]
fi
[ -d "$FAKE_ROOT/etc/premier-router/xray-transactions/lock" ]
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$ROLLBACK_CONFIG_HASH" ]
backend cmd_overlay_recover > "$TMP_ROOT/recover-rules.json"
jq -e '.ok and .recovered' "$TMP_ROOT/recover-rules.json" >/dev/null
[ ! -d "$FAKE_ROOT/etc/premier-router/xray-transactions/lock" ]
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$ROLLBACK_CONFIG_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-domains.txt" | awk '{print $1}')" = "$ROLLBACK_DOMAIN_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-ips.txt" | awk '{print $1}')" = "$ROLLBACK_IP_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/premier-router/xray-ownership.json" | awk '{print $1}')" = "$ROLLBACK_STATE_HASH" ]

if VPN_UI_TEST_ADOPT_CRASH_AFTER=config \
  backend apply_adopted_rules "$TMP_ROOT/failing-domains" "$TMP_ROOT/new-ips" \
    > "$TMP_ROOT/crash-config.json"; then
  printf 'config-phase crash injection unexpectedly returned success\n' >&2
  exit 1
else
  [ "$?" -eq 99 ]
fi
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" != "$ROLLBACK_CONFIG_HASH" ]
backend cmd_overlay_recover > "$TMP_ROOT/recover-config.json"
VPN_UI_TEST_ADOPT_CRASH_AFTER=
jq -e '.ok and .recovered' "$TMP_ROOT/recover-config.json" >/dev/null
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$ROLLBACK_CONFIG_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-domains.txt" | awk '{print $1}')" = "$ROLLBACK_DOMAIN_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-ips.txt" | awk '{print $1}')" = "$ROLLBACK_IP_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/premier-router/xray-ownership.json" | awk '{print $1}')" = "$ROLLBACK_STATE_HASH" ]

for boundary in after-backup after-rules after-config after-restart after-state; do
  VPN_UI_TEST_ADOPT_FAIL_AFTER="$boundary" \
    backend apply_adopted_rules "$TMP_ROOT/failing-domains" "$TMP_ROOT/new-ips" \
      > "$TMP_ROOT/rollback-$boundary.json"
  case "$boundary" in
    after-backup|after-rules)
      jq -e '.ok == false and
        (.error | contains("route lists and management state restored while external Xray bytes were preserved"))' \
        "$TMP_ROOT/rollback-$boundary.json" >/dev/null
      ;;
    *)
      jq -e '.ok == false and
        (.error | contains("exact Xray configuration, route lists, and management state restored"))' \
        "$TMP_ROOT/rollback-$boundary.json" >/dev/null
      ;;
  esac
  [ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$ROLLBACK_CONFIG_HASH" ]
  [ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-domains.txt" | awk '{print $1}')" = "$ROLLBACK_DOMAIN_HASH" ]
  [ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-ips.txt" | awk '{print $1}')" = "$ROLLBACK_IP_HASH" ]
  [ "$(sha256sum "$FAKE_ROOT/etc/premier-router/xray-ownership.json" | awk '{print $1}')" = "$ROLLBACK_STATE_HASH" ]
done
VPN_UI_TEST_ADOPT_FAIL_AFTER=

VPN_UI_TEST_ADOPT_JOURNAL_FAIL_STATE=prepared \
  backend apply_adopted_rules "$TMP_ROOT/failing-domains" "$TMP_ROOT/new-ips" \
    > "$TMP_ROOT/journal-prepared.json"
VPN_UI_TEST_ADOPT_JOURNAL_FAIL_STATE=
jq -e '.ok == false and (.error | contains("private apply journal"))' \
  "$TMP_ROOT/journal-prepared.json" >/dev/null
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$ROLLBACK_CONFIG_HASH" ]

VPN_UI_TEST_ADOPT_JOURNAL_FAIL_STATE=committed \
  backend apply_adopted_rules "$TMP_ROOT/failing-domains" "$TMP_ROOT/new-ips" \
    > "$TMP_ROOT/journal-committed.json"
VPN_UI_TEST_ADOPT_JOURNAL_FAIL_STATE=
jq -e '.ok == false and (.error | contains("journal commit failed")) and
  (.error | contains("exact Xray configuration"))' "$TMP_ROOT/journal-committed.json" >/dev/null
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$ROLLBACK_CONFIG_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-domains.txt" | awk '{print $1}')" = "$ROLLBACK_DOMAIN_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-ips.txt" | awk '{print $1}')" = "$ROLLBACK_IP_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/premier-router/xray-ownership.json" | awk '{print $1}')" = "$ROLLBACK_STATE_HASH" ]

VPN_UI_TEST_ADOPT_INVALID_AFTER_CONFIG=1 \
  backend apply_adopted_rules "$TMP_ROOT/failing-domains" "$TMP_ROOT/new-ips" \
    > "$TMP_ROOT/invalid-installed.json"
VPN_UI_TEST_ADOPT_INVALID_AFTER_CONFIG=0
jq -e '.ok == false and (.error | contains("installed Xray validation failed")) and
  (.error | contains("exact Xray configuration"))' "$TMP_ROOT/invalid-installed.json" >/dev/null
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$ROLLBACK_CONFIG_HASH" ]

VPN_UI_TEST_TAILSCALE_SNAPSHOT_AFTER='pid=999;enabled=true;backend=Running;ip4=100.64.0.6;route=changed' \
  backend apply_adopted_rules "$TMP_ROOT/new-domains" "$TMP_ROOT/new-ips" > "$TMP_ROOT/tailscale-rollback.json"
VPN_UI_TEST_TAILSCALE_SNAPSHOT_AFTER=
jq -e '.ok == false and (.error | contains("Tailscale PID"))' "$TMP_ROOT/tailscale-rollback.json" >/dev/null
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$ROLLBACK_CONFIG_HASH" ]

VPN_UI_TEST_XRAY_VALIDATE_FAIL=1 \
  backend apply_adopted_rules "$TMP_ROOT/new-domains" "$TMP_ROOT/new-ips" > "$TMP_ROOT/validation-failure.json"
VPN_UI_TEST_XRAY_VALIDATE_FAIL=0
jq -e '.ok == false and (.error | contains("Xray validation failed"))' "$TMP_ROOT/validation-failure.json" >/dev/null
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$ROLLBACK_CONFIG_HASH" ]

printf '%s\n' 'full:restart-must-roll-back.invalid' > "$TMP_ROOT/restart-domains"
VPN_UI_TEST_XRAY_RESTART_FAIL_ONCE=1 \
  backend apply_adopted_rules "$TMP_ROOT/restart-domains" "$TMP_ROOT/new-ips" > "$TMP_ROOT/restart-failure.json"
VPN_UI_TEST_XRAY_RESTART_FAIL_ONCE=0
jq -e '.ok == false and (.error | contains("Xray restart failed")) and (.error | contains("exact Xray configuration"))' \
  "$TMP_ROOT/restart-failure.json" >/dev/null
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$ROLLBACK_CONFIG_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-domains.txt" | awk '{print $1}')" = "$ROLLBACK_DOMAIN_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/direct-ips.txt" | awk '{print $1}')" = "$ROLLBACK_IP_HASH" ]
[ "$(sha256sum "$FAKE_ROOT/etc/premier-router/xray-ownership.json" | awk '{print $1}')" = "$ROLLBACK_STATE_HASH" ]

VPN_UI_TEST_ADOPT_FREE_BYTES=0 \
  backend apply_adopted_rules "$TMP_ROOT/new-domains" "$TMP_ROOT/new-ips" > "$TMP_ROOT/storage-zero.json"
VPN_UI_TEST_ADOPT_FREE_BYTES=10485760
required="$(jq -r '.error | capture("requires (?<n>[0-9]+) free bytes").n' "$TMP_ROOT/storage-zero.json")"
[ "$required" -gt 65536 ]
VPN_UI_TEST_ADOPT_FREE_BYTES="$((required - 1))" \
  backend apply_adopted_rules "$TMP_ROOT/new-domains" "$TMP_ROOT/new-ips" > "$TMP_ROOT/storage-below.json"
jq -e '.ok == false and (.error | contains("free bytes"))' "$TMP_ROOT/storage-below.json" >/dev/null
VPN_UI_TEST_ADOPT_FREE_BYTES="$required" \
  backend apply_adopted_rules "$TMP_ROOT/new-domains" "$TMP_ROOT/new-ips"

retained_transactions="$(find "$FAKE_ROOT/etc/premier-router/xray-transactions" \
  -mindepth 1 -maxdepth 1 -type d \( -name '*-adoption-*' -o -name '*-apply-*' \) |
  wc -l | tr -d ' ')"
[ "$retained_transactions" -le 4 ]
[ ! -d "$FAKE_ROOT/etc/premier-router/xray-transactions/lock" ]
! find "$FAKE_ROOT/etc/xray" -maxdepth 1 -name '.*.vpn-ui-candidate.*' -print | grep -q .

printf 'Adopted-overlay preview, exact adoption, structural apply, fail-closed rollback, Tailscale, validation, and storage tests passed\n'
