#!/usr/bin/env python3
"""Provisioning profiles from App Store Connect, for signing every build leg.

  profiles.py fetch --type MAC_APP_STORE [--type ...] --out DIR [--install]
      Downloads every ACTIVE profile of those types into DIR and writes
      DIR/profiles.json: {type: {bundle id: {name, uuid, team, expires, file}}}.
      --install also copies them where Xcode looks, and records in
      DIR/installed.txt the ones that weren't there before, for `cleanup`.
      Reads ASC_KEY_ID, ASC_ISSUER_ID and the key from the environment: the .p8
      as ASC_KEY_BASE64 (CI) or its path as ASC_KEY_PATH (a Mac).

  profiles.py cleanup --out DIR
      Removes exactly the profiles `fetch --install` added.

  profiles.py archive-args --profiles DIR/profiles.json --type TYPE --cert NAME [--team ID]
      Prints the xcodebuild archive settings, one per line, that let every target
      (the app and each extension) pick its own profile by bundle ID.

  profiles.py export-options --profiles DIR/profiles.json --type TYPE --archive X.xcarchive
                             --method METHOD --cert NAME [--installer-cert NAME]
                             [--internal-only true|false] [--team ID] --out PLIST
      Matches every app and extension in the archive to its profile by bundle ID
      and writes the ExportOptions.plist that signs each of them.

  With --team, both fail when the profiles belong to another team: the leg got
  another team's App Store Connect key. A profile accepts only its own team's
  certificates, so the signature can't end up in another team either.

  profiles.py selftest
      Offline check of the token signature, the profile choice, the install and
      the archive matching.

Prints names, bundle IDs and dates only, never a token or a profile's content:
an Ad Hoc profile lists device IDs.
"""
import argparse
import base64
import json
import os
import plistlib
import re
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com/v1/profiles"
# Names Xcode gives the profiles it manages; those may point at a cloud certificate
# this Mac doesn't hold.
XCODE_MANAGED = re.compile(r"^XC\b|Team (Store |Direct |Ad Hoc )?Provisioning Profile")
# Xcode 16 and later read the first, older Xcodes the second.
PROFILE_DIRS = ("Library/Developer/Xcode/UserData/Provisioning Profiles",
                "Library/MobileDevice/Provisioning Profiles")


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der):
    """openssl writes an ECDSA signature as DER; ES256 wants r and s as 32 bytes each."""
    i = 2 + (der[1] & 0x7F if der[1] & 0x80 else 0)
    raw = b""
    for _ in range(2):
        n = der[i + 1]
        raw += der[i + 2:i + 2 + n].lstrip(b"\0").rjust(32, b"\0")
        i += 2 + n
    return raw


def token(key_id, issuer, key_path):
    # stdlib Python can't sign ECDSA, so openssl does it.
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 900,
                                 "aud": "appstoreconnect-v1"}).encode())
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=f"{header}.{payload}".encode(),
                         capture_output=True, check=True).stdout
    return f"{header}.{payload}.{b64url(der_to_raw(der))}"


def env_token():
    missing = [k for k in ("ASC_KEY_ID", "ASC_ISSUER_ID") if not os.environ.get(k)]
    if not (os.environ.get("ASC_KEY_BASE64") or os.environ.get("ASC_KEY_PATH")):
        missing.append("ASC_KEY_BASE64 (or ASC_KEY_PATH)")
    if missing:
        sys.exit("profiles: set " + ", ".join(missing) + " — the App Store Connect key downloads the profiles"
                 ' (a leg with "asc-key": "alt" takes ASC_KEY_ID_ALT, ASC_ISSUER_ID_ALT and ASC_KEY_ALT_BASE64)')
    key_id, issuer = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
    if os.environ.get("ASC_KEY_PATH"):
        return token(key_id, issuer, os.environ["ASC_KEY_PATH"])
    # The key lives on disk only for the one openssl call.
    with tempfile.TemporaryDirectory() as d:
        key = Path(d) / "key.p8"
        key.touch(mode=0o600)
        key.write_bytes(base64.b64decode(os.environ["ASC_KEY_BASE64"]))
        return token(key_id, issuer, str(key))


