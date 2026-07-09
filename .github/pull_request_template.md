## Summary

-

## Risk Level

- [ ] low: docs, comments, formatting, static tests only
- [ ] medium: LuCI UI behavior, parsing, non-critical docs/tests
- [ ] high: installer, updater, package, image, first-boot, reset, firewall, Xray, Tailscale, AdGuard, backup/rollback, migration, authentication
- [ ] release-critical: can brick, lock out, disconnect, erase, leak, or break a remote customer router

## Router State Impact

- [ ] no router state changed
- [ ] changes runtime config
- [ ] changes package install/update behavior
- [ ] changes image/default first-boot behavior
- [ ] changes firewall/routing/DNS/VPN/Xray/Tailscale/AdGuard/auth/reset behavior

Describe changed state:

-

## Sensitive Areas Touched

- [ ] installer/update
- [ ] OpenWrt package/IPK/feed
- [ ] custom image/ImageBuilder
- [ ] Xray/VLESS/routing/firewall
- [ ] Tailscale/Headscale
- [ ] first-boot/setup wizard
- [ ] reset/factory setup
- [ ] authentication/RBAC/SSH
- [ ] backup/rollback/migration
- [ ] none of the above

## Verification

Tests run:

```text

```

Tests not run and why:

```text

```

VM evidence:

```text

```

Hardware evidence:

```text

```

## Release Impact

- [ ] no release impact
- [ ] release candidate/staging only
- [ ] requires version bump
- [ ] requires IPK rebuild
- [ ] requires custom image rebuild
- [ ] requires update-panel compatibility test
- [ ] release publication requested by user using `PUBLISH RELEASE <version>`

## Rollback / Recovery

-

## Secret-Safety Check

- [ ] I checked that no secrets, private VLESS URLs, client UUIDs, subscription IDs, auth keys, private keys, passwords, unredacted QR codes, packet captures, or customer data are committed.
