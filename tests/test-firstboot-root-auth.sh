#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/ubus" <<'EOF'
#!/bin/sh
case "$*" in
  'call session login '*)
    printf '%s\n' '{"ubus_rpc_session":"verified-session"}'
    ;;
  *)
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
[ "$expression" = '@.ubus_rpc_session' ] && printf '%s\n' 'verified-session'
EOF

chmod 0755 "$TMP_DIR/ubus" "$TMP_DIR/jsonfilter"

FIRSTBOOT_SETUP_LIB_ONLY=1 \
UBUS_BIN="$TMP_DIR/ubus" \
JSONFILTER_BIN="$TMP_DIR/jsonfilter" \
  . "$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"

verify_root_login 'test-password'

UBUS_BIN=/bin/false
if verify_root_login 'test-password'; then
  printf '%s\n' "root authentication verification accepted a failed login" >&2
  exit 1
fi

printf '%s\n' "first-boot root authentication regression test passed"
