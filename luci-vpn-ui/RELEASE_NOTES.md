Router UI 0.7.2

• Replaces native Update-page buttons with direct authenticated action links,
  preventing LuCI from disabling them through stale or mismatched view
  permission state.
• Replaces the native weekly-update checkbox with an explicit enable/disable
  action using the same authenticated helper.
• Keeps automatic browser reload when LuCI restarts during installation.
• The standalone router-terminal installer validates that the installed
  release contains a callable Update page.
• Retains mandatory verified backups, background jobs, automatic rollback,
  Tailscale peer ping, and VPN health in Status Overview.
