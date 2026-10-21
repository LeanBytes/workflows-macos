# Two-product example (base + pro)

A repo shipping two products defines two self-contained files under
`Config/products/`. The shell workflows are the **same trigger-only** shells as
the single-product examples in the parent folder — identity is **discovered**,
not passed in the shell.

- `Config/products/base.json` — the free product (S3 root).
- `Config/products/pro.json` — the pro superset: `"s3-subpath": "pro"` on its
  direct leg, and its own appcast seed.

Each product versions and releases **independently**: tag `base-v2.13.0` to ship
base, `pro-v2.13.0` to ship pro (same or different days). On push to main, each
builds **only when its own file (or its source-paths) changed**.

No extra secrets: both products are signed with the team's certificates, and
each app and extension gets the profile for its own bundle ID, downloaded from
App Store Connect at build time.
