#!/usr/bin/env python3
"""
products.py — the prepare "brain" for every Apple platform.

A repo describes each product it ships as a self-contained JSON file at
`Config/products/<id>.json`: build identity, a `platforms` block naming where
each platform ships, and a mandatory inline `changelog`. This script discovers
those files, expands each product into one LEG per platform and channel, and
computes what each orchestrator needs, emitting `key=value` lines meant to be
appended to `$GITHUB_OUTPUT`.

    {
      "product-name": "FlowMoose",
      "scheme": "FlowMoose",
      "bundle-id": "io.leanbytes.flowmoose",
      "platforms": {
        "macos": {
          "direct":    { "appcast": true },
          "app-store": { "scheme": "FlowMoose Store",
                         "bundle-id": "io.leanbytes.flowmoose.mas",
                         "configuration": "Release Store" }
        }
      },
      "source-paths": ["FlowMoose/**", "Project.swift"],
      "changelog": { "versions": [ { "version": "2.14.0", "items": [] } ] }
    }

Channels per platform: ios takes app-store and ad-hoc; macos takes app-store
and direct. A leg's object holds only what differs from the product (scheme,
bundle-id, configuration, product-name), plus `distribute` on an app-store or
ad-hoc leg and the S3/Sparkle settings on a direct leg. An empty object means
the product's defaults.

Subcommands:
  discover       Every leg of every product (the PR compile fan-out).
  plan           What builds on a push to main. A product builds only when its
                 version is unreleased (no bare `<prefix><version>` tag) AND it
                 changed:
                   * with a Direct leg, since its last `-beta.N` tag. The beta
                     counter is what Direct users see, so it stays.
                   * without one, since SINCE: the commit the last successful
                     run of the workflow built from. App Store and Ad Hoc builds
                     get no tags (a tag marks a build that reaches customers on
                     its own, and a TestFlight upload doesn't), and the last good
                     run takes the tag's place: a failed run, a [skip ci] push or
                     a queued run GitHub dropped for a newer one is picked up by
                     the next run instead of being lost.
  plan-release   A pushed `<prefix><version>` tag -> that product's Direct leg.
                 App Store legs build nothing: the build tested in TestFlight is
                 the one you submit.
  plan-alpha     A manual alpha of one product, from any branch -> every leg.
                 App Store legs go to TestFlight as internal-only builds; a
                 product with a Direct leg is tagged `-alpha.N`.

Pure stdlib. Git access is isolated so the logic unit-tests offline: set
`GIT_TAGS` (space-separated) and `ASSUME_CHANGED` (space-separated ids treated
as changed, or `*` for every product) to stub git, and `BUILD_NUMBER` to pin the
timestamp.

Env inputs:
  PRODUCTS_DIR                 product dir (default "Config/products")
  SINCE                        (plan) the commit to compare a product without a
                               Direct leg against: the head of the last successful
                               run (the workflow falls back to github.event.before)
  TAG                          (plan-release) the pushed github.ref_name
  PRODUCT_ID / VERSION_BASE    (plan-alpha) the product, and a base-version override
  GIT_TAGS / BUILD_NUMBER      test-injection overrides
  ASSUME_CHANGED               ids to treat as changed, or `*` for all. Stubs git
                               for tests AND backs the orchestrator's force
                               input. Empty == unset.
"""
import glob
import json
import os
import re
import subprocess
import sys

# How each platform/channel pair is built, signed and shipped. `build` picks the
# callee: _build-ios.yml, _build-mac-store.yml or _build-mac-direct.yml.
LEG_KINDS = {
    ("ios", "app-store"): {"build": "ios", "destination": "generic/platform=iOS",
                           "profile-type": "IOS_APP_STORE", "export-method": "app-store-connect"},
    ("ios", "ad-hoc"): {"build": "ios", "destination": "generic/platform=iOS",
                        "profile-type": "IOS_APP_ADHOC", "export-method": "release-testing"},
    ("macos", "app-store"): {"build": "mac-store", "destination": "generic/platform=macOS",
                             "profile-type": "MAC_APP_STORE", "export-method": "app-store-connect"},
    ("macos", "direct"): {"build": "mac-direct", "destination": "generic/platform=macOS",
                          "profile-type": "MAC_APP_DIRECT", "export-method": "developer-id"},
}
CHANNELS = {"ios": ("app-store", "ad-hoc"), "macos": ("app-store", "direct")}
# Designed in, switched on when the first app ships there.
NOT_YET = ("tvos", "visionos")

