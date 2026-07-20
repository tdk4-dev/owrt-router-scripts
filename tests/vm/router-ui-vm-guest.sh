#!/bin/ash
set -eu
umask 077

CA_FILE="${ROUTER_UI_VM_CA_FILE:-/etc/ssl/certs/router-ui-vm-ca.pem}"
export SSL_CERT_FILE="$CA_FILE"

die() { printf 'VM-GATE-ERROR: %s\n' "$*" >&2; exit 1; }
jget() { jsonfilter -i "$1" -e "$2" | sed -n '1p'; }
wait_for() {
  description="$1"; shift
  tries=0
  while [ "$tries" -lt 180 ]; do
    "$@" && return 0
    sleep 1
    tries=$((tries + 1))
  done
  die "timed out waiting for $description"
}

measure() {
  profile="$1"
  expected_backing_kib="$2"
  expected_ubifs_df_total_kib="$3"
  mem_total="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  root_total="$(df -Pk / | awk 'NR == 2 {print $2}')"
  root_free="$(df -Pk / | awk 'NR == 2 {print $4}')"
  [ -d /overlay ] || die "/overlay is not mounted"
  overlay_total="$(df -Pk /overlay | awk 'NR == 2 {print $2}')"
  overlay_free="$(df -Pk /overlay | awk 'NR == 2 {print $4}')"
  tmp_total="$(df -Pk /tmp | awk 'NR == 2 {print $2}')"
  tmp_free="$(df -Pk /tmp | awk 'NR == 2 {print $4}')"
  overlay_source="$(awk '$2 == "/overlay" {print $1; exit}' /proc/mounts)"
  [ -n "$overlay_source" ] || die "could not identify /overlay backing device"
  overlay_block="${overlay_source#/dev/}"
  [ -r "/sys/class/block/$overlay_block/size" ] ||
    die "could not measure /overlay backing device: $overlay_source"
  overlay_backing_kib="$(($(cat "/sys/class/block/$overlay_block/size") / 2))"
  grep -Eq '^[^ ]+ /tmp tmpfs ' /proc/mounts || die "/tmp is not RAM-backed"
  [ "$mem_total" -le 262144 ] && [ "$mem_total" -ge 220000 ] ||
    die "MemTotal is inconsistent with a 256 MiB guest: $mem_total"
  case "$profile" in rd23-stock|rd23-ubootmod) ;; *) die "unknown storage profile: $profile" ;; esac
  [ "$expected_backing_kib" -gt 0 ] && [ "$expected_ubifs_df_total_kib" -gt 0 ] ||
    die "invalid target-derived storage limits"
  [ "$overlay_backing_kib" -eq "$expected_backing_kib" ] ||
    die "$profile writable backing is $overlay_backing_kib KiB, expected exact RD23 extent $expected_backing_kib KiB"
  [ "$overlay_total" -le "$overlay_backing_kib" ] ||
    die "$profile filesystem reports more space than its exact backing extent"
  printf '{"profile":"%s","configured_ram_mib":256,"mem_total_kib":%s,' "$profile" "$mem_total"
  printf '"root_total_kib":%s,"root_free_kib":%s,' "$root_total" "$root_free"
  printf '"overlay_total_kib":%s,"overlay_free_kib":%s,' "$overlay_total" "$overlay_free"
  printf '"overlay_backing_device":"%s","overlay_backing_kib":%s,' "$overlay_source" "$overlay_backing_kib"
  printf '"target_expected_ubifs_df_total_kib":%s,' "$expected_ubifs_df_total_kib"
  printf '"tmp_total_kib":%s,"tmp_free_kib":%s,"tmp_ram_backed":true}\n' "$tmp_total" "$tmp_free"
}

protected_hash() {
  work="/tmp/router-ui-protected.$$"
  : > "$work"
  for path in /etc/config /etc/xray /etc/vpn-ui-update.conf /etc/crontabs/root; do
    if [ -f "$path" ]; then
      sha256sum "$path" >> "$work"
    elif [ -d "$path" ]; then
      find "$path" -type f -print | sort | while IFS= read -r file; do sha256sum "$file"; done >> "$work"
    fi
  done
  sha256sum "$work" | awk '{print $1}'
  rm -f "$work"
}

