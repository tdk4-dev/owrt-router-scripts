# Router Registry Design

A per-router registry is required for commercial preparation, validation, and
support, but the live registry must never be stored in this public repository.

## Router-local metadata

The router keeps only non-secret local metadata in UCI package
`/etc/config/premier_router`:

- `router_id`
- `install_method`
- `support_level`
- `registration_state`
- `version` (reported from the installed package version file)
- `direct_rules_channel`

The locally generated router ID is random and non-secret. Public UI and helper
output expose only its short form. Registration and support-access state are
descriptive metadata; they do not create a tunnel or remote account. Support
access defaults to disabled and must remain explicit, visible, and revocable.

## Private off-router registry

The off-router registry belongs in a private SQLite or PostgreSQL database,
not public GitHub. A practical initial deployment may use a private SQLite
database on the Mac Pro with encrypted backups. The production destination is
Premier Broker backed by PostgreSQL.

Suggested fields are:

- router ID
- model and hardware profile
- serial number or MAC address only when operationally necessary, treated as private
- batch and customer/order reference
- image version and OpenWrt version
- package version
- image SHA256 and individual IPK SHA256 values
- install method, support level, and registration state
- provisioning state and direct-rules channel
- last validation date and non-secret notes

The registry must not contain VLESS links, subscription URLs, authentication or
preauth keys, private keys, passwords, customer traffic logs, or other router
secrets. Secrets belong in a separate vault or broker secret store with access
control and audit logging.

## Deferred provisioning console

The factory flasher/provisioning console is deliberately outside v0.8. It
should be implemented and reviewed separately, for example on
`feat/factory-provisioning-console`, after the package-first release candidate
is validated. Production Headscale registration and live support-session
brokering are also deferred.
