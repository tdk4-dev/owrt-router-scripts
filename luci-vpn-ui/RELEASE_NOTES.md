Router UI 0.7.1

• Fixes Download and install being incorrectly disabled for an authenticated
  administrator.
• Fixes the weekly automatic-update checkbox being disabled by the same LuCI
  view-permission mismatch.
• When LuCI restarts during installation, the open Update tab now reloads
  automatically and resumes from the durable update-job state instead of
  ending with an XHR error.
• The standalone router-terminal installer now validates that the installed
  release includes a callable Update page.
• Retains the 0.7.0 background jobs, mandatory verified backups, automatic
  rollback, Tailscale peer ping, and VPN health Overview section.
