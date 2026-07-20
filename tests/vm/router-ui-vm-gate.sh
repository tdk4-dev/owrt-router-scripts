#!/bin/bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RELEASE_DIR="${RELEASE_DIR:?RELEASE_DIR is required}"
X86_IMAGE_ARCHIVE="${X86_IMAGE_ARCHIVE:?X86_IMAGE_ARCHIVE is required}"
SYNTHETIC_DIR="${SYNTHETIC_DIR:?SYNTHETIC_DIR is required}"
EVIDENCE_DIR="${EVIDENCE_DIR:?EVIDENCE_DIR is required}"
DIAGNOSTIC_CASE="${ROUTER_UI_VM_DIAGNOSTIC_CASE:-full}"
DIAGNOSTIC_RUN="${ROUTER_UI_VM_DIAGNOSTIC:-0}"
HARNESS_SOURCE_SHA="${ROUTER_UI_VM_HARNESS_SHA:-}"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
SERVER_PORT="${ROUTER_UI_VM_HTTPS_PORT:-18443}"
SSH_PORT="${ROUTER_UI_VM_SSH_PORT:-22220}"
HTTP_PORT="${ROUTER_UI_VM_HTTP_PORT:-18080}"
SERIAL_PORT="${ROUTER_UI_VM_SERIAL_PORT:-22330}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-vm-gate.XXXXXX")"
ORIGIN="https://10.0.2.2:$SERVER_PORT"
HOST_ORIGIN="https://127.0.0.1:$SERVER_PORT"
BASELINE_VERSIONS=(0.5.1 0.5.2 0.6.0 0.7.0 0.7.1 0.7.2 0.7.3 0.7.4 0.7.5 0.7.6 0.7.8 0.7.9 0.7.10)
FAULT_BOUNDARIES=(before-mutation snapshot_ready applying after-premier-router-core after-luci-app-premier-router after-premier-router-setup validating committing rollback_pending rolling_back rollback-after-premier-router-core rollback-after-luci-app-premier-router rollback-after-premier-router-setup compatibility-cleanup post-reboot-validation)
CURRENT_PID=""
SERVER_PID=""
STOCK_WRITABLE_KIB=0
STOCK_UBIFS_DF_KIB=0
UBOOTMOD_WRITABLE_KIB=0
UBOOTMOD_UBIFS_DF_KIB=0

cleanup() {
  status=$?
  trap - EXIT INT TERM
  set +e
  if [[ -n "$CURRENT_PID" ]]; then
    if kill -0 "$CURRENT_PID" 2>/dev/null && declare -F capture_guest_state >/dev/null; then
      capture_guest_state "cleanup-failure" >/dev/null 2>&1 || true
    fi
    kill -9 "$CURRENT_PID" 2>/dev/null
    wait "$CURRENT_PID" 2>/dev/null
    CURRENT_PID=""
  fi
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=""
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() { printf 'VM-GATE-ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing host dependency: $1"; }
case "$DIAGNOSTIC_CASE" in
  full|rescue-0.7.0) ;;
  *) fail "unsupported VM gate case selector: $DIAGNOSTIC_CASE" ;;
esac
case "$DIAGNOSTIC_RUN" in 0|1) ;; *) fail "ROUTER_UI_VM_DIAGNOSTIC must be 0 or 1" ;; esac
if [[ "$DIAGNOSTIC_RUN" = 1 ]]; then
  [[ "$HARNESS_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] ||
    fail "diagnostic VM gate requires an exact harness source SHA"
else
  [[ "$DIAGNOSTIC_CASE" = full ]] || fail "targeted cases are diagnostic-only"
fi
for tool in awk curl gzip jq make node openssl python3 qemu-img qemu-system-x86_64 sed sha256sum ssh ssh-keygen stat tar tee timeout zstd; do need "$tool"; done
mkdir -p "$EVIDENCE_DIR" "$WORK/server/releases/latest/download" \
  "$WORK/server/releases/download/vpn-panel-v0.7.11" "$WORK/server/baselines" "$WORK/server/vm"
: > "$EVIDENCE_DIR/vm-measurements.jsonl"
: > "$EVIDENCE_DIR/transition-results.jsonl"
: > "$EVIDENCE_DIR/fault-results.jsonl"
: > "$EVIDENCE_DIR/storage-results.jsonl"
: > "$EVIDENCE_DIR/published-baselines.jsonl"

record_result() {
  file="$1" kind="$2" name="$3" status="$4"
  if [[ $# -ge 5 ]]; then details="$5"; else details='{}'; fi
  jq -cn --arg kind "$kind" --arg name "$name" --arg status "$status" \
    --argjson details "$details" '{kind:$kind,name:$name,status:$status,details:$details}' >> "$file"
}

load_storage_profiles() {
  local profile pattern archive member provenance
  for profile in rd23-stock rd23-ubootmod; do
    case "$profile" in
      rd23-stock) pattern='*xiaomi-ax3000t-stock.tar.gz' ;;
      rd23-ubootmod) pattern='*xiaomi-ax3000t-ubootmod.tar.gz' ;;
    esac
    archive="$(find "$RELEASE_DIR" -maxdepth 1 -type f -name "$pattern" | sed -n '1p')"
    [[ -n "$archive" ]] || fail "release set lacks $profile image archive"
    member="$(tar -tzf "$archive" | awk '/\/image-provenance\.json$/ && !found {print; found=1}')"
    [[ -n "$member" ]] || fail "$profile archive lacks image provenance"
    provenance="$WORK/$profile.provenance.json"
    tar -xOzf "$archive" "$member" > "$provenance"
    jq -e --arg profile "$profile" '.storage_profile == $profile and
      .writable_backing_kib > 0 and .expected_ubifs_df_total_kib > 0 and
      .writable_backing_kib == .rd23_storage_layout.rootfs_data_volume_kib' \
      "$provenance" >/dev/null || fail "$profile storage provenance is incomplete"
    case "$profile" in
      rd23-stock)
        STOCK_WRITABLE_KIB="$(jq -r '.writable_backing_kib' "$provenance")"
        STOCK_UBIFS_DF_KIB="$(jq -r '.expected_ubifs_df_total_kib' "$provenance")"
        ;;
      rd23-ubootmod)
        UBOOTMOD_WRITABLE_KIB="$(jq -r '.writable_backing_kib' "$provenance")"
        UBOOTMOD_UBIFS_DF_KIB="$(jq -r '.expected_ubifs_df_total_kib' "$provenance")"
        ;;
    esac
  done
}

