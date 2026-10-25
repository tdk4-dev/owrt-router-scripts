$1 == "tcp" || $1 == "tcp6" {
  local_address = $4
  if (local_address ~ /^fe80::/) {
    sub(/^fe80::.*:/, "fe80::link-local:", local_address)
  }
  printf "%s %s %s %s\n", $1, local_address, $5, $6
}
