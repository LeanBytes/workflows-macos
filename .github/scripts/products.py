#!/usr/bin/env python3
"""
products.py — the prepare "brain" for the per-product, independent workflows.

A repo describes each product it ships as a self-contained JSON file at
`Config/products/<id>.json` (build identity + a mandatory inline `changelog`).
This script discovers those files and computes what each orchestrator needs,
emitting `key=value` lines meant to be appended to `$GITHUB_OUTPUT`.

Subcommands:
  discover       Identity of every product (for the PR compile fan-out).
  plan-beta      The beta cutting set on a push to main — a product is cut ONLY
                 when its version is unreleased AND its own product file changed
                 since its last beta (changelog-driven). Each product is fully
                 independent: own version line, own `<id>-v<ver>-beta.N` counter.
  plan-release   Parse a pushed `<id>-v<version>` tag → the single target product,
                 validated against that product's changelog.versions[0].

Everything is pure stdlib. Git access is isolated so the logic unit-tests
offline: set `GIT_TAGS` (space-separated) and `CHANGED_PRODUCTS` (space-separated
ids treated as "changed since last beta") to stub git, and `BUILD_NUMBER` to
pin the timestamp.

Env inputs:
  PRODUCTS_DIR                 product dir (default "Config/products")
  DEF_BUILD_DIRECT/…           channel-toggle defaults a product inherits when it
  DEF_BUILD_STORE                omits the key (mirror the orchestrator inputs)
  DEF_DIST_STORE / DEF_DIST_APPCAST / DEF_HAS_FINDER / DEF_HAS_QL
  DEF_APPCAST_FILENAME / DEF_APPCAST_SEED
  TAG                          (plan-release) the pushed github.ref_name
  GIT_TAGS / CHANGED_PRODUCTS / BUILD_NUMBER   test-injection overrides
"""
import glob
import json
import os
import re
import subprocess
import sys


def die(msg):
    print(f"::error::{msg}", file=sys.stderr)
    sys.exit(1)


def note(msg):
    print(f"::notice::{msg}", file=sys.stderr)


def as_bool(v, default):
    if v is None or v == "":
        return default
    if isinstance(v, bool):
        return v
    return str(v).strip().lower() == "true"


def emit(key, value):
    print(f"{key}={value}")


def compact(x):
    return json.dumps(x, separators=(",", ":"))


def strip_internal(rec):
    return {k: v for k, v in rec.items() if not k.startswith("_")}


# ── git (isolated + injectable) ──────────────────────────────────────────────
def git_tags():
    inj = os.environ.get("GIT_TAGS")
    if inj is not None:
        return [t for t in inj.split() if t]
    out = subprocess.run(["git", "tag", "--list"], capture_output=True, text=True)
    return [t for t in out.stdout.splitlines() if t]


def product_changed_since(pid, last_tag, products_dir):
    """True if Config/products/<id>.json differs between last_tag and HEAD."""
    inj = os.environ.get("CHANGED_PRODUCTS")
    if inj is not None:
        return pid in inj.split()
    path = os.path.join(products_dir, f"{pid}.json")
    rc = subprocess.run(["git", "diff", "--quiet", last_tag, "HEAD", "--", path]).returncode
    return rc != 0


def build_number():
    inj = os.environ.get("BUILD_NUMBER")
    if inj:
        return inj
    return subprocess.run(["date", "-u", "+%y%m%d%H%M%S"], capture_output=True, text=True).stdout.strip()


# ── discovery + validation + defaulting ──────────────────────────────────────
def read_defaults():
    return {
        "build_direct": as_bool(os.environ.get("DEF_BUILD_DIRECT"), True),
        "build_store": as_bool(os.environ.get("DEF_BUILD_STORE"), False),
        "dist_store": as_bool(os.environ.get("DEF_DIST_STORE"), False),
        "dist_appcast": as_bool(os.environ.get("DEF_DIST_APPCAST"), False),
        "has_finder": as_bool(os.environ.get("DEF_HAS_FINDER"), False),
        "has_ql": as_bool(os.environ.get("DEF_HAS_QL"), False),
        "appcast_filename": os.environ.get("DEF_APPCAST_FILENAME") or "appcast.xml",
        "appcast_seed": os.environ.get("DEF_APPCAST_SEED") or "Config/appcast.xml",
    }