install_non_secret_test_profile() {
  source_version="$1"
  fixture_base="$2"
  case "$source_version" in
    0.5.1|0.5.2|0.6.0|0.7.*) ;;
    *) die "test profile requested for unsupported baseline: $source_version" ;;
  esac

  mkdir -p /etc/xray/vless-profiles.d
  curl -fsSL --proto '=https' "$fixture_base/profile.conf" \
    -o /etc/xray/vless-profiles.d/disposable-vm-fixture.conf
  curl -fsSL --proto '=https' "$fixture_base/selected" \
    -o /etc/xray/vless-selected
  curl -fsSL --proto '=https' "$fixture_base/direct-domains.txt" \
    -o /etc/xray/direct-domains.txt
  chmod 700 /etc/xray/vless-profiles.d
  chmod 600 /etc/xray/vless-profiles.d/disposable-vm-fixture.conf \
    /etc/xray/vless-selected /etc/xray/direct-domains.txt
}

install_baseline() {
  version="$1" base="$2"
  work="$(mktemp -d /tmp/router-ui-baseline.XXXXXX)"
  curl -fsSL --proto '=https' "$base/$version/luci-vpn-ui.tar.gz" -o "$work/luci-vpn-ui.tar.gz"
  curl -fsSL --proto '=https' "$base/$version/luci-vpn-ui.tar.gz.sha256" -o "$work/luci-vpn-ui.tar.gz.sha256"
  expected="$(awk '{print $1}' "$work/luci-vpn-ui.tar.gz.sha256" | sed -n '1p')"
  [ "$expected" = "$(sha256sum "$work/luci-vpn-ui.tar.gz" | awk '{print $1}')" ] || die "published $version checksum mismatch"
  tar -xzf "$work/luci-vpn-ui.tar.gz" -C "$work"
  [ "$(sed -n '1p' "$work/luci-vpn-ui/VERSION")" = "$version" ] || die "published $version bundle metadata mismatch"
  fixture_origin="${base%/baselines}/fixtures/legacy-nonsecret"
  install_non_secret_test_profile "$version" "$fixture_origin"
  SKIP_SYSUPGRADE_BACKUP=1 INSTALL_GEOSITE=0 UPDATE_GEOSITE=0 sh "$work/luci-vpn-ui/install.sh"
  [ "$(sed -n '1p' /usr/share/vpn-ui/version)" = "$version" ] || die "baseline $version did not install exactly"
  rm -rf "$work"
}

