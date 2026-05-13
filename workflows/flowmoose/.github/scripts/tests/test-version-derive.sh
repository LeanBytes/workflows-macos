#!/usr/bin/env bash
#
# Unit tests for .github/scripts/version-derive.sh.
#
# Each case calls the script with a fixed input and asserts on stdout
# and the exit code. Tests run against the actual repository's tags for
# the snapshot/pr cases (no fixture needed: the repo's history is the
# fixture).

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
DERIVE_SCRIPT="$REPO_ROOT/.github/scripts/version-derive.sh"

if [ ! -x "$DERIVE_SCRIPT" ]; then
  chmod +x "$DERIVE_SCRIPT"
fi

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

assert_matches() {
  local actual="$1" pattern="$2" name="$3"
  if [[ "$actual" =~ $pattern ]]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "    pattern: '$pattern'"
    echo "    actual:  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local actual="$1" expected="$2" name="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (exit $actual != $expected)"
    FAIL=$((FAIL + 1))
  fi
}

echo "test: release v1.0.2 -> 1.0.2"
out=$("$DERIVE_SCRIPT" release v1.0.2)
assert_eq "$out" "1.0.2" "release with bare tag"

echo "test: release refs/tags/v1.2.3 -> 1.2.3"
out=$("$DERIVE_SCRIPT" release refs/tags/v1.2.3)
assert_eq "$out" "1.2.3" "release with fully-qualified ref"

echo "test: release main -> error"
set +e
out=$("$DERIVE_SCRIPT" release main 2>/dev/null)
rc=$?
set -e
assert_exit "$rc" "1" "release with branch name fails"
assert_eq "$out" "" "release with branch name produces no stdout"

echo "test: release v1.0 -> error (incomplete semver)"
set +e
out=$("$DERIVE_SCRIPT" release v1.0 2>/dev/null)
rc=$?
set -e
assert_exit "$rc" "1" "release with two-part version fails"

echo "test: snapshot -> matches semver + git-describe suffix"
out=$("$DERIVE_SCRIPT" snapshot)
# Format: X.Y.Z-N-gSHA where SHA is at least 7 hex chars. --long always
# adds the -N-gSHA suffix, even when HEAD is exactly on a tag.
assert_matches "$out" "^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-g[0-9a-f]{7,}$" "snapshot produces git-describe long format"

echo "test: pr -> matches semver + git-describe suffix"
out=$("$DERIVE_SCRIPT" pr)
assert_matches "$out" "^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-g[0-9a-f]{7,}$" "pr produces git-describe long format"

echo ""
echo "==============================================================="
echo "Result: $PASS passed, $FAIL failed"
echo "==============================================================="

exit $FAIL
