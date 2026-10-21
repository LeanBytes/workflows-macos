#!/usr/bin/env bash
# Offline tests for the shared scripts and workflows — no network, no signing.
# products.py: git is stubbed via GIT_TAGS / ASSUME_CHANGED, the timestamp via
# BUILD_NUMBER; the change checks also run against real throwaway git repos.
# Run from anywhere:  bash tests/run.sh   (needs python3, git, openssl, yq)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/.github/scripts/products.py"
FX="$ROOT/tests/fixtures"
MULTI="$FX/multi-independent/Config/products"
SINGLE="$FX/single/Config/products"
MIXED="$FX/mixed/Config/products"
DUAL="$FX/dual-bare/Config/products"
UNIVERSAL="$FX/universal/Config/products"
ADHOC="$FX/adhoc/Config/products"
RETIRED="$FX/retired/Config/products"
W="$ROOT/.github/workflows"
FAIL=0

CAP()  { OUT=$(env "$@" 2>/tmp/pd.err); RC=$?; }
pass() { echo "  ok  : $*"; }
bad()  { echo "  FAIL: $*"; echo "    rc=$RC"; echo "    stdout: $OUT"; echo "    stderr: $(cat /tmp/pd.err)"; FAIL=1; }
line() { grep -qxF "$2" <<<"$OUT" && pass "$1" || bad "$1 — missing line: $2"; }
jok()  { python3 - "$OUT" "$2" <<'PY' && pass "$1" || bad "$1"
import json, sys
o = dict(l.split("=", 1) for l in sys.argv[1].splitlines() if "=" in l)
L = lambda k="legs": {x["leg"]: x for x in json.loads(o[k])}
P = lambda: {x["id"]: x for x in json.loads(o["products"])}
exec(sys.argv[2])
PY
}
err()  { grep -qF "$2" /tmp/pd.err && [ $RC -ne 0 ] && pass "$1" || bad "$1 — expected exit≠0 and: $2"; }

echo "== discover (multi-independent: a Mac app on two channels + an iPhone app) =="
CAP PRODUCTS_DIR="$MULTI" python3 "$PY" discover
[ $RC -eq 0 ] && pass "exit 0" || bad "discover exit"
line "ids sorted glob" "ids=companion main"
jok "one leg per platform and channel" \
  'assert sorted(L()) == ["companion-ios-app-store", "main-macos-app-store", "main-macos-direct"], L()'
jok "each leg lands in its callee's subset" \
  'assert list(L("ios-legs")) == ["companion-ios-app-store"]; assert list(L("mac-store-legs")) == ["main-macos-app-store"]; assert list(L("mac-direct-legs")) == ["main-macos-direct"]'
line "has-ios" "has-ios=true"
line "has-mac-store" "has-mac-store=true"
line "has-mac-direct" "has-mac-direct=true"
jok "a leg carries how it is built and signed" \
  'l = L()["companion-ios-app-store"]; assert (l["destination"], l["profile-type"], l["export-method"]) == ("generic/platform=iOS", "IOS_APP_STORE", "app-store-connect"), l; d = L()["main-macos-direct"]; assert (d["destination"], d["profile-type"], d["export-method"]) == ("generic/platform=macOS", "MAC_APP_DIRECT", "developer-id"), d'
jok "internal keys never reach the workflows" \
  'assert all(not k.startswith("_") for l in json.loads(o["legs"]) for k in l)'
jok "test defaults: first product (companion) is iPhone-only → Simulator" \
  'assert o["test-scheme"] == "Companion" and o["test-destination"].startswith("platform=iOS Simulator"), o'

echo "== plan: companion released (idle), main mid-dev, no betas yet =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="companion-v1.3.0" BUILD_NUMBER="260704000000" python3 "$PY" plan
[ $RC -eq 0 ] && pass "exit 0" || bad "plan exit"
jok "only main → beta.1 (idle companion skipped)" \
  'p = P(); assert list(p) == ["main"], p; assert p["main"]["release-tag"] == "main-v2.14.0-beta.1"; assert o["build-number"] == "260704000000"'
jok "the Direct leg carries the beta version, the App Store leg the bare one" \
  'l = L(); assert l["main-macos-direct"]["marketing"] == "2.14.0-beta.1", l; assert l["main-macos-app-store"]["marketing"] == "2.14.0"; assert l["main-macos-direct"]["artifact-label"] == "v2.14.0-beta.1"'
line "no iPhone leg builds" "has-ios=false"

echo "== plan: nothing released, no tags, no successful run yet → both build =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="" BUILD_NUMBER="x" python3 "$PY" plan
jok "both build; the store-only product gets no tag" \
  'p = P(); assert sorted(p) == ["companion", "main"], p; assert p["companion"]["release-tag"] == "", p; assert o["has-any"] == "true"'
grep -q "no earlier successful run to compare against" /tmp/pd.err && pass "says why the store-only product builds" \
  || bad "a store-only product built without SINCE must say why"

echo "== plan: push 2 — only main changed =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1" ASSUME_CHANGED="main" BUILD_NUMBER="x" python3 "$PY" plan
jok "only main → beta.2; companion unchanged → skipped" \
  'p = P(); assert list(p) == ["main"], p; assert p["main"]["release-tag"] == "main-v2.14.0-beta.2"'

echo "== plan: main released → only companion builds =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0" BUILD_NUMBER="x" python3 "$PY" plan
jok "only companion, untagged" \
  'p = P(); assert list(p) == ["companion"], p; assert list(L()) == ["companion-ios-app-store"]'

echo "== force: ASSUME_CHANGED overrides \"nothing changed\", not \"already shipped\" =="
# Backs the orchestrator's force checkbox. `*` = every product; a list names
# them. Empty MUST count as unset, or the off position of the switch would
# silently stop every build on every normal push (#25).
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1" ASSUME_CHANGED="*" BUILD_NUMBER="x" python3 "$PY" plan
jok "'*' forces every product despite no change" \
  'assert sorted(P()) == ["companion", "main"], P()'

