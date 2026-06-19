Router UI 0.6.0

• VPN Panel is focused only on VPN profiles, subscriptions, automatic
  switching, direct-routing rules, and per-device VPN controls.
• Tailscale has its own expanded panel with visible tailnet devices, online
  state, route details, exit-node indicators, last-seen timestamps, and
  authenticated Tailscale ping actions.
• Update is now a top-level LuCI menu with installed version, latest released
  version, release date, update status, and full release notes.
• Router release downloads remain SHA-256 verified and transactional, with a
  rollback snapshot created before installation.
• All LuCI view paths are versioned to prevent stale browser modules after an
  update.
