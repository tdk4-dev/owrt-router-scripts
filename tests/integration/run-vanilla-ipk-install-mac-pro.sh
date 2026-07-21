#!/bin/bash
set -euo pipefail
umask 077

VBOXMANAGE=/usr/local/bin/VBoxManage
VM_NAME=RouterUI-Vanilla-24.10.5-RC1
SNAPSHOT_NAME=clean-openwrt-24.10.5-vanilla
HOST_ONLY_IF=vboxnet1
HOST_ADDRESS=192.168.1.2
GUEST_ADDRESS=192.168.1.1
HTTPS_PORT=19443
SOURCE_ROOT="${SOURCE_ROOT:?SOURCE_ROOT is required}"
CANDIDATE_DIR="${CANDIDATE_DIR:?CANDIDATE_DIR is required}"
REMOTE_ROOT="${REMOTE_ROOT:?REMOTE_ROOT is required}"
VANILLA_ROOT=/Users/mac-pro-host/Documents/RouterUI-release/vanilla-openwrt-24.10.5
IMAGE_GZ="$VANILLA_ROOT/openwrt-24.10.5-x86-64-generic-squashfs-combined.img.gz"
RAW_IMAGE="$VANILLA_ROOT/openwrt-24.10.5-x86-64-generic-squashfs-combined.img"
VDI="$VANILLA_ROOT/openwrt-24.10.5-x86-64-generic-squashfs-combined.vdi"
IMAGE_URL=https://downloads.openwrt.org/releases/24.10.5/targets/x86/64/openwrt-24.10.5-x86-64-generic-squashfs-combined.img.gz
IMAGE_SHA=a1d5feaf8aeb3656625581bc190bbc811b1732fa1d0b062abbd0a036f99a9264
PUBLIC_KEY="$CANDIDATE_DIR/production-2026-07.pub"
EXPECTED_FINGERPRINT=d055711acf1d9a5b
SERVER_PID=
VM_STARTED=false
RUN_ROOT=