# Empty must behave EXACTLY like unset, whatever git then says — that is the
# invariant, and it holds without depending on this repo's tag state.
E=$(PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1" ASSUME_CHANGED="" BUILD_NUMBER="x" python3 "$PY" plan 2>/dev/null)
U=$(PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1"                     BUILD_NUMBER="x" python3 "$PY" plan 2>/dev/null)
[ "$E" = "$U" ] && pass "empty ASSUME_CHANGED behaves exactly like unset" \
  || { echo "  FAIL: ASSUME_CHANGED='' differs from unset — the off position of force"; FAIL=1; }

CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0 companion-v1.3.0" ASSUME_CHANGED="*" BUILD_NUMBER="x" python3 "$PY" plan
jok "a released version is NOT forced — gate (a) still stands" \
  'assert o["has-any"] == "false", o'
grep -q "force was set, but" /tmp/pd.err \
  && pass "forcing a released version warns loudly instead of going quietly green" \
  || { echo "  FAIL: forcing an already-released version must ::warning::, not ::notice::"; FAIL=1; }

# The wiring: `*` when the box is ticked, "" when it is not — never a value that
# products.py would read as "nothing changed". And the commit of the last
# successful run, which a product without a Direct leg compares against: the
# push's own `before` would lose the changes of a failed run, a [skip ci] push,
# or a queued run GitHub cancelled for a newer one.
DWF="$W/distribute.yml"
grep -q "^      force:" "$DWF" && pass "distribute.yml declares force" \
  || { echo "  FAIL: distribute.yml has no force input"; FAIL=1; }
grep -qF "ASSUME_CHANGED: \${{ inputs.force && '*' || '' }}" "$DWF" \
  && pass "force wires to ASSUME_CHANGED ('*' on, '' off)" \
  || { echo "  FAIL: distribute.yml must set ASSUME_CHANGED from force"; FAIL=1; }
grep -qF 'SINCE: ${{ steps.since.outputs.since }}' "$DWF" \
  && grep -qF 'actions/workflows/$wf/runs?branch=main&status=success' "$DWF" \
  && pass "plan compares against the last successful run on main" \
  || { echo "  FAIL: distribute.yml must pass the last successful run's head to products.py plan as SINCE"; FAIL=1; }
for f in "$DWF" "$ROOT/examples/per-app/distribute.yml"; do
  grep -qE '^  actions: read' "$f" && pass "$(basename "$(dirname "$f")")/$(basename "$f") grants actions: read" \
    || { echo "  FAIL: $f must grant 'actions: read' — without it the runs list answers 403"; FAIL=1; }
done
grep -rqE "CHANGED_PRODUCTS|force-beta|plan-beta" "$ROOT/.github" \
  && { echo "  FAIL: a retired name (CHANGED_PRODUCTS / force-beta / plan-beta) is still referenced"; FAIL=1; } \
  || pass "no stale CHANGED_PRODUCTS / force-beta / plan-beta references"

echo "== plan-release =="
CAP PRODUCTS_DIR="$MULTI" TAG="main-v2.14.0" BUILD_NUMBER="x" python3 "$PY" plan-release
[ $RC -eq 0 ] && pass "main release exit 0" || bad "main release exit"
line "target-id=main" "target-id=main"
line "version=2.14.0" "version=2.14.0"
jok "only the Direct leg rebuilds, with the bare version" \
  'l = L(); assert list(l) == ["main-macos-direct"], l; assert l["main-macos-direct"]["marketing"] == "2.14.0"; assert o["has-mac-store"] == "false"'

CAP PRODUCTS_DIR="$MULTI" TAG="companion-v1.3.0" BUILD_NUMBER="x" python3 "$PY" plan-release
[ $RC -eq 0 ] && pass "companion (store-only) release exit 0" || bad "companion release exit"
line "store-only release builds nothing" "has-any=false"
grep -q "nothing is built" /tmp/pd.err && pass "and says so" || bad "a store-only release must say nothing is built"

for T in "main-v9.9.9" "v2.14.0" "bogus-v1.0.0" "main-v2.14.0-beta.1" "main-v2.14.0-alpha.1"; do
  CAP PRODUCTS_DIR="$MULTI" TAG="$T" python3 "$PY" plan-release
  [ $RC -ne 0 ] && pass "reject '$T'" || bad "'$T' should fail (rc=$RC)"
done

echo "== single-product fixture =="
CAP PRODUCTS_DIR="$SINGLE" python3 "$PY" discover
line "single ids" "ids=app"
CAP PRODUCTS_DIR="$SINGLE" GIT_TAGS="" BUILD_NUMBER="x" python3 "$PY" plan
jok "app → beta.1" 'assert P()["app"]["release-tag"] == "app-v1.0.0-beta.1"'
CAP PRODUCTS_DIR="$SINGLE" TAG="app-v1.0.0" BUILD_NUMBER="x" python3 "$PY" plan-release
line "app release target" "target-id=app"

echo "== mixed: primary (empty id → bare v*) + prefixed pro, both at root =="
CAP PRODUCTS_DIR="$MIXED" python3 "$PY" discover
line "mixed ids (keys from filenames)" "ids=base pro"
CAP PRODUCTS_DIR="$MIXED" GIT_TAGS="" BUILD_NUMBER="x" python3 "$PY" plan
jok "base → bare v1.0.0-beta.1; pro → pro-v2.0.0-beta.1" \
  'p = P(); assert p["base"]["release-tag"] == "v1.0.0-beta.1", p; assert p["pro"]["release-tag"] == "pro-v2.0.0-beta.1", p'
jok "direct settings: changelog-filename and appcast-filename default vs override" \
  'l = L(); assert l["base-macos-direct"]["changelog-filename"] == "Changelog.json"; assert l["pro-macos-direct"]["changelog-filename"] == "Changelog-pro.json"; assert l["pro-macos-direct"]["appcast-filename"] == "appcast-pro.xml"; assert l["base-macos-direct"]["appcast"] is True'
jok "a leg names its own certificate; the other legs keep the team's" \
  'l = L(); assert l["base-macos-direct"]["cert-secret"] == "DEVELOPER_ID_P12_ALT_BASE64"; assert l["base-macos-direct"]["cert-password-secret"] == "DEVELOPER_ID_PASSWORD_ALT"; assert l["pro-macos-direct"]["cert-secret"] == ""; assert l["base-macos-app-store"]["cert-secret"] == ""'
jok "the leg's scheme overrides the product's; distribute false is carried" \
  'l = L(); assert l["base-macos-app-store"]["scheme"] == "FileFillet_Store"; assert l["base-macos-app-store"]["distribute"] is False; assert l["pro-macos-app-store"]["distribute"] is True'
CAP PRODUCTS_DIR="$MIXED" TAG="v1.0.0" BUILD_NUMBER="x" python3 "$PY" plan-release
line "bare tag → primary" "target-id=base"
CAP PRODUCTS_DIR="$MIXED" TAG="pro-v2.0.0" BUILD_NUMBER="x" python3 "$PY" plan-release
line "prefixed tag → pro" "target-id=pro"
CAP PRODUCTS_DIR="$MIXED" GIT_TAGS="v1.0.0" BUILD_NUMBER="x" python3 "$PY" plan
jok "base released (bare v1.0.0) → idle; only pro builds" \
  'assert list(P()) == ["pro"], P()'

echo "== universal: one product, iPhone + Mac, both App Store =="
CAP PRODUCTS_DIR="$UNIVERSAL" ASSUME_CHANGED="*" BUILD_NUMBER="7" python3 "$PY" plan
jok "both legs, one version, no tag; the Mac leg uses its own scheme" \
  'l = L(); assert sorted(l) == ["game-ios-app-store", "game-macos-app-store"], l; assert {x["marketing"] for x in l.values()} == {"1.0.0"}; assert l["game-macos-app-store"]["scheme"] == "GameMac"; assert l["game-ios-app-store"]["bundle-id"] == l["game-macos-app-store"]["bundle-id"]; assert P()["game"]["release-tag"] == ""'
jok "tests default to ONE leg: the Mac scheme on the Mac, never the iPhone scheme on the Mac" \
  'assert (o["test-scheme"], o["test-destination"]) == ("GameMac", "platform=macOS"), o'

echo "== ad hoc: an iPhone product for registered devices =="
CAP PRODUCTS_DIR="$ADHOC" ASSUME_CHANGED="*" BUILD_NUMBER="7" python3 "$PY" plan
jok "Ad Hoc profile and export method; distributes by default" \
  'l = L()["family-ios-ad-hoc"]; assert (l["profile-type"], l["export-method"], l["distribute"]) == ("IOS_APP_ADHOC", "release-testing", True), l'

echo "== validation: two empty-id products → hard error =="
CAP PRODUCTS_DIR="$DUAL" python3 "$PY" discover
err "dual-bare rejected" "at most one product may omit"

echo "== validation: a v0.5 / workflows-ios product file names every replacement =="
CAP PRODUCTS_DIR="$RETIRED" python3 "$PY" discover
err "build-app-store → platforms"      "'build-app-store' was retired in v0.6 — use \"platforms\""
err "scheme-store → the leg's scheme"  "'scheme-store' was retired in v0.6 — use \"scheme\" on the app-store leg"
err "has-finder → nothing to do"       "'has-finder' was retired in v0.6 — delete it: every extension is signed with the profile for its own bundle ID"
err "devid-profile-secret → nothing"   "'devid-profile-secret' was retired in v0.6 — delete it: profiles come from App Store Connect"
err "s3-subpath → the direct leg"      "'s3-subpath' was retired in v0.6 — move it onto the direct leg"
err "channel (workflows-ios) → platforms" "'channel' was retired in v0.6"
err "profile-secret (workflows-ios) → nothing" "'profile-secret' was retired in v0.6"

echo "== validation: malformed legs =="
# $1 = the "platforms" JSON; prints the product dir.
mkprod() {
  local d; d=$(mktemp -d)
  cat > "$d/x.json" <<JSON
{ "id": "x", "scheme": "X", "bundle-id": "com.example.x", $2
  "platforms": $1,
  "changelog": { "versions": [ { "version": "1.0.0", "items": [] } ] } }
JSON
  echo "$d"
}
chk_invalid() { # 1=name 2=platforms 3=expected message [4=extra top-level keys]
  local d; d=$(mkprod "$2" "${4:-}")
  CAP PRODUCTS_DIR="$d" python3 "$PY" discover
  err "$1" "$3"
  rm -rf "$d"
}
chk_invalid "tvOS is designed in, not yet supported" '{"tvos": {"app-store": {}}}' "platform 'tvos' is not supported yet"
chk_invalid "unknown platform"                       '{"watch": {"app-store": {}}}' "unknown platform 'watch'"
chk_invalid "Ad Hoc is not a Mac channel"            '{"macos": {"ad-hoc": {}}}' "macos ships through app-store or direct, not 'ad-hoc'"
chk_invalid "Direct is not an iPhone channel"        '{"ios": {"direct": {}}}' "ios ships through app-store or ad-hoc, not 'direct'"
chk_invalid "a platform without a channel"           '{"ios": {}}' "platforms.ios names no channel"
chk_invalid "a leg must be an object"                '{"ios": {"app-store": true}}' "must be an object"
chk_invalid "Direct always publishes"                '{"macos": {"direct": {"distribute": false}}}' "a direct leg always publishes"
chk_invalid "S3/Sparkle settings only on Direct"     '{"ios": {"app-store": {"appcast": true}}}' "'appcast' belongs on a direct leg"
chk_invalid "typo in a leg key"                      '{"ios": {"app-store": {"shceme": "X"}}}' "unknown key 'shceme'"
chk_invalid "Direct needs the .app's name"           '{"macos": {"direct": {}}}' "no 'product-name' on the product or the leg"
d=$(mktemp -d); printf '{"id":"x","scheme":"X","bundle-id":"b","changelog":{"versions":[{"version":"1.0.0"}]}}' > "$d/x.json"
CAP PRODUCTS_DIR="$d" python3 "$PY" discover
err "no platforms block" "'platforms' is missing"
rm -rf "$d"

echo "== source-paths and real git: what counts as a change =="
# Real git repos, real `git diff` — ASSUME_CHANGED is deliberately NOT set, so
# these exercise the actual diff path rather than the test stub.
# $1 = dir, $2 = the platforms JSON, $3 = the "source-paths" JSON line (empty to omit it).
mkrepo() {
  mkdir -p "$1/Config/products" "$1/Sources"
  cat > "$1/Config/products/app.json" <<JSON
{ "id": "app", "scheme": "App", "product-name": "App", "bundle-id": "com.example.App",
  "platforms": $2,
  $3
  "changelog": { "versions": [ { "version": "1.0.0",
    "items": [ { "type": "feat", "title": { "en": "x" } } ] } ] } }
JSON
  (
    set -e; cd "$1"
    git init -q . && git config user.email t@t && git config user.name t
    echo 'let a = 1' > Sources/App.swift
    git add -A && git commit -qm init && git tag app-v1.0.0-beta.1
    echo 'let a = 2' > Sources/App.swift   # code-only: product file untouched
    git add -A && git commit -qm "code only"
  ) >/dev/null 2>&1
}
plan_in() { CAP bash -c "cd '$1' && PRODUCTS_DIR='$1/Config/products' GIT_TAGS='app-v1.0.0-beta.1' SINCE='$2' BUILD_NUMBER=x python3 '$PY' plan"; }

DIRECT='{"macos": {"direct": {}}}'
STORE='{"ios": {"app-store": {}}}'
WITH=$(mktemp -d); mkrepo "$WITH" "$DIRECT" '"source-paths": ["Sources/**"],'
plan_in "$WITH" ""
jok "Direct: code-only change WITH source-paths → beta.2" \
  'p = P(); assert p["app"]["release-tag"] == "app-v1.0.0-beta.2", p'
jok "source-paths stays internal — not emitted to the workflow matrix" \
  'assert all("source-paths" not in x and "_source_paths" not in x for x in json.loads(o["legs"]))'
WITHOUT=$(mktemp -d); mkrepo "$WITHOUT" "$DIRECT" ''
plan_in "$WITHOUT" ""
line "Direct: code-only change WITHOUT source-paths → nothing builds" "has-any=false"
{ grep -q '::warning::' /tmp/pd.err && grep -q 'source-paths' /tmp/pd.err; } \
  && pass "the silent skip is a warning naming the fix" \
  || bad "expected a ::warning:: mentioning source-paths; got: $(cat /tmp/pd.err)"

# A product without a Direct leg compares against SINCE (the last successful
# run's commit), never tags.
S_WITH=$(mktemp -d); mkrepo "$S_WITH" "$STORE" '"source-paths": ["Sources/**"],'
PREV=$(git -C "$S_WITH" rev-parse HEAD~1); HEAD_=$(git -C "$S_WITH" rev-parse HEAD)
plan_in "$S_WITH" "$PREV"
jok "store-only: code-only change WITH source-paths → builds, untagged" \
  'p = P(); assert list(p) == ["app"] and p["app"]["release-tag"] == "", p'
plan_in "$S_WITH" "$HEAD_"
line "store-only: nothing of it changed since the last successful run → nothing builds" "has-any=false"
grep -q "the last successful run" /tmp/pd.err && pass "and the warning names the reference" || bad "store-only skip must name the last successful run"
plan_in "$S_WITH" "0000000000000000000000000000000000000000"
jok "store-only: an all-zero reference (a branch's first push) → builds" 'assert list(P()) == ["app"], P()'
plan_in "$S_WITH" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
jok "store-only: a reference git cannot resolve (force-push) → builds rather than ship nothing" 'assert list(P()) == ["app"], P()'
S_WITHOUT=$(mktemp -d); mkrepo "$S_WITHOUT" "$STORE" ''
plan_in "$S_WITHOUT" "$(git -C "$S_WITHOUT" rev-parse HEAD~1)"
line "store-only: code-only change WITHOUT source-paths → nothing builds" "has-any=false"
rm -rf "$WITH" "$WITHOUT" "$S_WITH" "$S_WITHOUT"

echo "== plan-alpha =="
CAP PRODUCTS_DIR="$MIXED" PRODUCT_ID="pro" GIT_TAGS="pro-v2.0.0-alpha.1" BUILD_NUMBER="9" python3 "$PY" plan-alpha
[ $RC -eq 0 ] && pass "exit 0" || bad "plan-alpha exit"
line "Direct product: counted from its alpha tags" "alpha-tag=pro-v2.0.0-alpha.2"
jok "every leg; only the App Store leg is internal-only; Direct carries the alpha version" \
  'l = L(); assert sorted(l) == ["pro-macos-app-store", "pro-macos-direct"], l; assert l["pro-macos-app-store"]["internal-only"] is True and l["pro-macos-direct"]["internal-only"] is False; assert l["pro-macos-direct"]["marketing"] == "2.0.0-alpha.2"; assert l["pro-macos-app-store"]["marketing"] == "2.0.0"'
CAP PRODUCTS_DIR="$UNIVERSAL" GIT_TAGS="" BUILD_NUMBER="9" python3 "$PY" plan-alpha
line "one product: product-id may stay empty" "target-id=game"
line "no Direct leg → no tag" "alpha-tag="
line "the S3/summary label carries the build number instead" "alpha-label=1.0.0-9"
CAP PRODUCTS_DIR="$MIXED" BUILD_NUMBER="9" python3 "$PY" plan-alpha
err "several products: product-id is required" "set product-id"
CAP PRODUCTS_DIR="$MIXED" PRODUCT_ID="nope" python3 "$PY" plan-alpha
err "an unknown product-id is named" "product-id 'nope' matches no product file"
CAP PRODUCTS_DIR="$MIXED" PRODUCT_ID="pro" GIT_TAGS="pro-v2.0.0" python3 "$PY" plan-alpha
err "an alpha of a released version is refused" "already released"
CAP PRODUCTS_DIR="$MIXED" PRODUCT_ID="pro" VERSION_BASE="3.0.0" GIT_TAGS="pro-v2.0.0" BUILD_NUMBER="9" python3 "$PY" plan-alpha
line "version-base starts the next version's alphas" "alpha-tag=pro-v3.0.0-alpha.1"

echo "== profiles.py: token, profile choice, install/cleanup, export options =="
python3 -I "$ROOT/.github/scripts/profiles.py" selftest >/tmp/pf.out 2>&1 \
  && pass "$(cat /tmp/pf.out)" || { echo "  FAIL: profiles.py selftest"; cat /tmp/pf.out; FAIL=1; }

echo "== classify_upload: altool outcome classification =="
# Sourced from the shipped script rather than re-implemented, so this test cannot
# drift from what the publish steps actually run.
source "$ROOT/.github/scripts/classify-upload.sh"
cls() { GOT=$(classify_upload "$2" "$3"); [ "$GOT" = "$4" ] && pass "$1" || { echo "  FAIL: $1 — got '$GOT', want '$4'"; FAIL=1; }; }

cls "clean success → accepted" 0 \
  "UPLOAD SUCCEEDED with no errors
No errors uploading archive at './App.pkg'." accepted
cls "exit 0, quiet output → accepted" 0 "Uploading... done" accepted
# Verbatim from the FrameBison run that reported green while the upload failed.
cls "build-number collision (-19232) → failed" 31 \
  "ERROR: [ContentDelivery.Uploader.7814C25280] The provided entity includes an attribute with a value that has already been used (-19232) The bundle version must be higher than the previously uploaded version: '1'.
ERROR: [altool.main] ExitFailure (31)" failed
cls "true redundant upload (ITMS-90189) → already-present" 31 \
  "ERROR: [altool] Redundant Binary Upload. There already exists a binary upload with build version '42' (ITMS-90189)" already-present
cls "opaque altool error → failed" 1 "ERROR: [altool.main] network unreachable" failed

echo
echo "== wiring: every call passes what its callee declares =="
# actionlint cannot see across `uses:`, so a misspelt or missing input only
# fails at run time — in an app repo. Checked here for every orchestrator and
# every example shell.
if ! command -v yq >/dev/null; then
  echo "  FAIL: yq is needed for the wiring check (brew install yq)"; FAIL=1
else
  python3 - "$ROOT" <<'PYW' || FAIL=1
import glob, json, os, re, subprocess, sys
root = sys.argv[1]
def load(p):
    return json.loads(subprocess.run(["yq", "-o=json", ".", p], capture_output=True, text=True, check=True).stdout)
wf = {os.path.basename(p): load(p) for p in glob.glob(f"{root}/.github/workflows/*.yml")}
callers = list(wf.items()) + [(f"examples/{os.path.basename(p)}", load(p))
                              for p in glob.glob(f"{root}/examples/per-app/*.yml")]
bad, calls = [], 0
for cname, doc in callers:
    for jname, job in (doc.get("jobs") or {}).items():
        m = re.match(r"LeanBytes/workflows-macos/\.github/workflows/([\w.-]+\.yml)@", job.get("uses", ""))
        if not m:
            continue
        calls += 1
        callee = m.group(1)
        if callee not in wf:
            bad.append(f"{cname}:{jname} calls {callee}, which does not exist")
            continue
        wc = (wf[callee].get("on") or {}).get("workflow_call") or {}
        ins, secs = wc.get("inputs") or {}, wc.get("secrets") or {}
        given_in = job.get("with") or {}
        given_sec = job.get("secrets") or {}
        given_sec = {} if given_sec == "inherit" else given_sec
        bad += [f"{cname}:{jname} → {callee}: unknown input '{k}'" for k in given_in if k not in ins]
        bad += [f"{cname}:{jname} → {callee}: required input '{k}' not passed"
                for k, d in ins.items() if (d or {}).get("required") and k not in given_in]
        bad += [f"{cname}:{jname} → {callee}: unknown secret '{k}'" for k in given_sec if k not in secs]
        bad += [f"{cname}:{jname} → {callee}: required secret '{k}' not passed"
                for k, d in secs.items() if (d or {}).get("required") and k not in given_sec]
for b in bad:
    print(f"  FAIL: {b}")
if not bad:
    print(f"  ok  : all {calls} calls pass exactly what their callee declares")
sys.exit(1 if bad else 0)
PYW
fi

echo
echo "== profiles: from App Store Connect, before any app code, nowhere in GitHub =="
grep -rln 'PROV_PROF_' "$W" "$ROOT/examples" \
  && { echo "  FAIL: a PROV_PROF_* secret is still declared or passed — profiles come from App Store Connect"; FAIL=1; } \
  || pass "no PROV_PROF_* secret anywhere"
grep -rq 'PROVISIONING_PROFILE_SPECIFIER=[^$]' "$W" "$ROOT/.github/scripts" \
  && { echo "  FAIL: a literal PROVISIONING_PROFILE_SPECIFIER signs every target with one profile"; FAIL=1; } \
  || pass "no literal PROVISIONING_PROFILE_SPECIFIER (each target looks up its own)"
# Step order: the download must come before Tuist, SwiftPM resolution and the
# pre-build script, so no app code ever runs next to the App Store Connect key.
python3 - "$W" <<'PYO' || FAIL=1
import re, sys
bad = []
for f in ("_build-ios.yml", "_build-mac-store.yml", "_build-mac-direct.yml"):
    names = re.findall(r"^      - name: (.+)$", open(f"{sys.argv[1]}/{f}").read(), re.M)
    if "Download provisioning profiles" not in names:
        bad.append(f"{f}: no 'Download provisioning profiles' step"); continue
    first_app_code = min(i for i, n in enumerate(names)
                         if re.search(r"Tuist|Resolve|Pre-build", n))
    if names.index("Download provisioning profiles") > first_app_code:
        bad.append(f"{f}: profiles are downloaded after app code ran ({names[first_app_code]})")
for b in bad: print(f"  FAIL: {b}")
if not bad: print("  ok  : all three build callees download profiles before any app code runs")
sys.exit(1 if bad else 0)
PYO

echo
echo "== secrets: each reaches only the steps that use it =="
# A secret in a job-level env reaches the app's own pre-build script, SwiftPM
# plugins and the Tuist installer. Per step instead, and only where used.
python3 - "$W" <<'PYS' || FAIL=1
import re, sys
ALLOWED = {
    "ASC_KEY_BASE64": {"Download provisioning profiles", "Notarize"},
    "DEVELOPER_ID_P12_BASE64": {"Set up signing"},
    "APPLE_DISTR_P12_BASE64": {"Verify .p12 envelope (diagnostic)", "Set up keychain"},
    "MAC_DISTR_P12_BASE64": {"Set up keychain"},
}
bad = []
for f in ("_build-ios.yml", "_build-mac-store.yml", "_build-mac-direct.yml"):
    text = open(f"{sys.argv[1]}/{f}").read()
    jobs = text[text.index("\njobs:"):]
    head, _, steps = jobs.partition("    steps:")
    if "secrets." in head:
        bad.append(f"{f}: a secret in the job-level env")
    for block in re.split(r"\n      - name: ", steps)[1:]:
        name = block.splitlines()[0].strip()
        for secret, allowed in ALLOWED.items():
            if f"secrets.{secret}" in block and name not in allowed:
                bad.append(f"{f}: step '{name}' gets {secret}")
for b in bad: print(f"  FAIL: {b}")
if not bad: print("  ok  : certificates and the App Store Connect key reach only their own steps")
sys.exit(1 if bad else 0)
PYS
# Public repos: anyone signed in to GitHub can download a run's artifacts.
for f in _build-ios _build-mac-store _build-mac-direct; do
  n="$(grep -c '^ *retention-days:' "$W/$f.yml")"
  k="$(grep -c 'retention-days: ${{ github.event.repository.private == false && 1 || inputs.artifact-retention-days }}' "$W/$f.yml")"
  [ "$n" = "$k" ] && [ "$n" != "0" ] && pass "$f.yml keeps artifacts one day in a public repo ($k upload(s))" \
    || { echo "  FAIL: $f.yml — $k of $n uploads cap retention for public repos"; FAIL=1; }
done

echo
echo "== signing: every ephemeral keychain disarms its auto-lock =="
# A keychain straight out of `security create-keychain` inherits lock-on-sleep +
# a 300s idle-lock, which fires mid-archive and hangs codesign on an unlock
# prompt no headless runner answers. Every signing path must follow the create
# with `set-keychain-settings` (no -t/-l ⇒ no timeout) and an explicit unlock.
kc() { # name file
  local body; body="$(grep -A 15 'security create-keychain' "$ROOT/$2")"
  grep -q 'security set-keychain-settings' <<<"$body" \
    && grep -q 'security unlock-keychain' <<<"$body" \
    && pass "$1" || { echo "  FAIL: $1 — create-keychain is not followed by set-keychain-settings + unlock-keychain"; FAIL=1; }
  if grep -qE 'set-keychain-settings.*(-[a-z]*[tl])' <<<"$body"; then
    echo "  FAIL: $1 — set-keychain-settings must carry no -t/-l, or the fuse is only lengthened"; FAIL=1
  else
    pass "$1 — no -t/-l, so no timeout at all"
  fi
}
kc "build-direct.sh"       .github/scripts/build-direct.sh
kc "_build-mac-store.yml"  .github/workflows/_build-mac-store.yml
kc "_build-ios.yml"        .github/workflows/_build-ios.yml

echo
echo "== publish gate: a cancelled build must not publish =="
# `!= 'failure'` alone lets a wedged/evicted build job through, shipping half a
# release. 'skipped' stays permitted (a product without a leg of some kind).
for pair in distribute:3 distribute-alpha:3 distribute-release:1; do
  wf="${pair%%:*}"; want="${pair##*:}"
  g="$(grep -c "result != 'cancelled'" "$W/$wf.yml")"
  [ "$g" -eq "$want" ] && pass "$wf.yml excludes cancelled for all $want build job(s)" \
    || { echo "  FAIL: $wf.yml — expected $want \"result != 'cancelled'\" guards, found $g"; FAIL=1; }
done

echo
echo "== runs-on: every input-driven job takes a vars override =="
# The per-app shell's runs-on-* input is the default; a same-named repo Variable
# overrides it with no commit. Unset is '' (falsy), so the input must remain the
# right-hand side of the ||, and the variable must NOT be wrapped in fromJSON —
# it carries a bare label, not JSON.
ro() { # var  file  input-expression
  local got; got="$(grep -F "runs-on: \${{ vars.$1" "$ROOT/$2" || true)"
  [ -n "$got" ] || { echo "  FAIL: $2 — no vars.$1 override on runs-on"; FAIL=1; return; }
  grep -qF "vars.$1 || fromJSON(inputs.$3)" <<<"$got" \
    && pass "$2 ← vars.$1" \
    || { echo "  FAIL: $2 — override must read: vars.$1 || fromJSON(inputs.$3)"; echo "    got:$got"; FAIL=1; }
  grep -qF "fromJSON(vars.$1" <<<"$got" && { echo "  FAIL: $2 — vars.$1 must not be fromJSON'd; it is a bare label"; FAIL=1; } || true
}
# The invariant, not just the known sites: no workflow may hardcode a runner. A
# literal runs-on is a job the caller cannot point anywhere, and if anything
# needs: it the whole pipeline deadlocks — silently, because a job queued for a
# runner that does not exist never goes red. selftest.yml is the one exception
# (this repo has no self-hosted runner at all; see #14).
lit="$(grep -l "^    runs-on: [^$]" "$W"/*.yml 2>/dev/null \
       | xargs -I{} basename {} | grep -vx 'selftest.yml' || true)"
[ -z "$lit" ] && pass "no workflow hardcodes a runner (except selftest.yml)" \
  || { echo "  FAIL: literal runs-on in: $lit — every job must take an input"; FAIL=1; }

ro RUNS_ON_BUILD_MAC_DIRECT .github/workflows/_build-mac-direct.yml runs-on
ro RUNS_ON_BUILD_MAC_STORE  .github/workflows/_build-mac-store.yml  runs-on
ro RUNS_ON_BUILD_IOS        .github/workflows/_build-ios.yml        runs-on
ro RUNS_ON_TEST             .github/workflows/_test.yml             runs-on
ro RUNS_ON_BUILD            .github/workflows/distribute-pr.yml     runs-on-build
ro RUNS_ON_DISCOVER         .github/workflows/distribute-pr.yml     runs-on-discover
for wf in distribute distribute-release distribute-alpha; do
  ro RUNS_ON_PUBLISH ".github/workflows/$wf.yml" runs-on-publish
  ro RUNS_ON_PREPARE ".github/workflows/$wf.yml" runs-on-prepare
done

echo
echo "== changelog: every type the apps render reaches the notes =="
# The apps' What's New views know feat/fix/core/lang/release. CI knew three, so
# six MacPacker releases shipped without their lang items (#17). chore stays a
# silent drop; anything else must be dropped LOUDLY, never silently, and never
# onto stdout — stdout IS the release notes.
CL="$ROOT/.github/scripts/changelog-from-json.sh"
cat > /tmp/cl-types.json <<'JSON'
{"versions":[{"version":"1.0.0","items":[
  {"type":"feat","title":{"en":"F"}},   {"type":"fix","title":{"en":"B"}},
  {"type":"core","title":{"en":"C"}},   {"type":"lang","title":{"en":"L"}},
  {"type":"release","title":{"en":"A"}},{"type":"chore","title":{"en":"Internal"}},
  {"type":"l10n","title":{"en":"Typo"}}
]}]}
JSON
SUM=/tmp/cl-summary.md; : > "$SUM"
OUT="$(CHANGELOG_PATH=/tmp/cl-types.json VERSION=1.0.0 GITHUB_STEP_SUMMARY="$SUM" bash "$CL" 2>/tmp/cl.err)"
for sec in "New Features" "Bug Fixes" "Improvements" "Localization" "Announcements"; do
  grep -qxF "### $sec" <<<"$OUT" && pass "renders ### $sec" \
    || { echo "  FAIL: '### $sec' missing from the notes"; FAIL=1; }
done
grep -q "Internal" <<<"$OUT" && { echo "  FAIL: chore leaked into customer-facing notes"; FAIL=1; } \
  || pass "chore dropped from the notes"
grep -q "chore" /tmp/cl.err && { echo "  FAIL: chore warned about; it is a deliberate silent drop"; FAIL=1; } \
  || pass "chore dropped silently (no warning)"
grep -q "Typo" <<<"$OUT" && { echo "  FAIL: unknown type 'l10n' rendered; it must be dropped"; FAIL=1; } \
  || pass "unknown type dropped from the notes"
grep -q "::warning::.*l10n" /tmp/cl.err && pass "unknown type warned on stderr" \
  || { echo "  FAIL: unknown type 'l10n' dropped silently — the #17 bug"; FAIL=1; }
grep -q "l10n" "$SUM" && pass "unknown type reaches \$GITHUB_STEP_SUMMARY" \
  || { echo "  FAIL: unknown type missing from the step summary"; FAIL=1; }
grep -q "::warning::" <<<"$OUT" && { echo "  FAIL: a warning reached stdout — stdout is the release notes"; FAIL=1; } \
  || pass "warnings never touch stdout"

echo
echo "== timeouts: the build ceilings are callable, not literals =="
# Parameterising the job ceiling alone would be a trap: the Archive step's own
# cap would silently bite first for anyone who raised the job (#18).
for f in _build-mac-direct _build-mac-store _build-ios; do
  b="$W/$f.yml"
  grep -qF 'timeout-minutes: ${{ inputs.job-timeout-minutes }}' "$b" \
    && grep -qF 'timeout-minutes: ${{ inputs.archive-timeout-minutes }}' "$b" \
    && pass "$f.yml: job + archive ceilings both take inputs" \
    || { echo "  FAIL: $f.yml still hardcodes a build or archive timeout"; FAIL=1; }
done
BUILD_CALLS='_build-mac-direct.yml@\|_build-mac-store.yml@\|_build-ios.yml@'
for wf in distribute distribute-release distribute-alpha; do
  b="$W/$wf.yml"
  n="$(grep -c 'job-timeout-minutes: ${{ inputs.build-timeout-minutes }}' "$b" || true)"
  c="$(grep -c "$BUILD_CALLS" "$b" || true)"
  [ "$n" = "$c" ] && [ "$n" != "0" ] && pass "$wf.yml forwards the ceilings to all $c build call(s)" \
    || { echo "  FAIL: $wf.yml forwards to $n of $c build call(s) — an input nothing forwards is unreachable"; FAIL=1; }
done

echo
echo "== distribute-pr: every leg compiles, unconditionally =="
# The PR job must compile what the merge will build: one matrix entry per leg,
# each with that leg's scheme, configuration AND destination. It must also
# compile whether or not tests run — gating the build on run-tests made this an
# 11-second no-op for every app using the `swift` test runner, whose tests never
# open the Xcode project (#21).
PRWF="$W/distribute-pr.yml"
jobblk() { awk -v j="  $1:" '$0==j{f=1;next} f&&/^  [a-z][a-z0-9_-]*:[ ]*$/{f=0} f' "$PRWF"; }
stepblk() { awk -v n="$1" 'index($0,"- name: "n){f=1;next} f&&/^      - name: /{f=0} f'; }
b="$(jobblk compile)"
[ -n "$b" ] || { echo "  FAIL: distribute-pr.yml has no 'compile' job — nothing compiles"; FAIL=1; }
grep -q "needs.discover.outputs.legs" <<<"$b" && grep -q "needs.discover.outputs.has-any == 'true'" <<<"$b" \
  && pass "compile fans out over every leg (gated on has-any)" \
  || { echo "  FAIL: compile must matrix over legs and gate on has-any"; FAIL=1; }
for k in scheme configuration destination; do
  grep -q "matrix.leg.$k" <<<"$b" && pass "compile takes each leg's $k" \
    || { echo "  FAIL: compile must use matrix.leg.$k — another pairing never ships"; FAIL=1; }
done
grep -qE "^ *if:.*run-tests" <<<"$b" \
  && { echo "  FAIL: compile gates a step on run-tests — compiling must not depend on testing (#21)"; FAIL=1; } \
  || pass "compile has no run-tests gate"
c="$(stepblk 'Compile (no signing)' <<<"$b")"
[ -n "$c" ] || { echo "  FAIL: compile has no 'Compile (no signing)' step"; FAIL=1; }
grep -q "^ *if:" <<<"$c" \
  && { echo "  FAIL: the Compile step is conditional — a build that can skip itself is how #21 hid"; FAIL=1; } \
  || pass "the Compile step is unconditional"
grep -q "CODE_SIGNING_ALLOWED=NO" <<<"$c" && ! grep -q "xcodebuild archive" <<<"$c" \
  && pass "compiles unsigned, without archiving" \
  || { echo "  FAIL: compile must build unsigned (fork PRs get no secrets) and must not archive"; FAIL=1; }
for o in legs has-any; do
  grep -q "      $o: \${{ steps.d.outputs.$o }}" "$PRWF" \
    && pass "discover forwards $o" \
    || { echo "  FAIL: discover does not forward $o — the compile has nothing to fan out from"; FAIL=1; }
done

echo
echo "== post-build hook: declared, invoked safely, forwarded everywhere =="
# An app must be able to inspect what it just built. The hook takes the .app on
# every path — never the .pkg or .ipa — so a caller's script needs no
# per-channel branch, and an input nothing forwards is unreachable (#18).
for f in distribute-pr distribute distribute-release distribute-alpha _build-mac-direct _build-mac-store _build-ios; do
  grep -q "^      post-build-script:" "$W/$f.yml" && pass "$f.yml declares post-build-script" \
    || { echo "  FAIL: $f.yml has no post-build-script input"; FAIL=1; }
done
# Each orchestrator must hand it to every build callee it calls.
for wf in distribute distribute-release distribute-alpha; do
  n="$(grep -c 'post-build-script: ${{ inputs.post-build-script }}' "$W/$wf.yml" || true)"
  c="$(grep -c "$BUILD_CALLS" "$W/$wf.yml" || true)"
  [ "$n" = "$c" ] && [ "$n" != "0" ] && pass "$wf.yml forwards it to all $c build call(s)" \
    || { echo "  FAIL: $wf.yml forwards to $n of $c build call(s) — unreachable from an app repo"; FAIL=1; }
done
# The space trap: a store configuration like "Release Store" puts a space in
# BUILT_PRODUCTS_DIR, so an unquoted path passes on one leg and fails on the
# other. Every invocation must quote its argument.
bad="$(grep -rn 'bash "\$POST_BUILD_SCRIPT" [^"]' "$W" || true)"
[ -z "$bad" ] && pass "every invocation quotes the bundle path" \
  || { echo "  FAIL: unquoted post-build argument — breaks on a configuration with a space:"; echo "$bad"; FAIL=1; }
# The callees hand over the .app from the ARCHIVE, not the exported artifact:
# the store callees export a .pkg / .ipa, and the hook contract is a bundle.
for f in _build-mac-store _build-ios; do
  grep -q 'app.xcarchive/Products/Applications' "$W/$f.yml" \
    && pass "$f.yml passes the archived .app" \
    || { echo "  FAIL: $f.yml must pass the .app inside the archive"; FAIL=1; }
done
grep -q 'ARCHIVE/Products/Applications' "$ROOT/.github/scripts/build-direct.sh" \
  && pass "build-direct.sh passes the archived .app" \
  || { echo "  FAIL: build-direct.sh post-build must use the archived .app"; FAIL=1; }
# One phase <-> one step: the script owns the logic, the workflow calls it.
for ph in profiles setup signing archive post-build export notarize staple verify package verify-packages cleanup; do
  grep -q "build-direct.sh $ph\$" "$W/_build-mac-direct.yml" \
    && grep -qE "^  $ph\) +phase_" "$ROOT/.github/scripts/build-direct.sh" \
    || { echo "  FAIL: phase '$ph' is not both a build-direct.sh phase and an _build-mac-direct.yml step"; FAIL=1; }
done
pass "build-direct.sh phases and _build-mac-direct.yml steps stay in lockstep"

echo
echo "== post-build: resolving the product survives a huge settings dump =="
# `awk … exit` behind a PIPE leaves printf writing into a closed reader. Once
# the dump passes the 64 KiB pipe buffer, printf takes SIGPIPE and pipefail
# fails the step — so the hook died on any scheme with more than one target,
# while a single-target scheme passed on output size alone (#28). A here-string
# is a temp file: no reader to disappear.
BIG=/tmp/sbs-big.txt
python3 - "$BIG" <<'PYGEN'
import sys
L = ["    ACTION = build",
     "    BUILT_PRODUCTS_DIR = /Users/x/DerivedData/Build/Products/Release Store",
     "    FULL_PRODUCT_NAME = My App.app"]
L += ["    SETTING_%05d = padding-%s" % (i, "x" * 40) for i in range(3000)]
open(sys.argv[1], "w").write("\n".join(L) + "\n")
PYGEN
sz=$(wc -c < "$BIG" | tr -d ' ')
[ "$sz" -gt 65536 ] && pass "fixture is ${sz}B — past the 64 KiB pipe buffer" \
  || { echo "  FAIL: fixture only ${sz}B, would not reach the buffer limit"; FAIL=1; }

# The extraction exactly as the compile job runs it. Repeated: the pipe form's
# failure is a race (9/10 on a real dump), so pin the fix, not the bug.
extract() {
  set -euo pipefail
  local settings; settings=$(cat "$BIG")
  local d n
  d=$(awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}' <<<"$settings")
  n=$(awk -F' = ' '/^ *FULL_PRODUCT_NAME = /{print $2; exit}' <<<"$settings")
  printf '%s/%s' "$d" "$n"
}
bad=0
for _ in 1 2 3 4 5; do
  GOT=$(extract 2>/dev/null) || { bad=$((bad+1)); continue; }
  [ "$GOT" = "/Users/x/DerivedData/Build/Products/Release Store/My App.app" ] || bad=$((bad+1))
done
[ "$bad" -eq 0 ] && pass "5/5 clean extractions, space in the path preserved" \
  || { echo "  FAIL: $bad/5 extractions failed or returned the wrong path"; FAIL=1; }

grep -q "printf '%s" "$PRWF" \
  && { echo "  FAIL: a printf|awk pipe is back in distribute-pr.yml — SIGPIPE on any multi-target scheme (#28)"; FAIL=1; } \
  || pass "no printf|awk pipe remains"
n=$(grep -c "awk -F' = ' '/^ \*BUILT_PRODUCTS_DIR = /{print \$2; exit}' <<<" "$PRWF" || true)
[ "$n" = "1" ] && pass "the compile job uses the here-string form" \
  || { echo "  FAIL: expected 1 here-string extraction, found $n"; FAIL=1; }
n=$(grep -c "xcodebuild -showBuildSettings failed for scheme" "$PRWF" || true)
[ "$n" = "1" ] && pass "a showBuildSettings failure is surfaced instead of dying silently" \
  || { echo "  FAIL: showBuildSettings stderr is discarded"; FAIL=1; }
rm -f "$BIG"

echo
echo "== actions: nothing left on the deprecated Node 20 runtime =="
# GitHub is forcing Node 20 actions onto Node 24 and will stop doing so. The
# cache SUB-actions lagged at v4 (node20) while actions/cache itself was already
# v5 (node24) in the same files — mixed majors, and only the sub-actions warned.
# A minimum per action, not an exact pin, so this does not go stale on every
# upstream release; an UNKNOWN action fails too, forcing a deliberate choice.
python3 - "$ROOT" <<'PYCHK' || FAIL=1
import glob, os, re, sys
MIN = {            # first major running on node24
    "actions/checkout": 6,
    "actions/cache": 5,
    "actions/cache/restore": 5,
    "actions/cache/save": 5,
    "actions/upload-artifact": 7,
    "actions/download-artifact": 8,
}
bad = []
seen = set()
for f in sorted(glob.glob(os.path.join(sys.argv[1], ".github/workflows/*.yml"))):
    for n, line in enumerate(open(f), 1):
        m = re.search(r"uses:\s*(actions/[\w./-]+)@v(\d+)", line)
        if not m:
            continue
        name, major = m.group(1), int(m.group(2))
        seen.add(name)
        where = f"{os.path.basename(f)}:{n}"
        if name not in MIN:
            bad.append(f"{where}  {name}@v{major} is not in the known-good table — "
                       f"check its runtime and add a minimum")
        elif major < MIN[name]:
            bad.append(f"{where}  {name}@v{major} runs on node20; needs >= v{MIN[name]}")
for b in bad:
    print(f"  FAIL: {b}")
if not bad:
    print(f"  ok  : all {len(seen)} distinct actions are on a node24 major")
sys.exit(1 if bad else 0)
PYCHK

echo
echo "== shared scripts: checked out at the called workflow's own commit =="
# `github.job_workflow_sha` does not exist: it came out empty, actions/checkout
# took the default branch, and every pinned caller ran main's scripts (#34).
python3 - "$ROOT/.github/workflows" <<'PYREF' || FAIL=1
import glob, os, re, sys
WANT = "${{ job.workflow_sha || 'job.workflow_sha-is-empty' }}"
bad, n = [], 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.yml"))):
    for step in re.split(r"\n(?=\s*- )", open(f).read()):
        if "repository: LeanBytes/workflows-macos" not in step:
            continue
        n += 1
        m = re.search(r"^\s*ref:\s*(.+?)\s*$", step, re.M)
        if not m or m.group(1) != WANT:
            bad.append(f"{os.path.basename(f)}: shared scripts checked out at "
                       f"{m.group(1) if m else 'no ref, i.e. the default branch'}")
if not n:
    bad.append("no shared-script checkout found")
for b in bad:
    print(f"  FAIL: {b}")
if not bad:
    print(f"  ok  : all {n} shared-script checkouts use the called workflow's own commit and fail when it is empty")
sys.exit(1 if bad else 0)
PYREF

echo
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED ✅" || { echo "SOME TESTS FAILED ❌"; exit 1; }