validate_baseline() {
  version="$1" expected_worker="$2" expected_validator="$3"
  expected_xray_version="$4" expected_xray_binary="$5"
  [ "$(sed -n '1p' /usr/share/vpn-ui/version)" = "$version" ] ||
    die "baseline version contract failed: $version"
  worker_sha="$(sha256sum /usr/sbin/vpn-ui-update | awk '{print $1}')"
  validator_sha="$(sha256sum /usr/sbin/vpn-ui | awk '{print $1}')"
  [ "$worker_sha" = "$expected_worker" ] || die "legacy worker hash mismatch: $version"
  [ "$validator_sha" = "$expected_validator" ] || die "legacy validator hash mismatch: $version"
  for path in \
    /usr/share/vpn-ui/version \
    /usr/sbin/vpn-ui \
    /usr/sbin/vpn-ui-update \
    /etc/xray/vless-profiles.d/disposable-vm-fixture.conf \
    /etc/xray/vless-selected \
    /etc/xray/direct-domains.txt; do
    [ -f "$path" ] || die "baseline filesystem contract missing: $path"
  done
  set +e
  /usr/sbin/vpn-ui check > /tmp/vpn-ui-baseline-self-validation.log 2>&1
  validator_rc=$?
  set -e
  cat /tmp/vpn-ui-baseline-self-validation.log
  [ "$validator_rc" -eq 0 ] || die "legacy self-validation command failed: $version (rc=$validator_rc)"
  grep -q '"ok":true' /tmp/vpn-ui-baseline-self-validation.log ||
    die "legacy self-validation rejected its installed baseline: $version"
  contract_file="/tmp/router-ui-baseline-contract.$$"
  {
    printf '%s\n' "$version"
    for path in \
      /usr/share/vpn-ui/version \
      /usr/sbin/vpn-ui \
      /usr/sbin/vpn-ui-update \
      /etc/xray/vless-profiles.d/disposable-vm-fixture.conf \
      /etc/xray/vless-selected \
      /etc/xray/direct-domains.txt; do
      sha256sum "$path"
    done
  } > "$contract_file"
  contract_sha="$(sha256sum "$contract_file" | awk '{print $1}')"
  rm -f "$contract_file"
  xray_version="$(opkg status xray-core | sed -n 's/^Version: //p' | sed -n '1p')"
  [ "$xray_version" = "$expected_xray_version" ] ||
    die "installed Xray package version differs from the exact locked IPK: $xray_version"
  xray_binary="$(command -v xray || command -v xray-latest || true)"
  [ -n "$xray_binary" ] || die "baseline Xray binary is missing"
  xray_binary_sha="$(sha256sum "$xray_binary" | awk '{print $1}')"
  [ "$xray_binary_sha" = "$expected_xray_binary" ] ||
    die "installed Xray binary differs from the exact locked IPK: $xray_binary_sha"
  protected_sha="$(protected_hash)"
  printf '{"version":"%s","worker_sha256":"%s","validator_sha256":"%s",' \
    "$version" "$worker_sha" "$validator_sha"
  printf '"filesystem_contract_sha256":"%s","protected_sha256":"%s",' \
    "$contract_sha" "$protected_sha"
  printf '"xray_package_version":"%s","xray_binary":"%s","xray_binary_sha256":"%s",' \
    "$xray_version" "$xray_binary" "$xray_binary_sha"
  printf '"self_validation":{"command":"/usr/sbin/vpn-ui check","exit_code":0,"ok":true}}\n'
}

old_status_is() {
  wanted="$1"
  [ "$(sed -n '1p' /tmp/vpn-ui-update/status 2>/dev/null)" = "$wanted" ]
}

run_old_worker() {
  origin="$1" source="$2"
  before="$(protected_hash)"
  VPN_UI_RELEASE_BASE="$origin/releases/latest/download" /usr/sbin/vpn-ui-update check-start >/tmp/old-check-start.json
  wait_for "old-worker check" old_status_is success
  VPN_UI_RELEASE_BASE="$origin/releases/latest/download" /usr/sbin/vpn-ui-update apply-start >/tmp/old-apply-start.json
  wait_for "old-worker completion" old_status_is success
  [ "$(sed -n '1p' /usr/share/vpn-ui/version)" = 0.7.11 ] || die "old worker did not install 0.7.11"
  transaction="$(sed -n '1p' /root/premier-router-updates/active-transaction)"
  journal="/root/premier-router-updates/$transaction/state.json"
  [ "$(jget "$journal" '@.state')" = committed_pending_reboot_validation ] || die "old worker hid pending reboot validation"
  [ "$(jget "$journal" '@.rollback_status')" = not_started ] || die "unexpected rollback after old-worker success"
  [ "$(jget "/root/premier-router-updates/$transaction/legacy-worker-handoff.json" '@.alive_after_candidate_validation')" = true ] ||
    die "legacy worker handoff evidence is missing"
  [ "$(protected_hash)" = "$before" ] || die "protected configuration changed during old-worker transition"
  if [ "$source" = 0.7.9 ]; then
    grep -q PREMIER_ROUTER_079_COMPAT_NOOP /www/luci-static/resources/view/status/include/_35_vpn.js ||
      die "0.7.9 compatibility module is not the verified no-op"
  else
    [ ! -e /www/luci-static/resources/view/status/include/_35_vpn.js ] || die "0.7.10 unexpectedly gained compatibility module"
  fi
  printf '%s\n' "$transaction"
}