fail() { printf 'VANILLA-IPK-ERROR: %s\n' "$*" >&2; exit 1; }
vm_exists() { "$VBOXMANAGE" showvminfo "$VM_NAME" >/dev/null 2>&1; }
vm_state() { "$VBOXMANAGE" showvminfo "$VM_NAME" --machinereadable | sed -n 's/^VMState="\([^"]*\)"/\1/p'; }
guest_ssh() {
  ssh -o BatchMode=yes -o PreferredAuthentications=none -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/tmp/router-ui-vanilla-known-hosts -o ConnectTimeout=3 \
    root@"$GUEST_ADDRESS" "$@"
}
wait_guest() {
  local deadline=$(( $(date +%s) + 180 ))
  while ! guest_ssh true >/dev/null 2>&1; do
    (( $(date +%s) < deadline )) || return 1
    sleep 1
  done
}
wait_poweroff() {
  local deadline=$(( $(date +%s) + 90 ))
  while [[ "$(vm_state)" != poweroff ]]; do
    (( $(date +%s) < deadline )) || return 1
    sleep 1
  done
}
wait_reboot() {
  local previous="$1" deadline=$(( $(date +%s) + 180 )) current
  while :; do
    current="$(guest_ssh cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    if [[ -n "$current" && "$current" != "$previous" ]] && guest_ssh true >/dev/null 2>&1; then
      printf '%s\n' "$current"
      return 0
    fi
    (( $(date +%s) < deadline )) || return 1
    sleep 1
  done
}
stop_vm() {
  [[ "$VM_STARTED" = true ]] || return 0
  if [[ "$(vm_state)" = running ]]; then
    guest_ssh 'sync; poweroff' >/dev/null 2>&1 || true
    wait_poweroff || "$VBOXMANAGE" controlvm "$VM_NAME" poweroff >/dev/null
  fi
  VM_STARTED=false
}
cleanup() {
  local rc=$?
  set +e
  [[ -z "$SERVER_PID" ]] || { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }
  stop_vm
  if vm_exists && [[ "$(vm_state)" = poweroff ]] &&
    "$VBOXMANAGE" snapshot "$VM_NAME" list --machinereadable 2>/dev/null | grep -Fq "SnapshotName=\"$SNAPSHOT_NAME\""; then
    "$VBOXMANAGE" snapshot "$VM_NAME" restore "$SNAPSHOT_NAME" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

[[ "$SOURCE_ROOT" = /Users/mac-pro-host/Documents/RouterUI-release/Premier-Router-0.7.11-rc1-worktree ]]
[[ "$CANDIDATE_DIR" = "$REMOTE_ROOT"/assets/* ]]
[[ -x "$VBOXMANAGE" && -s "$PUBLIC_KEY" && -s "$CANDIDATE_DIR/SHA256SUMS" ]]
[[ "$(/Users/mac-pro-host/.local/libexec/premier-router/usign-c4c72b1 -F -p "$PUBLIC_KEY")" = "$EXPECTED_FINGERPRINT" ]]

mkdir -p "$VANILLA_ROOT" "$REMOTE_ROOT/evidence/vanilla-ipk"
if [[ ! -s "$IMAGE_GZ" ]]; then
  curl -fL --retry 3 "$IMAGE_URL" -o "$IMAGE_GZ"
fi
[[ "$(shasum -a 256 "$IMAGE_GZ" | awk '{print $1}')" = "$IMAGE_SHA" ]] || fail 'vanilla image hash mismatch'

if ! vm_exists; then
  [[ ! -e "$RAW_IMAGE" && ! -e "$VDI" ]] || fail 'vanilla VM disk target already exists without a registered VM'
  gzip -dc "$IMAGE_GZ" > "$RAW_IMAGE"
  "$VBOXMANAGE" convertfromraw "$RAW_IMAGE" "$VDI" --format VDI >/dev/null
  rm -f "$RAW_IMAGE"
  if ! "$VBOXMANAGE" list hostonlyifs | grep -Fq "Name:            $HOST_ONLY_IF"; then
    "$VBOXMANAGE" hostonlyif create >/dev/null
  fi
  "$VBOXMANAGE" hostonlyif ipconfig "$HOST_ONLY_IF" --ip "$HOST_ADDRESS" --netmask 255.255.255.0
  "$VBOXMANAGE" createvm --name "$VM_NAME" --ostype Linux_64 --register >/dev/null
  "$VBOXMANAGE" modifyvm "$VM_NAME" --memory 256 --cpus 1 --ioapic on --rtcuseutc on \
    --nic1 hostonly --hostonlyadapter1 "$HOST_ONLY_IF" --nictype1 82540EM \
    --nic2 nat --nictype2 82540EM --audio none --clipboard-mode disabled --draganddrop disabled \
    --uart1 0x3F8 4 --uartmode1 file "$VANILLA_ROOT/serial.log"
  "$VBOXMANAGE" storagectl "$VM_NAME" --name SATA --add sata --controller IntelAhci --portcount 1
  "$VBOXMANAGE" storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 --type hdd --medium "$VDI"
  "$VBOXMANAGE" startvm "$VM_NAME" --type headless >/dev/null
  VM_STARTED=true
  wait_guest || fail 'vanilla OpenWrt did not expose SSH on the isolated host-only interface'
  guest_ssh 'grep -q "DISTRIB_RELEASE=.24.10.5." /etc/openwrt_release; [ ! -e /usr/share/vpn-ui/version ]; ! opkg status premier-router-core 2>/dev/null | grep -q installed'
  guest_ssh 'sync; poweroff' >/dev/null 2>&1 || true
  wait_poweroff || fail 'vanilla OpenWrt did not power off for its clean snapshot'
  VM_STARTED=false
  "$VBOXMANAGE" snapshot "$VM_NAME" take "$SNAPSHOT_NAME" --description 'Official OpenWrt 24.10.5 x86/64 image; no Premier Router files or packages' >/dev/null
fi

[[ "$(vm_state)" = poweroff ]] || fail 'vanilla VM must be powered off before testing'
info="$($VBOXMANAGE showvminfo "$VM_NAME" --machinereadable)"
grep -Fq 'memory=256' <<< "$info" && grep -Fq 'cpus=1' <<< "$info" || fail 'vanilla VM sizing drift'
grep -Fq 'nic1="hostonly"' <<< "$info" && grep -Fq 'nic2="nat"' <<< "$info" || fail 'vanilla VM network isolation drift'

RUN_ROOT="$REMOTE_ROOT/runs/vanilla-ipk-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$RUN_ROOT/server/direct" "$RUN_ROOT/server/feed" "$RUN_ROOT/tls"
ln -s "$CANDIDATE_DIR"/* "$RUN_ROOT/server/direct/"
tar -xzf "$CANDIDATE_DIR/premier-router-opkg-feed-0.7.11.tar.gz" -C "$RUN_ROOT/server/feed"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj '/CN=Router UI vanilla local CA' \
  -keyout "$RUN_ROOT/tls/ca.key" -out "$RUN_ROOT/tls/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -sha256 -subj "/CN=$HOST_ADDRESS" \
  -keyout "$RUN_ROOT/tls/server.key" -out "$RUN_ROOT/tls/server.csr" >/dev/null 2>&1
printf 'subjectAltName=IP:%s\nextendedKeyUsage=serverAuth\n' "$HOST_ADDRESS" > "$RUN_ROOT/tls/server.ext"
openssl x509 -req -sha256 -days 1 -in "$RUN_ROOT/tls/server.csr" -CA "$RUN_ROOT/tls/ca.crt" \
  -CAkey "$RUN_ROOT/tls/ca.key" -CAcreateserial -extfile "$RUN_ROOT/tls/server.ext" \
  -out "$RUN_ROOT/tls/server.crt" >/dev/null 2>&1
ruby "$REMOTE_ROOT/runtime/https-artifact-server.rb" --root "$RUN_ROOT/server" \
  --cert "$RUN_ROOT/tls/server.crt" --key "$RUN_ROOT/tls/server.key" --port "$HTTPS_PORT" \
  > "$RUN_ROOT/https-server.log" 2>&1 &
SERVER_PID=$!
sleep 1
kill -0 "$SERVER_PID" 2>/dev/null || fail 'vanilla local HTTPS server failed to start'

validate_installed() {
  local label="$1" before_boot="$2" after_boot="$3" before_config="$4" evidence="$5"
  [[ "$before_boot" != "$after_boot" ]] || fail "$label did not change boot ID"
  guest_ssh '
    [ "$(sed -n "1p" /usr/share/vpn-ui/version)" = 0.7.11 ]
    for package in premier-router-core luci-app-premier-router premier-router-setup; do
      [ "$(opkg status "$package" | sed -n "s/^Version: //p" | sed -n "1p")" = 0.7.11-1 ]
      [ -s "/usr/lib/opkg/info/$package.list" ]
    done
    /usr/sbin/vpn-ui check
    /usr/sbin/vpn-ui vpn-summary | jsonfilter -e "@" >/dev/null
    /usr/sbin/vpn-ui tailscale-status | jsonfilter -e "@" >/dev/null
    /usr/sbin/vpn-ui update-status | jsonfilter -e "@" >/dev/null
    usign -q -V -p /usr/share/premier-router/keys/release.pub \
      -m /etc/premier-router/installed-manifest.json \
      -x /etc/premier-router/installed-manifest.json.sig
    [ "$(usign -F -p /usr/share/premier-router/keys/release.pub)" = d055711acf1d9a5b ]
    [ -s /www/setup/index.html ] && [ -x /usr/sbin/vpn-ui ]
    for asset in /luci-static/resources/view/network/vpn.js \
      /luci-static/resources/view/network/tailscale.js \
      /luci-static/resources/view/system/update.js /setup/index.html; do
      [ "$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1$asset")" = 200 ]
    done
    ! find /usr/share/premier-router /etc/premier-router -type f \
      \( -name "*.sec" -o -name "*.key" -o -name "*.pem" \) | grep -q .
  ' > "$evidence/functional-validation.log"
  after_config="$(guest_ssh sha256sum /etc/config/router-ui-vanilla-fixture | awk '{print $1}')"
  [[ "$after_config" = "$before_config" ]] || fail "$label did not preserve configuration"
  printf 'pre_boot=%s\npost_boot=%s\nconfig_sha256=%s\n' "$before_boot" "$after_boot" "$after_config" \
    > "$evidence/persistence.txt"
  guest_ssh 'opkg status premier-router-core luci-app-premier-router premier-router-setup; for package in premier-router-core luci-app-premier-router premier-router-setup; do opkg files "$package"; done' \
    > "$evidence/package-metadata.txt"
}

run_path() {
  local path="$1" evidence="$RUN_ROOT/path-$1" before_boot after_boot before_config
  mkdir -p "$evidence"
  "$VBOXMANAGE" snapshot "$VM_NAME" restore "$SNAPSHOT_NAME" >/dev/null
  "$VBOXMANAGE" startvm "$VM_NAME" --type headless >/dev/null
  VM_STARTED=true
  wait_guest || fail "vanilla path $path SSH readiness failed"
  guest_ssh 'grep -q "DISTRIB_RELEASE=.24.10.5." /etc/openwrt_release; [ ! -e /usr/share/vpn-ui/version ]; ! opkg status premier-router-core 2>/dev/null | grep -q installed'
  guest_ssh 'printf "config fixture main\n\toption marker synthetic-preserved\n" > /etc/config/router-ui-vanilla-fixture'
  before_config="$(guest_ssh sha256sum /etc/config/router-ui-vanilla-fixture | awk '{print $1}')"
  guest_ssh 'umask 077; cat > /etc/ssl/certs/router-ui-vanilla-ca.pem' < "$RUN_ROOT/tls/ca.crt"
  before_boot="$(guest_ssh cat /proc/sys/kernel/random/boot_id)"
  if [[ "$path" = A ]]; then
    for file in production-2026-07.pub SHA256SUMS SHA256SUMS.sig \
      premier-router-core_0.7.11-1_all.ipk luci-app-premier-router_0.7.11-1_all.ipk \
      premier-router-setup_0.7.11-1_all.ipk; do
      guest_ssh "umask 077; cat > '/tmp/$file'" < "$CANDIDATE_DIR/$file"
    done
    guest_ssh '
      usign -q -V -p /tmp/production-2026-07.pub -m /tmp/SHA256SUMS -x /tmp/SHA256SUMS.sig
      for file in premier-router-core_0.7.11-1_all.ipk luci-app-premier-router_0.7.11-1_all.ipk premier-router-setup_0.7.11-1_all.ipk; do
        expected="$(awk -v file="$file" "$2 == file {print $1}" /tmp/SHA256SUMS)"
        [ "$(sha256sum "/tmp/$file" | awk "{print \$1}")" = "$expected" ]
      done
      SSL_CERT_FILE=/etc/ssl/certs/router-ui-vanilla-ca.pem opkg update
      SSL_CERT_FILE=/etc/ssl/certs/router-ui-vanilla-ca.pem opkg install \
        /tmp/premier-router-core_0.7.11-1_all.ipk \
        /tmp/luci-app-premier-router_0.7.11-1_all.ipk \
        /tmp/premier-router-setup_0.7.11-1_all.ipk
    ' > "$evidence/install.log" 2>&1
  else
    guest_ssh "umask 077; cat > '/etc/opkg/keys/$EXPECTED_FINGERPRINT'" < "$PUBLIC_KEY"
    guest_ssh "printf '%s\n' 'src/gz premier_router https://$HOST_ADDRESS:$HTTPS_PORT/feed' > /etc/opkg/customfeeds.conf.d/premier-router.conf
      SSL_CERT_FILE=/etc/ssl/certs/router-ui-vanilla-ca.pem opkg update
      SSL_CERT_FILE=/etc/ssl/certs/router-ui-vanilla-ca.pem opkg install \
        premier-router-core luci-app-premier-router premier-router-setup" \
      > "$evidence/install.log" 2>&1
  fi
  guest_ssh 'sync; reboot' >/dev/null 2>&1 || true
  after_boot="$(wait_reboot "$before_boot")" || fail "vanilla path $path did not return after reboot"
  validate_installed "path-$path" "$before_boot" "$after_boot" "$before_config" "$evidence"
  stop_vm
  "$VBOXMANAGE" snapshot "$VM_NAME" restore "$SNAPSHOT_NAME" >/dev/null
}

run_path A
run_path B

[[ "$(vm_state)" = poweroff ]] || fail 'vanilla VM is not powered off'
[[ -z "$($VBOXMANAGE list runningvms | awk -F'"' '$2 ~ /^RouterUI-/ {print $2}')" ]] || fail 'a RouterUI VM remains running'
printf 'Vanilla OpenWrt direct-IPK and signed-feed installation paths passed: %s\n' "$RUN_ROOT"
trap - EXIT INT TERM