def resolve(products_dir, defaults):
    """Glob → validate → normalize. Returns records with identity + internal _version.

    Every product must carry a mandatory inline `changelog` with a
    versions[0].version; required build identity is validated per enabled channel.
    Fails loudly (exit 1) listing every problem.
    """
    files = sorted(glob.glob(os.path.join(products_dir, "*.json")))
    if not files:
        die(f"no product files in {products_dir}/ (expected Config/products/<id>.json)")

    errors, resolved, seen = [], [], set()
    for f in files:
        try:
            p = json.load(open(f, encoding="utf-8"))
        except Exception as e:  # noqa: BLE001 — surface any parse error verbatim
            errors.append(f"{f}: invalid JSON: {e}")
            continue
        if not isinstance(p, dict):
            errors.append(f"{f}: top-level value is not a JSON object")
            continue

        pid = str(p.get("id") or "").strip()
        if not pid:
            errors.append(f"{f}: missing required 'id'")
            pid = os.path.splitext(os.path.basename(f))[0]
        if pid in seen:
            errors.append(f"duplicate product id '{pid}'")
        seen.add(pid)

        platform = str(p.get("platform") or "macos").strip()
        if platform not in ("macos", "ios"):
            errors.append(f"product '{pid}': platform must be macos|ios (got '{platform}')")

        build_direct = as_bool(p.get("build-direct"), defaults["build_direct"])
        build_store = as_bool(p.get("build-app-store"), defaults["build_store"])
        scheme = str(p.get("scheme") or "").strip()
        product_name = str(p.get("product-name") or "").strip()
        bundle_id = str(p.get("bundle-id") or "").strip()
        scheme_store = str(p.get("scheme-store") or "").strip()

        if platform == "macos" and build_direct:
            if not scheme:
                errors.append(f"product '{pid}': 'scheme' is required for a Direct build")
            if not product_name:
                errors.append(f"product '{pid}': 'product-name' is required")
            if not bundle_id:
                errors.append(f"product '{pid}': 'bundle-id' is required")
        if build_store:
            if not scheme_store:
                errors.append(f"product '{pid}': 'scheme-store' is required for an App Store build")
            if not bundle_id:
                errors.append(f"product '{pid}': 'bundle-id' is required")

        # Mandatory inline changelog → the product's version source.
        version = ""
        cl = p.get("changelog")
        if not isinstance(cl, dict) or not (cl.get("versions") or []):
            errors.append(f"product '{pid}': mandatory 'changelog' with versions[0].version is missing")
        else:
            version = str((cl["versions"][0] or {}).get("version") or "").strip()
            if not version:
                errors.append(f"product '{pid}': changelog.versions[0].version is empty")

        resolved.append({
            "id": pid,
            "platform": platform,
            "build-direct": build_direct,
            "build-app-store": build_store,
            "distribute-app-store": as_bool(p.get("distribute-app-store"), defaults["dist_store"]),
            "distribute-appcast": as_bool(p.get("distribute-appcast"), defaults["dist_appcast"]),
            "has-finder": as_bool(p.get("has-finder"), defaults["has_finder"]),
            "has-quicklook": as_bool(p.get("has-quicklook"), defaults["has_ql"]),
            "scheme": scheme,
            "product-name": product_name,
            "bundle-id": bundle_id,
            "bundle-id-finder": str(p.get("bundle-id-finder") or ""),
            "bundle-id-quicklook": str(p.get("bundle-id-quicklook") or ""),
            "scheme-store": scheme_store,
            "bundle-id-store": str(p.get("bundle-id-store") or ""),
            "bundle-id-finder-store": str(p.get("bundle-id-finder-store") or ""),
            "bundle-id-quicklook-store": str(p.get("bundle-id-quicklook-store") or ""),
            "devid-profile-secret": str(p.get("devid-profile-secret") or ""),
            "store-profile-secret": str(p.get("store-profile-secret") or ""),
            "s3-subpath": str(p.get("s3-subpath") or "").strip("/"),
            "appcast-filename": str(p.get("appcast-filename") or defaults["appcast_filename"]),
            "appcast-seed-path": str(p.get("appcast-seed-path") or defaults["appcast_seed"]),
            "_version": version,
        })

    if errors:
        for e in errors:
            print(f"::error::products: {e}", file=sys.stderr)
        sys.exit(1)
    return resolved


def mac_subsets(records):
    """direct-build / app-store-build subset arrays — macOS only (iOS never
    reaches the mac callees; a future _build-ios.yml consumes the ios subset)."""
    direct = [r for r in records if r["build-direct"] and r["platform"] == "macos"]
    store = [r for r in records if r["build-app-store"] and r["platform"] == "macos"]
    return direct, store


# ── subcommands ──────────────────────────────────────────────────────────────
def cmd_discover(products_dir, defaults):
    records = [strip_internal(r) for r in resolve(products_dir, defaults)]
    direct, store = mac_subsets(records)
    emit("products", compact(records))
    emit("direct-products", compact(direct))
    emit("store-products", compact(store))
    emit("has-direct", "true" if direct else "false")
    emit("has-store", "true" if store else "false")
    emit("ids", " ".join(r["id"] for r in records))


