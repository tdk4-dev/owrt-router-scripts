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

printf 'Mac Pro VM controller contract passed\n'
