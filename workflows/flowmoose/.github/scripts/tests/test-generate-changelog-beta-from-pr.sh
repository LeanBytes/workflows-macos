#!/usr/bin/env bash
#
# Unit tests for the new PR_TITLE/PR_NUMBER beta-mode path in
# .github/scripts/generate-changelog.sh.
#
# Verifies that:
#   * Beta + PR_TITLE + PR_NUMBER → one entry built from them, regardless
#     of git-log content.
#   * Beta without PR_TITLE/PR_NUMBER → falls back to the legacy
#     HEAD~1..HEAD git-log walk.
#   * Stable + PR_TITLE/PR_NUMBER → ignores them, uses git-log walk
#     (PR_TITLE/PR_NUMBER are beta-only).

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
GEN_SCRIPT="$REPO_ROOT/.github/scripts/generate-changelog.sh"

TMPDIR=$(mktemp -d)
ORIG_DIR=$(pwd)
cleanup() {
  cd "$ORIG_DIR" 2>/dev/null || true
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

PASS=0
FAIL=0

assert_eq() {
  local actual="$1" expected="$2" name="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "    expected: '$expected'"
    echo "    actual:   '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

# Set up a repo with two commits — first plain, second a squash-merge style
# title with a (#NN) suffix. This lets us verify both paths.
setup_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cd "$dir"
  git init -q -b main
  git config user.email "test@example.com"
  git config user.name "Test User"
  git commit --allow-empty -q -m "initial commit"
  git commit --allow-empty -q -m "LB-100 First real PR (#42)"
}

write_seed() {
  local path="$1"
  cat >"$path" <<'EOF'
{
  "product": "FlowMoose",
  "generated_at": "",
  "versions": []
}
EOF
}

read_field() {
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
versions = d.get('versions') or []
if not versions:
    print('')
elif sys.argv[2] == '__entries_count__':
    print(len(versions[0].get('entries') or []))
else:
    entries = versions[0].get('entries') or []
    if not entries:
        print('')
    else:
        print(entries[0].get(sys.argv[2], ''))
" "$1" "$2"
}

############################################################################
echo "Test 1: beta + PR_TITLE + PR_NUMBER → one entry from them"
############################################################################
setup_repo "$TMPDIR/repo1"
write_seed "$TMPDIR/in.json"
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out.json" \
VERSION="1.0.2" \
BUILD_NUMBER="260508120000" \
CHANNEL="beta" \
PRODUCT_NAME="FlowMoose" \
PR_TITLE="Generate changelog for update dialog (LB-397)" \
PR_NUMBER="80" \
RELEASED_AT="2026-05-08T12:00:00Z" \
"$GEN_SCRIPT" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
assert_eq "$(read_field "$TMPDIR/out.json" __entries_count__)" "1" "exactly one entry emitted"
assert_eq "$(read_field "$TMPDIR/out.json" title)" "Generate changelog for update dialog (LB-397)" "title strips trailing (#NN) but keeps (LB-NNN)"
assert_eq "$(read_field "$TMPDIR/out.json" pr)" "80" "pr matches PR_NUMBER"

############################################################################
echo "Test 2: beta + PR_TITLE with trailing (#NN) → suffix stripped"
############################################################################
setup_repo "$TMPDIR/repo2"
write_seed "$TMPDIR/in.json"
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out.json" \
VERSION="1.0.2" \
BUILD_NUMBER="260508120001" \
CHANNEL="beta" \
PRODUCT_NAME="FlowMoose" \
PR_TITLE="Some manual title (LB-200) (#99)" \
PR_NUMBER="99" \
RELEASED_AT="2026-05-08T12:00:01Z" \
"$GEN_SCRIPT" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
assert_eq "$(read_field "$TMPDIR/out.json" title)" "Some manual title (LB-200)" "trailing (#NN) stripped from PR_TITLE"

############################################################################
echo "Test 3: beta WITHOUT PR_TITLE/PR_NUMBER → legacy git-log walk"
############################################################################
setup_repo "$TMPDIR/repo3"
write_seed "$TMPDIR/in.json"
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out.json" \
VERSION="1.0.2" \
BUILD_NUMBER="260508120002" \
CHANNEL="beta" \
PRODUCT_NAME="FlowMoose" \
RELEASED_AT="2026-05-08T12:00:02Z" \
"$GEN_SCRIPT" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
# HEAD~1..HEAD covers commit "LB-100 First real PR (#42)" — has (#NN) suffix, so it counts.
assert_eq "$(read_field "$TMPDIR/out.json" __entries_count__)" "1" "git-log path emits 1 entry from (#42) commit"
assert_eq "$(read_field "$TMPDIR/out.json" title)" "LB-100 First real PR" "git-log path strips (#42) suffix"
assert_eq "$(read_field "$TMPDIR/out.json" pr)" "42" "pr from (#42) suffix"

############################################################################
echo "Test 4: stable + PR_TITLE/PR_NUMBER → ignored, uses git-log walk"
############################################################################
setup_repo "$TMPDIR/repo4"
# stable mode requires no prior v*.*.* tag for the simplest path; range is empty
write_seed "$TMPDIR/in.json"
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out.json" \
VERSION="1.0.0" \
BUILD_NUMBER="260508120003" \
CHANNEL="stable" \
PRODUCT_NAME="FlowMoose" \
PR_TITLE="Should be ignored (LB-999)" \
PR_NUMBER="999" \
RELEASED_AT="2026-05-08T12:00:03Z" \
"$GEN_SCRIPT" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
# No prior stable tag → range empty → 0 entries (PR_TITLE/PR_NUMBER ignored on stable).
assert_eq "$(read_field "$TMPDIR/out.json" __entries_count__)" "0" "stable ignores PR_TITLE/PR_NUMBER"

############################################################################
echo "Test 5: beta + PR_NUMBER non-integer → fallback to git-log"
############################################################################
setup_repo "$TMPDIR/repo5"
write_seed "$TMPDIR/in.json"
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out.json" \
VERSION="1.0.2" \
BUILD_NUMBER="260508120005" \
CHANNEL="beta" \
PRODUCT_NAME="FlowMoose" \
PR_TITLE="Nice title (LB-500)" \
PR_NUMBER="not-an-int" \
RELEASED_AT="2026-05-08T12:00:05Z" \
"$GEN_SCRIPT" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
assert_eq "$(read_field "$TMPDIR/out.json" pr)" "42" "non-integer PR_NUMBER falls back to git-log entry"

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "FAILED: $PASS passed, $FAIL failed"
  exit 1
fi
echo "OK: all $PASS assertions passed"
