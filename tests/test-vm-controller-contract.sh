#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONTROLLER="$ROOT_DIR/tests/integration/repro-recovery-lock-mac-pro.sh"

bash -n "$CONTROLLER"
grep -Fq 'export SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem' "$CONTROLLER"
grep -Fq 'journal_token_shape=%s' "$CONTROLLER"
grep -Fq 'lock_owner=absent' "$CONTROLLER"
grep -Fq 'normalize-listeners.awk' "$CONTROLLER"
! grep -Fq 'printf "%s\n" "$token"' "$CONTROLLER"
awk '
  /wait_for_terminal_and_unlock .*next-recovery-observations.tsv/ { after_next_reboot = 1; next }
  after_next_reboot && /stage_guest_runtime/ { staged = 1; exit }
  after_next_reboot && /next-committed-validation.log/ { exit }
  END { exit !staged }
' "$CONTROLLER"

VANILLA_CONTROLLER="$ROOT_DIR/tests/integration/run-vanilla-ipk-install-mac-pro.sh"
grep -Fq 'expected="$(grep -F "  $file" /tmp/SHA256SUMS | cut -d " " -f 1)"' \
  "$VANILLA_CONTROLLER"
grep -Fq '> /etc/opkg/customfeeds.conf' "$VANILLA_CONTROLLER"
! grep -Fq '/etc/opkg/customfeeds.conf.d/' "$VANILLA_CONTROLLER"
grep -Fq 'cat /tmp/router-ui-vanilla-ca.pem >> /etc/ssl/certs/ca-certificates.crt' \
  "$VANILLA_CONTROLLER"
! grep -Fq -- '--no-check-certificate' "$VANILLA_CONTROLLER"
grep -Fq 'guest_ssh '\''
    set -e' "$VANILLA_CONTROLLER"

printf 'Mac Pro VM controller contract passed\n'