def get(url, tok):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
    try:
        # python.org's Python ships without root certificates; macOS keeps them here.
        ctx = ssl.create_default_context(cafile="/etc/ssl/cert.pem")
        with urllib.request.urlopen(req, timeout=60, context=ctx) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            detail = json.load(e)["errors"][0].get("detail", "")
        except Exception:
            detail = ""
        hint = {401: "key ID, issuer ID and .p8 don't match, or the key was revoked",
                403: "this key's role may not read profiles; the profile endpoints need an Admin key"}.get(e.code)
        sys.exit(f"App Store Connect answered {e.code}. {detail}" + (f" ({hint})" if hint else ""))


def choose(profiles, bundles):
    """{bundle id: [profile attributes, best first]}: hand-made before Xcode-managed,
    then the latest expiry."""
    # ponytail: picks by name and date. Matching each profile's certificates against
    # the keychain would be exact; add it if this rule ever picks a profile export can't use.
    found = {}
    for p in profiles:
        bundle = bundles.get(p["relationships"]["bundleId"]["data"]["id"], "?")
        found.setdefault(bundle, []).append(p["attributes"])
    for candidates in found.values():
        candidates.sort(key=lambda a: a["expirationDate"], reverse=True)
        candidates.sort(key=lambda a: bool(XCODE_MANAGED.search(a["name"])))
    return found


def install(files, out):
    """Copy the profiles where Xcode looks. Only the ones not already there are
    recorded, so cleanup never removes a profile someone else installed."""
    added = []
    for d in PROFILE_DIRS:
        target = Path.home() / d
        target.mkdir(parents=True, exist_ok=True)
        for f in files:
            dest = target / f.name
            if not dest.exists():
                dest.write_bytes(f.read_bytes())
                added.append(str(dest))
    with open(out / "installed.txt", "a") as fh:
        fh.writelines(p + "\n" for p in added)


def fetch(args):
    tok = env_token()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    result, files = {}, []
    for t in args.type:
        query = urllib.parse.urlencode({
            "filter[profileType]": t, "filter[profileState]": "ACTIVE", "include": "bundleId",
            "fields[profiles]": "name,uuid,expirationDate,profileContent,bundleId",
            "fields[bundleIds]": "identifier", "limit": 200})
        url, profiles, bundles = f"{API}?{query}", [], {}
        while url:
            page = get(url, tok)
            profiles += page["data"]
            bundles.update({b["id"]: b["attributes"]["identifier"]
                            for b in page.get("included", []) if b["type"] == "bundleIds"})
            url = page.get("links", {}).get("next")
        result[t] = {}
        found = choose(profiles, bundles)
        if not found:
            print(f"{t:15} no active profiles")
        for bundle, candidates in sorted(found.items()):
            best = candidates[0]
            content = base64.b64decode(best["profileContent"])
            team = re.search(rb"<key>TeamIdentifier</key>\s*<array>\s*<string>([^<]+)</string>", content)
            file = out / (best["uuid"] + (".provisionprofile" if t.startswith("MAC") else ".mobileprovision"))
            file.write_bytes(content)
            files.append(file)
            result[t][bundle] = {"name": best["name"], "uuid": best["uuid"],
                                 "team": team.group(1).decode() if team else "",
                                 "expires": best["expirationDate"][:10], "file": str(file)}
            others = ", ".join(c["name"] for c in candidates[1:])
            print(f"{t:15} {bundle:40} {best['name']} (expires {best['expirationDate'][:10]})"
                  + (f"; also active: {others}" if others else ""))
    (out / "profiles.json").write_text(json.dumps(result, indent=2))
    if args.install:
        install(files, out)


