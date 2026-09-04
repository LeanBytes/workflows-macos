#!/usr/bin/env bash
# Offline unit tests for .github/scripts/products.py — no git repo, no network.
# Git is stubbed via GIT_TAGS / CHANGED_PRODUCTS; the timestamp via BUILD_NUMBER.
# Run from anywhere:  bash tests/run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/.github/scripts/products.py"
MULTI="$ROOT/tests/fixtures/multi-independent/Config/products"
SINGLE="$ROOT/tests/fixtures/single/Config/products"
MIXED="$ROOT/tests/fixtures/mixed/Config/products"
DUAL="$ROOT/tests/fixtures/dual-bare/Config/products"
FAIL=0

CAP()  { OUT=$(env "$@" 2>/tmp/pd.err); RC=$?; }
pass() { echo "  ok  : $*"; }
bad()  { echo "  FAIL: $*"; echo "    rc=$RC"; echo "    stdout: $OUT"; echo "    stderr: $(cat /tmp/pd.err)"; FAIL=1; }
line() { grep -qxF "$2" <<<"$OUT" && pass "$1" || bad "$1 — missing line: $2"; }
jok()  { python3 - "$OUT" "$2" <<'PY' && pass "$1" || bad "$1"
import json, sys
o = dict(l.split("=", 1) for l in sys.argv[1].splitlines() if "=" in l)
exec(sys.argv[2])
PY
}

echo "== discover (multi-independent) =="
CAP PRODUCTS_DIR="$MULTI" python3 "$PY" discover
[ $RC -eq 0 ] && pass "exit 0" || bad "discover exit"
line "has-direct=true" "has-direct=true"
line "has-store=true"  "has-store=true"
line "ids sorted glob" "ids=companion main"
jok "products=2, direct=1 (main), store=1 (main; companion is iOS)" \
  'assert len(json.loads(o["products"]))==2; assert [x["id"] for x in json.loads(o["direct-products"])]==["main"]; assert [x["id"] for x in json.loads(o["store-products"])]==["main"]'

echo "== plan-beta: companion released (idle), main mid-dev, no betas yet =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="companion-v1.3.0" BUILD_NUMBER="260704000000" python3 "$PY" plan-beta
[ $RC -eq 0 ] && pass "exit 0" || bad "plan-beta exit"
jok "only main → beta.1 (idle companion skipped)" \
  'b=json.loads(o["beta-products"]); assert [x["id"] for x in b]==["main"], b; assert b[0]["release-tag"]=="main-v2.14.0-beta.1"; assert o["build-number"]=="260704000000"'

echo "== plan-beta: both mid-dev, nothing released → both first beta =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "both → beta.1" \
  'b=json.loads(o["beta-products"]); assert sorted(x["id"] for x in b)==["companion","main"]; assert o["has-any"]=="true"'

echo "== plan-beta: USER SCENARIO push 2 — only main changed =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1 companion-v1.3.0-beta.1" CHANGED_PRODUCTS="main" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "only main → beta.2; companion unchanged → skipped" \
  'b=json.loads(o["beta-products"]); assert [x["id"] for x in b]==["main"], b; assert b[0]["release-tag"]=="main-v2.14.0-beta.2"'

echo "== plan-beta: main released → only companion cuts =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "only companion → beta.1" \
  'b=json.loads(o["beta-products"]); assert [x["id"] for x in b]==["companion"], b; assert b[0]["release-tag"]=="companion-v1.3.0-beta.1"'

echo "== plan-release =="
CAP PRODUCTS_DIR="$MULTI" TAG="main-v2.14.0" BUILD_NUMBER="x" python3 "$PY" plan-release
[ $RC -eq 0 ] && pass "main release exit 0" || bad "main release exit"
line "target-id=main" "target-id=main"
line "version=2.14.0" "version=2.14.0"
line "has-direct=true" "has-direct=true"

CAP PRODUCTS_DIR="$MULTI" TAG="companion-v1.3.0" BUILD_NUMBER="x" python3 "$PY" plan-release
[ $RC -eq 0 ] && pass "companion release exit 0" || bad "companion release exit"
line "target-id=companion" "target-id=companion"
line "companion iOS → no mac direct" "has-direct=false"

