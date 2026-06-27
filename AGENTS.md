# Repository Instructions

- For home-network, OpenWrt, VPN, DNS, DHCP, SSH alias, selfhost service, or
  device-topology work, read `NETWORK_INVENTORY.md` and `INCIDENT_LOG.md`
  before doing fresh discovery.
- Treat `NETWORK_INVENTORY.md` as the project source of truth for known
  devices, addresses, ports, services, and stale/conflicting network notes.
- Treat `INCIDENT_LOG.md` as the chronological source of truth for outages,
  symptoms, diagnoses, attempted fixes, verified solutions, and unresolved
  follow-up work.
- Whenever a network-related change is made from this repository, update
  `NETWORK_INVENTORY.md` in the same task with the new state or with any
  verified corrections.
- During incident response, add or update an `INCIDENT_LOG.md` entry in the
  same task. Record timestamps with timezone, distinguish verified facts from
  hypotheses, and include the exact validation that proved or disproved a fix.
- Reopen an existing incident when symptoms recur from the same cause. Create
  a new incident when the cause is different or not yet established, and
  cross-reference related incidents.
- Do not add secrets to the repository. Keep passwords, auth keys, private
  VLESS URLs, client UUIDs/subscription IDs, and private keys out of
  `NETWORK_INVENTORY.md`, `INCIDENT_LOG.md`, and committed files.
- Do not start, stop, or switch macOS VPN/Network Extension services on the
  admin Mac during remote recovery. Such a change can disconnect the active
  management path. Use ordinary SSH, Tailscale diagnostics, or remote relay
  hosts unless the user explicitly authorizes a Mac VPN change for that task.