LEG_KEYS = {"scheme", "bundle-id", "configuration", "product-name", "cert-secret", "cert-password-secret"}
DIRECT_KEYS = {"appcast", "s3-subpath", "appcast-filename", "appcast-seed-path", "changelog-filename"}

_EXT = "delete it: every extension is signed with the profile for its own bundle ID"
_PROFILE = "delete it: profiles come from App Store Connect at build time"
# Keys of the v0.5 (macOS) and v0.4 (workflows-ios) formats. Each fails loudly
# with what to do instead, so an app that bumps its pin learns what to change.
RETIRED = {
    "platform": 'move it into "platforms": {"<platform>": {"<channel>": {}}}',
    "channel": 'move it into "platforms": {"ios": {"<channel>": {}}}',
    "build-direct": 'use "platforms": {"macos": {"direct": {}}}',
    "build-app-store": 'use "platforms": {"macos": {"app-store": {}}}',
    "distribute-app-store": 'delete it; an app-store leg uploads unless it says "distribute": false',
    "distribute-appcast": 'use "appcast": true on the direct leg',
    "distribute": 'move it onto the leg: "distribute": false',
    "scheme-store": 'use "scheme" on the app-store leg',
    "bundle-id-store": 'use "bundle-id" on the app-store leg',
    "has-finder": _EXT,
    "has-quicklook": _EXT,
    "bundle-id-finder": _EXT,
    "bundle-id-quicklook": _EXT,
    "bundle-id-finder-store": _EXT,
    "bundle-id-quicklook-store": _EXT,
    "devid-profile-secret": _PROFILE,
    "store-profile-secret": _PROFILE,
    "profile-secret": _PROFILE,
    "devid-cert-secret": 'use "cert-secret" on the direct leg',
    "devid-cert-password-secret": 'use "cert-password-secret" on the direct leg',
    "cert-secret": 'move it onto the leg that signs with it',
    "cert-password-secret": 'move it onto the leg that signs with it',
    "s3-subpath": 'move it onto the direct leg',
    "appcast-filename": 'move it onto the direct leg',
    "appcast-seed-path": 'move it onto the direct leg',
    "changelog-filename": 'move it onto the direct leg',
}

IOS_SIMULATOR = "platform=iOS Simulator,name=iPhone 17"


def die(msg):
    print(f"::error::{msg}", file=sys.stderr)
    sys.exit(1)


def note(msg):
    print(f"::notice::{msg}", file=sys.stderr)


def warn(msg):
    print(f"::warning::{msg}", file=sys.stderr)


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


def tag_prefix(rec):
    """Bare 'v' for the primary (empty-id) product, '<id>-v' otherwise. The
    prefix is a git-tag/workflow identifier only — never the app's version."""
    return "v" if rec.get("_bare") else f'{rec["id"]}-v'


# ── git (isolated + injectable) ──────────────────────────────────────────────
def git_tags():
    inj = os.environ.get("GIT_TAGS")
    if inj is not None:
        return [t for t in inj.split() if t]
    out = subprocess.run(["git", "tag", "--list"], capture_output=True, text=True)
    return [t for t in out.stdout.splitlines() if t]


def assumed_changed(key):
    """None when ASSUME_CHANGED is unset, else whether it names this product."""
    # Empty counts as UNSET, deliberately. The obvious workflow wiring for an
    # off switch renders to "", and under an `is not None` test that would mean
    # "nothing changed" — silently stopping every build on every normal push.
    inj = os.environ.get("ASSUME_CHANGED", "").strip()
    if not inj:
        return None
    return inj == "*" or key in inj.split()


