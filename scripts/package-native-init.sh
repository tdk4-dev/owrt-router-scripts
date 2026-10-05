#!/bin/sh
# Online setup-package install only: initialize untouched upstream Xray defaults.
# Existing/manual/adopted state is deliberately left for its existing owner.
pr_initialize_clean_native_xray() (
  root="${1:-}"
  config="$root/etc/config/xray"
  [ -f "$config" ] && [ ! -L "$config" ] || exit 0
  for directory in "$root/etc/config" "$root/etc/xray"; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || exit 0
  done
  for existing in "$root/etc/firstboot-wizard/complete" \
    "$root/etc/premier-router/xray-ownership.json" "$root/etc/init.d/xray-exit-st"; do
    [ ! -e "$existing" ] && [ ! -L "$existing" ] || exit 0
  done
  [ -z "$(find "$root/etc/xray" -mindepth 1 ! -name config.json.example -print)" ] || exit 0
  [ ! -L "$root/etc/xray/config.json.example" ] || exit 0
  [ -z "$(pidof xray xray-latest 2>/dev/null || true)" ] || exit 0
  pending="$(uci -q changes xray)" || exit 1
  [ -z "$pending" ] || exit 0
  expected="$(cat <<'EOF' | LC_ALL=C sort
xray.enabled=xray
xray.enabled.enabled='0'
xray.config=xray
xray.config.confdir='/etc/xray'
xray.config.conffiles='/etc/xray/config.json'
xray.config.datadir='/usr/share/xray'
xray.config.format='json'
EOF
)"
  actual="$(uci -q show xray)" || exit 1
  actual="$(printf '%s\n' "$actual" | LC_ALL=C sort)"
  [ "$actual" = "$expected" ] || exit 0

  saved="$(mktemp -d "$root/tmp/premier-router-native-init.XXXXXX")" || exit 1
  cp -p "$config" "$saved/xray" || { rmdir "$saved"; exit 1; }
  cleanup_native_init() {
    code=$?
    if [ "$code" -ne 0 ]; then
      uci -q revert xray || true
      cp -p "$saved/xray" "$config" || code=1
    fi
    rm -rf "$saved"
    exit "$code"
  }
  trap cleanup_native_init EXIT
  trap 'exit 1' HUP INT TERM
  uci set xray.config.conffiles=/etc/xray/exit-st-cf.json &&
    uci -q delete xray.config.confdir && uci commit xray || exit 1
  # Keep Xray disabled until the administrator selects a profile and enables VPN.
  # The existing native renderer creates/validates the config on first selection.
)
