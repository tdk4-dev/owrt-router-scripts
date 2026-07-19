# OpenWrt First-Boot Wizard Test Environment

This is a local preview for the x86 image first-boot assistant. It has no
router side effects. The server mocks the router API and lets the UI
exercise router naming, Wi-Fi validation, optional AdGuard installation and
filter selection, VPN setup, and Tailscale setup.

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
- AdGuard storage preview and explicit optional-install flow.
- AdGuard filters selected by default after installation:
  - AdGuard DNS filter
  - AdAway Default Blocklist
  - AdGuard DNS Popup Hosts filter
  - HaGeZi's Ultimate Blocklist

The production image integration:

- Serve the assistant as the default `uhttpd` page while setup is incomplete.
- POST the final payload to a BusyBox-compatible helper.
- Hash and set the root password without logging it.
- Apply the validated router hostname to OpenWrt and Tailscale.
- Configure detected Wi-Fi radios with validated SSID and security settings.
- Render or disable Xray based on the VPN choice.
- Offer AdGuardHome installation only when projected persistent storage remains
  at or below 95%, then write its config using selected hostlist entries.
- Run `tailscale up` only when the user enables Tailscale and supplies a key,
  then verify that the client reaches a registered `Running` state.
- Mark setup complete and redirect future visits to LuCI.
