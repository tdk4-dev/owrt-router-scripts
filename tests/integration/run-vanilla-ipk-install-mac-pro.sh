#!/bin/bash
set -euo pipefail
[ -z "${ROUTER_UI_TIER0_GUARD_LOG:-}" ] || { printf 'vm-execution:%s\n' "${0##*/}" >> "$ROUTER_UI_TIER0_GUARD_LOG"; exit 97; }
umask 077

VBOXMANAGE=/usr/local/bin/VBoxManage
USIGN_BIN="${USIGN_BIN:-/Users/mac-pro-host/.local/libexec/premier-router/usign-c4c72b1}"
EXPECTED_CANDIDATE_APP_VERSION=0.7.11-rc.11
EXPECTED_CANDIDATE_PACKAGE_VERSION=0.7.11~rc11-1
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
MANIFEST="$CANDIDATE_DIR/router-release-manifest.json"
MANIFEST_SIGNATURE="$CANDIDATE_DIR/router-release-manifest.json.sig"
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
stop_server() {
  [[ -z "$SERVER_PID" ]] || {
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=
  }
}
cleanup() {
  local rc=$?
  set +e
  stop_server
  stop_vm
  if vm_exists && [[ "$(vm_state)" = poweroff ]] &&
    "$VBOXMANAGE" snapshot "$VM_NAME" list --machinereadable 2>/dev/null | grep -Fq "SnapshotName=\"$SNAPSHOT_NAME\""; then
    "$VBOXMANAGE" snapshot "$VM_NAME" restore "$SNAPSHOT_NAME" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

[[ "$SOURCE_ROOT" = /Users/mac-pro-host/Documents/RouterUI-release/Premier-Router-0.7.11-rc11-worktree ]]
[[ "$CANDIDATE_DIR" = "$REMOTE_ROOT"/assets/* ]]
[[ "$USIGN_BIN" = /* && -x "$USIGN_BIN" ]] || fail 'USIGN_BIN must be an absolute executable path'
[[ -x "$VBOXMANAGE" && -s "$MANIFEST" && -s "$MANIFEST_SIGNATURE" &&
  -s "$CANDIDATE_DIR/SHA256SUMS" && -s "$CANDIDATE_DIR/SHA256SUMS.sig" ]]

CANDIDATE_SIGNING_KEY_ID="$(jq -er \
  '.signing_key_id | select(type == "string" and test("^[A-Za-z0-9._-]+$"))' "$MANIFEST")"
CANDIDATE_SIGNING_KEY_FINGERPRINT="$(jq -er \
  '.signing_key_fingerprint | select(type == "string" and test("^[0-9a-f]{16}$"))' "$MANIFEST")"
PUBLIC_KEY="$CANDIDATE_DIR/$CANDIDATE_SIGNING_KEY_ID.pub"
[[ -s "$PUBLIC_KEY" ]] || fail 'candidate public key asset is missing'
[[ "$("$USIGN_BIN" -F -p "$PUBLIC_KEY")" = "$CANDIDATE_SIGNING_KEY_FINGERPRINT" ]] ||
  fail 'candidate public key fingerprint does not match the manifest'
"$USIGN_BIN" -q -V -p "$PUBLIC_KEY" -m "$MANIFEST" -x "$MANIFEST_SIGNATURE" ||
  fail 'candidate router release manifest signature is invalid'
"$USIGN_BIN" -q -V -p "$PUBLIC_KEY" -m "$CANDIDATE_DIR/SHA256SUMS" \
  -x "$CANDIDATE_DIR/SHA256SUMS.sig" || fail 'candidate SHA256SUMS signature is invalid'
(cd "$CANDIDATE_DIR" && shasum -a 256 -c SHA256SUMS) ||
  fail 'candidate bytes differ from the signed SHA256SUMS inventory'

CANDIDATE_APP_VERSION="$(jq -er '.app_version | select(type == "string")' "$MANIFEST")"
CANDIDATE_PACKAGE_VERSION="$(jq -er '.package_version | select(type == "string")' "$MANIFEST")"
CANDIDATE_RELEASE_TAG="$(jq -er \
  '.release_tag | select(type == "string" and test("^[A-Za-z0-9._~-]+$"))' "$MANIFEST")"
CANDIDATE_SOURCE_COMMIT="$(jq -er \
  '.source_commit | select(type == "string" and test("^[0-9a-f]{40}$"))' "$MANIFEST")"
[[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" = "$CANDIDATE_SOURCE_COMMIT" ]] ||
  fail 'candidate manifest source differs from the source worktree HEAD'
[[ -z "$(git -C "$SOURCE_ROOT" status --short)" ]] ||
  fail 'source worktree is dirty'
[[ "$CANDIDATE_APP_VERSION" = "$EXPECTED_CANDIDATE_APP_VERSION" ]] ||
  fail "candidate app version is $CANDIDATE_APP_VERSION, expected $EXPECTED_CANDIDATE_APP_VERSION"
[[ "$CANDIDATE_PACKAGE_VERSION" = "$EXPECTED_CANDIDATE_PACKAGE_VERSION" ]] ||
  fail "candidate package version is $CANDIDATE_PACKAGE_VERSION, expected $EXPECTED_CANDIDATE_PACKAGE_VERSION"
[[ "$CANDIDATE_RELEASE_TAG" = "vpn-panel-v$CANDIDATE_APP_VERSION" ]] ||
  fail 'candidate manifest release tag does not match its app version'
[[ "$(jq -er .channel "$MANIFEST")" = candidate ]] || fail 'candidate manifest is not on the candidate channel'

ACTIVE_KEY_ID="$(jq -er '.active_key_id' "$SOURCE_ROOT/release/keys/trusted-keys.json")"
ACTIVE_KEY_FINGERPRINT="$(jq -er --arg key "$ACTIVE_KEY_ID" \
  '.keys[] | select(.key_id == $key and .status == "active") | .fingerprint' \
  "$SOURCE_ROOT/release/keys/trusted-keys.json")"
ACTIVE_KEY_PATH="$(jq -er --arg key "$ACTIVE_KEY_ID" \
  '.keys[] | select(.key_id == $key and .status == "active") | .public_key_path' \
  "$SOURCE_ROOT/release/keys/trusted-keys.json")"
[[ "$CANDIDATE_SIGNING_KEY_ID" = "$ACTIVE_KEY_ID" &&
  "$CANDIDATE_SIGNING_KEY_FINGERPRINT" = "$ACTIVE_KEY_FINGERPRINT" ]] ||
  fail 'candidate is not signed by the committed active key'
cmp -s "$PUBLIC_KEY" "$SOURCE_ROOT/$ACTIVE_KEY_PATH" ||
  fail 'candidate public key differs from the committed active key'

CORE_IPK="$(jq -er '.packages[] | select(.name == "premier-router-core") | .filename' "$MANIFEST")"
LUCI_IPK="$(jq -er '.packages[] | select(.name == "luci-app-premier-router") | .filename' "$MANIFEST")"
SETUP_IPK="$(jq -er '.packages[] | select(.name == "premier-router-setup") | .filename' "$MANIFEST")"
FEED_ARCHIVE="$(jq -er '.package_feed.filename | select(type == "string")' "$MANIFEST")"
FEED_ARCHIVE_SHA256="$(jq -er \
  '.package_feed.sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' "$MANIFEST")"
[[ "$CORE_IPK" = "premier-router-core_${CANDIDATE_PACKAGE_VERSION}_all.ipk" &&
  "$LUCI_IPK" = "luci-app-premier-router_${CANDIDATE_PACKAGE_VERSION}_all.ipk" &&
  "$SETUP_IPK" = "premier-router-setup_${CANDIDATE_PACKAGE_VERSION}_all.ipk" ]] ||
  fail 'candidate IPK filenames do not match the signed package version'
[[ "$FEED_ARCHIVE" = "premier-router-opkg-feed-$CANDIDATE_APP_VERSION.tar.gz" ]] ||
  fail 'candidate feed filename does not match the signed app version'
[[ -s "$CANDIDATE_DIR/$FEED_ARCHIVE" ]] || fail 'candidate feed archive is missing'
[[ "$(shasum -a 256 "$CANDIDATE_DIR/$FEED_ARCHIVE" | awk '{print $1}')" = \
  "$FEED_ARCHIVE_SHA256" ]] ||
  fail 'candidate feed archive differs from the hash in the signed manifest'

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
tar -xzf "$CANDIDATE_DIR/$FEED_ARCHIVE" -C "$RUN_ROOT/server/feed"
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
  guest_ssh "expected_app='$CANDIDATE_APP_VERSION'; expected_package='$CANDIDATE_PACKAGE_VERSION'; expected_fingerprint='$CANDIDATE_SIGNING_KEY_FINGERPRINT';" '
    set -e
    [ "$(sed -n "1p" /usr/share/vpn-ui/version)" = "$expected_app" ]
    for package in premier-router-core luci-app-premier-router premier-router-setup; do
      [ "$(opkg status "$package" | sed -n "s/^Version: //p" | sed -n "1p")" = "$expected_package" ]
      [ -s "/usr/lib/opkg/info/$package.list" ]
    done
    /usr/sbin/vpn-ui check
    /usr/sbin/vpn-ui vpn-summary | jsonfilter -e "@" >/dev/null
    /usr/sbin/vpn-ui tailscale-status | jsonfilter -e "@" >/dev/null
    /usr/sbin/vpn-ui update-status | jsonfilter -e "@" >/dev/null
    [ "$(/usr/bin/usign -F -p /usr/share/premier-router/keys/release.pub)" = "$expected_fingerprint" ]
    [ -s /www/setup/index.html ] && [ -x /usr/sbin/vpn-ui ]
    for asset in /luci-static/resources/view/network/vpn.js \
      /luci-static/resources/view/network/tailscale.js \
      /luci-static/resources/view/system/update.js /setup/index.html; do
      [ "$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1$asset")" = 200 ]
    done
    for root in /usr/share/premier-router /etc/premier-router; do
      [ ! -d "$root" ] || ! find "$root" -type f \
        \( -name "*.sec" -o -name "*.key" -o -name "*.pem" \) | grep -q .
    done
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
  guest_ssh 'umask 077; cat > /tmp/router-ui-vanilla-ca.pem' < "$RUN_ROOT/tls/ca.crt"
  guest_ssh '
    set -e
    [ -s /etc/ssl/certs/ca-certificates.crt ]
    cat /tmp/router-ui-vanilla-ca.pem >> /etc/ssl/certs/ca-certificates.crt
    rm -f /tmp/router-ui-vanilla-ca.pem
  '
  before_boot="$(guest_ssh cat /proc/sys/kernel/random/boot_id)"
  if [[ "$path" = A ]]; then
    for file in "$CANDIDATE_SIGNING_KEY_ID.pub" SHA256SUMS SHA256SUMS.sig \
      "$CORE_IPK" "$LUCI_IPK" "$SETUP_IPK"; do
      guest_ssh "umask 077; cat > '/tmp/$file'" < "$CANDIDATE_DIR/$file"
    done
    guest_ssh "key_asset='$CANDIDATE_SIGNING_KEY_ID.pub'; core_ipk='$CORE_IPK'; luci_ipk='$LUCI_IPK'; setup_ipk='$SETUP_IPK';" '
      set -e
      /usr/bin/usign -q -V -p "/tmp/$key_asset" -m /tmp/SHA256SUMS -x /tmp/SHA256SUMS.sig
      for file in "$core_ipk" "$luci_ipk" "$setup_ipk"; do
        expected="$(grep -F "  $file" /tmp/SHA256SUMS | cut -d " " -f 1)"
        [ -n "$expected" ]
        [ "$(sha256sum "/tmp/$file" | awk "{print \$1}")" = "$expected" ]
      done
      opkg update
      opkg install \
        "/tmp/$core_ipk" "/tmp/$luci_ipk" "/tmp/$setup_ipk"
    ' > "$evidence/install.log" 2>&1
  else
    guest_ssh "umask 077; cat > '/etc/opkg/keys/$CANDIDATE_SIGNING_KEY_FINGERPRINT'" < "$PUBLIC_KEY"
    guest_ssh "set -e
      printf '%s\n' 'src/gz premier_router https://$HOST_ADDRESS:$HTTPS_PORT/feed' > /etc/opkg/customfeeds.conf
      opkg update
      opkg install \
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

stop_server
[[ "$(vm_state)" = poweroff ]] || fail 'vanilla VM is not powered off'
[[ -z "$($VBOXMANAGE list runningvms | awk -F'"' '$2 ~ /^RouterUI-/ {print $2}')" ]] || fail 'a RouterUI VM remains running'
printf 'Vanilla OpenWrt direct-IPK and signed-feed installation paths passed for %s (%s): %s\n' \
  "$CANDIDATE_APP_VERSION" "$CANDIDATE_RELEASE_TAG" "$RUN_ROOT"
trap - EXIT INT TERM
