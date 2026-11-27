# Router UI 0.7.11 security remediation

The integration baseline is `eb9805f36add48a5f3b074740f4148a8888f6ab7`
(`codex/router-ui-rc25-session-recovery`, clean and equal to its remote).
That source retains RC24 identity `0.7.11-rc.24` / `0.7.11~rc24-1`.
It contains RC24 `2226495d3e1777750ad106a7211a868ba6f55a46` and the
LuCI session recovery change. The branch starts from canonical
`origin/main` at `18562f49bcac914acf3b07749f5b8863d8016e00` and
fast-forwards through the existing integration history. At baseline capture,
the published stable was `vpn-panel-v0.7.10` at `ce758c54ca37daa64bb1a738ae5dee20dcf8bddd`.
The original local working tree is a separate 0.8 WIP at `582024c2`
with two tracked edits and untracked working files. No WIP files entered
the integration candidate.

## Consolidated audit register

Daybreak references use the numbered RC24 report. Independent references use
the numbered report spanning the session-recovery branch, published 0.7.10
and local 0.8 development. Applicable rows describe the source change.
Release qualification is a separate result.

| Finding | Audit reference | Disposition and evidence |
| --- | --- | --- |
| Executable failover state in shared temporary space | Daybreak 1 | Applicable to 0.7.11. `vpn-ui` reads bounded numeric state and atomically replaces it in private runtime storage. The previous temporary file is ignored. |
| Bootstrap executes a separate validator | Daybreak 2 | Applicable to 0.7.11. `bootstrap-router-ui-ipk-install.sh` extracts the validator from the verified core IPK and compares the supplied sidecar. Standalone local install also verifies its signed manifest and copies authenticated inputs into private staging before executing them. |
| ImageBuilder inputs lack authenticated provenance | Daybreak 3, Independent 12 | Factory images and image-building tooling only. No ImageBuilder execution or firmware artifact is needed for the package-only workflow. Retain as a blocker for a future image build. Immutable pinning of third-party workflow actions is a separate supply-chain improvement. |
| First reachable client can claim Factory hardware | Daybreak 4, Independent 4 | Factory images only. The live setup IPK preinst writes the private package-install guard, and the CGI checks it before apply. Factory commissioning still needs per-device owner proof, a bounded authenticated claim and consistent retry state before image distribution. |
| Credentials in exported process arguments | Daybreak 5, Independent 8 in part | Operator tooling and package enrollment. The operator collector saves process names without arguments and masks Tailscale keys in text captures. Package enrollment uses a write-only RPC method, bounded stdin and a private key file. Factory request, root and AdGuard credential handling remain image work. |
| Shared privileged updater staging | Daybreak 6 | Applicable to 0.7.11. Discovery, apply and automatic updates allocate private temporary directories. Configuration recovery is written inside the persistent transaction. |
| Unbounded release downloads | Daybreak 7 | Applicable to 0.7.11. Metadata and signatures have fixed ceilings. Artifact limits come from signed sizes with a hard cap, available-space checks in native update, HTTPS-only curl redirects and a file-size limit for the transfer process. |
| Profile and subscription paths exceed delegated storage | Daybreak 8 | Applicable to 0.7.11. The backend validates bounded identifiers before path use, rejects symlinked input files and keeps supported existing filename characters. |
| Same-origin checksum authenticates an executable release | Independent 1 | Legacy stable only. The new path uses an independently sourced rescue script or digest and signed target metadata. The legacy automatic updater and mutable legacy geosite path are outside migration trust. |
| LuCI read scope grants the full management dispatcher | Independent 2 | Already resolved on the 0.7.11 baseline. The read ACL grants only the allowlisted helper. The finding remains in legacy and reviewed 0.8 snapshots. |
| Completed onboarding can be reopened without owner authorization | Independent 3 | Local 0.8 only. The 0.7.11 package does not dispatch the 0.8 reopen action, and uses the live-install guard. |
| Failed journal writes and replacement of unresolved transactions | Independent 5 | Applicable to 0.7.11. State transitions propagate persistence errors, update and recovery share the descriptor lock, recovery reads the journal under lock, and new operations cannot replace unresolved state. |
| Dependency changes escape exact rollback | Independent 6 | Applicable to 0.7.11. Native apply verifies prerequisites and uses opkg without dependency mutation. Signed-feed rescue provisions prerequisites before capturing the rollback state. Retained package bytes and validator are authenticated again during rollback. |
| Signing-key selection differs across discovery, apply and recovery | Independent 7 | Applicable to 0.7.11. Discovery and apply use the same key resolver and require an active signer. Recovery accepts active or previous keys with matching registered fingerprints. An old installed-package-set manifest authenticates its validator through the signed core IPK. |
| IPv4 interception lacks a fail-closed forwarding policy | Independent 9 | A kill switch, IPv6 interception and guest or additional VLAN coverage are inapplicable to the stated package contract. The package preserves the router's existing forwarding and DNS policy. When the IPv4 proxy is stopped, base forwarding applies. Verify existing IPv4 split routing, direct exceptions and DNS preservation in the VM. |
| AdGuard listener scope and DNS cutover in onboarding | Independent 10 | Image commissioning only. Live IPK installation does not run wizard AdGuard setup or replace dnsmasq configuration. A future image must qualify loopback DNS, restricted management binding and failed-cutover restoration. |
| Route diagnostics disclose unrelated connections and disable TLS verification | Independent 11 | Applicable to 0.7.11. The writer-only action correlates the exact local socket and requested domain, omits raw access logs and uses TLS verification. It performs no public-IP lookups as part of the domain probe. |
| Support export labels version equality as integrity | Independent 13 | Local 0.8 only. The support export and its verification flag are absent from the package release line. |

## Release scope

The package qualification target is vanilla OpenWrt 24.10.5 x86/64.
Install from the signed feed or authenticated bootstrap. Migrate existing
0.7.10 installations using the exact, independently authenticated rescue
entry point. Verify the initial script digest through the trusted delivery
channel before invoking it. A checksum beside an unauthenticated installer
is insufficient. Rescue pins and verifies OpenWrt dependency indexes.
Dependency installation is a prerequisite and is outside exact rollback.
The transactional preimage includes the three Premier packages and supported
application, router and service state. Manual rollback targets the latest
active transaction.

The release does not distribute custom firmware or qualify Factory,
RD23 stock or ubootmod installation, IPv6 interception, guest VLANs, VPN
kill-switch behavior or delegated customer-write roles. Full LuCI write
permission is administrative. OpenWrt firmware and feed security maintenance
remain independent of the Premier package lifecycle. Signed metadata expiry
and sequence persistence remain longer-term trust improvements. Existing
version ordering and independently authenticated initial installers are
the current contract.
