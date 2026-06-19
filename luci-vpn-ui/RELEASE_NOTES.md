Router UI 0.7.0

• Update checks and installations now run as background jobs, so LuCI no
  longer reports a false XHR timeout while GitHub downloads or services
  restart.
• Every installation creates and validates a full OpenWrt sysupgrade backup
  before changing files. Installer failures and failed post-install checks
  automatically restore the panel snapshot.
• The Update page reports each backup, stage, and failure clearly and can
  optionally install stable releases once a week using the same safeguards.
• Tailscale peer Ping buttons remain available to authenticated read-only
  views; the backend still validates that the target is a visible tailnet
  peer.
• Status > Overview now includes VPN service health, selected profile,
  endpoint and server IP, direct-domain rule count, and selected-server ping.
• A standalone router-terminal installer can install the latest stable
  release or a pinned release such as 0.6.0 with checksum verification,
  mandatory backup, validation, and rollback.
