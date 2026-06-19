Router UI 0.7.5

• Tailscale peer Ping now opens an immediate progress modal and replaces it
  with the reachable/unreachable result, latency, and direct or DERP route.
• Removes the old result area below the full peer table, which made a
  successful click appear to do nothing until the user scrolled to the end.
• Uses a fresh cache-safe Tailscale module path.
• Retains mandatory verified backups, background jobs, automatic rollback,
  browser reload after LuCI restarts, and VPN health in Status Overview.
