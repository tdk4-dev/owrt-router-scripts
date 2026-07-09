# Router Scripts Footer and Status Metadata

The package-safe v0.8 implementation exposes Router Scripts metadata through
`vpn-ui footer-info`, the LuCI Status Overview card, and the VPN Router UI.
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
Adding text to the literal LuCI page footer remains deferred until a supported
hook or package-diversion mechanism is proven on clean install, upgrade, and
removal. Do not copy theme footer templates from this project into an IPK.