def cmd_plan_beta(products_dir, defaults):
    records = resolve(products_dir, defaults)
    tags = set(git_tags())
    cutting = []
    for r in records:
        pid, v = r["id"], r["_version"]
        if f"{pid}-v{v}" in tags:                       # released → idle → skip
            note(f"{pid}: v{v} already released — idle (bump its changelog to cut betas)")
            continue
        betas = [t for t in tags if t.startswith(f"{pid}-v{v}-beta.")]
        if betas:                                       # re-beta ONLY if this product changed
            nums = [int(t.rsplit(".", 1)[1]) for t in betas if t.rsplit(".", 1)[1].isdigit()]
            last_n = max(nums) if nums else 0
            last_tag = f"{pid}-v{v}-beta.{last_n}"
            if not product_changed_since(pid, last_tag, products_dir):
                note(f"{pid}: unchanged since {last_tag} — skip")
                continue
            n = last_n + 1
        else:
            n = 1                                       # first beta of v — the bump IS the change
        rec = strip_internal(r)
        rec.update({
            "version": v,
            "marketing-direct": f"{v}-beta.{n}",
            "marketing-store": v,
            "artifact-label": f"v{v}-beta.{n}",
            "release-tag": f"{pid}-v{v}-beta.{n}",
        })
        cutting.append(rec)

    direct, store = mac_subsets(cutting)
    emit("beta-products", compact(cutting))
    emit("direct-products", compact(direct))
    emit("store-products", compact(store))
    emit("has-direct", "true" if direct else "false")
    emit("has-store", "true" if store else "false")
    emit("has-appcast", "true" if any(r["distribute-appcast"] for r in cutting) else "false")
    emit("has-any", "true" if cutting else "false")
    emit("build-number", build_number())
    # Test scheme/app-name default to the FIRST discovered product (always
    # present, even when the cutting set is empty) so the opt-in test gate has a
    # scheme regardless of what changed this push.
    emit("test-scheme", records[0].get("scheme") or records[0].get("scheme-store"))
    emit("test-app-name", records[0].get("product-name"))


def cmd_plan_release(products_dir, defaults):
    records = resolve(products_dir, defaults)
    tag = (os.environ.get("TAG") or "").strip()
    if not tag:
        die("TAG (github.ref_name) is required for plan-release")
    if re.search(r"-(?:beta|alpha)\.", tag):
        die(f"'{tag}' is a beta/alpha tag and must not reach the release flow — fix the shell tag filter")

    by_id = {r["id"]: r for r in records}
    hit = None
    for pid in sorted(by_id, key=len, reverse=True):     # longest id first (no ambiguity)
        prefix = f"{pid}-v"
        if tag.startswith(prefix):
            ver = tag[len(prefix):]
            if re.match(r"^\d+\.\d+(\.\d+)?$", ver):
                hit = (pid, ver)
                break
    if not hit:
        die(f"'{tag}' matches no <id>-vX.Y.Z for any discovered product — every product releases via its own '<id>-v*' tag (bare 'v*' is not used)")

    pid, ver = hit
    r = by_id[pid]
    if ver != r["_version"]:
        die(f"tag '{tag}' (={ver}) != Config/products/{pid}.json changelog.versions[0].version (={r['_version']}). Bump the changelog or fix the tag.")

    rec = strip_internal(r)
    direct = [rec] if (rec["build-direct"] and rec["platform"] == "macos") else []
    store = [rec] if (rec["build-app-store"] and rec["platform"] == "macos") else []
    emit("target-id", pid)
    emit("version", ver)
    emit("artifact-label", f"v{ver}")
    emit("build-number", build_number())
    emit("products", compact([rec]))
    emit("direct-products", compact(direct))
    emit("store-products", compact(store))
    emit("has-direct", "true" if direct else "false")
    emit("has-store", "true" if store else "false")
    emit("has-appcast", "true" if rec["distribute-appcast"] else "false")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    products_dir = os.environ.get("PRODUCTS_DIR") or "Config/products"
    defaults = read_defaults()
    if cmd == "discover":
        cmd_discover(products_dir, defaults)
    elif cmd == "plan-beta":
        cmd_plan_beta(products_dir, defaults)
    elif cmd == "plan-release":
        cmd_plan_release(products_dir, defaults)
    else:
        die(f"unknown subcommand '{cmd}' (expected discover | plan-beta | plan-release)")


if __name__ == "__main__":
    main()
