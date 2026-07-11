#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VPN_UI="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
ROUTER_PREP="$ROOT_DIR/image-overlay/usr/sbin/router-prep"
DEFAULT_CONFIG="$ROOT_DIR/luci-vpn-ui/files/etc/config/premier_router"
VERSION_FILE="$ROOT_DIR/luci-vpn-ui/files/usr/share/vpn-ui/version"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/router-metadata-test.XXXXXX")"
FAKE_STATE="$TMP_DIR/uci-state"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/router-prep"
: > "$FAKE_STATE"

cat > "$TMP_DIR/bin/opkg" <<'EOF'
#!/bin/sh
[ "${1:-}" = status ] || exit 1
printf 'Package: %s\nVersion: 0.8.0-1\nStatus: install user installed\n' "${2:-unknown}"
EOF
chmod 755 "$TMP_DIR/bin/opkg"
cat > "$TMP_DIR/build-info" <<'EOF'
VERSION=0.8.0
PACKAGE_VERSION=0.8.0-1
SOURCE_COMMIT=1234567890abcdef1234567890abcdef12345678
SOURCE_DIRTY=0
BUILD_DATE=
EOF
cat > "$TMP_DIR/manifest.json" <<'EOF'
{"package_version":"0.8.0-1","generated_at":"2026-07-11T00:00:00Z"}
EOF
cat > "$TMP_DIR/openwrt_release" <<'EOF'
DISTRIB_RELEASE='24.10.5'
DISTRIB_TARGET='x86/64'
EOF

cat > "$TMP_DIR/bin/uci" <<'EOF'
#!/bin/sh
set -eu

state="${FAKE_UCI_STATE:?}"
[ "${1:-}" != "-q" ] || shift
command="${1:-}"
[ "$#" -eq 0 ] || shift

case "$command" in
  get)
    key="${1:-}"
    value="$(sed -n "s|^$key=||p" "$state" | tail -n 1)"
    [ -n "$value" ] || exit 1
    printf '%s\n' "$value"
    ;;
  set)
    assignment="${1:-}"
    key="${assignment%%=*}"
    value="${assignment#*=}"
    tmp="$state.tmp.$$"
    awk -F= -v key="$key" '$1 != key { print }' "$state" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$state"
    ;;
  commit)
    ;;
  *)
    printf 'unsupported fake uci command: %s\n' "$command" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "$TMP_DIR/bin/uci"

cat > "$TMP_DIR/bin/vpn-ui" <<EOF
#!/bin/sh
FAKE_UCI_STATE='$FAKE_STATE' \\
VPN_UI_UCI_BIN='$TMP_DIR/bin/uci' \\
VPN_UI_VERSION_FILE='$VERSION_FILE' \\
exec sh '$VPN_UI' "\$@"
EOF
chmod 755 "$TMP_DIR/bin/vpn-ui"

run_vpn_ui() {
  FAKE_UCI_STATE="$FAKE_STATE" \
  VPN_UI_UCI_BIN="$TMP_DIR/bin/uci" \
  VPN_UI_VERSION_FILE="$VERSION_FILE" \
  VPN_UI_OPKG_BIN="$TMP_DIR/bin/opkg" \
  VPN_UI_BUILD_INFO_FILE="$TMP_DIR/build-info" \
  VPN_UI_INSTALLED_MANIFEST_FILE="$TMP_DIR/manifest.json" \
  VPN_UI_OPENWRT_RELEASE_FILE="$TMP_DIR/openwrt_release" \
  VPN_UI_HARDWARE_PROFILE=generic \
    sh "$VPN_UI" "$@"
}

for expected in \
  "option install_method 'manual-ipk-install'" \
  "option install_source 'package-first-local-ipk'" \
  "option support_level 'self-managed'" \
  "option registration_state 'local-only'" \
  "option direct_rules_channel 'stable'" \
  "option support_visible '1'" \
  "option support_tailnet_enabled '0'" \
  "option footer_enabled '1'" \
  "option footer_mode 'compact'" \
  "option prepared_by_owner '0'" \
  "option sealed '0'"
do
  grep -Fq "$expected" "$DEFAULT_CONFIG"
done

defaults="$(run_vpn_ui footer-info)"
printf '%s\n' "$defaults" | grep -q '"ok":true'
printf '%s\n' "$defaults" | grep -q '"version":"0.8.0"'
printf '%s\n' "$defaults" | grep -q '"install_method":"manual-ipk-install"'
printf '%s\n' "$defaults" | grep -q '"install_source":"package-first-local-ipk"'
printf '%s\n' "$defaults" | grep -q '"support_level":"self-managed"'
printf '%s\n' "$defaults" | grep -q '"registration_state":"local-only"'
printf '%s\n' "$defaults" | grep -q '"direct_rules_channel":"stable"'
printf '%s\n' "$defaults" | grep -q '"support_access_state":"disabled"'
printf '%s\n' "$defaults" | grep -q '"router_id_short":"pr-[0-9a-f][0-9a-f]*"'
printf '%s\n' "$defaults" | grep -q '"footer_label":"Router Scripts v0.8.0 (manual-ipk-install, support: self-managed, registration: local-only, support access: disabled)"'

