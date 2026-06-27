#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/uci" <<'EOF'
#!/bin/sh
log="${TEST_UCI_LOG:?}"
case "$*" in
  "show wireless")
    printf '%s\n' \
      "wireless.radio0=wifi-device" \
      "wireless.radio1=wifi-device"
    ;;
  "-q get wireless.radio0.band") printf '%s\n' "2g" ;;
  "-q get wireless.radio1.band") printf '%s\n' "5g" ;;
  "-q get wireless.radio0.hwmode"|"-q get wireless.radio1.hwmode") exit 1 ;;
  *) printf '%s\n' "$*" >> "$log" ;;
esac
EOF

cat > "$TMP_DIR/wifi" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${TEST_WIFI_LOG:?}"
EOF

chmod 0755 "$TMP_DIR/uci" "$TMP_DIR/wifi"
export TEST_UCI_LOG="$TMP_DIR/uci.log"
export TEST_WIFI_LOG="$TMP_DIR/wifi.log"
PATH="$TMP_DIR:$PATH"
export PATH

FIRSTBOOT_SETUP_LIB_ONLY=1 STATE_DIR="$TMP_DIR/state" \
  . "$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"

radios="$(wifi_radios_json)"
printf '%s' "$radios" | grep -q '"device":"radio0","band":"2g"'
printf '%s' "$radios" | grep -q '"device":"radio1","band":"5g"'

configure_wifi true true true "Test WiFi" sae-mixed "test-password" US auto 36 false true

grep -q 'set wireless.firstboot_2g.device=radio0' "$TEST_UCI_LOG"
grep -q 'set wireless.firstboot_5g.device=radio1' "$TEST_UCI_LOG"
grep -q 'set wireless.firstboot_2g.encryption=sae-mixed' "$TEST_UCI_LOG"
grep -q 'set wireless.radio1.channel=36' "$TEST_UCI_LOG"
grep -q '^reload$' "$TEST_WIFI_LOG"

mkdir -p "$STATE_DIR"
touch "$IN_PROGRESS_FILE"
mark_phase_done account
status="$(ok_status)"
printf '%s' "$status" | grep -q '"complete":false'
printf '%s' "$status" | grep -q '"inProgress":true'
printf '%s' "$status" | grep -q '"completedPhases":\["account"\]'

printf '%s\n' "first-boot Wi-Fi UCI regression test passed"
