Router UI 0.8.0

• Adds System > Reset for custom images. It asks for explicit confirmation,
  clears first-boot, VPN, AdGuardHome, Tailscale, Wi-Fi, SSH key, and root
  password state, then reboots back to the setup assistant.
• Polishes reset progress handling. If LuCI loses the XHR while the router is
  rebooting, the page keeps waiting for the setup assistant instead of showing
  a timeout warning.
• Adds the dark first-boot setup assistant for custom images, including account,
  Wi-Fi, VPN, AdGuardHome filter, Tailscale/Headscale, and review/apply steps.
• Replaces the setup assistant's text badge with a consistent built-in burger
  mark that does not depend on host emoji fonts.
• Adds the owner preparation panel for pre-handoff checks, owner tailnet login,
  customer access policy, backup validation, preview Wi-Fi radios, and sealing.
• Adds custom ImageBuilder support for x86/64 and Xiaomi AX3000T/RD23 packages,
  overlays, first-boot setup, router preparation, and generated image archives.
• Converts release staging to real OpenWrt IPK packages with opkg feed
  metadata, package-first running-router updates, legacy tar.gz migration, and
  images built from the same package artifacts.
• Adds preserved UCI router metadata for installation method, support level,
  registration/support state, local random router ID, owner-prep state, and
  sealing. Only a shortened router ID is exposed by helpers and UI.
• Shows a non-secret Router Scripts metadata label on Status Overview and the
  VPN page. IPKs intentionally do not own LuCI theme footer files; literal
  footer injection remains deferred until a package-safe hook is proven.
• Fixes first-boot root password handling so LuCI and SSH authenticate with the
  password entered in the setup wizard.
• Fixes first-boot VLESS enablement when direct routing rules are empty, and
  improves Apply setup progress feedback.
• Fixes the LuCI Status overview VPN include by installing both cache-safe and
  compatibility module names.
• Keeps the 0.7.5 Tailscale peer Ping behavior: immediate progress modal,
  reachable/unreachable result, latency, and direct or DERP route.