full_router_id="$(sed -n 's/^premier_router.router.router_id=//p' "$FAKE_STATE")"
[ -n "$full_router_id" ]
case "$defaults" in *"$full_router_id"*) printf 'full router id leaked\n' >&2; exit 1 ;; esac

installed="$(run_vpn_ui metadata-installed package-first-staged)"
printf '%s\n' "$installed" | grep -q '"install_source":"package-first-staged"'
installed_at="$(printf '%s\n' "$installed" | sed -n 's/.*"installed_at":"\([^"]*\)".*/\1/p')"
[ -n "$installed_at" ]
reinstalled="$(run_vpn_ui metadata-installed package-first-staged)"
printf '%s\n' "$reinstalled" | grep -Fq "\"installed_at\":\"$installed_at\""

build="$(run_vpn_ui installed-build)"
printf '%s\n' "$build" | grep -q '"package_version":"0.8.0-1"'
printf '%s\n' "$build" | grep -q '"source_commit_short":"1234567890ab"'
printf '%s\n' "$build" | grep -q '"build_date":"2026-07-11T00:00:00Z"'
printf '%s\n' "$build" | grep -Fq "\"installed_at\":\"$installed_at\""
printf '%s\n' "$build" | grep -q '"manifest_present":true'
printf '%s\n' "$build" | grep -q '"package_set_verified":true'
printf '%s\n' "$build" | grep -q '"openwrt_version":"24.10.5"'
printf '%s\n' "$build" | grep -q '"openwrt_target":"x86/64"'

run_vpn_ui metadata-set owner-prepared-standard standard support-disabled 1 0 >/dev/null
run_vpn_ui metadata-init >/dev/null
preserved="$(run_vpn_ui router-metadata)"
printf '%s\n' "$preserved" | grep -q '"install_method":"owner-prepared-standard"'
printf '%s\n' "$preserved" | grep -q '"support_level":"standard"'
printf '%s\n' "$preserved" | grep -q '"registration_state":"support-disabled"'
printf '%s\n' "$preserved" | grep -q '"prepared_by_owner":true'
[ "$(sed -n 's/^premier_router.router.router_id=//p' "$FAKE_STATE")" = "$full_router_id" ]

ROUTER_PREP_STATE_DIR="$TMP_DIR/router-prep" \
ROUTER_PREP_VPN_UI_BIN="$TMP_DIR/bin/vpn-ui" \
  sh "$ROUTER_PREP" policy owner-prepared-managed 1 0 1 0 1 1 managed support-enabled
managed="$(run_vpn_ui footer-info)"
printf '%s\n' "$managed" | grep -q '"install_method":"owner-prepared-managed"'
printf '%s\n' "$managed" | grep -q '"support_level":"managed"'
printf '%s\n' "$managed" | grep -q '"registration_state":"support-enabled"'
printf '%s\n' "$managed" | grep -q '"support_tailnet_enabled":true'
printf '%s\n' "$managed" | grep -q '"support_access_state":"enabled"'

ROUTER_PREP_STATE_DIR="$TMP_DIR/router-prep" \
ROUTER_PREP_VPN_UI_BIN="$TMP_DIR/bin/vpn-ui" \
  sh "$ROUTER_PREP" policy owner-prepared-managed 1 0 1 0 1 1 priority support-registered
priority="$(run_vpn_ui metadata)"
printf '%s\n' "$priority" | grep -q '"support_level":"priority"'
printf '%s\n' "$priority" | grep -q '"registration_state":"support-registered"'

ROUTER_PREP_STATE_DIR="$TMP_DIR/router-prep" \
ROUTER_PREP_VPN_UI_BIN="$TMP_DIR/bin/vpn-ui" \
  sh "$ROUTER_PREP" seal
sealed="$(run_vpn_ui router-metadata)"
printf '%s\n' "$sealed" | grep -q '"sealed":true'

invalid="$(run_vpn_ui metadata-set invalid self-managed local-only)"
printf '%s\n' "$invalid" | grep -q '"ok":false'

all_output="$defaults$preserved$managed$priority$sealed"
printf '%s' "$all_output" | grep -Eqi 'auth.?key|preauth|nodekey|client.?uuid|subscription.?url|vless://|private key|password=' && {
  printf 'metadata output contains secret-shaped fields\n' >&2
  exit 1
}

printf 'Router metadata behavior checks passed\n'