for T in "main-v9.9.9" "v2.14.0" "bogus-v1.0.0" "main-v2.14.0-beta.1"; do
  CAP PRODUCTS_DIR="$MULTI" TAG="$T" python3 "$PY" plan-release
  [ $RC -ne 0 ] && pass "reject '$T'" || bad "'$T' should fail (rc=$RC)"
done

echo "== single-product fixture =="
CAP PRODUCTS_DIR="$SINGLE" python3 "$PY" discover
line "single ids" "ids=app"
CAP PRODUCTS_DIR="$SINGLE" GIT_TAGS="" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "app → beta.1" 'b=json.loads(o["beta-products"]); assert b[0]["release-tag"]=="app-v1.0.0-beta.1"'
CAP PRODUCTS_DIR="$SINGLE" TAG="app-v1.0.0" BUILD_NUMBER="x" python3 "$PY" plan-release
line "app release target" "target-id=app"

echo "== mixed: primary (empty id → bare v*) + prefixed pro, both at root =="
CAP PRODUCTS_DIR="$MIXED" python3 "$PY" discover
line "mixed ids (keys from filenames)" "ids=base pro"
CAP PRODUCTS_DIR="$MIXED" GIT_TAGS="" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "base → bare v1.0.0-beta.1; pro → pro-v2.0.0-beta.1" \
  'b={x["id"]:x for x in json.loads(o["beta-products"])}; assert b["base"]["release-tag"]=="v1.0.0-beta.1", b["base"]["release-tag"]; assert b["pro"]["release-tag"]=="pro-v2.0.0-beta.1", b["pro"]["release-tag"]'
jok "changelog-filename default vs override" \
  'b={x["id"]:x for x in json.loads(o["beta-products"])}; assert b["base"]["changelog-filename"]=="Changelog.json"; assert b["pro"]["changelog-filename"]=="Changelog-pro.json"'
jok "per-product devid cert secret carried (base overrides, pro defaults)" \
  'b={x["id"]:x for x in json.loads(o["beta-products"])}; assert b["base"]["devid-cert-secret"]=="DEVELOPER_ID_P12_ALT_BASE64"; assert b["base"]["devid-cert-password-secret"]=="DEVELOPER_ID_PASSWORD_ALT"; assert b["pro"]["devid-cert-secret"]==""'
CAP PRODUCTS_DIR="$MIXED" TAG="v1.0.0" BUILD_NUMBER="x" python3 "$PY" plan-release
line "bare tag → primary" "target-id=base"
CAP PRODUCTS_DIR="$MIXED" TAG="pro-v2.0.0" BUILD_NUMBER="x" python3 "$PY" plan-release
line "prefixed tag → pro" "target-id=pro"
CAP PRODUCTS_DIR="$MIXED" GIT_TAGS="v1.0.0" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "base released (bare v1.0.0) → idle; only pro cuts" \
  'b=[x["id"] for x in json.loads(o["beta-products"])]; assert b==["pro"], b'

echo "== validation: two empty-id products → hard error =="
CAP PRODUCTS_DIR="$DUAL" python3 "$PY" discover
{ [ $RC -ne 0 ] && grep -q "at most one product may omit" /tmp/pd.err; } && pass "dual-bare rejected" || bad "dual-bare should fail with the one-primary error (rc=$RC)"

