# Footer Branding

Append Router Scripts metadata to the existing LuCI/OpenWrt footer without
removing the upstream LuCI/OpenWrt attribution.

Preferred format:

```text
Powered by LuCI openwrt-24.10 branch (...) / OpenWrt 24.10.5 (...) / Router Scripts vX.Y.Z (owner-prepared-standard)
```

Allowed install-mode labels:

- `owner-prepared-managed`
- `owner-prepared-standard`
- `self-managed-image`
- `manual-ipk-install`
- `dev-vm`
- `unknown`

Short labels may be used only when the full mode is too long:

```text
Router Scripts vX.Y.Z (registered)
Router Scripts vX.Y.Z (manual installation)
```

Spell `registered` correctly.

`registered` must mean an implemented and visible state, preferably "enrolled
into an owner/support registry or support tailnet". If that state is not
implemented, use `manual installation`, `self-managed`, or `unknown`.