extract_openwrt_gzip_image() {
  local source="$1" destination="$2" log="$3" status=0 lines
  if gzip -dc "$source" > "$destination" 2> "$log"; then
    :
  else
    status=$?
    lines="$(awk 'NF { count++ } END { print count + 0 }' "$log")"
    if [[ "$status" -ne 2 ]] || [[ "$lines" -ne 1 ]] ||
      ! grep -Eq '^gzip: .*: decompression OK, trailing garbage ignored$' "$log"; then
      cat "$log" >&2
      fail "OpenWrt image decompression failed: $(basename "$source")"
    fi
  fi
  [[ -s "$destination" ]] || fail "OpenWrt image decompressed to an empty file: $(basename "$source")"
  qemu-img info --output=json "$destination" |
    jq -e '.format == "raw" and .["virtual-size"] > 0' >/dev/null ||
    fail "OpenWrt image is not a nonempty raw disk: $(basename "$source")"
}

setup_tls() {
  openssl genrsa -out "$WORK/ca.key" 2048 >/dev/null 2>&1
  openssl req -x509 -new -key "$WORK/ca.key" -sha256 -days 2 \
    -subj '/CN=Router UI disposable VM test CA' -out "$WORK/ca.crt" >/dev/null 2>&1
  openssl genrsa -out "$WORK/server.key" 2048 >/dev/null 2>&1
  openssl req -new -key "$WORK/server.key" -subj '/CN=10.0.2.2' -out "$WORK/server.csr" >/dev/null 2>&1
  printf 'subjectAltName=IP:10.0.2.2,IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n' > "$WORK/server.ext"
  openssl x509 -req -in "$WORK/server.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
    -CAcreateserial -out "$WORK/server.crt" -days 2 -sha256 -extfile "$WORK/server.ext" >/dev/null 2>&1
}

