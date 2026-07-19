#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firstboot-wifi-test.XXXXXX")"
LOG_FILE="$TMP_DIR/uci.log"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

FIRSTBOOT_SETUP_LIB_ONLY=1 . "$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"

uci() {
  [ "${1:-}" != "-q" ] || shift
  case "${1:-}" in
    show)
      [ "${2:-}" = "wireless" ] && {
        printf '%s\n' \
          'wireless.radio0=wifi-device' \
          'wireless.radio1=wifi-device'
      }
      ;;
    get)
      case "${2:-}" in
        wireless.radio0.band) printf '%s\n' 2g ;;
        wireless.radio1.band) printf '%s\n' 5g ;;
        *) return 1 ;;
      esac
      ;;
    set|delete|commit)
      printf '%s\n' "$*" >> "$LOG_FILE"
      ;;
    *) return 1 ;;
  esac
}

wifi() {
  printf 'wifi %s\n' "$*" >> "$LOG_FILE"
}

: > "$LOG_FILE"
configure_wifi true true true 'Customer WiFi' sae-mixed 'test-password' ru auto 36 false true
grep -Fq 'set wireless.radio0.country=RU' "$LOG_FILE"
grep -Fq 'set wireless.radio1.country=RU' "$LOG_FILE"
grep -Fq 'set wireless.firstboot_2g=wifi-iface' "$LOG_FILE"
grep -Fq 'set wireless.firstboot_5g=wifi-iface' "$LOG_FILE"
grep -Fq 'set wireless.firstboot_2g.ssid=Customer WiFi' "$LOG_FILE"
grep -Fq 'set wireless.firstboot_5g.ssid=Customer WiFi' "$LOG_FILE"
grep -Fq 'set wireless.firstboot_2g.encryption=sae-mixed' "$LOG_FILE"
grep -Fq 'set wireless.firstboot_2g.key=test-password' "$LOG_FILE"
grep -Fq 'set wireless.radio1.channel=36' "$LOG_FILE"
grep -Fq 'set wireless.firstboot_2g.isolate=true' "$LOG_FILE"
grep -Fq 'wifi reload' "$LOG_FILE"

: > "$LOG_FILE"
configure_wifi true true false 'Open Guest' none '' us 11 auto true false
grep -Fq 'set wireless.firstboot_2g.encryption=none' "$LOG_FILE"
grep -Fq 'delete wireless.firstboot_2g.key' "$LOG_FILE"
if grep -Fq 'set wireless.firstboot_2g.key=' "$LOG_FILE"; then
  printf 'open Wi-Fi configuration unexpectedly wrote a password\n' >&2
  exit 1
fi

invalid_password="$(configure_wifi true true false 'Customer WiFi' psk2 short US auto auto false false)"
printf '%s\n' "$invalid_password" | grep -Fq 'Wi-Fi password must be 8 to 63 characters.'
invalid_country="$(configure_wifi true true false 'Customer WiFi' psk2 'test-password' USA auto auto false false)"
printf '%s\n' "$invalid_country" | grep -Fq 'Wi-Fi country code must contain two letters.'
invalid_channel="$(configure_wifi true true false 'Customer WiFi' psk2 'test-password' US 14 auto false false)"
printf '%s\n' "$invalid_channel" | grep -Fq 'Invalid 2.4 GHz channel.'

printf '%s\n' 'First-boot Wi-Fi configuration checks passed'