echo "== source-paths: a code-only change cuts a beta =="
# Real git repos, real `git diff` — CHANGED_PRODUCTS is deliberately NOT set, so
# these exercise the actual diff path rather than the test stub.
# $1 = dir, $2 = the "source-paths" JSON line (empty to omit it).
mkrepo() {
  mkdir -p "$1/Config/products" "$1/Sources"
  cat > "$1/Config/products/app.json" <<JSON
{ "id": "app", "platform": "macos", "scheme": "App", "product-name": "App",
  "bundle-id": "com.example.App", "build-direct": true,
  $2
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
planbeta() { CAP bash -c "cd '$1' && PRODUCTS_DIR='$1/Config/products' GIT_TAGS='app-v1.0.0-beta.1' BUILD_NUMBER=x python3 '$PY' plan-beta"; }

WITH=$(mktemp -d); mkrepo "$WITH" '"source-paths": ["Sources/**"],'
planbeta "$WITH"
jok "code-only change WITH source-paths → cuts beta.2" \
  'b=json.loads(o["beta-products"]); assert [x["id"] for x in b]==["app"], b; assert b[0]["release-tag"]=="app-v1.0.0-beta.2", b[0]["release-tag"]'
jok "source-paths stays internal — not emitted to the workflow matrix" \
  'assert all("source-paths" not in x and "_source_paths" not in x for x in json.loads(o["beta-products"]))'

WITHOUT=$(mktemp -d); mkrepo "$WITHOUT" ''
planbeta "$WITHOUT"
line "code-only change WITHOUT source-paths → nothing cuts" "has-any=false"
{ grep -q '::warning::' /tmp/pd.err && grep -q 'source-paths' /tmp/pd.err; } \
  && pass "the silent skip is now a warning naming the fix" \
  || bad "expected a ::warning:: mentioning source-paths; got: $(cat /tmp/pd.err)"
rm -rf "$WITH" "$WITHOUT"

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
echo "== signing: every ephemeral keychain disarms its auto-lock =="
# A keychain straight out of `security create-keychain` inherits lock-on-sleep +
# a 300s idle-lock, which fires mid-archive and hangs codesign on an unlock
# prompt no headless runner answers. Both signing paths must follow the create
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
kc "build-direct.sh"      .github/scripts/build-direct.sh
kc "_build-app-store.yml" .github/workflows/_build-app-store.yml

echo
echo "== publish gate: a cancelled build must not publish =="
# `!= 'failure'` alone lets a wedged/evicted build job through, shipping a
# half-built beta. 'skipped' stays permitted (single-channel products).
for wf in distribute-beta distribute-release; do
  g="$(grep -c "result != 'cancelled'" "$ROOT/.github/workflows/$wf.yml")"
  [ "$g" -eq 2 ] && pass "$wf.yml excludes cancelled for both channels" \
    || { echo "  FAIL: $wf.yml — expected 2 \"result != 'cancelled'\" guards, found $g"; FAIL=1; }
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
# The invariant, not just the seven known sites: no workflow may hardcode a
# runner. A literal runs-on is a job the caller cannot point anywhere, and if
# anything needs: it the whole pipeline deadlocks — silently, because a job
# queued for a runner that does not exist never goes red. selftest.yml is the
# one exception (this repo has no self-hosted runner at all; see #14).
lit="$(grep -l "^    runs-on: [^$]" "$ROOT"/.github/workflows/*.yml 2>/dev/null \
       | xargs -I{} basename {} | grep -vx 'selftest.yml' || true)"
[ -z "$lit" ] && pass "no workflow hardcodes a runner (except selftest.yml)" \
  || { echo "  FAIL: literal runs-on in: $lit — every job must take an input"; FAIL=1; }

ro RUNS_ON_BUILD_DIRECT .github/workflows/_build-direct.yml    runs-on
ro RUNS_ON_BUILD_STORE  .github/workflows/_build-app-store.yml runs-on
ro RUNS_ON_TEST         .github/workflows/_test.yml            runs-on
ro RUNS_ON_BUILD        .github/workflows/distribute-pr.yml    runs-on-build
for wf in distribute-beta distribute-release distribute-alpha; do
  ro RUNS_ON_PUBLISH ".github/workflows/$wf.yml" runs-on-publish
done
ro RUNS_ON_DISCOVER .github/workflows/distribute-pr.yml runs-on-discover
for wf in distribute-beta distribute-release distribute-alpha; do
  ro RUNS_ON_PREPARE ".github/workflows/$wf.yml" runs-on-prepare
done

echo
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED ✅" || { echo "SOME TESTS FAILED ❌"; exit 1; }