def changed_between(ref, rec, products_dir):
    """True if the product's file, or any of its source-paths, differs between
    ref and HEAD. A ref git cannot resolve (a force-pushed `before`) counts as
    changed: building once too often beats silently shipping nothing."""
    paths = [os.path.join(products_dir, rec["_file"]), *rec["_source_paths"]]
    rc = subprocess.run(["git", "diff", "--quiet", ref, "HEAD", "--", *paths],
                        stderr=subprocess.DEVNULL).returncode
    return rc != 0


def build_number():
    inj = os.environ.get("BUILD_NUMBER")
    if inj:
        return inj
    return subprocess.run(["date", "-u", "+%y%m%d%H%M%S"], capture_output=True, text=True).stdout.strip()


# ── discovery + validation + defaulting ──────────────────────────────────────
def resolve_legs(pid, p, errors):
    """Expand a product's `platforms` block into leg records."""
    scheme = str(p.get("scheme") or "").strip()
    bundle_id = str(p.get("bundle-id") or "").strip()
    configuration = str(p.get("configuration") or "").strip() or "Release"
    product_name = str(p.get("product-name") or "").strip()

    platforms = p.get("platforms")
    if not isinstance(platforms, dict) or not platforms:
        errors.append(f"product '{pid}': 'platforms' is missing — name where each platform ships, "
                      f'e.g. "platforms": {{"macos": {{"direct": {{}}}}}}')
        return []

    legs = []
    for plat, channels in platforms.items():
        if plat in NOT_YET:
            errors.append(f"product '{pid}': platform '{plat}' is not supported yet")
            continue
        if plat not in CHANNELS:
            errors.append(f"product '{pid}': unknown platform '{plat}' — one of {', '.join(CHANNELS)}")
            continue
        if not isinstance(channels, dict) or not channels:
            errors.append(f"product '{pid}': platforms.{plat} names no channel — one of {', '.join(CHANNELS[plat])}")
            continue
        for chan, leg in channels.items():
            where = f"product '{pid}': platforms.{plat}.{chan}"
            if chan not in CHANNELS[plat]:
                errors.append(f"{where}: {plat} ships through {' or '.join(CHANNELS[plat])}, not '{chan}'")
                continue
            if not isinstance(leg, dict):
                errors.append(f"{where}: must be an object ({{}} for the product's defaults)")
                continue
            allowed = LEG_KEYS | (DIRECT_KEYS if chan == "direct" else {"distribute"})
            for k in leg:
                if k in allowed:
                    continue
                if k in DIRECT_KEYS:
                    errors.append(f"{where}: '{k}' belongs on a direct leg")
                elif k == "distribute":
                    errors.append(f"{where}: a direct leg always publishes; 'distribute' is for app-store and ad-hoc legs")
                else:
                    errors.append(f"{where}: unknown key '{k}'")

            l_scheme = str(leg.get("scheme") or scheme).strip()
            l_bundle = str(leg.get("bundle-id") or bundle_id).strip()
            l_name = str(leg.get("product-name") or product_name).strip()
            if not l_scheme:
                errors.append(f"{where}: no 'scheme' on the product or the leg")
            if not l_bundle:
                errors.append(f"{where}: no 'bundle-id' on the product or the leg")
            if chan == "direct" and not l_name:
                # The Direct build finds <product-name>.app and names the DMG/ZIP after it.
                errors.append(f"{where}: no 'product-name' on the product or the leg — the Direct build needs the .app's name")

            kind = LEG_KINDS[(plat, chan)]
            legs.append({
                "id": pid,
                "leg": f"{pid}-{plat}-{chan}",
                "platform": plat,
                "channel": chan,
                "scheme": l_scheme,
                "bundle-id": l_bundle,
                "configuration": str(leg.get("configuration") or configuration).strip(),
                "product-name": l_name or l_scheme,
                "distribute": as_bool(leg.get("distribute"), True),
                "destination": kind["destination"],
                "profile-type": kind["profile-type"],
                "export-method": kind["export-method"],
                "cert-secret": str(leg.get("cert-secret") or ""),
                "cert-password-secret": str(leg.get("cert-password-secret") or ""),
                "appcast": as_bool(leg.get("appcast"), False),
                "s3-subpath": str(leg.get("s3-subpath") or "").strip("/"),
                "appcast-filename": str(leg.get("appcast-filename") or "appcast.xml"),
                "appcast-seed-path": str(leg.get("appcast-seed-path") or "Config/appcast.xml"),
                "changelog-filename": str(leg.get("changelog-filename") or "Changelog.json"),
                "_build": kind["build"],
            })
    return legs


