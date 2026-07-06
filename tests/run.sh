#!/usr/bin/env bash
# Offline unit tests for .github/scripts/products.py — no git repo, no network.
# Git is stubbed via GIT_TAGS / CHANGED_PRODUCTS; the timestamp via BUILD_NUMBER.
# Run from anywhere:  bash tests/run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/.github/scripts/products.py"
MULTI="$ROOT/tests/fixtures/multi-independent/Config/products"
SINGLE="$ROOT/tests/fixtures/single/Config/products"
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

echo
[ $FAIL -eq 0 ] && echo "ALL products.py TESTS PASSED ✅" || { echo "SOME TESTS FAILED ❌"; exit 1; }
