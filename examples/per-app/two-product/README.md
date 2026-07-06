# Two-product example (base + pro)

A repo shipping two products defines two self-contained files under
`Config/products/`. The three shell workflows are the **same trigger-only**
shells as the single-product examples in the parent folder — identity is
**discovered**, not passed in the shell.

- `Config/products/base.json` — the free product (S3 root, default profiles).
- `Config/products/pro.json` — the pro superset: `s3-subpath: "pro"`, its own
  `devid-profile-secret` / `store-profile-secret`, and its own appcast seed.

Each product versions and releases **independently**: tag `base-v2.13.0` to ship
base, `pro-v2.13.0` to ship pro (same or different days). On push to main, each
cuts a beta **only when its own file changed**.

Add the `PROV_PROF_DEVID_PRO_BASE64` / `PROV_PROF_STORE_PRO_BASE64` repo secrets
and pass them through in the beta/release shells' `secrets:` block.
