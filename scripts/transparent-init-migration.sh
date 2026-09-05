#!/bin/sh
# Sourced in package preinst/postinst; never execute a retained init during migration.
transparent_init_check() {
  local init="$1"
  [ ! -L "$init" ] || return 1
  [ -e "$init" ] || return 0
  [ -f "$init" ] && [ "$(wc -c < "$init")" -le 1048576 ] || return 1
  sh -n "$init" || return 1
  [ "$(sed -n '1p' "$init")" = '#!/bin/sh /etc/rc.common' ] || return 1
  ! grep -Eq '^[[:space:]]*USE_PROCD=' "$init" || return 1
  ! grep -Eq '^[[:space:]]*(\. |source )' "$init" ||
    grep -Fqx '# premier-router lifecycle migration v1' "$init" || return 1
  grep -Eq '^TABLE="?xray_transparent"?$' "$init" || return 1
  grep -Eq '^ROUTE_TABLE="?100"?$' "$init" || return 1
  [ "$(grep -Ec '^[[:space:]]*start\(\)[[:space:]]*\{' "$init")" = 1 ] || return 1
  [ "$(grep -Ec '^[[:space:]]*stop\(\)[[:space:]]*\{' "$init")" = 1 ] || return 1
  if grep -Fqx '# premier-router lifecycle migration v1' "$init"; then
    [ "$(grep -Ec '^vpn_ui_legacy_start\(\)[[:space:]]*\{' "$init")" = 1 ] || return 1
    [ "$(tail -n 5 "$init")" = "$(cat <<'EOF'
# premier-router lifecycle migration v1
. "${VPN_UI_ROOT_PREFIX:-}/usr/libexec/premier-router/transparent-routing.sh"
start() { vpn_ui_start_legacy "$@"; }
running() { vpn_ui_transparent_running; }
EXTRA_COMMANDS="${EXTRA_COMMANDS:-} running"
EOF
)" ]
  else
    ! grep -q 'vpn_ui_legacy_start' "$init"
  fi
}

transparent_init_migrate() {
  local init="$1" candidate_sha="$2" artifact="$1-opkg" tmp
  transparent_init_check "$init" || return 1
  [ -f "$artifact" ] && [ ! -L "$artifact" ] || {
    [ ! -e "$artifact" ] && [ ! -L "$artifact" ]
    return
  }
  [ "$(sha256sum "$artifact" | awk '{print $1}')" = "$candidate_sha" ] || return 1
  # A conffile can carry endpoint exemptions or owner routing rules. Preserve
  # its body and guard its start/running entry points instead of overwriting it.
  if ! grep -Fqx '# premier-router lifecycle migration v1' "$init"; then
    tmp="$init.premier-new.$$"
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
    awk '/^[[:space:]]*start\(\)[[:space:]]*\{/ {
      sub(/start\(\)/, "vpn_ui_legacy_start()")
    } {print}' "$init" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat >> "$tmp" <<'EOF'

# premier-router lifecycle migration v1
. "${VPN_UI_ROOT_PREFIX:-}/usr/libexec/premier-router/transparent-routing.sh"
start() { vpn_ui_start_legacy "$@"; }
running() { vpn_ui_transparent_running; }
EXTRA_COMMANDS="${EXTRA_COMMANDS:-} running"
EOF
    if ! transparent_init_check "$tmp"; then rm -f "$tmp"; return 1; fi
    chmod 755 "$tmp" && mv "$tmp" "$init" || { rm -f "$tmp"; return 1; }
  fi
  rm -f "$artifact"
}
