#!/usr/bin/env bash
# Offline unit tests for .github/scripts/products.py — no git repo, no network.
# Git is stubbed via GIT_TAGS / ASSUME_CHANGED; the timestamp via BUILD_NUMBER.
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
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1 companion-v1.3.0-beta.1" ASSUME_CHANGED="main" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "only main → beta.2; companion unchanged → skipped" \
  'b=json.loads(o["beta-products"]); assert [x["id"] for x in b]==["main"], b; assert b[0]["release-tag"]=="main-v2.14.0-beta.2"'

echo "== plan-beta: main released → only companion cuts =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "only companion → beta.1" \
  'b=json.loads(o["beta-products"]); assert [x["id"] for x in b]==["companion"], b; assert b[0]["release-tag"]=="companion-v1.3.0-beta.1"'

echo "== force-beta: ASSUME_CHANGED overrides \"nothing changed\", not \"already shipped\" =="
# Backs the orchestrator's force-beta checkbox. `*` = every product; a list
# names them. Empty MUST count as unset, or the off position of the switch
# would silently stop every beta on every normal push (#25).
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1 companion-v1.3.0-beta.1" ASSUME_CHANGED="*" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "'*' forces every product despite no change" \
  'b=json.loads(o["beta-products"]); assert sorted(x["id"] for x in b)==["companion","main"], b'

