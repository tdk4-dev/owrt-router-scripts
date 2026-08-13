#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh"
UPDATER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-updater-source.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

. "$LIB"

pr_version_newer 0.7.11-rc.8 0.7.11-rc.5
pr_version_newer 0.7.11-rc.8 0.7.11-rc.6
pr_version_newer 0.7.11-rc.8 0.7.11-rc.7
pr_version_newer 0.7.11 0.7.11-rc.8
! pr_version_newer 0.7.11-rc.8 0.7.11
! pr_version_newer 0.7.11-rc.7 0.7.11-rc.8
! pr_version_newer 0.7.11-rc.8 0.7.11-rc.8
pr_package_version_matches_app 0.7.11-rc.8 0.7.11~rc8-1
pr_package_version_matches_app 0.7.11 0.7.11-1

HASH_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HASH_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
[ "$(pr_offer_identity_decision 0.7.11-rc.7 0.7.11-rc.8 '' '')" = upgrade ]
[ "$(pr_offer_identity_decision 0.7.11-rc.8 0.7.11 "$HASH_A" "$HASH_B")" = upgrade ]
[ "$(pr_offer_identity_decision 0.7.11-rc.8 0.7.11-rc.8 "$HASH_A" "$HASH_A")" = repeat-identical ]
if pr_offer_identity_decision 0.7.11-rc.8 0.7.11-rc.8 "$HASH_A" "$HASH_B" >/dev/null; then
  printf 'different bytes were accepted under the consumed RC8 identity\n' >&2
  exit 1
fi
if pr_offer_identity_decision 0.7.11 0.7.11-rc.8 '' '' >/dev/null; then
  printf 'stable-to-RC8 downgrade was accepted\n' >&2
  exit 1
fi

mkdir -p "$TMP_ROOT/root/etc/config" "$TMP_ROOT/root/etc/xray" \
  "$TMP_ROOT/root/etc/premier-router" "$TMP_ROOT/root/etc/crontabs" \
  "$TMP_ROOT/root/usr/lib/opkg" "$TMP_ROOT/root/root/premier-router-updates" \
  "$TMP_ROOT/root/tmp"
printf '%s\n' fixture-boot > "$TMP_ROOT/boot-id"
printf '%s\n' 'config interface lan' > "$TMP_ROOT/root/etc/config/network"
printf '%s\n' '{"routing":{"rules":[]}}' > "$TMP_ROOT/root/etc/xray/config.json"
printf '%s\n' '{"mode":"adopted-overlay"}' > "$TMP_ROOT/root/etc/premier-router/xray-ownership.json"
printf '%s\n' "AUTO_UPDATE='0'" > "$TMP_ROOT/root/etc/vpn-ui-update.conf"
printf '%s\n' '# fixture cron' > "$TMP_ROOT/root/etc/crontabs/root"
printf '%s\n' 'Package: base-files' > "$TMP_ROOT/root/usr/lib/opkg/status"

PREMIER_ROUTER_HOST_TEST=1
VPN_UI_ROOT_PREFIX="$TMP_ROOT/root"
VPN_UI_UPDATE_LIB="$LIB"
VPN_UI_UPDATE_SOURCE_ONLY=1
VPN_UI_BOOT_ID_FILE="$TMP_ROOT/boot-id"
VPN_UI_TEST_PROCESS_START_ID=fixture-start
export PREMIER_ROUTER_HOST_TEST VPN_UI_ROOT_PREFIX VPN_UI_UPDATE_LIB
export VPN_UI_UPDATE_SOURCE_ONLY VPN_UI_BOOT_ID_FILE VPN_UI_TEST_PROCESS_START_ID
. "$UPDATER"

# Exact protected-state restoration is tested with ordinary temporary files only.
TXN_DIR="$PERSIST_ROOT/source-rollback-fixture"
mkdir -p "$TXN_DIR/rollback"
snapshot_protected_state
SOURCE_FINGERPRINT="$(sha256sum "$TXN_DIR/rollback/protected-source.fingerprint" | awk '{print $1}')"
printf '%s\n' 'mutated' > "$TMP_ROOT/root/etc/config/network"
printf '%s\n' 'new unowned file' > "$TMP_ROOT/root/etc/xray/extra.json"
restore_protected_state
[ "$(sha256sum "$TXN_DIR/rollback/protected-restored.fingerprint" | awk '{print $1}')" = "$SOURCE_FINGERPRINT" ]
grep -Fqx 'config interface lan' "$TMP_ROOT/root/etc/config/network"
[ ! -e "$TMP_ROOT/root/etc/xray/extra.json" ]

# A live owner blocks a second updater. A mismatched boot identity is stale and recoverable.
lock_acquire source-owner
lock_assert source-owner
if lock_acquire competing-owner; then
  printf 'live update lock allowed a second owner\n' >&2
  exit 1
fi
sed 's/^boot_id=.*/boot_id=stale-boot/' "$LOCK_DIR/owner" > "$LOCK_DIR/owner.new"
mv "$LOCK_DIR/owner.new" "$LOCK_DIR/owner"
lock_acquire recovered-owner
lock_assert recovered-owner
lock_release recovered-owner
[ ! -e "$LOCK_DIR" ]

# Recovery of an interrupted pre-mutation journal must fail closed without rollback mutation.
J_TRANSACTION_ID=source-recovery-fixture
TXN_DIR="$PERSIST_ROOT/$J_TRANSACTION_ID"
JOURNAL="$TXN_DIR/state.json"
mkdir -p "$TXN_DIR/rollback"
J_SOURCE_APP_VERSION=0.7.11-rc.7
J_SOURCE_PACKAGE_VERSION=0.7.11~rc7-1
J_SOURCE_UPDATER_PROTOCOL=2
J_SOURCE_TYPE=ipk
J_TARGET_APP_VERSION=0.7.11-rc.8
J_TARGET_PACKAGE_VERSION=0.7.11~rc8-1
J_TARGET_TAG=vpn-panel-v0.7.11-rc.8
J_TARGET_MANIFEST_HASH="$HASH_A"
J_STATE=preflight
J_LAST_COMPLETED_STATE=discovered
J_MUTATION_STARTED=false
J_BACKUP_PATH=''
J_ROLLBACK_BUNDLE_PATH=''
J_ROLLBACK_STATUS=not_started
J_ERROR_CLASS=''
J_ERROR_CODE=''
J_ERROR_MESSAGE=''
J_CREATED_AT=2026-08-13T00:00:00Z
J_UPDATED_AT="$J_CREATED_AT"
J_BOOT_ID=fixture-boot
J_WORKER_TOKEN=old-owner
J_INVOCATION=manual
J_NEEDS_REBOOT_VALIDATION=false
journal_write
printf '%s\n' "$J_TRANSACTION_ID" > "$ACTIVE_FILE"
recover_transaction
journal_load "$JOURNAL"
[ "$J_STATE" = failed_before_mutation ]
[ "$J_MUTATION_STARTED" = false ]
[ "$J_ERROR_CLASS" = recovery ]
[ "$J_ERROR_CODE" = failed_before_mutation ]
[ ! -e "$LOCK_DIR" ]

printf 'Updater source-only ordering, identity, lock, recovery, and exact restoration contracts passed\n'
