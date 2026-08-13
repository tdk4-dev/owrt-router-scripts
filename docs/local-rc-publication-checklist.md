# Router UI 0.7.11 RC publication checklist

- [ ] Exact RC commit is reviewed and deliberately merged to `origin/main`.
- [ ] One controlled RD23 hardware canary passes installation, reboot,
  configuration preservation, UI/backend health and exact rollback.
- [ ] Two encrypted production-key backups exist; at least one is outside the
  Mac Pro; both checksums and a fingerprint recovery test are recorded.
- [ ] Fleet routers that trusted only the lost key have completed the
  authenticated public-key bootstrap.
- [ ] The immutable local RC archive hash and candidate validation report are
  independently reviewed.
- [ ] Explicit stable-publication authorization is recorded.
- [ ] Only after all preceding items: create the stable annotated tag from a
  commit contained in `origin/main`, publish reviewed assets and deliberately
  update the stable pointer.
