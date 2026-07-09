# Customer and Owner Policy Modes

The product must support different ownership modes without hidden access.

## Modes

### `owner-prepared-managed`

Used when the seller prepares a router before shipping and enrolls it into a
support tailnet or registry. The customer-facing UI may hide advanced controls,
but support access must be visible, documented, and revocable.

### `owner-prepared-standard`

Used for non-technical customers after owner prep, WAN/Wi-Fi/VPN checks,
backup, and seal. The customer UI should focus on VPN status, allowed
server/profile controls, updates, reset, and support-access state.

### `self-managed-image`

Used when a technical customer flashes a custom image and owns the router. No
owner support tailnet is enrolled by default. Full admin controls are visible
unless the customer chooses otherwise.

### `manual-ipk-install`

Used when project IPKs are installed on an existing OpenWrt router. The
installer must not create support access, remove existing admin access, remove
SSH keys, replace Tailscale identity, or overwrite local VPN/AdGuard/router
state unless explicitly requested.

### `dev-vm`

Used only for testing. Temporary credentials, firewall exceptions, and fake
state may be acceptable, but the mode must never be described as
production-safe.

## Root Access Limitation

Hiding LuCI pages from a root user is not a security boundary. A customer with
root SSH or full root LuCI can edit files and services directly. Real
separation requires a scoped LuCI/rpcd customer user without SSH/root
privileges, plus a separate owner/root path for support.

## Support Access Principles

- No hidden owner tunnel.
- No irreversible lock-in.
- No silent re-enrollment after customer disables support access.
- No long-lived preauth keys stored after enrollment.
- Support status should be visible in LuCI and preferably in footer/status UI.
- Provide one-click disable/revoke where practical.
- Provide an emergency local reset path.