# Empty must behave EXACTLY like unset, whatever git then says — that is the
# invariant, and it holds without depending on this repo's tag state.
E=$(PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1" ASSUME_CHANGED="" BUILD_NUMBER="x" python3 "$PY" plan-beta 2>/dev/null)
U=$(PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1"                     BUILD_NUMBER="x" python3 "$PY" plan-beta 2>/dev/null)
[ "$E" = "$U" ] && pass "empty ASSUME_CHANGED behaves exactly like unset" \
  || { echo "  FAIL: ASSUME_CHANGED='' differs from unset — the off position of force-beta"; FAIL=1; }

CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0 companion-v1.3.0" ASSUME_CHANGED="*" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "a released version is NOT forced — gate (a) still stands" \
  'assert o["has-any"]=="false", o'
grep -q "force-beta was set, but" /tmp/pd.err \
  && pass "forcing a released version warns loudly instead of going quietly green" \
  || { echo "  FAIL: forcing an already-released version must ::warning::, not ::notice::"; FAIL=1; }

# The wiring: `*` when the box is ticked, "" when it is not — never a value that
# products.py would read as "nothing changed".
BWF="$ROOT/.github/workflows/distribute-beta.yml"
grep -q "force-beta:" "$BWF" && pass "distribute-beta.yml declares force-beta" \
  || { echo "  FAIL: distribute-beta.yml has no force-beta input"; FAIL=1; }
grep -qF "ASSUME_CHANGED: \${{ inputs.force-beta && '*' || '' }}" "$BWF" \
  && pass "force-beta wires to ASSUME_CHANGED ('*' on, '' off)" \
  || { echo "  FAIL: distribute-beta.yml must set ASSUME_CHANGED from force-beta"; FAIL=1; }
grep -rq "CHANGED_PRODUCTS" "$ROOT/.github" \
  && { echo "  FAIL: CHANGED_PRODUCTS still referenced — it was renamed to ASSUME_CHANGED"; FAIL=1; } \
  || pass "no stale CHANGED_PRODUCTS references"

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
# Real git repos, real `git diff` — ASSUME_CHANGED is deliberately NOT set, so
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
for f in _build-direct _build-app-store; do
  b="$ROOT/.github/workflows/$f.yml"
  grep -qF 'timeout-minutes: ${{ inputs.job-timeout-minutes }}' "$b" \
    && grep -qF 'timeout-minutes: ${{ inputs.archive-timeout-minutes }}' "$b" \
    && pass "$f.yml: job + archive ceilings both take inputs" \
    || { echo "  FAIL: $f.yml still hardcodes a build or archive timeout"; FAIL=1; }
done
for wf in distribute-beta distribute-release distribute-alpha; do
  b="$ROOT/.github/workflows/$wf.yml"
  n="$(grep -c 'job-timeout-minutes: ${{ inputs.build-timeout-minutes }}' "$b" || true)"
  c="$(grep -c '_build-direct.yml@\|_build-app-store.yml@' "$b" || true)"
  [ "$n" = "$c" ] && [ "$n" != "0" ] && pass "$wf.yml forwards the ceilings to all $c build call(s)" \
    || { echo "  FAIL: $wf.yml forwards to $n of $c build call(s) — an input nothing forwards is unreachable"; FAIL=1; }
done

echo
echo "== distribute-pr: every enabled channel compiles, unconditionally =="
# The PR job must compile what the merge will build: one leg per channel, each
# with that channel's scheme AND configuration. It must also compile whether or
# not tests run — gating the build on run-tests made this an 11-second no-op for
# every app using the `swift` test runner, whose tests never open the Xcode
# project (#21).
PRWF="$ROOT/.github/workflows/distribute-pr.yml"
jobblk() { awk -v j="  $1:" '$0==j{f=1;next} f&&/^  [a-z][a-z0-9_-]*:[ ]*$/{f=0} f' "$PRWF"; }
stepblk() { awk -v n="$1" 'index($0,"- name: "n){f=1;next} f&&/^      - name: /{f=0} f'; }

# (job, subset, has-flag, scheme key, configuration input)
chk_leg() { # 1=job 2=subset 3=has 4=scheme-key 5=config
  local b; b="$(jobblk "$1")"
  [ -n "$b" ] || { echo "  FAIL: distribute-pr.yml has no '$1' job — that channel never compiles"; FAIL=1; return; }
  grep -q "needs.discover.outputs.$2" <<<"$b" && grep -q "needs.discover.outputs.$3 == 'true'" <<<"$b" \
    && pass "$1 fans out over $2 (gated on $3)" \
    || { echo "  FAIL: $1 must matrix over $2 and gate on $3"; FAIL=1; }
  grep -q "matrix.product.$4" <<<"$b" && grep -q "inputs.$5" <<<"$b" \
    && pass "$1 builds $4 with $5" \
    || { echo "  FAIL: $1 must pair scheme '$4' with configuration '$5' — the other pairing never ships"; FAIL=1; }
  grep -qE "^ *if:.*run-tests" <<<"$b" \
    && { echo "  FAIL: $1 gates a step on run-tests — compiling must not depend on testing (#21)"; FAIL=1; } \
    || pass "$1 has no run-tests gate"
  local c; c="$(stepblk 'Compile (no signing)' <<<"$b")"
  [ -n "$c" ] || { echo "  FAIL: $1 has no 'Compile (no signing)' step"; FAIL=1; return; }
  grep -q "^ *if:" <<<"$c" \
    && { echo "  FAIL: $1's Compile step is conditional — a build that can skip itself is how #21 hid"; FAIL=1; } \
    || pass "$1's Compile step is unconditional"
  grep -q "CODE_SIGNING_ALLOWED=NO" <<<"$c" && ! grep -q "xcodebuild archive" <<<"$c" \
    && pass "$1 compiles unsigned, without archiving" \
    || { echo "  FAIL: $1 must build unsigned (fork PRs get no secrets) and must not archive"; FAIL=1; }
}
chk_leg verify-direct direct-products has-direct scheme       configuration-direct
chk_leg verify-store  store-products  has-store  scheme-store configuration-app-store

for o in direct-products store-products has-direct has-store; do
  grep -q "      $o: \${{ steps.d.outputs.$o }}" "$PRWF" \
    && pass "discover forwards $o" \
    || { echo "  FAIL: discover does not forward $o — the legs have nothing to fan out from"; FAIL=1; }
done

echo
echo "== post-build hook: declared, invoked safely, forwarded everywhere =="
# An app must be able to inspect what it just built. The hook takes the .app on
# every path — never the .pkg — so a caller's script needs no per-channel
# branch, and an input nothing forwards is unreachable (the #18 lesson).
W="$ROOT/.github/workflows"
for f in distribute-pr distribute-beta distribute-release distribute-alpha _build-direct _build-app-store; do
  grep -q "^      post-build-script:" "$W/$f.yml" && pass "$f.yml declares post-build-script" \
    || { echo "  FAIL: $f.yml has no post-build-script input"; FAIL=1; }
done
# Each orchestrator must hand it to every build callee it calls.
for wf in distribute-beta distribute-release distribute-alpha; do
  n="$(grep -c 'post-build-script: ${{ inputs.post-build-script }}' "$W/$wf.yml" || true)"
  c="$(grep -c '_build-direct.yml@\|_build-app-store.yml@' "$W/$wf.yml" || true)"
  [ "$n" = "$c" ] && [ "$n" != "0" ] && pass "$wf.yml forwards it to all $c build call(s)" \
    || { echo "  FAIL: $wf.yml forwards to $n of $c build call(s) — unreachable from an app repo"; FAIL=1; }
done
# The space trap: a store configuration like "Release Store" puts a space in
# BUILT_PRODUCTS_DIR, so an unquoted path passes on Direct and fails only on the
# store leg. Every invocation must quote its argument.
bad="$(grep -rn 'bash "\$POST_BUILD_SCRIPT" [^"]' "$W" || true)"
[ -z "$bad" ] && pass "every invocation quotes the bundle path" \
  || { echo "  FAIL: unquoted post-build argument — breaks on a configuration with a space:"; echo "$bad"; FAIL=1; }
# The callees hand over the .app from the ARCHIVE, not the exported artifact:
# _build-app-store.yml exports a .pkg, and the hook contract is a bundle.
grep -q 'app.xcarchive/Products/Applications' "$W/_build-app-store.yml" \
  && pass "_build-app-store.yml passes the archived .app, not the .pkg" \
  || { echo "  FAIL: _build-app-store.yml must pass the .app inside the archive"; FAIL=1; }
grep -q 'ARCHIVE/Products/Applications' "$ROOT/.github/scripts/build-direct.sh" \
  && pass "build-direct.sh passes the archived .app" \
  || { echo "  FAIL: build-direct.sh post-build must use the archived .app"; FAIL=1; }
# One phase <-> one step: the script owns the logic, the workflow calls it.
grep -q 'build-direct.sh post-build' "$W/_build-direct.yml" \
  && grep -q 'post-build)       phase_post_build' "$ROOT/.github/scripts/build-direct.sh" \
  && pass "build-direct.sh phase and _build-direct.yml step stay in lockstep" \
  || { echo "  FAIL: post-build must be a build-direct.sh phase invoked by a matching step"; FAIL=1; }

echo
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED ✅" || { echo "SOME TESTS FAILED ❌"; exit 1; }
