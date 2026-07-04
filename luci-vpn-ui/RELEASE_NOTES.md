Router UI 0.7.6

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
