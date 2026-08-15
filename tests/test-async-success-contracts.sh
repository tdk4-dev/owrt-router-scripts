#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
UPDATER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
UPDATE_VIEW="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/system/update.js"
TAILSCALE_VIEW="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/network/tailscale.js"

extract_function() {
  sed -n "/^$1()/,/^}/p" "$2"
}

# Update Check and Apply are resolved only by a validated exact job identity.
grep -Fq 'job_create "$token" "$kind"' "$UPDATER"
grep -Fq 'job_status_json "${2:-}" "${3:-}"' "$UPDATER"
grep -Fq 'J_OPERATION_JOB_ID="$ACTIVE_JOB_ID"' "$UPDATER"
grep -Fq "this.callHelper(['update-job-status', jobId, kind])" "$UPDATE_VIEW"
grep -Fq 'job.id !== jobId || job.kind !== kind' "$UPDATE_VIEW"
! sed -n '/pollJob: function/,/startJob: function/p' "$UPDATE_VIEW" |
  grep -Fq "this.callHelper(['update-status'])"

# Tailscale mutations wait for fresh runtime/boot/backend observations and restore on failure.
for fn in cmd_tailscale_stop cmd_tailscale_restart cmd_tailscale_logout; do
  extract_function "$fn" "$HELPER" | grep -Fq 'tailscale_wait_'
  extract_function "$fn" "$HELPER" | grep -Fq 'tailscale_action_failed'
done
extract_function cmd_tailscale_up "$HELPER" | grep -Fq 'tailscale_registration_ready'
extract_function cmd_tailscale_up "$HELPER" | grep -Fq 'tailscale_action_failed'
! extract_function cmd_tailscale_stop "$HELPER" | grep -Fq '|| true'
! extract_function cmd_tailscale_restart "$HELPER" | grep -Fq '|| true'
grep -Fq "return this.pollStatus(predicate, 0);" "$TAILSCALE_VIEW"
grep -Fq "_('Tailscale stopped.')" "$TAILSCALE_VIEW"
grep -Fq "_('Tailscale restarted.')" "$TAILSCALE_VIEW"
grep -Fq "_('Tailscale settings applied.')" "$TAILSCALE_VIEW"
grep -Fq "_('Tailscale logged out.')" "$TAILSCALE_VIEW"

# Subscription and reachability refreshes are synchronous and verify newly written output.
extract_function cmd_subscription_sync "$HELPER" | grep -Fq 'sync_subscription'
extract_function sync_subscription "$HELPER" | grep -Fq 'subscription metadata postcondition failed'
extract_function cmd_refresh_pings "$HELPER" | grep -Fq 'rm -f "$PING_DIR/$id"'
extract_function cmd_refresh_pings "$HELPER" | grep -Fq 'wait'
extract_function cmd_refresh_pings "$HELPER" | grep -Fq 'fresh result for every profile'

# Automatic-switch settings are committed and re-read; scheduled switching propagates apply failure.
extract_function cmd_auto_config "$HELPER" | grep -Fq 'automatic-switch configuration postcondition failed'
extract_function cmd_auto_tick "$HELPER" | grep -Fq 'render_and_apply "$best_id" "$DOMAINS_FILE" "$IPS_FILE" "0" || return 1'
extract_function cmd_auto_tick "$HELPER" | grep -Fq 'apply_adopted_rules "$DOMAINS_FILE" "$IPS_FILE" "$best_id" || return 1'

printf '%s\n' 'Adjacent asynchronous-success source contracts passed for Update, Tailscale, subscriptions, reachability, and automatic switching'
