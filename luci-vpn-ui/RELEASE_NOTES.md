Router UI 0.7.9

• Uses stable LuCI asset names (`vpn.js`, `tailscale.js`, `update.js`,
  `35_vpn.js`) instead of embedding Router UI versions in filenames.
• Removes stale versioned LuCI assets during install so future releases do not
  require filename churn or workflow edits.
• Adds release checks that fail if current LuCI asset filenames become
  versioned again.
• Stops RAM-backed router log growth by capping `/tmp/xray-access.log` and
  `/tmp/xray-error.log` during install init and the existing one-minute
  Router UI auto-tick.
• Disables AdGuardHome file-backed query logging on OpenWrt, where
  `/var/lib/adguardhome` lives under tmpfs, and removes the accumulated
  querylog file during update.
• New x86 first-boot/setup installs use a 24-hour in-memory AdGuard query log
  without writing `querylog.json` into RAM.
• Fixes imported subscription profile switching on Xray 25 by omitting empty
  direct-domain routing rules from generated Xray configs.
• First-boot setup accepts HTTPS subscription links as well as direct
  `vless://` links when VPN is enabled.
• Fixes imported VLESS Reality profiles that do not specify `flow=` by
  omitting the Xray `flow` field instead of forcing Vision mode.
• Existing 0.7.5-imported profiles are corrected when loaded if their original
  VLESS URL did not contain `flow=`.
• Routes TCP port 8080 directly in generated Xray configs so Speedtest latency
  probes do not fail through VPS paths that block outbound 8080.
• Selected-profile health now checks the active SOCKS/Xray path; saved profiles
  show endpoint TCP reachability as a muted `tcp ...` probe instead of a fake
  VPN latency.
• LuCI VPN notifications are collapsed to one visible banner.
• Retains mandatory verified backups, background jobs, automatic rollback,
  browser reload after LuCI restarts, and VPN health in Status Overview.