run_rescue() {
  origin="$1" source="$2"
  before="$(protected_hash)"
  curl -fsSL --proto '=https' "$origin/releases/download/vpn-panel-v0.7.11/rescue-router-ui.sh" -o /tmp/rescue-router-ui.sh
  chmod 700 /tmp/rescue-router-ui.sh
  ROUTER_UI_RELEASE_BASE="$origin/releases/download/vpn-panel-v0.7.11" sh /tmp/rescue-router-ui.sh
  [ "$(sed -n '1p' /usr/share/vpn-ui/version)" = 0.7.11 ] || die "rescue from $source did not install 0.7.11"
  grep -qx 'UPDATER_PROTOCOL=2' /usr/share/premier-router/build-info || die "rescue did not install protocol 2"
  [ "$(protected_hash)" = "$before" ] || die "rescue changed protected configuration"
  sed -n '1p' /root/premier-router-updates/active-transaction
}

verify_target() {
  expected="$1" source="$2" phase="${3:-post-reboot}"
  [ "$(sed -n '1p' /usr/share/vpn-ui/version)" = "$expected" ] || die "target version mismatch"
  for package in premier-router-core luci-app-premier-router premier-router-setup; do
    actual="$(opkg status "$package" | sed -n 's/^Version: //p' | sed -n '1p')"
    [ "$actual" = "$expected-1" ] || die "$package version mismatch: $actual"
  done
  transaction="$(sed -n '1p' /root/premier-router-updates/active-transaction)"
  journal="/root/premier-router-updates/$transaction/state.json"
  case "$phase" in
    pending) [ "$(jget "$journal" '@.state')" = committed_pending_reboot_validation ] ;;
    post-reboot) [ "$(jget "$journal" '@.state')" = committed ] ;;
    *) die "unknown target validation phase" ;;
  esac || die "transaction state mismatch for $phase"
  [ -x "/root/premier-router-updates/$transaction/rollback.sh" ] || die "exact rollback command missing"
  [ "$source" != 0.7.9 ] || [ ! -e /www/luci-static/resources/view/status/include/_35_vpn.js ] ||
    [ "$phase" = pending ] || die "compatibility module survived reboot validation"
}

run_rollback() {
  transaction="$1" expected="$2"
  sh "/root/premier-router-updates/$transaction/rollback.sh"
  [ "$(sed -n '1p' /usr/share/vpn-ui/version)" = "$expected" ] || die "rollback did not restore $expected"
  [ "$(jget "/root/premier-router-updates/$transaction/state.json" '@.state')" = rolled_back ] || die "rollback state is false"
  sh "/root/premier-router-updates/$transaction/rollback.sh"
}

verify_clean_image() {
  expected_fingerprint="$1"
  [ "$(sed -n '1p' /usr/share/vpn-ui/version)" = 0.7.11 ] || die "clean image version mismatch"
  for package in premier-router-core luci-app-premier-router premier-router-setup; do
    [ "$(opkg status "$package" | sed -n 's/^Version: //p' | sed -n '1p')" = 0.7.11-1 ] ||
      die "clean image package version mismatch: $package"
  done
  /usr/sbin/vpn-ui-update status > /tmp/clean-status.json
  [ "$(jget /tmp/clean-status.json '@.protocol')" = 2 ] || die "clean image protocol 2 is missing"
  usign -q -V -p /usr/share/premier-router/keys/release.pub \
    -m /etc/premier-router/installed-manifest.json \
    -x /etc/premier-router/installed-manifest.json.sig || die "clean image installed package set signature failed"
  [ "$(usign -F -p /usr/share/premier-router/keys/release.pub)" = "$expected_fingerprint" ] ||
    die "clean image production public key mismatch"
  [ -s /www/cgi-bin/firstboot-setup ] && [ -s /www/setup/index.html ] || die "setup page is missing"
  for route in network/vpn network/tailscale system/update; do
    grep -q "\"path\":[[:space:]]*\"$route\"" /usr/share/luci/menu.d/luci-app-vpn-ui.json ||
      die "clean image LuCI route missing: $route"
  done
  for package in premier-router-core luci-app-premier-router premier-router-setup; do
    list="/usr/lib/opkg/info/$package.list"
    [ -s "$list" ] || die "clean image package list missing: $package"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      [ ! -e "/overlay/upper$path" ] && [ ! -L "/overlay/upper$path" ] ||
        die "package-owned file is duplicated in writable overlay: $path"
    done < "$list"
  done
  dmesg | grep -Eqi 'out of memory|oom-killer|killed process' && die "clean image experienced OOM"
}

