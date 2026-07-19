# Router Scripts Footer and Status Metadata

The package-safe v0.8 implementation exposes Router Scripts metadata through
`vpn-ui footer-info`, the LuCI Status Overview card, the VPN Router UI, and a
package-owned branding strip at the bottom of each project LuCI panel (VPN,
Tailscale, Update, and Reset).
Project IPKs deliberately do not own or overwrite LuCI theme `footer.ut`
files, because those paths belong to the installed theme packages and would
create removal and upgrade conflicts.

Preferred format:

```text
Router Scripts vX.Y.Z (owner-prepared-standard, support: standard, registration: support-disabled)
```

Allowed install-mode labels:

- `owner-prepared-managed`
- `owner-prepared-standard`
- `self-managed-image`
- `manual-ipk-install`
- `legacy-migrated`
- `dev-vm`
- `unknown`

The compact runtime label is:

```text
Router Scripts vX.Y.Z (manual-ipk-install, support: self-managed, registration: local-only)
```

Spell `registered` correctly.

`registered` must mean an implemented and visible state, preferably "enrolled
into an owner/support registry or support tailnet". If that state is not
implemented, use `manual installation`, `self-managed`, or `unknown`.

Read the non-secret metadata with:

```sh
vpn-ui router-metadata
vpn-ui footer-info
```

The complete router ID is never returned. Only `router_id_short` is exposed.
The persistent source of truth is UCI package `/etc/config/premier_router`.
The package-safe v0.8 implementation decorates the existing LuCI footer at
runtime from project-owned shared JavaScript. It does not replace the footer or
own a theme path, so the original LuCI/OpenWrt attribution remains present.
Do not copy theme footer templates from this project into an IPK.