def cleanup(args):
    listed = Path(args.out) / "installed.txt"
    if listed.exists():
        for p in listed.read_text().splitlines():
            Path(p).unlink(missing_ok=True)
        listed.unlink()


def c99(text):
    """Xcode's :c99extidentifier operator, the one PRODUCT_MODULE_NAME uses by default."""
    text = re.sub(r"[^A-Za-z0-9_]", "_", text)
    return "_" + text if text[:1].isdigit() else text


def same_team(args, profiles):
    """With --team, every profile must belong to that team. An App Store Connect key
    sees only its own team's profiles, so another team here means the leg got the
    wrong key ("asc-key") — and a build signed in that team would ship."""
    teams = sorted({p["team"] for p in profiles})
    if args.team and teams != [args.team]:
        sys.exit(f"profiles: the {args.type} profiles belong to team {', '.join(teams)}, but this leg signs for "
                 f"team {args.team}; give the leg that team's App Store Connect key (\"asc-key\")")


def archive_args(args):
    # A profile named on the command line applies to every target, which signs an
    # extension with the app's profile. Indirection instead: each target looks up
    # PP_<its own bundle ID>, and this sets one PP_ per profile the team has. A
    # target without one (a framework) resolves to empty and needs none. UUIDs,
    # not names: a renewed profile can share its name with the old one.
    # (A placeholder signature can't replace this: on Xcode 27.1 an iOS target with
    # any entitlement refuses to archive without a profile.)
    profiles = {b: p for b, p in json.loads(Path(args.profiles).read_text()).get(args.type, {}).items() if b != "?"}
    if not profiles:
        sys.exit(f"profiles: no active {args.type} profile for this team; create one per bundle ID in the developer portal")
    same_team(args, profiles.values())
    team = next(iter(profiles.values()))["team"]
    print("\n".join(["CODE_SIGN_STYLE=Manual", f"DEVELOPMENT_TEAM={team}", f"CODE_SIGN_IDENTITY={args.cert}",
                     "PROVISIONING_PROFILE_SPECIFIER=$(PP_$(PRODUCT_BUNDLE_IDENTIFIER:c99extidentifier))"]
                    + [f"PP_{c99(b)}={p['uuid']}" for b, p in sorted(profiles.items())]))


def bundles_in(archive):
    """(path, bundle id) of every app and extension in the archive, the app itself first.
    Bundles inside frameworks (Sparkle's helpers) bring their own signature and get no profile."""
    found = []
    for b in sorted((Path(archive) / "Products" / "Applications").rglob("*")):
        if b.suffix in (".app", ".appex") and b.is_dir() and ".framework/" not in str(b):
            info = b / "Contents" / "Info.plist" if (b / "Contents").is_dir() else b / "Info.plist"
            found.append((b, plistlib.loads(info.read_bytes())["CFBundleIdentifier"]))
    return found


def export_options(args):
    profiles = json.loads(Path(args.profiles).read_text()).get(args.type, {})
    mapping, used, team = {}, [], ""
    for i, (path, bundle) in enumerate(bundles_in(args.archive)):
        p = profiles.get(bundle)
        if p:
            mapping[bundle] = p["uuid"]  # the UUID, not the name: names aren't unique
            used.append(p)
            team = team or p["team"]
            print(f"{path.name:32} {bundle:40} {p['name']}")
        elif i == 0:
            sys.exit(f"profiles: no active {args.type} profile for {bundle}; create it once in the developer portal")
        else:
            print(f"{path.name:32} {bundle:40} no {args.type} profile (export fails if it needs one)")
    same_team(args, used)
    opts = {"method": args.method, "destination": "export", "signingStyle": "manual",
            "teamID": team, "signingCertificate": args.cert, "provisioningProfiles": mapping}
    if args.installer_cert:
        opts["installerSigningCertificate"] = args.installer_cert
    if args.method == "app-store-connect":
        opts["uploadSymbols"] = True
        # Defaults to true and rewrites CFBundleVersion at export, destroying the
        # monotonic timestamp build number (and classify-upload.sh's -19232 meaning).
        opts["manageAppVersionAndBuildNumber"] = False
        if str(args.internal_only).lower() == "true":
            # App Store Connect keeps the build from external testers and the App Store.
            opts["testFlightInternalTestingOnly"] = True
    with open(args.out, "wb") as f:
        plistlib.dump(opts, f)