fill_to_free() {
  wanted="$1" filler=/root/router-ui-storage-pressure.fill
  rm -f "$filler"
  free="$(df -Pk /overlay | awk 'NR == 2 {print $4}')"
  [ "$free" -gt "$wanted" ] || die "cannot raise free space to requested target"
  count=$((free - wanted))
  dd if=/dev/zero of="$filler" bs=1024 count="$count" conv=fsync 2>/dev/null
  actual="$(df -Pk /overlay | awk 'NR == 2 {print $4}')"
  [ "$actual" -le $((wanted + 256)) ] || die "storage filler did not reach target free space"
}

concurrency_race() {
  origin="$1" discovery="$2"
  VPN_UI_RELEASE_ORIGIN="$origin" VPN_UI_DISCOVERY_BASE="$discovery" \
    VPN_UI_SYNC_WORKER=1 /usr/sbin/vpn-ui-update check-start >/tmp/concurrency-check.json
  /usr/sbin/vpn-ui-update set-auto 1 >/dev/null
  before_count="$(find /root/premier-router-updates -mindepth 1 -maxdepth 1 -type d ! -name known-good ! -name quarantine ! -name update.lock | wc -l)"
  VPN_UI_RELEASE_ORIGIN="$origin" /usr/sbin/vpn-ui-update apply-start >/tmp/concurrency-cli.json 2>&1 & p1=$!
  VPN_UI_RELEASE_ORIGIN="$origin" /usr/sbin/vpn-ui update-apply-start >/tmp/concurrency-rpc.json 2>&1 & p2=$!
  VPN_UI_RELEASE_ORIGIN="$origin" VPN_UI_DISCOVERY_BASE="$discovery" /usr/sbin/vpn-ui-update auto >/tmp/concurrency-auto.json 2>&1 & p3=$!
  wait "$p1" || true; wait "$p2" || true; wait "$p3" || true
  sleep 2
  after_count="$(find /root/premier-router-updates -mindepth 1 -maxdepth 1 -type d ! -name known-good ! -name quarantine ! -name update.lock | wc -l)"
  [ $((after_count - before_count)) -eq 1 ] || die "concurrent callers created more than one transaction"
  refused="$(grep -l 'another update transaction owns the lock' /tmp/concurrency-*.json 2>/dev/null | wc -l)"
  [ "$refused" -ge 1 ] || die "concurrency losers did not receive truthful lock responses"
  printf '{"transactions_created":1,"truthful_loser_responses":%s}\n' "$refused"
}

case "${1:-}" in
  measure) shift; measure "$@" ;;
  protected-hash) protected_hash ;;
  install-baseline) shift; install_baseline "$@" ;;
  validate-baseline) shift; validate_baseline "$@" ;;
  old-worker) shift; run_old_worker "$@" ;;
  rescue) shift; run_rescue "$@" ;;
  verify-target) shift; verify_target "$@" ;;
  verify-clean-image) shift; verify_clean_image "$@" ;;
  rollback) shift; run_rollback "$@" ;;
  fill-to-free) shift; fill_to_free "$@" ;;
  concurrency-race) shift; concurrency_race "$@" ;;
  *) die "unknown guest command: ${1:-missing}" ;;
esac