def resolve(products_dir):
    """Glob → validate → normalize. Returns product records, each with its legs.

    Every product must carry a mandatory inline `changelog` with a
    versions[0].version and at least one leg. Fails loudly (exit 1) listing
    every problem.
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

        stem = os.path.splitext(os.path.basename(f))[0]
        file_id = str(p.get("id") or "").strip()   # empty/omitted → primary, bare v* tags
        bare = file_id == ""
        pid = file_id or stem                        # internal key (artifacts/matrix/S3) — always set
        if file_id and file_id != stem:
            errors.append(f"{f}: id '{file_id}' must match the filename ('{stem}.json') — rename to '{file_id}.json', or drop 'id' for the primary product")
        if pid in seen:
            errors.append(f"duplicate product id/key '{pid}'")
        seen.add(pid)

        for k, instead in RETIRED.items():
            if k in p:
                errors.append(f"product '{pid}': '{k}' was retired in v0.6 — {instead}")

        legs = resolve_legs(pid, p, errors)

        # Mandatory inline changelog → the product's version source.
        version = ""
        cl = p.get("changelog")
        if not isinstance(cl, dict) or not (cl.get("versions") or []):
            errors.append(f"product '{pid}': mandatory 'changelog' with versions[0].version is missing")
        else:
            version = str((cl["versions"][0] or {}).get("version") or "").strip()
            if not version:
                errors.append(f"product '{pid}': changelog.versions[0].version is empty")

        name = str(p.get("product-name") or "").strip() or (legs[0]["product-name"] if legs else pid)
        resolved.append({
            "id": pid,
            "product-name": name,
            "_legs": legs,
            "_has_direct": any(l["channel"] == "direct" for l in legs),
            "_version": version,
            "_bare": bare,
            "_file": os.path.basename(f),
            # Git pathspecs this product builds from, e.g. ["MyApp/**",
            # "Project.swift"]. Optional; when set, a change to any of them
            # builds on its own, so a code-only fix ships without a cosmetic
            # edit to the product file. Internal: plan only.
            "_source_paths": [str(x) for x in (p.get("source-paths") or []) if str(x).strip()],
        })

    if sum(1 for r in resolved if r["_bare"]) > 1:
        errors.append("at most one product may omit 'id' — the primary uses bare 'v*' tags; give the others a unique id")

    if errors:
        for e in errors:
            print(f"::error::products: {e}", file=sys.stderr)
        sys.exit(1)
    return resolved


# ── output ───────────────────────────────────────────────────────────────────
def emit_legs(legs):
    """The leg list plus one subset per build callee. A job `if:` cannot read
    `matrix`, and an empty matrix throws rather than skipping — so every subset
    comes with the presence boolean its build job gates on."""
    emit("legs", compact([strip_internal(l) for l in legs]))
    for build in ("ios", "mac-store", "mac-direct"):
        sub = [strip_internal(l) for l in legs if l["_build"] == build]
        emit(f"{build}-legs", compact(sub))
        emit(f"has-{build}", "true" if sub else "false")
    emit("has-appcast", "true" if any(l["channel"] == "direct" and l["appcast"] for l in legs) else "false")
    emit("has-any", "true" if legs else "false")


def emit_test_defaults(records):
    # The FIRST discovered product (always present, even when nothing builds)
    # gives the opt-in test gate a scheme regardless of what changed. Scheme and
    # destination come from ONE leg: its Mac leg if it has one (no Simulator
    # needed), else its first — an iPhone scheme tested on the Mac just fails.
    first = records[0]
    legs = first["_legs"]
    leg = next((l for l in legs if l["platform"] == "macos"), legs[0] if legs else None)
    emit("test-scheme", leg["scheme"] if leg else "")
    emit("test-app-name", first["product-name"])
    emit("test-destination", "platform=macOS" if leg and leg["platform"] == "macos" else IOS_SIMULATOR)


def cut(rec, legs, version, label, marketing_direct, release_tag):
    """The product row and its legs, versioned for this build."""
    out = []
    for l in legs:
        leg = dict(l)
        # App Store Connect rejects a non-N.N.N CFBundleShortVersionString, so
        # every leg but Direct carries the bare version; the build number tells
        # builds apart.
        leg.update({"version": version,
                    "marketing": marketing_direct if l["channel"] == "direct" else version,
                    "artifact-label": label})
        out.append(leg)
    row = {"id": rec["id"], "product-name": rec["product-name"], "version": version,
           "release-tag": release_tag, "has-direct": rec["_has_direct"]}
    return row, out


# ── subcommands ──────────────────────────────────────────────────────────────
def cmd_discover(products_dir):
    records = resolve(products_dir)
    legs = [l for r in records for l in r["_legs"]]
    emit("products", compact([strip_internal(r) for r in records]))
    emit_legs(legs)
    emit("ids", " ".join(r["id"] for r in records))
    emit_test_defaults(records)


def unchanged_warning(rec, products_dir, since):
    f = f"{products_dir}/{rec['_file']}"
    if rec["_source_paths"]:
        warn(f"{rec['id']}: neither {f} nor its source-paths changed {since} — nothing built")
    else:
        # A warning, not a notice: a push that DID change code still ships
        # nothing, and the run is otherwise green. Without `source-paths` the
        # check cannot see code at all, so say what to do about it.
        warn(f"{rec['id']}: {f} unchanged {since} — nothing built. Code-only changes do NOT "
             f"trigger a build; add \"source-paths\" to the product file (e.g. "
             f"[\"{rec['id']}/**\", \"Project.swift\"]) so they do.")


def cmd_plan(products_dir):
    records = resolve(products_dir)
    tags = set(git_tags())
    forced = bool(os.environ.get("ASSUME_CHANGED", "").strip())
    since = os.environ.get("SINCE", "").strip()
    build = build_number()
    rows, legs = [], []
    for r in records:
        pid, v = r["id"], r["_version"]
        pfx = tag_prefix(r)                             # 'v' (primary) or '<id>-v'
        if f"{pfx}{v}" in tags:                          # released → idle → skip
            # Forcing overrides "nothing changed", never "already released" —
            # App Store Connect rejects further builds of an approved version.
            # But a run asked to force that quietly does nothing looks broken
            # exactly when it is behaving correctly, so say so and name the way out.
            if forced:
                warn(f"{pid}: force was set, but {pfx}{v} is already released — nothing built. "
                     f"Forcing overrides 'nothing changed', not 'already shipped'. Bump "
                     f"changelog.versions[0].version to start the next version.")
            else:
                note(f"{pid}: {pfx}{v} already released — idle (bump its changelog to build again)")
            continue

        if r["_has_direct"]:
            betas = [t for t in tags if t.startswith(f"{pfx}{v}-beta.")]
            nums = [int(t.rsplit(".", 1)[1]) for t in betas if t.rsplit(".", 1)[1].isdigit()]
            if nums:                                    # rebuild ONLY if this product changed
                last_tag = f"{pfx}{v}-beta.{max(nums)}"
                changed = assumed_changed(pid)
                if changed is None:
                    changed = changed_between(last_tag, r, products_dir)
                if not changed:
                    unchanged_warning(r, products_dir, f"since {last_tag}")
                    continue
                n = max(nums) + 1
            else:
                n = 1                                   # first beta of v — the bump IS the change
            row, cut_legs = cut(r, r["_legs"], v, f"v{v}-beta.{n}", f"{v}-beta.{n}", f"{pfx}{v}-beta.{n}")
        else:
            # No Direct leg, so no tags: the last successful run is the reference.
            changed = assumed_changed(pid)
            if changed is None:
                if not since or set(since) == {"0"}:
                    # No successful run yet (the first run after moving to v0.6),
                    # or a manual run with nothing to compare against: build.
                    note(f"{pid}: no earlier successful run to compare against — building")
                    changed = True
                else:
                    changed = changed_between(since, r, products_dir)
            if not changed:
                unchanged_warning(r, products_dir, f"since {since[:12]}, the last successful run")
                continue
            row, cut_legs = cut(r, r["_legs"], v, f"v{v}-{build}", v, "")
        rows.append(row)
        legs.extend(cut_legs)

    emit("products", compact(rows))
    emit_legs(legs)
    emit("build-number", build)
    emit_test_defaults(records)


def cmd_plan_release(products_dir):
    records = resolve(products_dir)
    tag = (os.environ.get("TAG") or "").strip()
    if not tag:
        die("TAG (github.ref_name) is required for plan-release")
    if re.search(r"-(?:beta|alpha)\.", tag):
        die(f"'{tag}' is a beta/alpha tag and must not reach the release flow — fix the shell tag filter")

    # Each product's tag prefix: 'v' for the primary (empty id), '<id>-v' otherwise.
    # Match the longest prefix first, so 'pro-v…' binds to 'pro' before the bare 'v…'.
    candidates = sorted(((tag_prefix(r), r) for r in records), key=lambda c: len(c[0]), reverse=True)
    hit = None
    for prefix, r in candidates:
        if tag.startswith(prefix):
            ver = tag[len(prefix):]
            if re.match(r"^\d+\.\d+(\.\d+)?$", ver):
                hit = (r, ver)
                break
    if not hit:
        die(f"'{tag}' matches no product's release tag — the primary product releases via 'vX.Y.Z', others via '<id>-vX.Y.Z'")

    r, ver = hit
    if ver != r["_version"]:
        die(f"tag '{tag}' (={ver}) != Config/products/{r['_file']} changelog.versions[0].version (={r['_version']}). Bump the changelog or fix the tag.")

    direct = [l for l in r["_legs"] if l["channel"] == "direct"]
    if not direct:
        note(f"{r['id']}: no Direct leg — the tag marks the release, and nothing is built. "
             f"Submit the build you tested in TestFlight in App Store Connect.")
    row, legs = cut(r, direct, ver, f"v{ver}", ver, tag)
    emit("target-id", r["id"])
    emit("version", ver)
    emit("artifact-label", f"v{ver}")
    emit("build-number", build_number())
    emit("products", compact([row]))
    emit_legs(legs)


def cmd_plan_alpha(products_dir):
    records = resolve(products_dir)
    want = (os.environ.get("PRODUCT_ID") or "").strip()
    if want:
        hits = [r for r in records if r["id"] == want]
        if not hits:
            die(f"product-id '{want}' matches no product file — known: {', '.join(r['id'] for r in records)}")
        r = hits[0]
    elif len(records) == 1:
        r = records[0]
    else:
        die(f"this repo has {len(records)} products — set product-id to one of: {', '.join(r['id'] for r in records)}")

    pfx = tag_prefix(r)
    base = (os.environ.get("VERSION_BASE") or "").strip() or r["_version"]
    tags = set(git_tags())
    if f"{pfx}{base}" in tags:
        die(f"{pfx}{base} is already released — an alpha is for an unreleased version. Bump the base first.")

    build = build_number()
    if r["_has_direct"]:
        # The tag pins the exact commit handed out and is the next run's counter.
        n = 1 + sum(1 for t in tags if t.startswith(f"{pfx}{base}-alpha."))
        label, tag = f"{base}-alpha.{n}", f"{pfx}{base}-alpha.{n}"
    else:
        label, tag = f"{base}-{build}", ""
    row, legs = cut(r, r["_legs"], base, label, label, tag)
    for leg in legs:
        # Marked in App Store Connect as internal-only: it never reaches
        # external testers or the App Store.
        leg["internal-only"] = leg["channel"] == "app-store"
    emit("target-id", r["id"])
    emit("version", base)
    emit("alpha-label", label)
    emit("alpha-tag", tag)
    emit("build-number", build)
    emit("products", compact([row]))
    emit_legs(legs)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    products_dir = os.environ.get("PRODUCTS_DIR") or "Config/products"
    commands = {"discover": cmd_discover, "plan": cmd_plan,
                "plan-release": cmd_plan_release, "plan-alpha": cmd_plan_alpha}
    if cmd not in commands:
        die(f"unknown subcommand '{cmd}' (expected {' | '.join(commands)})")
    commands[cmd](products_dir)


if __name__ == "__main__":
    main()
