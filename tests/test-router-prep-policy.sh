#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/state" "$TMP_DIR/menu"
cat > "$TMP_DIR/uci" <<'EOF'
#!/bin/sh
case "$*" in
  "-q delete firewall.router_prep_adguard") exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod 0755 "$TMP_DIR/uci"
PATH="$TMP_DIR:$PATH"
export PATH

ROUTER_PREP_STATE_DIR="$TMP_DIR/state" \
  sh "$ROOT_DIR/image-overlay/usr/sbin/router-prep" init
[ -s "$TMP_DIR/state/token" ]
[ -f "$TMP_DIR/state/customer-policy.conf" ]

cat > "$TMP_DIR/state/customer-policy.conf" <<'EOF'
CUSTOMER_VPN='1'
CUSTOMER_TAILSCALE='0'
CUSTOMER_UPDATE='0'
CUSTOMER_PACKAGES='0'
CUSTOMER_ADGUARD='1'
EOF
printf '%s\n' '{"package-manager":true}' > "$TMP_DIR/menu/packages.json"

ROUTER_PREP_STATE_DIR="$TMP_DIR/state" \
ROUTER_PREP_MENU_FILE="$TMP_DIR/menu/vpn.json" \
ROUTER_PREP_PACKAGE_MENU="$TMP_DIR/menu/packages.json" \
  sh "$ROOT_DIR/image-overlay/usr/sbin/router-prep" apply-policy

grep -q '"admin/network/vpn"' "$TMP_DIR/menu/vpn.json"
! grep -q '"admin/network/tailscale"' "$TMP_DIR/menu/vpn.json"
! grep -q '"admin/update"' "$TMP_DIR/menu/vpn.json"
[ -f "$TMP_DIR/menu/packages.json.router-prep-disabled" ]

sed "s/CUSTOMER_TAILSCALE='0'/CUSTOMER_TAILSCALE='1'/; s/CUSTOMER_UPDATE='0'/CUSTOMER_UPDATE='1'/; s/CUSTOMER_PACKAGES='0'/CUSTOMER_PACKAGES='1'/" \
  "$TMP_DIR/state/customer-policy.conf" > "$TMP_DIR/state/customer-policy.conf.new"
mv "$TMP_DIR/state/customer-policy.conf.new" "$TMP_DIR/state/customer-policy.conf"

ROUTER_PREP_STATE_DIR="$TMP_DIR/state" \
ROUTER_PREP_MENU_FILE="$TMP_DIR/menu/vpn.json" \
ROUTER_PREP_PACKAGE_MENU="$TMP_DIR/menu/packages.json" \
  sh "$ROOT_DIR/image-overlay/usr/sbin/router-prep" apply-policy

grep -q '"admin/network/tailscale"' "$TMP_DIR/menu/vpn.json"
grep -q '"admin/update"' "$TMP_DIR/menu/vpn.json"
[ -f "$TMP_DIR/menu/packages.json" ]

printf '%s\n' "router preparation policy regression test passed"
