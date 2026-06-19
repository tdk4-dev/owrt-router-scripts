Router UI 0.7.4

• Replaces native Tailscale peer Ping buttons with authenticated action links,
  preventing LuCI from leaving them inactive through native disabled state.
• Uses a fresh cache-safe Tailscale module path so already-open browser
  sessions cannot retain the broken control.
• Retains the 0.7.3 update validation and automatic-update argument fixes.
• Retains mandatory verified backups, background jobs, automatic rollback,
  browser reload after LuCI restarts, and VPN health in Status Overview.
