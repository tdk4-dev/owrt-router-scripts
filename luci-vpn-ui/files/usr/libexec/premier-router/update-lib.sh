#!/bin/sh

PR_UPDATE_PROTOCOL=2
PR_PROJECT_PACKAGES="premier-router-core luci-app-premier-router premier-router-setup"

pr_log() { printf '%s\n' "$*" >&2; }
pr_fail() { pr_log "ERROR: $*"; return 1; }
pr_need() { command -v "$1" >/dev/null 2>&1 || pr_fail "missing required command: $1"; }
pr_json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r//g' |
    awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}
pr_json_string() { printf '"%s"' "$(pr_json_escape "$1")"; }
pr_one_line() { printf '%s' "$1" | tr '\r\n' '  ' | tr -s ' ' | cut -c 1-500; }
pr_read_first() { sed -n '1p' "$1" 2>/dev/null | tr -d '\r\n'; }
pr_sha256() { sha256sum "$1" | awk '{ print $1 }'; }
pr_size() { wc -c < "$1" | tr -d ' '; }

pr_safe_asset_name() {
  local name="$1"
  [ -n "$name" ] || return 1
  case "$name" in /*|.|..|*\\*) return 1 ;; esac
  printf '%s' "$name" | grep -q '/' && return 1
  LC_ALL=C printf '%s' "$name" | grep -q '[[:cntrl:]]' && return 1
  return 0
}
pr_version_valid() {
  printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(RC[0-9]+|-rc\.[0-9]+|-test[0-9]+)?$'
}
pr_version_newer() {
  pr_version_valid "$1" && pr_version_valid "$2" || return 2
  awk -v left="$1" -v right="$2" 'BEGIN {
    lkind = rkind = 2
    lserial = rserial = 0
    if (match(left, /-test[0-9]+$/)) {
      lkind = 0
      lserial = substr(left, RSTART + 5) + 0
      left = substr(left, 1, RSTART - 1)
    } else if (match(left, /-rc\.[0-9]+$/)) {
      lkind = 1
      lserial = substr(left, RSTART + 4) + 0
      left = substr(left, 1, RSTART - 1)
    } else if (match(left, /RC[0-9]+$/)) {
      lkind = 1
      lserial = substr(left, RSTART + 2) + 0
      left = substr(left, 1, RSTART - 1)
    }
    if (match(right, /-test[0-9]+$/)) {
      rkind = 0
      rserial = substr(right, RSTART + 5) + 0
      right = substr(right, 1, RSTART - 1)
    } else if (match(right, /-rc\.[0-9]+$/)) {
      rkind = 1
      rserial = substr(right, RSTART + 4) + 0
      right = substr(right, 1, RSTART - 1)
    } else if (match(right, /RC[0-9]+$/)) {
      rkind = 1
      rserial = substr(right, RSTART + 2) + 0
      right = substr(right, 1, RSTART - 1)
    }
    ln = split(left, l, ".")
    rn = split(right, r, ".")
    n = ln > rn ? ln : rn
    for (i = 1; i <= n; i++) {
      lv = (i <= ln) ? l[i] + 0 : 0
      rv = (i <= rn) ? r[i] + 0 : 0
      if (lv > rv) exit 0
      if (lv < rv) exit 1
    }
    if (lkind > rkind) exit 0
    if (lkind < rkind) exit 1
    if (lserial > rserial) exit 0
    exit 1
  }'
}

pr_package_version_matches_app() {
  local app="$1" package="$2" base serial release expected
  release="${package##*-}"
  printf '%s' "$release" | grep -Eq '^[0-9]+$' || return 1
  case "$app" in
    *-rc.*)
      base="${app%-rc.*}"
      serial="${app##*-rc.}"
      expected="$base~rc$serial-$release"
      ;;
    *RC*)
      base="${app%RC*}"
      serial="${app##*RC}"
      expected="$base~rc$serial-$release"
      ;;
    *-test*)
      base="${app%-test*}"
      serial="${app##*-test}"
      expected="$base~test$serial-$release"
      ;;
    *) expected="$app-$release" ;;
  esac
  [ "$package" = "$expected" ]
}

pr_download() {
  local url="$1" dst="$2" attempt=1
  case "$url" in https://*) ;; *) return 1 ;; esac
  while [ "$attempt" -le 3 ]; do
    rm -f "$dst"
    if command -v curl >/dev/null 2>&1; then
      curl -4 -fsSL --proto '=https' --connect-timeout 10 --max-time 120 \
        "$url" -o "$dst" && return 0
    elif command -v wget >/dev/null 2>&1; then
      wget -T 120 -qO "$dst" "$url" && return 0
    elif command -v uclient-fetch >/dev/null 2>&1; then
      uclient-fetch -T 120 -q -O "$dst" "$url" && return 0
    else
      return 1
    fi
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
  return 1
}

pr_json_values() {
  local file="$1" jf_expr="$2" jq_expr="$3"
  local bin="${PR_JSONFILTER_BIN:-jsonfilter}"
  if command -v "$bin" >/dev/null 2>&1; then
    "$bin" -i "$file" -e "$jf_expr"
  elif [ "${PREMIER_ROUTER_HOST_TEST:-0}" = "1" ] &&
    command -v jq >/dev/null 2>&1; then
    jq -r "$jq_expr | select(. != null) |
      if type == \"boolean\" then tostring else . end" "$file"
  else
    pr_fail "jsonfilter is required"
  fi
}
pr_json_get() { pr_json_values "$1" "$2" "$3" | sed -n '1p'; }

pr_verify_signature() {
  local message="$1" signature="$2" public_key="$3"
  local usign_bin="${PR_USIGN_BIN:-usign}"
  [ -s "$message" ] && [ -s "$signature" ] && [ -s "$public_key" ] || return 1
  command -v "$usign_bin" >/dev/null 2>&1 || return 1
  "$usign_bin" -q -V -m "$message" -x "$signature" -p "$public_key"
}
pr_resolve_trusted_release_key() {
  local registry="$1" public_root="$2" requested_id="$3"
  local usign_bin="${PR_USIGN_BIN:-usign}"
  local index=0 key_id status fingerprint public_name public_key actual
  [ -s "$registry" ] && [ -d "$public_root" ] || return 1
  while [ "$index" -lt 64 ]; do
    key_id="$(pr_json_get "$registry" "@.keys[$index].key_id" ".keys[$index].key_id // empty")"
    [ -n "$key_id" ] || break
    if [ "$key_id" = "$requested_id" ]; then
      status="$(pr_json_get "$registry" "@.keys[$index].status" ".keys[$index].status // empty")"
      case "$status" in active|previous) ;; *) pr_fail "release key is not trusted: $key_id ($status)"; return 1 ;; esac
      fingerprint="$(pr_json_get "$registry" "@.keys[$index].fingerprint" ".keys[$index].fingerprint // empty")"
      public_name="$(pr_json_get "$registry" "@.keys[$index].public_key_path" ".keys[$index].public_key_path // empty")"
      printf '%s' "$fingerprint" | grep -Eq '^[0-9a-f]{16}$' || return 1
      printf '%s' "$public_name" | grep -Eq '^[A-Za-z0-9._-]+\.pub$' || return 1
      public_key="$public_root/$public_name"
      [ -s "$public_key" ] && command -v "$usign_bin" >/dev/null 2>&1 || return 1
      actual="$("$usign_bin" -F -p "$public_key")" || return 1
      [ "$actual" = "$fingerprint" ] || return 1
      PR_TRUSTED_KEY_ID="$key_id"
      PR_TRUSTED_KEY_STATUS="$status"
      PR_TRUSTED_KEY_FINGERPRINT="$fingerprint"
      PR_TRUSTED_PUBLIC_KEY="$public_key"
      export PR_TRUSTED_KEY_ID PR_TRUSTED_KEY_STATUS
      export PR_TRUSTED_KEY_FINGERPRINT PR_TRUSTED_PUBLIC_KEY
      return 0
    fi
    index=$((index + 1))
  done
  pr_fail "unknown release key ID: $requested_id"
}
pr_detect_openwrt_version() {
  local release_file="${PR_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
  sed -n "s/^DISTRIB_RELEASE=['\"]\([^'\"]*\)['\"]$/\1/p" "$release_file" | sed -n '1p'
}
pr_detect_target() {
  local release_file="${PR_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
  sed -n "s/^DISTRIB_TARGET=['\"]\([^'\"]*\)['\"]$/\1/p" "$release_file" | sed -n '1p'
}
pr_target_supported() {
  local manifest="$1" actual="$2" index=0 target
  while [ "$index" -lt 32 ]; do
    target="$(pr_json_get "$manifest" "@.supported_targets[$index]" ".supported_targets[$index] // empty")"
    [ -n "$target" ] || break
    [ "$target" = "$actual" ] && return 0
    index=$((index + 1))
  done
  return 1
}
pr_transition_supported() {
  local manifest="$1" source_version="$2" source_protocol="$3"
  local index=0 version protocol
  while [ "$index" -lt 64 ]; do
    version="$(pr_json_get "$manifest" "@.transitions[$index].source_version" ".transitions[$index].source_version // empty")"
    [ -n "$version" ] || break
    protocol="$(pr_json_get "$manifest" "@.transitions[$index].source_protocol" ".transitions[$index].source_protocol // empty")"
    if [ "$version" = "$source_version" ] && [ "$protocol" = "$source_protocol" ]; then
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

pr_manifest_validate() {
  local manifest="$1" expected_key_id="$2" source_version="$3" source_protocol="$4"
  local expected_fingerprint="${5:-}" key_fingerprint
  local schema protocol channel app package_version tag commit dirty key_id minimum
  local openwrt_min openwrt_max openwrt_version target
  local index=0 count=0 name filename version architecture size sha install_order
  local names="" filenames="" orders="" validator_file validator_size validator_sha validator_protocol
  local object object_file object_size object_sha object_protocol
  schema="$(pr_json_get "$manifest" '@.schema_version' '.schema_version // empty')"
  protocol="$(pr_json_get "$manifest" '@.update_protocol' '.update_protocol // empty')"
  channel="$(pr_json_get "$manifest" '@.channel' '.channel // empty')"
  app="$(pr_json_get "$manifest" '@.app_version' '.app_version // empty')"
  package_version="$(pr_json_get "$manifest" '@.package_version' '.package_version // empty')"
  tag="$(pr_json_get "$manifest" '@.release_tag' '.release_tag // empty')"
  commit="$(pr_json_get "$manifest" '@.source_commit' '.source_commit // empty')"
  dirty="$(pr_json_get "$manifest" '@.source_dirty' '.source_dirty')"
  key_id="$(pr_json_get "$manifest" '@.signing_key_id' '.signing_key_id // empty')"
  key_fingerprint="$(pr_json_get "$manifest" '@.signing_key_fingerprint' '.signing_key_fingerprint // empty')"
  minimum="$(pr_json_get "$manifest" '@.minimum_updater_protocol' '.minimum_updater_protocol // empty')"

  [ "$schema" = "2" ] || pr_fail "unsupported manifest schema: $schema" || return 1
  [ "$protocol" = "2" ] || pr_fail "unsupported update protocol: $protocol" || return 1
  case "$channel" in stable|candidate) ;; *)
    pr_fail "unsupported release channel: $channel" || return 1
  esac
  case "$channel:$app" in stable:*-test*|stable:*-rc.*|stable:*RC*)
    pr_fail "prerelease versions are forbidden on the stable channel" || return 1
  esac
  pr_version_valid "$app" || pr_fail "malformed app version: $app" || return 1
  pr_package_version_matches_app "$app" "$package_version" ||
    pr_fail "package version mismatch" || return 1
  [ "$tag" = "vpn-panel-v$app" ] || pr_fail "release tag mismatch" || return 1
  printf '%s' "$commit" | grep -Eq '^[0-9a-f]{40}$' ||
    pr_fail "invalid source commit" || return 1
  [ "$dirty" = "false" ] || pr_fail "dirty release provenance is forbidden" || return 1
  [ "$key_id" = "$expected_key_id" ] || pr_fail "signing key ID mismatch" || return 1
  [ -z "$expected_fingerprint" ] || [ "$key_fingerprint" = "$expected_fingerprint" ] ||
    pr_fail "signing key fingerprint mismatch" || return 1
  printf '%s' "$minimum" | grep -Eq '^[0-9]+$' ||
    pr_fail "invalid minimum updater protocol" || return 1
  [ "$minimum" -le "$PR_UPDATE_PROTOCOL" ] ||
    pr_fail "updater protocol $PR_UPDATE_PROTOCOL is too old" || return 1
  pr_transition_supported "$manifest" "$source_version" "$source_protocol" ||
    pr_fail "unsupported source transition: $source_version protocol $source_protocol" || return 1

  openwrt_min="$(pr_json_get "$manifest" '@.supported_openwrt.min' '.supported_openwrt.min // empty')"
  openwrt_max="$(pr_json_get "$manifest" '@.supported_openwrt.max' '.supported_openwrt.max // empty')"
  openwrt_version="$(pr_detect_openwrt_version)"
  pr_version_valid "$openwrt_min" && pr_version_valid "$openwrt_max" &&
    pr_version_valid "$openwrt_version" ||
    pr_fail "invalid OpenWrt version constraint" || return 1
  if pr_version_newer "$openwrt_min" "$openwrt_version"; then
    pr_fail "OpenWrt $openwrt_version is too old" || return 1
  fi
  if pr_version_newer "$openwrt_version" "$openwrt_max"; then
    pr_fail "OpenWrt $openwrt_version is too new" || return 1
  fi
  target="$(pr_detect_target)"
  [ -n "$target" ] && pr_target_supported "$manifest" "$target" ||
    pr_fail "unsupported OpenWrt target: ${target:-unknown}" || return 1

  while [ "$index" -lt 32 ]; do
    name="$(pr_json_get "$manifest" "@.packages[$index].name" ".packages[$index].name // empty")"
    [ -n "$name" ] || break
    filename="$(pr_json_get "$manifest" "@.packages[$index].filename" ".packages[$index].filename // empty")"
    version="$(pr_json_get "$manifest" "@.packages[$index].version" ".packages[$index].version // empty")"
    architecture="$(pr_json_get "$manifest" "@.packages[$index].architecture" ".packages[$index].architecture // empty")"
    size="$(pr_json_get "$manifest" "@.packages[$index].size" ".packages[$index].size // empty")"
    sha="$(pr_json_get "$manifest" "@.packages[$index].sha256" ".packages[$index].sha256 // empty")"
    install_order="$(pr_json_get "$manifest" "@.packages[$index].install_order" ".packages[$index].install_order // empty")"
    case " $PR_PROJECT_PACKAGES " in *" $name "*) ;; *)
      pr_fail "unexpected project package: $name" || return 1 ;;
    esac
    case " $names " in *" $name "*) pr_fail "duplicate package name: $name" || return 1 ;; esac
    case " $filenames " in *" $filename "*) pr_fail "duplicate package filename: $filename" || return 1 ;; esac
    case " $orders " in *" $install_order "*) pr_fail "duplicate package install order: $install_order" || return 1 ;; esac
    pr_safe_asset_name "$filename" || pr_fail "unsafe package filename: $filename" || return 1
    [ "$filename" = "${name}_${package_version}_all.ipk" ] ||
      pr_fail "package filename metadata mismatch: $filename" || return 1
    [ "$version" = "$package_version" ] || pr_fail "package version mismatch: $name" || return 1
    [ "$architecture" = "all" ] || pr_fail "unsupported package architecture" || return 1
    printf '%s' "$size" | grep -Eq '^[1-9][0-9]*$' || pr_fail "invalid package size" || return 1
    printf '%s' "$sha" | grep -Eq '^[0-9a-f]{64}$' || pr_fail "invalid package hash" || return 1
    printf '%s' "$install_order" | grep -Eq '^[1-9][0-9]*$' || pr_fail "invalid install order" || return 1
    names="$names $name"
    filenames="$filenames $filename"
    orders="$orders $install_order"
    count=$((count + 1))
    index=$((index + 1))
  done
  [ "$count" = "3" ] || pr_fail "manifest must contain exactly three project packages" || return 1
  for name in $PR_PROJECT_PACKAGES; do
    case " $names " in *" $name "*) ;; *) pr_fail "missing package: $name" || return 1 ;; esac
  done

  validator_file="$(pr_json_get "$manifest" '@.candidate_validator.filename' '.candidate_validator.filename // empty')"
  validator_size="$(pr_json_get "$manifest" '@.candidate_validator.size' '.candidate_validator.size // empty')"
  validator_sha="$(pr_json_get "$manifest" '@.candidate_validator.sha256' '.candidate_validator.sha256 // empty')"
  validator_protocol="$(pr_json_get "$manifest" '@.candidate_validator.protocol' '.candidate_validator.protocol // empty')"
  pr_safe_asset_name "$validator_file" || pr_fail "unsafe validator filename" || return 1
  printf '%s' "$validator_size" | grep -Eq '^[1-9][0-9]*$' || pr_fail "invalid validator size" || return 1
  printf '%s' "$validator_sha" | grep -Eq '^[0-9a-f]{64}$' || pr_fail "invalid validator hash" || return 1
  [ "$validator_protocol" = "1" ] || pr_fail "unsupported validator protocol" || return 1
  filenames="$filenames $validator_file"

  for object in transaction_supervisor update_library compatibility.status_0_7_9 standalone_installer initial_ipk_bootstrap rescue; do
    object_file="$(pr_json_get "$manifest" "@.$object.filename" ".$object.filename // empty")"
    object_size="$(pr_json_get "$manifest" "@.$object.size" ".$object.size // empty")"
    object_sha="$(pr_json_get "$manifest" "@.$object.sha256" ".$object.sha256 // empty")"
    object_protocol="$(pr_json_get "$manifest" "@.$object.protocol" ".$object.protocol // empty")"
    pr_safe_asset_name "$object_file" || pr_fail "unsafe asset filename: $object" || return 1
    case " $filenames " in *" $object_file "*) pr_fail "duplicate release filename: $object_file" || return 1 ;; esac
    printf '%s' "$object_size" | grep -Eq '^[1-9][0-9]*$' ||
      pr_fail "invalid asset size: $object" || return 1
    printf '%s' "$object_sha" | grep -Eq '^[0-9a-f]{64}$' ||
      pr_fail "invalid asset hash: $object" || return 1
    case "$object" in
      standalone_installer|transaction_supervisor) [ "$object_protocol" = 2 ] ;;
      update_library|compatibility.status_0_7_9|initial_ipk_bootstrap|rescue) [ "$object_protocol" = 1 ] ;;
    esac || pr_fail "unsupported asset protocol: $object" || return 1
    filenames="$filenames $object_file"
  done
}

pr_ipk_control() {
  tar -xzOf "$1" ./control.tar.gz 2>/dev/null | tar -xzOf - ./control 2>/dev/null
}
pr_ipk_field() { pr_ipk_control "$1" | sed -n "s/^$2: //p" | sed -n '1p'; }
pr_validate_ipk() {
  local ipk="$1" name="$2" version="$3" architecture="$4" size="$5" sha="$6"
  [ "$(pr_size "$ipk")" = "$size" ] || pr_fail "size mismatch: $(basename "$ipk")" || return 1
  [ "$(pr_sha256 "$ipk")" = "$sha" ] || pr_fail "hash mismatch: $(basename "$ipk")" || return 1
  [ "$(pr_ipk_field "$ipk" Package)" = "$name" ] || pr_fail "IPK package mismatch" || return 1
  [ "$(pr_ipk_field "$ipk" Version)" = "$version" ] || pr_fail "IPK version mismatch" || return 1
  [ "$(pr_ipk_field "$ipk" Architecture)" = "$architecture" ] ||
    pr_fail "IPK architecture mismatch" || return 1
}