prepare_server() {
  local file version base versions
  for file in "$RELEASE_DIR"/*; do
    [[ -f "$file" ]] || continue
    ln "$file" "$WORK/server/releases/latest/download/$(basename "$file")"
    ln "$file" "$WORK/server/releases/download/vpn-panel-v0.7.11/$(basename "$file")"
  done
  mkdir -p "$WORK/server/releases/download/vpn-panel-v0.7.12"
  for file in "$SYNTHETIC_DIR"/*; do
    [[ -f "$file" ]] || continue
    ln "$file" "$WORK/server/releases/download/vpn-panel-v0.7.12/$(basename "$file")"
  done
  cp "$ROOT_DIR/tests/vm/router-ui-vm-guest.sh" "$WORK/server/vm/"
  if [[ "$DIAGNOSTIC_CASE" = rescue-0.7.0 ]]; then
    versions=(0.7.0)
  else
    versions=("${BASELINE_VERSIONS[@]}")
  fi
  for version in "${versions[@]}"; do
    base="https://github.com/tdk4-dev/owrt-router-scripts/releases/download/vpn-panel-v$version"
    mkdir -p "$WORK/server/baselines/$version"
    curl -fL --retry 3 "$base/luci-vpn-ui.tar.gz" -o "$WORK/server/baselines/$version/luci-vpn-ui.tar.gz"
    curl -fL --retry 3 "$base/luci-vpn-ui.tar.gz.sha256" -o "$WORK/server/baselines/$version/luci-vpn-ui.tar.gz.sha256"
    (cd "$WORK/server/baselines/$version" && sha256sum -c luci-vpn-ui.tar.gz.sha256 >/dev/null)
    jq -cn --arg version "$version" \
      --arg sha256 "$(sha256sum "$WORK/server/baselines/$version/luci-vpn-ui.tar.gz" | awk '{print $1}')" \
      --argjson size "$(wc -c < "$WORK/server/baselines/$version/luci-vpn-ui.tar.gz" | tr -d ' ')" \
      '{version:$version,asset:"luci-vpn-ui.tar.gz",sha256:$sha256,size:$size,source:"exact-published-release"}' \
      >> "$EVIDENCE_DIR/published-baselines.jsonl"
  done
  python3 "$ROOT_DIR/tests/vm/https-artifact-server.py" --root "$WORK/server" \
    --cert "$WORK/server.crt" --key "$WORK/server.key" --port "$SERVER_PORT" \
    >"$EVIDENCE_DIR/https-server.log" 2>&1 &
  SERVER_PID=$!
  for _ in {1..30}; do
    curl -fsS --connect-timeout 1 --max-time 5 --cacert "$WORK/ca.crt" \
      "$HOST_ORIGIN/releases/latest/download/vpn-ui-version.txt" >/dev/null && return
    sleep 1
  done
  fail "local TLS-valid artifact server did not start"
}

build_vm_base() {
  local ib_name="openwrt-imagebuilder-$OPENWRT_VERSION-x86-64.Linux-x86_64"
  local archive="$WORK/$ib_name.tar.zst" ib="$WORK/$ib_name" packages overlay="$WORK/base-overlay"
  local host_bin="$WORK/host-bin"
  jq -n '{kind:"deterministic-non-secret-test-profile",
    applies_to:["0.7.0","0.7.1","0.7.2","0.7.3","0.7.4","0.7.5","0.7.6","0.7.8","0.7.9","0.7.10"],
    endpoint:"192.0.2.1",endpoint_class:"IANA-TEST-NET-1",reachable_endpoint:false,
    subscription_url_present:false,private_key_present:false,
    protected_by_hash_contract:true}' > "$EVIDENCE_DIR/vm-test-profile.json"
  mkdir -p "$host_bin"
  cat > "$host_bin/sha256" <<'EOF'
#!/bin/sh
sha256sum "$@" | awk '{print $1}'
EOF
  chmod 755 "$host_bin/sha256"
  PATH="$host_bin:$PATH"
  export PATH
  curl -fL --retry 3 "https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/x86/64/$ib_name.tar.zst" -o "$archive"
  tar --use-compress-program=unzstd -xf "$archive" -C "$WORK"
  "$ROOT_DIR/scripts/patch-openwrt-x86-writable-extent.sh" \
    "$ib/scripts/gen_image_generic.sh"
  grep -q ROOTFS_SIZE_SPEC "$ib/scripts/gen_image_generic.sh" ||
    fail "VM ImageBuilder lacks exact writable-extent support"
  sed -i 's/^CONFIG_TARGET_ROOTFS_EXT4FS=y$/# CONFIG_TARGET_ROOTFS_EXT4FS is not set/' "$ib/.config"
  grep -q '^# CONFIG_TARGET_ROOTFS_EXT4FS is not set$' "$ib/.config" ||
    fail "could not disable the unused VM ext4 image variant"
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/ssh-key"
  mkdir -p "$overlay/etc/config" "$overlay/etc/dropbear" "$overlay/etc/ssl/certs"
  cp "$WORK/ssh-key.pub" "$overlay/etc/dropbear/authorized_keys"
  cp "$WORK/ca.crt" "$overlay/etc/ssl/certs/router-ui-vm-ca.pem"
  cat > "$overlay/etc/config/network" <<'EOF'
config interface 'loopback'
  option device 'lo'
  option proto 'static'
  option ipaddr '127.0.0.1'
  option netmask '255.0.0.0'
config interface 'lan'
  option device 'eth0'
  option proto 'dhcp'
EOF
  # The harness itself is deliberately umask 077, but ImageBuilder preserves
  # FILES directory modes.  An unreadable /etc tree prevents ubusd from
  # starting and leaves the guest stuck at "procd: - ubus -".
  chmod 755 "$overlay" "$overlay/etc" "$overlay/etc/config" \
    "$overlay/etc/dropbear" "$overlay/etc/ssl" "$overlay/etc/ssl/certs"
  chmod 600 "$overlay/etc/dropbear/authorized_keys"
  chmod 644 "$overlay/etc/config/network" \
    "$overlay/etc/ssl/certs/router-ui-vm-ca.pem"
  for path in "$overlay" "$overlay/etc" "$overlay/etc/config" \
    "$overlay/etc/dropbear" "$overlay/etc/ssl" "$overlay/etc/ssl/certs"; do
    [[ "$(stat -c '%a' "$path")" = 755 ]] ||
      fail "unsafe ImageBuilder overlay directory mode: $path"
  done
  [[ "$(stat -c '%a' "$overlay/etc/dropbear/authorized_keys")" = 600 ]] ||
    fail "unsafe VM authorized-keys mode"
  [[ "$(stat -c '%a' "$overlay/etc/config/network")" = 644 ]] ||
    fail "unsafe VM network-config mode"
  [[ "$(stat -c '%a' "$overlay/etc/ssl/certs/router-ui-vm-ca.pem")" = 644 ]] ||
    fail "unsafe VM test-CA mode"
  packages="$(awk 'NF && $1 !~ /^#/ {printf "%s ",$1}' "$ROOT_DIR/image/openwrt-fin0-packages.txt") dropbear ca-bundle usign"
  local profile budget profiles
  if [[ "$DIAGNOSTIC_CASE" = rescue-0.7.0 ]]; then
    profiles=(rd23-stock)
  else
    profiles=(rd23-stock rd23-ubootmod)
  fi
  for profile in "${profiles[@]}"; do
    case "$profile" in
      rd23-stock) budget="$STOCK_WRITABLE_KIB" ;;
      rd23-ubootmod) budget="$UBOOTMOD_WRITABLE_KIB" ;;
    esac
    rm -rf "$ib/bin/targets/x86/64"
    if ! (umask 022 && ROOTFS_WRITABLE_KIB="$budget" make -C "$ib" image \
      PROFILE=generic PACKAGES="$packages" FILES="$overlay" ROOTFS_PARTSIZE=128) \
      > "$EVIDENCE_DIR/vm-base-$profile-build.log" 2>&1; then
      cat "$EVIDENCE_DIR/vm-base-$profile-build.log" >&2
      fail "VM base build failed for the $profile exact writable extent"
    fi
    base_gz="$(find "$ib/bin/targets/x86/64" -maxdepth 1 -type f -name '*squashfs-combined.img.gz' | sed -n '1p')"
    [[ -n "$base_gz" ]] || fail "VM base build did not produce the $profile combined squashfs image"
    extract_openwrt_gzip_image "$base_gz" "$WORK/vm-base-$profile.img" \
      "$EVIDENCE_DIR/vm-base-$profile-gzip.log"
  done
  ln -s "$WORK/vm-base-rd23-stock.img" "$WORK/vm-base.img"
}

extract_candidate_image() {
  mkdir -p "$WORK/candidate-archive"
  tar -xzf "$X86_IMAGE_ARCHIVE" -C "$WORK/candidate-archive"
  candidate_gz="$(find "$WORK/candidate-archive" -type f -name '*squashfs-combined.img.gz' | sed -n '1p')"
  [[ -n "$candidate_gz" ]] || fail "candidate archive lacks x86 combined squashfs image"
  extract_openwrt_gzip_image "$candidate_gz" "$WORK/candidate.img" \
    "$EVIDENCE_DIR/candidate-image-gzip.log"
}

clone_disk() {
  backing="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  qemu-img create -q -f qcow2 -F "${3:-raw}" -b "$backing" "$2"
}

start_vm() {
  disk="$1" name="$2"
  [[ -z "$CURRENT_PID" ]] || fail "serial harness attempted to overlap project VMs"
  qemu-system-x86_64 -name "router-ui-vm-$name" -machine pc,accel=tcg -cpu qemu64 \
    -m 256 -smp 1 -drive "file=$disk,if=ide,format=qcow2" \
    -nic "user,model=e1000,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$HTTP_PORT-:80" \
    -chardev "socket,id=serial0,host=127.0.0.1,port=$SERIAL_PORT,server=on,wait=off,logfile=$EVIDENCE_DIR/$name.serial.log" \
    -serial chardev:serial0 -display none \
    >"$EVIDENCE_DIR/$name.qemu.log" 2>&1 &
  CURRENT_PID=$!
  sleep 1
  kill -0 "$CURRENT_PID" 2>/dev/null || {
    cat "$EVIDENCE_DIR/$name.qemu.log" >&2
    cat "$EVIDENCE_DIR/$name.serial.log" >&2
    wait "$CURRENT_PID" 2>/dev/null || true
    CURRENT_PID=""
    fail "QEMU process exited before readiness: $name"
  }
}

ssh_base=(ssh -i "$WORK/ssh-key" -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 root@127.0.0.1)
console_bootstrap_key() {
  ROUTER_UI_VM_PUBLIC_KEY="$(cat "$WORK/ssh-key.pub")" \
  ROUTER_UI_VM_CA_B64="$(base64 < "$WORK/ca.crt" | tr -d '\n')" \
    python3 - "$SERIAL_PORT" <<'PY'
import os, socket, sys, time
try:
    sock = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1)
    sock.settimeout(0.2)
    sock.sendall(b"\n")
    time.sleep(1)
    key = os.environ["ROUTER_UI_VM_PUBLIC_KEY"]
    ca = os.environ["ROUTER_UI_VM_CA_B64"]
    command = (
        "uci -q set network.lan.proto='dhcp'; "
        "uci -q delete network.lan.ipaddr; uci -q delete network.lan.netmask; "
        "uci -q delete network.lan.gateway; uci -q delete network.lan.dns; "
        "uci commit network; /etc/init.d/network restart; "
        "mkdir -p /etc/dropbear /etc/ssl/certs; "
        "printf '%s\\n' '" + key + "' > /etc/dropbear/authorized_keys; "
        "printf '%s' '" + ca + "' | base64 -d > /etc/ssl/certs/router-ui-vm-ca.pem; "
        "chmod 600 /etc/dropbear/authorized_keys; /etc/init.d/dropbear restart\n"
    )
    for byte in command.encode():
        sock.sendall(bytes((byte,)))
        time.sleep(0.003)
    time.sleep(1)
    sock.close()
except OSError:
    pass
PY
}
wait_serial_console() {
  local serial_log="$1"
  for _ in {1..120}; do
    grep -q 'Please press Enter to activate this console' "$serial_log" && return
    kill -0 "$CURRENT_PID" 2>/dev/null || fail "VM exited before its serial console became ready"
    sleep 1
  done
  fail "VM serial console did not become ready"
}
wait_ssh() {
  for _ in {1..120}; do
    "${ssh_base[@]}" true >/dev/null 2>&1 && return
    sleep 1
  done
  fail "VM SSH did not become ready"
}
start_candidate_vm() {
  local disk="$1" name="$2"
  start_vm "$disk" "$name"
  wait_serial_console "$EVIDENCE_DIR/$name.serial.log"
  console_bootstrap_key
  wait_ssh
}
guest() {
  local command="" arg
  for arg in "$@"; do printf -v quoted '%q' "$arg"; command+=" $quoted"; done
  "${ssh_base[@]}" "SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem curl -fsSL --proto '=https' '$ORIGIN/vm/router-ui-vm-guest.sh' -o /tmp/router-ui-vm-guest.sh && chmod 700 /tmp/router-ui-vm-guest.sh && /tmp/router-ui-vm-guest.sh$command"
}
capture_guest_state() {
  local name="$1" out="$EVIDENCE_DIR/$1"
  [[ -n "$CURRENT_PID" ]] && kill -0 "$CURRENT_PID" 2>/dev/null || return 0
  timeout 20 "${ssh_base[@]}" '
    echo "== version =="
    sed -n "1p" /usr/share/vpn-ui/version 2>/dev/null || true
    echo "== updater status =="
    /usr/sbin/vpn-ui-update status 2>/dev/null || true
    echo "== project opkg status =="
    for package in premier-router-core luci-app-premier-router premier-router-setup; do
      opkg status "$package" 2>/dev/null || true
    done
    echo "== filesystems =="
    df -Pk / /overlay /tmp 2>/dev/null || true
    echo "== memory =="
    sed -n "/^MemTotal:/p" /proc/meminfo
    echo "== protected filesystem hashes =="
    for path in /etc/config /etc/xray /etc/vpn-ui-update.conf /etc/crontabs/root; do
      if [ -f "$path" ]; then sha256sum "$path"; fi
      if [ -d "$path" ]; then find "$path" -type f -exec sha256sum {} \; | sort; fi
    done
    echo "== updater evidence hashes =="
    find /root/premier-router-updates -maxdepth 4 -type f -exec sha256sum {} \; 2>/dev/null | sort
    echo "== updater service state =="
    /etc/init.d/premier-router-update-recovery enabled 2>/dev/null; echo "enabled_rc=$?"
    /etc/init.d/premier-router-update-recovery running 2>/dev/null; echo "running_rc=$?"
  ' > "$out.filesystem.txt" 2>&1 || true
  timeout 20 "${ssh_base[@]}" '
    find /root/premier-router-updates -maxdepth 4 -type f \
      \( -name "*.json" -o -name "*.log" -o -name "*.txt" \) -print 2>/dev/null | sort |
    while IFS= read -r file; do
      echo "===== $file ====="
      sed -n "1,800p" "$file"
    done
  ' > "$out.transaction-evidence.txt" 2>&1 || true
  timeout 20 "${ssh_base[@]}" logread > "$out.logread.txt" 2>&1 || true
  timeout 20 "${ssh_base[@]}" '
    find /tmp -maxdepth 1 -type f \
      \( -name "vpn-ui*.log" -o -name "vpn-ui*.json" \) -print 2>/dev/null | sort |
    while IFS= read -r file; do
      echo "===== $file ====="
      sed -n "1,800p" "$file"
    done
  ' > "$out.guest-bootstrap-and-validator.txt" 2>&1 || true
}
record_measurement() {
  name="$1" profile="${2:-rd23-stock}"
  case "$profile" in
    rd23-stock) measurement="$(guest measure "$profile" "$STOCK_WRITABLE_KIB" "$STOCK_UBIFS_DF_KIB")" ;;
    rd23-ubootmod) measurement="$(guest measure "$profile" "$UBOOTMOD_WRITABLE_KIB" "$UBOOTMOD_UBIFS_DF_KIB")" ;;
    *) fail "unknown measurement profile: $profile" ;;
  esac
  jq -cn --arg name "$name" --argjson measurement "$measurement" '$measurement + {case:$name}' >> "$EVIDENCE_DIR/vm-measurements.jsonl"
}
measure_stock() { guest measure rd23-stock "$STOCK_WRITABLE_KIB" "$STOCK_UBIFS_DF_KIB"; }
measure_ubootmod() { guest measure rd23-ubootmod "$UBOOTMOD_WRITABLE_KIB" "$UBOOTMOD_UBIFS_DF_KIB"; }
shutdown_vm() {
  [[ -n "$CURRENT_PID" ]] || fail "shutdown requested without an owned VM PID"
  set +e
  "${ssh_base[@]}" 'sync; poweroff' >/dev/null 2>&1
  for _ in {1..30}; do kill -0 "$CURRENT_PID" 2>/dev/null || break; sleep 1; done
  kill "$CURRENT_PID" 2>/dev/null || true
  wait "$CURRENT_PID" 2>/dev/null
  set -e
  CURRENT_PID=""
}
hard_poweroff_vm() {
  [[ -n "$CURRENT_PID" ]] || fail "power-off requested without an owned VM PID"
  kill -9 "$CURRENT_PID" 2>/dev/null || true
  wait "$CURRENT_PID" 2>/dev/null || true
  CURRENT_PID=""
}
normal_reboot() {
  before="$("${ssh_base[@]}" cat /proc/sys/kernel/random/boot_id)"
  "${ssh_base[@]}" 'sync; reboot' >/dev/null 2>&1 || true
  sleep 2
  wait_ssh
  after="$("${ssh_base[@]}" cat /proc/sys/kernel/random/boot_id)"
  [[ "$before" != "$after" ]] || fail "VM reboot did not change boot ID"
}

prepare_baselines() {
  local versions version
  if [[ "$DIAGNOSTIC_CASE" = rescue-0.7.0 ]]; then
    versions=(0.7.0)
  else
    versions=("${BASELINE_VERSIONS[@]}")
  fi
  for version in "${versions[@]}"; do
    disk="$WORK/baseline-$version.qcow2"
    clone_disk "$WORK/vm-base.img" "$disk" raw
    start_vm "$disk" "prepare-$version"; wait_ssh; record_measurement "prepare-$version"
    guest install-baseline "$version" "$ORIGIN/baselines" 2>&1 |
      tee "$EVIDENCE_DIR/prepare-$version.guest-bootstrap.log"
    capture_guest_state "prepare-$version-complete"
    shutdown_vm
  done
}

run_old_worker_matrix() {
  for version in 0.7.9 0.7.10; do
    disk="$WORK/old-worker-$version.qcow2"
    clone_disk "$WORK/baseline-$version.qcow2" "$disk" qcow2
    start_vm "$disk" "old-worker-$version"; wait_ssh; record_measurement "old-worker-$version"
    before="$(guest protected-hash)"; usage_before="$(measure_stock)"
    transaction="$(guest old-worker "$ORIGIN" "$version" | tail -n 1)"
    usage_candidate="$(measure_stock)"
    guest verify-target 0.7.11 "$version" pending
    node "$ROOT_DIR/tests/vm/check-status-card.cjs" \
      "http://127.0.0.1:$HTTP_PORT/cgi-bin/luci/admin/status/overview" \
      > "$EVIDENCE_DIR/old-worker-$version-visible-card.json"
    normal_reboot; guest verify-target 0.7.11 "$version" post-reboot
    usage_committed="$(measure_stock)"
    [[ "$(guest protected-hash)" = "$before" ]] || fail "protected hash drift after old-worker reboot"
    guest rollback "$transaction" "$version"; usage_rolled_back="$(measure_stock)"; normal_reboot
    [[ "$(sed -n '1p' < <("${ssh_base[@]}" cat /usr/share/vpn-ui/version))" = "$version" ]] || fail "old-worker rollback did not persist"
    usage_after="$(measure_stock)"
    details="$(jq -cn --arg transaction "$transaction" --argjson before "$usage_before" \
      --argjson candidate "$usage_candidate" --argjson committed "$usage_committed" \
      --argjson rolled_back "$usage_rolled_back" --argjson after "$usage_after" \
      '{transaction:$transaction,disk_before:$before,disk_candidate:$candidate,
        disk_committed:$committed,disk_rolled_back:$rolled_back,disk_after_reboot:$after}')"
    record_result "$EVIDENCE_DIR/transition-results.jsonl" old-worker "$version->0.7.11->rollback" pass "$details"
    shutdown_vm; rm -f "$disk"
  done
}

run_rescue_matrix() {
  local versions version rescue_log
  if [[ "$DIAGNOSTIC_CASE" = rescue-0.7.0 ]]; then
    versions=(0.7.0)
  else
    versions=("${BASELINE_VERSIONS[@]}")
  fi
  for version in "${versions[@]}"; do
    disk="$WORK/rescue-$version.qcow2"
    clone_disk "$WORK/baseline-$version.qcow2" "$disk" qcow2
    start_vm "$disk" "rescue-$version"; wait_ssh; record_measurement "rescue-$version"
    before="$(guest protected-hash)"; usage_before="$(measure_stock)"
    rescue_log="$EVIDENCE_DIR/rescue-$version.guest-validator.log"
    guest rescue "$ORIGIN" "$version" 2>&1 | tee "$rescue_log"
    transaction="$(tail -n 1 "$rescue_log")"
    usage_candidate="$(measure_stock)"
    guest verify-target 0.7.11 "$version" pending
    capture_guest_state "rescue-$version-pending-reboot"
    normal_reboot
    guest verify-target 0.7.11 "$version" post-reboot
    usage_committed="$(measure_stock)"
    capture_guest_state "rescue-$version-committed"
    guest rollback "$transaction" "$version"
    usage_rolled_back="$(measure_stock)"
    capture_guest_state "rescue-$version-rolled-back"
    normal_reboot
    usage_final="$(measure_stock)"
    [[ "$("${ssh_base[@]}" sed -n '1p' /usr/share/vpn-ui/version)" = "$version" ]] || fail "rescue rollback did not persist: $version"
    [[ "$(guest protected-hash)" = "$before" ]] || fail "rescue protected hash drift: $version"
    details="$(jq -cn --arg transaction "$transaction" --argjson before "$usage_before" \
      --argjson candidate "$usage_candidate" --argjson committed "$usage_committed" \
      --argjson rolled_back "$usage_rolled_back" --argjson final "$usage_final" \
      '{transaction:$transaction,disk_before:$before,disk_candidate:$candidate,
        disk_committed:$committed,disk_rolled_back:$rolled_back,disk_after_rollback_reboot:$final}')"
    record_result "$EVIDENCE_DIR/transition-results.jsonl" rescue "$version->0.7.11->rollback" pass "$details"
    shutdown_vm; rm -f "$disk"
  done
}

run_refusals() {
  local values=(0.7.7 unknown 0.7 development 0.7.11RC1 0.8.0)
  for value in "${values[@]}"; do
    disk="$WORK/refuse-${value//[^A-Za-z0-9]/_}.qcow2"
    clone_disk "$WORK/baseline-0.7.10.qcow2" "$disk" qcow2
    start_vm "$disk" "refuse-${value//[^A-Za-z0-9]/_}"; wait_ssh; record_measurement "refuse-$value"
    "${ssh_base[@]}" "printf '%s\\n' '$value' > /usr/share/vpn-ui/version; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem curl -fsSL --proto '=https' '$ORIGIN/releases/download/vpn-panel-v0.7.11/rescue-router-ui.sh' -o /tmp/rescue; chmod 700 /tmp/rescue; ! SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem ROUTER_UI_RELEASE_BASE='$ORIGIN/releases/download/vpn-panel-v0.7.11' sh /tmp/rescue" >/dev/null
    record_result "$EVIDENCE_DIR/transition-results.jsonl" refusal "$value" pass '{}'
    shutdown_vm; rm -f "$disk"
  done
  disk="$WORK/refuse-target.qcow2"; clone_disk "$WORK/baseline-0.7.10.qcow2" "$disk" qcow2
  start_vm "$disk" refuse-other-target; wait_ssh; record_measurement refuse-other-target
  "${ssh_base[@]}" "SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem curl -fsSL --proto '=https' '$ORIGIN/releases/download/vpn-panel-v0.7.11/rescue-router-ui.sh' -o /tmp/rescue; chmod 700 /tmp/rescue; ! SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem ROUTER_UI_TARGET_VERSION=0.7.12 ROUTER_UI_RELEASE_BASE='$ORIGIN/releases/download/vpn-panel-v0.7.11' sh /tmp/rescue" >/dev/null
  record_result "$EVIDENCE_DIR/transition-results.jsonl" refusal direct-other-target pass '{}'
  shutdown_vm; rm -f "$disk"
}

run_clean_image() {
  disk="$WORK/clean-image.qcow2"; clone_disk "$WORK/candidate.img" "$disk" raw
  start_candidate_vm "$disk" clean-image; record_measurement clean-image
  fingerprint="$(sed -n '1p' "$ROOT_DIR/release/keys/router-ui-production.fingerprint")"
  guest verify-clean-image "$fingerprint"; normal_reboot; guest verify-clean-image "$fingerprint"
  record_result "$EVIDENCE_DIR/transition-results.jsonl" image clean-x86-boot pass '{}'
  shutdown_vm; rm -f "$disk"
}

run_protocol_v2() {
  disk="$WORK/protocol-v2.qcow2"; clone_disk "$WORK/candidate.img" "$disk" raw
  start_candidate_vm "$disk" protocol-v2; record_measurement protocol-v2
  discovery="$ORIGIN/releases/download/vpn-panel-v0.7.12"
  protected_before="$(guest protected-hash)"; usage_before="$(measure_stock)"
  "${ssh_base[@]}" "SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_RELEASE_ORIGIN='$ORIGIN' VPN_UI_DISCOVERY_BASE='$discovery' VPN_UI_SYNC_WORKER=1 /usr/sbin/vpn-ui-update check-start; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_RELEASE_ORIGIN='$ORIGIN' VPN_UI_SYNC_WORKER=1 /usr/sbin/vpn-ui-update apply-start" >/tmp/protocol-v2.log
  transaction="$("${ssh_base[@]}" sed -n '1p' /root/premier-router-updates/active-transaction)"
  guest verify-target 0.7.12 0.7.11 pending; usage_candidate_one="$(measure_stock)"
  normal_reboot; guest verify-target 0.7.12 0.7.11 post-reboot
  usage_committed_one="$(measure_stock)"
  guest rollback "$transaction" 0.7.11; usage_rollback_one="$(measure_stock)"; normal_reboot
  [[ "$(guest protected-hash)" = "$protected_before" ]] || fail "package rollback changed protected configuration"
  "${ssh_base[@]}" "mkdir -p /root/premier-router-updates/recovery-required-must-survive; printf '%s\\n' '{\"state\":\"recovery_required\"}' > /root/premier-router-updates/recovery-required-must-survive/state.json; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_RELEASE_ORIGIN='$ORIGIN' VPN_UI_DISCOVERY_BASE='$discovery' VPN_UI_SYNC_WORKER=1 /usr/sbin/vpn-ui-update check-start; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_RELEASE_ORIGIN='$ORIGIN' VPN_UI_SYNC_WORKER=1 /usr/sbin/vpn-ui-update apply-start" >/dev/null
  second_transaction="$("${ssh_base[@]}" sed -n '1p' /root/premier-router-updates/active-transaction)"
  normal_reboot; guest verify-target 0.7.12 0.7.11 post-reboot
  usage_committed_two="$(measure_stock)"
  "${ssh_base[@]}" test -f /root/premier-router-updates/recovery-required-must-survive/state.json || fail "cleanup pruned recovery-required evidence"
  tx_count="$("${ssh_base[@]}" "find /root/premier-router-updates -mindepth 1 -maxdepth 1 -type d | wc -l")"
  [[ "$tx_count" -le 6 ]] || fail "successful transactions accumulated without bound"
  guest rollback "$second_transaction" 0.7.11; normal_reboot
  [[ "$("${ssh_base[@]}" sed -n '1p' /usr/share/vpn-ui/version)" = 0.7.11 ]] || fail "retained exact rollback failed after cleanup"
  usage_final="$(measure_stock)"
  [[ "$(guest protected-hash)" = "$protected_before" ]] || fail "repeated package cycle changed protected configuration"
  record_result "$EVIDENCE_DIR/transition-results.jsonl" protocol-v2 \
    '0.7.11->0.7.12->0.7.11->0.7.12->0.7.11' pass \
    "$(jq -cn --argjson retained "$tx_count" --argjson before "$usage_before" \
      --argjson candidate_one "$usage_candidate_one" --argjson committed_one "$usage_committed_one" \
      --argjson rollback_one "$usage_rollback_one" --argjson committed_two "$usage_committed_two" \
      --argjson final "$usage_final" \
      '{retained_directories:$retained,disk_before:$before,disk_candidate_one:$candidate_one,
        disk_committed_one:$committed_one,disk_rollback_one:$rollback_one,
        disk_committed_two:$committed_two,disk_final:$final,protected_state_matches:true}')"
  shutdown_vm; rm -f "$disk"
}

run_storage_pressure() {
  local disk transaction required before after target state

  disk="$WORK/storage-normal.qcow2"; clone_disk "$WORK/baseline-0.7.10.qcow2" "$disk" qcow2
  start_vm "$disk" storage-normal; wait_ssh; record_measurement storage-normal
  before="$(measure_stock)"; transaction="$(guest rescue "$ORIGIN" 0.7.10 | tail -n 1)"
  candidate="$(measure_stock)"; normal_reboot; guest verify-target 0.7.11 0.7.10 post-reboot
  after="$(measure_stock)"
  record_result "$EVIDENCE_DIR/storage-results.jsonl" pressure normal-success pass \
    "$(jq -cn --argjson before "$before" --argjson candidate "$candidate" --argjson after "$after" \
      '{before:$before,candidate:$candidate,committed_after_reboot:$after}')"
  shutdown_vm; rm -f "$disk"

  disk="$WORK/storage-near.qcow2"; clone_disk "$WORK/baseline-0.7.10.qcow2" "$disk" qcow2
  start_vm "$disk" storage-near; wait_ssh; record_measurement storage-near
  "${ssh_base[@]}" "touch /etc/premier-router/test-mode; printf '%s\\n' before-mutation > /etc/premier-router/test-mode.fail-after; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem curl -fsSL --proto '=https' '$ORIGIN/releases/download/vpn-panel-v0.7.11/rescue-router-ui.sh' -o /tmp/r; chmod 700 /tmp/r; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_TEST_FAIL_MODE=return ROUTER_UI_RELEASE_BASE='$ORIGIN/releases/download/vpn-panel-v0.7.11' sh /tmp/r" >/dev/null 2>&1 || true
  transaction="$("${ssh_base[@]}" sed -n '1p' /root/premier-router-updates/active-transaction)"
  required="$("${ssh_base[@]}" "jsonfilter -i /root/premier-router-updates/$transaction/reservation.json -e '@.persistent_required_kib'")"
  "${ssh_base[@]}" /usr/sbin/vpn-ui-update recover >/dev/null
  target=$((required + 1024)); guest fill-to-free "$target"
  transaction="$(guest rescue "$ORIGIN" 0.7.10 | tail -n 1)"
  record_result "$EVIDENCE_DIR/storage-results.jsonl" pressure slightly-above-reservation pass \
    "$(jq -cn --argjson required "$required" --argjson target "$target" '{reservation_kib:$required,target_free_kib:$target}')"
  shutdown_vm; rm -f "$disk"

  disk="$WORK/storage-below.qcow2"; clone_disk "$WORK/baseline-0.7.10.qcow2" "$disk" qcow2
  start_vm "$disk" storage-below; wait_ssh; record_measurement storage-below
  before="$(guest protected-hash)"
  "${ssh_base[@]}" "touch /etc/premier-router/test-mode; printf '%s\\n' before-mutation > /etc/premier-router/test-mode.fail-after; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem curl -fsSL --proto '=https' '$ORIGIN/releases/download/vpn-panel-v0.7.11/rescue-router-ui.sh' -o /tmp/r; chmod 700 /tmp/r; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_TEST_FAIL_MODE=return ROUTER_UI_RELEASE_BASE='$ORIGIN/releases/download/vpn-panel-v0.7.11' sh /tmp/r" >/dev/null 2>&1 || true
  transaction="$("${ssh_base[@]}" sed -n '1p' /root/premier-router-updates/active-transaction)"
  required="$("${ssh_base[@]}" "jsonfilter -i /root/premier-router-updates/$transaction/reservation.json -e '@.persistent_required_kib'")"
  "${ssh_base[@]}" /usr/sbin/vpn-ui-update recover >/dev/null
  target=$((required - 1024)); (( target > 0 )) || fail "invalid below-reservation target"
  guest fill-to-free "$target"
  "${ssh_base[@]}" "SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem curl -fsSL --proto '=https' '$ORIGIN/releases/download/vpn-panel-v0.7.11/rescue-router-ui.sh' -o /tmp/r2; chmod 700 /tmp/r2; ! SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem ROUTER_UI_RELEASE_BASE='$ORIGIN/releases/download/vpn-panel-v0.7.11' sh /tmp/r2" >/dev/null
  [[ "$(guest protected-hash)" = "$before" ]] || fail "below-reservation refusal changed protected source"
  [[ "$("${ssh_base[@]}" sed -n '1p' /usr/share/vpn-ui/version)" = 0.7.10 ]] || fail "below-reservation refusal mutated source version"
  state="$("${ssh_base[@]}" '/usr/sbin/vpn-ui-update status | jsonfilter -e "@.job.stage"')"
  [[ "$state" = failed_before_mutation ]] || fail "low-space refusal was not pre-mutation"
  record_result "$EVIDENCE_DIR/storage-results.jsonl" pressure below-reservation-refusal pass \
    "$(jq -cn --argjson required "$required" --argjson target "$target" '{reservation_kib:$required,target_free_kib:$target,source_unchanged:true}')"
  shutdown_vm; rm -f "$disk"
}

run_concurrency() {
  disk="$WORK/concurrency.qcow2"; clone_disk "$WORK/candidate.img" "$disk" raw
  start_candidate_vm "$disk" concurrency; record_measurement concurrency
  details="$(guest concurrency-race "$ORIGIN" "$ORIGIN/releases/download/vpn-panel-v0.7.12")"
  record_result "$EVIDENCE_DIR/transition-results.jsonl" concurrency cli-rpc-cron pass "$details"
  shutdown_vm; rm -f "$disk"
}

run_fault_matrix() {
  for boundary in "${FAULT_BOUNDARIES[@]}"; do
    source_version=0.7.10
    target_version=0.7.11
    disk="$WORK/fault-${boundary}.qcow2"; clone_disk "$WORK/baseline-0.7.10.qcow2" "$disk" qcow2
    start_vm "$disk" "fault-$boundary"; wait_ssh; record_measurement "fault-$boundary"
    before="$(guest protected-hash)"
    case "$boundary" in
      rolling_back)
        transaction="$(guest rescue "$ORIGIN" 0.7.10 | tail -n 1)"
        "${ssh_base[@]}" "touch /etc/premier-router/test-mode; printf '%s\\n' '$boundary' > /etc/premier-router/test-mode.fail-after; sh /root/premier-router-updates/$transaction/rollback.sh" >/dev/null 2>&1 || true
        ;;
      rollback-after-*)
        shutdown_vm
        rm -f "$disk"; clone_disk "$WORK/candidate.img" "$disk" raw
        start_candidate_vm "$disk" "fault-$boundary"; record_measurement "fault-$boundary-ipk"
        source_version=0.7.11
        target_version=0.7.12
        before="$(guest protected-hash)"
        discovery="$ORIGIN/releases/download/vpn-panel-v0.7.12"
        "${ssh_base[@]}" "SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_RELEASE_ORIGIN='$ORIGIN' VPN_UI_DISCOVERY_BASE='$discovery' VPN_UI_SYNC_WORKER=1 /usr/sbin/vpn-ui-update check-start; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem VPN_UI_RELEASE_ORIGIN='$ORIGIN' VPN_UI_SYNC_WORKER=1 /usr/sbin/vpn-ui-update apply-start" >/dev/null
        transaction="$("${ssh_base[@]}" sed -n '1p' /root/premier-router-updates/active-transaction)"
        normal_reboot
        guest verify-target 0.7.12 0.7.11 post-reboot
        "${ssh_base[@]}" "touch /etc/premier-router/test-mode; printf '%s\\n' '$boundary' > /etc/premier-router/test-mode.fail-after; sh /root/premier-router-updates/$transaction/rollback.sh" >/dev/null 2>&1 || true
        ;;
      compatibility-cleanup|post-reboot-validation)
        shutdown_vm
        rm -f "$disk"; clone_disk "$WORK/baseline-0.7.9.qcow2" "$disk" qcow2
        start_vm "$disk" "fault-$boundary"; wait_ssh; record_measurement "fault-$boundary-079"
        source_version=0.7.9
        before="$(guest protected-hash)"
        guest rescue "$ORIGIN" 0.7.9 >/dev/null
        "${ssh_base[@]}" "touch /etc/premier-router/test-mode; printf '%s\\n' '$boundary' > /etc/premier-router/test-mode.fail-after; reboot" >/dev/null 2>&1 || true
        sleep 5
        ;;
      rollback_pending)
        "${ssh_base[@]}" "touch /etc/premier-router/test-mode /etc/premier-router/test-mode.force-candidate-failure; printf '%s\\n' '$boundary' > /etc/premier-router/test-mode.fail-after; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem ROUTER_UI_RELEASE_BASE='$ORIGIN/releases/download/vpn-panel-v0.7.11' sh -c 'curl -fsSL --proto \"=https\" \"$ORIGIN/releases/download/vpn-panel-v0.7.11/rescue-router-ui.sh\" -o /tmp/r; sh /tmp/r'" >/dev/null 2>&1 || true
        ;;
      *)
        "${ssh_base[@]}" "touch /etc/premier-router/test-mode; printf '%s\\n' '$boundary' > /etc/premier-router/test-mode.fail-after; SSL_CERT_FILE=/etc/ssl/certs/router-ui-vm-ca.pem ROUTER_UI_RELEASE_BASE='$ORIGIN/releases/download/vpn-panel-v0.7.11' sh -c 'curl -fsSL --proto \"=https\" \"$ORIGIN/releases/download/vpn-panel-v0.7.11/rescue-router-ui.sh\" -o /tmp/r; sh /tmp/r'" >/dev/null 2>&1 || true
        ;;
    esac
    "${ssh_base[@]}" test ! -e /etc/premier-router/test-mode.fail-after ||
      fail "fault boundary was not reached: $boundary"
    hard_poweroff_vm
    start_vm "$disk" "recover-$boundary"; wait_ssh; record_measurement "recover-$boundary"
    state=''
    for _ in {1..10}; do
      "${ssh_base[@]}" /etc/init.d/premier-router-update-recovery start >/dev/null 2>&1 || true
      state="$("${ssh_base[@]}" '/usr/sbin/vpn-ui-update status | jsonfilter -e "@.job.stage"' 2>/dev/null || true)"
      case "$state" in committed|rolled_back|failed_before_mutation) break ;; esac
      sleep 1
    done
    case "$state" in committed|rolled_back|failed_before_mutation) ;; *) fail "fault $boundary converged to unsafe state: $state" ;; esac
    [[ "$(guest protected-hash)" = "$before" ]] || fail "fault $boundary changed protected configuration"
    case "$state" in
      committed)
        guest verify-target "$target_version" "$source_version" post-reboot
        ;;
      rolled_back|failed_before_mutation)
        [[ "$("${ssh_base[@]}" sed -n '1p' /usr/share/vpn-ui/version)" = "$source_version" ]] ||
          fail "fault $boundary did not restore exact source version"
        ;;
    esac
    versions="$("${ssh_base[@]}" 'for p in premier-router-core luci-app-premier-router premier-router-setup; do opkg status "$p" | sed -n "s/^Version: //p" | sed -n 1p; done' | sed '/^$/d' | sort -u | wc -l)"
    [[ "$versions" -le 1 ]] || fail "fault $boundary left mixed project package versions"
    record_result "$EVIDENCE_DIR/fault-results.jsonl" power-loss "$boundary" pass \
      "$(jq -cn --arg final_state "$state" --arg source_version "$source_version" \
        '{final_state:$final_state,source_version:$source_version,injection_marker_consumed:true,protected_state_matches:true}')"
    shutdown_vm; rm -f "$disk"
  done
}

run_storage_profiles() {
  profile=rd23-ubootmod
  disk="$WORK/storage-$profile.qcow2"
  clone_disk "$WORK/vm-base-rd23-ubootmod.img" "$disk" raw
  start_vm "$disk" "storage-$profile"; wait_ssh
  record_measurement "storage-$profile" "$profile"
  guest install-baseline 0.7.10 "$ORIGIN/baselines"
  before="$(measure_ubootmod)"
  transaction="$(guest rescue "$ORIGIN" 0.7.10 | tail -n 1)"
  normal_reboot; guest verify-target 0.7.11 0.7.10 post-reboot
  committed="$(measure_ubootmod)"
  guest rollback "$transaction" 0.7.10; normal_reboot
  restored="$(measure_ubootmod)"
  record_result "$EVIDENCE_DIR/storage-results.jsonl" target-layout "$profile" pass \
    "$(jq -cn --argjson before "$before" --argjson committed "$committed" --argjson restored "$restored" \
      '{before:$before,committed:$committed,restored:$restored,transition_and_rollback:true}')"
  shutdown_vm; rm -f "$disk"
}

finalize_evidence() {
  local candidate_source harness_source
  candidate_source="$(jq -r .source_commit "$RELEASE_DIR/router-release-manifest.json")"
  harness_source="$HARNESS_SOURCE_SHA"
  [[ -n "$harness_source" ]] || harness_source="$candidate_source"
  jq -s '.' "$EVIDENCE_DIR/vm-measurements.jsonl" > "$EVIDENCE_DIR/vm-measurements.json"
  jq -s '.' "$EVIDENCE_DIR/transition-results.jsonl" > "$EVIDENCE_DIR/transition-results.json"
  jq -s '.' "$EVIDENCE_DIR/fault-results.jsonl" > "$EVIDENCE_DIR/fault-results.json"
  jq -s '.' "$EVIDENCE_DIR/storage-results.jsonl" > "$EVIDENCE_DIR/storage-results.json"
  jq -s '.' "$EVIDENCE_DIR/published-baselines.jsonl" > "$EVIDENCE_DIR/published-baselines.json"
  jq -n --argjson configured 256 \
    --argjson stock_backing "$STOCK_WRITABLE_KIB" \
    --argjson stock_ubifs_df "$STOCK_UBIFS_DF_KIB" \
    --argjson ubootmod_backing "$UBOOTMOD_WRITABLE_KIB" \
    --argjson ubootmod_ubifs_df "$UBOOTMOD_UBIFS_DF_KIB" \
    --arg source_commit "$candidate_source" \
    --arg harness_source_sha "$harness_source" \
    --arg diagnostic_case "$DIAGNOSTIC_CASE" \
    --arg diagnostic_run "$DIAGNOSTIC_RUN" \
    --arg key_fingerprint "$(sed -n '1p' "$ROOT_DIR/release/keys/router-ui-production.fingerprint")" \
    '{schema_version:1,candidate_source_sha:$source_commit,production_public_key_fingerprint:$key_fingerprint,
      harness_source_sha:$harness_source_sha,diagnostic_case:$diagnostic_case,
      diagnostic:($diagnostic_run == "1"),release_evidence:($diagnostic_run != "1"),
      configured_ram_mib:$configured,vm_execution_mode:"strictly-serial-exact-child-pid",
      storage_profiles:{"rd23-stock":{writable_backing_kib:$stock_backing,
        expected_ubifs_df_total_kib:$stock_ubifs_df},
        "rd23-ubootmod":{writable_backing_kib:$ubootmod_backing,
        expected_ubifs_df_total_kib:$ubootmod_ubifs_df}},
      storage_basis:"OpenWrt-v24.10.5-DTS-plus-exact-candidate-payload",
      physical_rd23_test:"pending-not-authorized"}' \
    > "$EVIDENCE_DIR/summary.json"
  (cd "$EVIDENCE_DIR" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print | sort | sed 's#^./##' |
    while read -r file; do sha256sum "$file"; done > SHA256SUMS)
}

setup_tls
prepare_server
load_storage_profiles
build_vm_base
if [[ "$DIAGNOSTIC_CASE" = rescue-0.7.0 ]]; then
  prepare_baselines
  run_rescue_matrix
else
  extract_candidate_image
  prepare_baselines
  run_old_worker_matrix
  run_rescue_matrix
  run_refusals
  run_clean_image
  run_protocol_v2
  run_concurrency
  run_fault_matrix
  run_storage_pressure
  run_storage_profiles
fi
finalize_evidence
printf 'Constrained Router UI VM gate passed (%s); evidence: %s\n' "$DIAGNOSTIC_CASE" "$EVIDENCE_DIR"
