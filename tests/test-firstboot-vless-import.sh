#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/vpn-ui" <<'EOF'
#!/bin/sh
case "$1" in
  validate-vless)
    printf '%s\n' '{"ok":true,"profile":{"id":"profile-test-id"}}'
    ;;
  add)
    # The real add command returns panel status, not profile.id.
    printf '%s\n' '{"ok":true,"profiles":[{"id":"profile-test-id"}]}'
    ;;
  *)
    printf '%s\n' '{"ok":false,"error":"unexpected command"}'
    exit 1
    ;;
esac
EOF

cat > "$TMP_DIR/jsonfilter" <<'EOF'
#!/bin/sh
expression=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -e) expression="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$expression" in
  '@.profile.id') printf '%s\n' 'profile-test-id' ;;
esac
EOF

chmod 0755 "$TMP_DIR/vpn-ui" "$TMP_DIR/jsonfilter"

FIRSTBOOT_SETUP_LIB_ONLY=1 \
VPN_UI_BIN="$TMP_DIR/vpn-ui" \
JSONFILTER_BIN="$TMP_DIR/jsonfilter" \
  . "$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"

import_vless_profile 'vless://redacted@example.test:443?security=reality&pbk=redacted&sid=redacted'
[ "$VPN_PROFILE_ID" = "profile-test-id" ]

printf '%s\n' "first-boot VLESS import ID regression test passed"
