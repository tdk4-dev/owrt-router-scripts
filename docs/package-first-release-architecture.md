# Package-first release architecture

`scripts/build-openwrt-ipks.sh` is the only project package build. It produces
three deterministic, architecture-independent IPKs and
`router-ui-packages.txt`. A second build compares every byte but does not become
another artifact source.

The core IPK owns the backend, supervisor, update library, target validator,
recovery service, release public key, build provenance, and standalone
installer. The LuCI IPK owns the stable 0.7.10-equivalent menu, ACL, views, and
one canonical status include. The setup IPK owns only the existing baseline
first-boot files. `/etc/vpn-ui-update.conf` is the sole package conffile.

Staging extracts public helper assets from the canonical core IPK. The legacy
tar contains the three exact IPKs plus signed bridge metadata; it contains no
second copy of package-owned application files. Images install those same IPK
bytes through a local ImageBuilder feed and embed their package manifest,
hashes, source commit, epoch, target, profile, and OpenWrt version. Overlay paths
may be target-specific but must not overlap package ownership.

The staged release asset set is flat and unique. The compatibility bundle cannot include its
own hash inside the manifest it embeds; this cryptographic cycle is called out
explicitly in the manifest, while the legacy `.sha256` sidecar authenticates
transport after the manifest has authenticated every inner executable and IPK.

Local RC staging emits `candidate-channel.json`; it never rewrites a published
stable pointer. `Packages.sig` authenticates the ordinary opkg feed, while the
detached signature over the top-level `SHA256SUMS` authenticates the complete
flat candidate asset set. The installed-package manifest is separately signed
and references the same three canonical IPK hashes.