def selftest(_):
    import contextlib
    import io
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        key = d / "AuthKey_TEST.p8"
        subprocess.run(f"openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out '{key}'",
                       shell=True, check=True)
        header, payload, sig = token("TESTKEY123", "test-issuer", str(key)).split(".")
        raw = base64.urlsafe_b64decode(sig + "==")
        assert len(raw) == 64, len(raw)

        def der_int(x):
            x = x.lstrip(b"\0") or b"\0"
            x = b"\0" + x if x[0] & 0x80 else x
            return b"\x02" + bytes([len(x)]) + x
        body = der_int(raw[:32]) + der_int(raw[32:])
        (d / "sig").write_bytes(b"\x30" + bytes([len(body)]) + body)
        subprocess.run(["openssl", "ec", "-in", key, "-pubout", "-out", d / "pub.pem"], check=True, capture_output=True)
        subprocess.run(["openssl", "dgst", "-sha256", "-verify", d / "pub.pem", "-signature", d / "sig"],
                       input=f"{header}.{payload}".encode(), check=True, capture_output=True)
        assert json.loads(base64.urlsafe_b64decode(payload + "=="))["aud"] == "appstoreconnect-v1"

        # The CI form of the key, base64 in the environment, signs the same way.
        os.environ.update(ASC_KEY_ID="TESTKEY123", ASC_ISSUER_ID="test-issuer",
                          ASC_KEY_BASE64=base64.b64encode(key.read_bytes()).decode())
        os.environ.pop("ASC_KEY_PATH", None)
        assert len(env_token().split(".")) == 3

        found = choose(
            [{"relationships": {"bundleId": {"data": {"id": "B1"}}},
              "attributes": {"name": n, "uuid": u, "expirationDate": e}}
             for n, u, e in (("iOS Team Store Provisioning Profile: com.t", "X", "2027-09-01"),
                             ("T Store old", "OLD", "2026-11-01"), ("T Store", "NEW", "2027-06-01"))],
            {"B1": "com.t"})
        assert [a["uuid"] for a in found["com.t"]] == ["NEW", "OLD", "X"], found

        # install records only what it added; cleanup removes exactly that.
        home = d / "home"
        os.environ["HOME"] = str(home)
        mine, theirs = d / "U1.mobileprovision", d / "U9.mobileprovision"
        mine.write_bytes(b"mine")
        theirs.write_bytes(b"theirs")
        pre = home / PROFILE_DIRS[0] / theirs.name
        pre.parent.mkdir(parents=True)
        pre.write_bytes(b"installed by someone else")
        install([mine, theirs], d)
        assert all((home / p / mine.name).exists() for p in PROFILE_DIRS)
        cleanup(argparse.Namespace(out=d))
        assert not any((home / p / mine.name).exists() for p in PROFILE_DIRS)
        assert pre.read_bytes() == b"installed by someone else"

        app = d / "t.xcarchive/Products/Applications/T.app"
        for rel, bid in (("", "com.t"), ("PlugIns/W.appex", "com.t.w"),
                         ("Frameworks/S.framework/U.app", "org.s.u")):
            (app / rel).mkdir(parents=True, exist_ok=True)
            (app / rel / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bid}))
        (d / "p.json").write_text(json.dumps({"IOS_APP_STORE": {
            "com.t": {"name": "T", "uuid": "U1", "team": "TEAM1"},
            "com.t.w": {"name": "W", "uuid": "U2", "team": "TEAM1"}}}))

        def opts(**kw):
            ns = dict(profiles=d / "p.json", type="IOS_APP_STORE", archive=d / "t.xcarchive",
                      method="app-store-connect", cert="Apple Distribution", installer_cert=None,
                      internal_only=False, team="", out=d / "o.plist")
            ns.update(kw)
            with contextlib.redirect_stdout(io.StringIO()):
                export_options(argparse.Namespace(**ns))
            return plistlib.loads((d / "o.plist").read_bytes())
        o = opts()
        assert o["provisioningProfiles"] == {"com.t": "U1", "com.t.w": "U2"} and o["teamID"] == "TEAM1", o
        assert o["destination"] == "export" and o["manageAppVersionAndBuildNumber"] is False, o
        assert o["uploadSymbols"] is True and "testFlightInternalTestingOnly" not in o, o
        assert opts(internal_only=True)["testFlightInternalTestingOnly"] is True
        o = opts(method="developer-id", cert="Developer ID Application")
        assert "manageAppVersionAndBuildNumber" not in o and "uploadSymbols" not in o, o

        assert c99("io.leanbytes.flowmoose-beta") == "io_leanbytes_flowmoose_beta" and c99("1x") == "_1x"
        def args(**kw):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                archive_args(argparse.Namespace(**{**dict(profiles=d / "p.json", type="IOS_APP_STORE",
                                                          cert="Apple Distribution", team=""), **kw}))
            return buf.getvalue().splitlines()
        assert args() == [
            "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=TEAM1", "CODE_SIGN_IDENTITY=Apple Distribution",
            "PROVISIONING_PROFILE_SPECIFIER=$(PP_$(PRODUCT_BUNDLE_IDENTIFIER:c99extidentifier))",
            "PP_com_t=U1", "PP_com_t_w=U2"], args()

        # --team: a leg that states its team fails on another team's profiles (#38).
        assert args(team="TEAM1")[1] == "DEVELOPMENT_TEAM=TEAM1" and opts(team="TEAM1")["teamID"] == "TEAM1"
        (d / "p2.json").write_text(json.dumps({"IOS_APP_STORE": {
            "com.t": {"name": "T", "uuid": "U1", "team": "TEAM1"},
            "com.t.w": {"name": "W", "uuid": "U2", "team": "TEAM2"}}}))
        for call, want in ((lambda: args(team="OTHER"), "belong to team TEAM1, but this leg signs for team OTHER"),
                           (lambda: opts(team="OTHER"), "belong to team TEAM1, but this leg signs for team OTHER"),
                           (lambda: opts(profiles=d / "p2.json", team="TEAM1"), "belong to team TEAM1, TEAM2")):
            try:
                call()
            except SystemExit as e:
                assert want in str(e), e
            else:
                raise AssertionError(f"no failure: {want}")
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch")
    f.add_argument("--type", action="append", required=True)
    f.add_argument("--out", required=True)
    f.add_argument("--install", action="store_true")
    f.set_defaults(run=fetch)
    c = sub.add_parser("cleanup")
    c.add_argument("--out", required=True)
    c.set_defaults(run=cleanup)
    a = sub.add_parser("archive-args")
    for name in ("--profiles", "--type", "--cert"):
        a.add_argument(name, required=True)
    a.add_argument("--team", default="", help="the leg's Apple team ID; profiles of another team fail")
    a.set_defaults(run=archive_args)
    e = sub.add_parser("export-options")
    for name in ("--profiles", "--type", "--archive", "--method", "--cert", "--out"):
        e.add_argument(name, required=True)
    e.add_argument("--installer-cert")
    e.add_argument("--internal-only", default="false", help="true marks an App Store build internal-only")
    e.add_argument("--team", default="", help="the leg's Apple team ID; profiles of another team fail")
    e.set_defaults(run=export_options)
    sub.add_parser("selftest").set_defaults(run=selftest)
    args = ap.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
