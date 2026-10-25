# OpenWrt First-Boot Wizard Test Environment

This is a local preview for the x86 image first-boot assistant. It has no
router side effects. The server mocks the router API and lets the UI
exercise validation, AdGuard filter selection, VPN setup, and Tailscale setup.

Run it from the repo root:

```sh
node firstboot-wizard/server.mjs
```

Then open:

```text
http://127.0.0.1:8787
```

The mock uses the live router defaults captured from `openwrt-fin0`:

- LAN address shown to the user: `10.77.0.1`
- Installed AdGuard filters selected by default:
  - AdGuard DNS filter
  - AdAway Default Blocklist
  - AdGuard DNS Popup Hosts filter
  - HaGeZi's Ultimate Blocklist

The production image integration:

- Serve the assistant as the default `uhttpd` page while setup is incomplete.
- POST the final payload to a BusyBox-compatible helper.
- Hash and set the root password without logging it.
- Render or disable Xray based on the VPN choice.
- Write AdGuardHome config using selected hostlist entries.
- Run `tailscale up` only when the user enables Tailscale and supplies a key.
- Mark setup complete and redirect future visits to LuCI.
