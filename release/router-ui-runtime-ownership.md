# Router UI runtime ownership census

Candidate: `0.7.11-rc.14` (`0.7.11~rc14-1`). This is a pre-build source
contract, not release qualification. The machine-readable source of truth is
`release/router-ui-runtime-ownership.json`.

The install boundary is exactly three project IPKs:

| Package | Ownership |
| --- | --- |
| `premier-router-core` | backend, updater, validator, trust data, recovery and transparent-proxy service |
| `luci-app-premier-router` | LuCI menu, ACL and VPN, Tailscale, Update and overview assets |
| `premier-router-setup` | firstboot CGI, index, stylesheet, application and completion state |

Dependencies are installed only through those packages' declared dependency
closure. The core package owns the dependency declaration for Xray, Tailscale,
`nft`, TPROXY kernel support, full `ip`, conntrack, HTTPS/CA handling, signing,
JSON/ucode helpers, worker detachment and socket handoff.

| Visible surface | Controls | Required runtime sets |
| --- | ---: | --- |
| Update | 3 | LuCI, updater, trust, package manager, cron and worker runtime |
| Tailscale configuration and peer probe | 11 | LuCI, Tailscale init/UCI/binary and JSON runtime |
| Xray adoption | 4 | LuCI, Xray validation and managed state |
| Global VPN | 3 | Xray daemon, transparent proxy, nft/TPROXY/IP and managed state |
| Domain probe | 2 | HTTPS/DNS probe and managed state |
| Profiles | 8 | Xray render/validate, probes, transparent proxy and managed state |
| Subscriptions | 4 | HTTPS/CA/base64 and managed state |
| Automatic switching | 4 | probe, Xray, transparent proxy, cron and managed state |
| Direct rules | 6 | Xray render/validate, transparent proxy and managed state |
| Device VPN | 1 | transparent nft set, DHCP leases and conntrack |

Additional visible surfaces are the overview status include and the five-step
firstboot assistant. AdGuardHome remains optional: configuration controls must
be replaced by a non-actionable unavailable notice unless both its executable
and init service exist.

The clean-baseline guest census fails closed when any required package, path,
command, init service, UCI object, ubus object, TPROXY module, installer-created
manifest, or lifecycle-created configuration is absent, has no package owner,
has multiple owners, or differs from this contract. It also runs the
non-activating backend initialization, verifies all managed Xray state paths,
and compares each Xray/transparent init `running` result with the actual daemon
process or complete nftables and policy-routing kernel state.
Installer manifests and update-cache paths have separate, explicit lifecycle
owners; an IPK-only run requires them to be absent as a pair or present as a
complete pair, and the canonical installer/update qualification verifies their
later creation.
Baseline UCI files created at runtime retain explicit subsystem ownership
(`base-files:runtime`, `netifd:runtime`, and `dnsmasq-full:runtime`) even when
they are intentionally absent from every package file list.
