Router UI 0.7.3

• Fixes the helper dropping the required `0` or `1` argument when enabling or
  disabling weekly automatic updates.
• Fixes upgrades from 0.7.0 being rolled back with validation code 19 because
  the old updater incorrectly required every unchanged LuCI include filename
  to match the target release version.
• Keeps link-based update actions and explicit weekly-update opt-in/opt-out,
  avoiding LuCI native-control disabled state.
• Keeps automatic browser reload when LuCI restarts during installation.
• Retains mandatory verified backups, background jobs, automatic rollback,
  Tailscale peer ping, and VPN health in Status Overview.
