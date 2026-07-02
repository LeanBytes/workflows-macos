#!/usr/bin/env bash
#
# Run an app's Swift tests and report pass/fail + coverage. The test core behind `_test.yml` (and
# locally runnable), mirroring build-direct.sh's env-driven shape. Two runners, selectable via
# TEST_RUNNER (`xcodebuild` | `swift` | `both`):
#
#   • swift       — the core internal Swift package (where coverage matters): `swift test
#                   --enable-code-coverage`, in SWIFT_PACKAGE_PATH; derives line coverage % and
#                   optionally gates on COVERAGE_MIN.
#   • xcodebuild  — the app/UI scheme: tuist/swiftpm setup + container auto-detect + unsigned
#                   `xcodebuild test -resultBundlePath …` (runs XCTest + Swift Testing, app-hosted/UI).
#   • both        — swift then xcodebuild; fails if EITHER fails.
#
# Writes `test-report.json` (consumed by create_test_ticket.py) + a Markdown summary to
# $GITHUB_STEP_SUMMARY (visible on the run page, no download). Exit 0 = all passed; non-zero = a
# failing test, a coverage-gate miss, or an infra error.
#
# Env:
#   TEST_RUNNER (default xcodebuild) | CONFIGURATION (default Debug; Release auto-enables
#               ENABLE_TESTABILITY for the test build) | APP_NAME (for the report)
#   xcodebuild: TEST_SCHEME (required for that runner), TEST_PLAN (opt), USE_TUIST, EXTRA_ARGS,
#               PRE_BUILD_SCRIPT (opt)
#   swift:      SWIFT_PACKAGE_PATH (default .), SWIFT_TEST_FILTER (opt), COVERAGE_MIN (opt; "" = report only)

# NOTE: no `set -e` — failures are managed explicitly so the report is always written and both
# runners run under `both`.
set -uo pipefail

TEST_RUNNER="${TEST_RUNNER:-xcodebuild}"
CONFIGURATION="${CONFIGURATION:-Debug}"
USE_TUIST="${USE_TUIST:-false}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
SWIFT_PACKAGE_PATH="${SWIFT_PACKAGE_PATH:-.}"
SWIFT_TEST_FILTER="${SWIFT_TEST_FILTER:-}"
COVERAGE_MIN="${COVERAGE_MIN:-}"
TEST_SCHEME="${TEST_SCHEME:-}"
APP_NAME="${APP_NAME:-${TEST_SCHEME:-the app}}"

WORK="$PWD"

SWIFT_DID_RUN=0; SWIFT_RC=0; SWIFT_COV=""
XC_DID_RUN=0;    XC_RC=0

banner() { echo ""; echo "═══ $* ═══"; }

run_swift() {
  banner "swift test  (package: $SWIFT_PACKAGE_PATH)"
  SWIFT_DID_RUN=1
  local filter_args=()
  [ -n "$SWIFT_TEST_FILTER" ] && filter_args=(--filter "$SWIFT_TEST_FILTER")
  ( cd "$SWIFT_PACKAGE_PATH" && swift test --enable-code-coverage ${filter_args[@]+"${filter_args[@]}"} ) \
    2>&1 | tee "$WORK/swift-test.log"
  SWIFT_RC=${PIPESTATUS[0]}

  # Coverage % from llvm-cov's export JSON (path printed by --show-codecov-path).
  local cov_path
  cov_path=$( cd "$SWIFT_PACKAGE_PATH" && swift test --show-codecov-path 2>/dev/null )
  if [ -n "$cov_path" ] && [ -f "$cov_path" ]; then
    cp "$cov_path" "$WORK/swift-coverage.json" 2>/dev/null
    SWIFT_COV=$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); print(round(d["data"][0]["totals"]["lines"]["percent"],1))
except Exception: pass' "$cov_path")
    echo "swift line coverage: ${SWIFT_COV:-unknown}%"
  fi
}

run_xcodebuild() {
  banner "xcodebuild test  (scheme: $TEST_SCHEME, config: $CONFIGURATION)"
  : "${TEST_SCHEME:?TEST_SCHEME is required for the xcodebuild runner}"
  XC_DID_RUN=1

  if [ "$USE_TUIST" = "true" ]; then
    # Tuist via mise — the `brew tap tuist/tuist` cask is broken upstream (invalid
    # `conflicts_with formula:` stanza). mise is installed with its official
    # one-liner into ~/.local/bin (not on PATH by default → we prepend it); a
    # committed mise.toml pin is honored, else latest. `mise exec` runs Tuist
    # without it being on PATH. Whole sequence is managed (no `set -e`) → XC_RC=70.
    export PATH="$HOME/.local/bin:$PATH"
    if ! {
      { command -v mise >/dev/null 2>&1 || curl https://mise.run | sh; } &&
      mise install &&
      { mise exec -- tuist --version >/dev/null 2>&1 || mise use tuist@latest; } &&
      mise exec -- tuist install &&
      mise exec -- tuist generate --no-open
    }; then
      echo "::error::Tuist setup failed"; XC_RC=70; return
    fi
  fi
  if [ -n "${PRE_BUILD_SCRIPT:-}" ]; then
    bash "$PRE_BUILD_SCRIPT" || { echo "::error::pre-build script failed"; XC_RC=71; return; }
  fi

  local container=()
  shopt -s nullglob
  local ws=( *.xcworkspace ) proj=( *.xcodeproj )
  if [ "${#ws[@]}" -eq 1 ]; then container=(-workspace "${ws[0]}")
  elif [ "${#proj[@]}" -eq 1 ]; then container=(-project "${proj[0]}"); fi
  shopt -u nullglob

  local plan_args=()
  [ -n "${TEST_PLAN:-}" ] && plan_args=(-testPlan "$TEST_PLAN")

  # Debug enables testability by default; Release does not, so `@testable import` would
  # fail to compile. When testing in Release (the opt-in escape hatch), enable it for the
  # test build ONLY — the shipped archive is a separate xcodebuild run, so it's unaffected.
  local testability_args=()
  [ "$CONFIGURATION" = "Release" ] && testability_args=(ENABLE_TESTABILITY=YES)

  rm -rf "$WORK/test-results.xcresult"
  # EXTRA_ARGS intentionally unquoted (word-split into build settings).
  xcodebuild test \
    ${container[@]+"${container[@]}"} \
    -scheme "$TEST_SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -resultBundlePath "$WORK/test-results.xcresult" \
    ${plan_args[@]+"${plan_args[@]}"} \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    ${testability_args[@]+"${testability_args[@]}"} \
    $EXTRA_ARGS 2>&1 | tee "$WORK/xcodebuild-test.log"
  XC_RC=${PIPESTATUS[0]}
}

case "$TEST_RUNNER" in
  swift)      run_swift ;;
  xcodebuild) run_xcodebuild ;;
  both)       run_swift; run_xcodebuild ;;
  *) echo "::error::TEST_RUNNER must be xcodebuild|swift|both (got '$TEST_RUNNER')"; exit 2 ;;
esac

# ── Assemble test-report.json + the run-page summary, and decide the verdict ──
export SWIFT_DID_RUN SWIFT_RC SWIFT_COV XC_DID_RUN XC_RC APP_NAME TEST_SCHEME SWIFT_PACKAGE_PATH COVERAGE_MIN
python3 - "$WORK" <<'PY'
import json, os, re, sys
work = sys.argv[1]

def tail(path, n=40):
    try:
        return "".join(open(path, errors="replace").readlines()[-n:])
    except OSError:
        return ""

def failed_tests(path):
    try:
        text = open(path, errors="replace").read()
    except OSError:
        return []
    names = re.findall(r"Test Case '(-\[[^\]]+\])' failed", text)        # XCTest
    names += re.findall(r'Test "([^"]+)" (?:failed|recorded an issue)', text)  # Swift Testing
    seen, out = set(), []
    for n in names:
        if n not in seen:
            seen.add(n); out.append(n)
    return out

def envb(n): return os.environ.get(n) == "1"
def envi(n):
    try: return int(os.environ.get(n, "0"))
    except ValueError: return 0

runners, overall_ok, cov = [], True, None

if envb("SWIFT_DID_RUN"):
    rc = envi("SWIFT_RC"); ok = rc == 0
    failed = failed_tests(os.path.join(work, "swift-test.log"))
    cs = os.environ.get("SWIFT_COV", ""); cov = float(cs) if cs else None
    overall_ok = overall_ok and ok
    runners.append({"runner": "swift", "ok": ok,
                    "target": "%s (package)" % os.environ.get("SWIFT_PACKAGE_PATH", "."),
                    "failed_tests": failed, "failed_count": len(failed) or (0 if ok else 1),
                    "coverage_pct": cov, "rc": rc})

if envb("XC_DID_RUN"):
    rc = envi("XC_RC"); ok = rc == 0
    failed = failed_tests(os.path.join(work, "xcodebuild-test.log"))
    overall_ok = overall_ok and ok
    runners.append({"runner": "xcodebuild", "ok": ok,
                    "target": "%s (scheme)" % os.environ.get("TEST_SCHEME", "?"),
                    "failed_tests": failed, "failed_count": len(failed) or (0 if ok else 1), "rc": rc})

gate_msg = ""
cmin_s = os.environ.get("COVERAGE_MIN", "")
if cmin_s and cov is not None:
    try:
        if cov < float(cmin_s):
            overall_ok = False
            gate_msg = "Coverage %.1f%% is below the required %s%%." % (cov, cmin_s)
            print("::error::%s" % gate_msg)
    except ValueError:
        pass

log_tail = ""
for r in runners:
    if not r["ok"]:
        log_tail = tail(os.path.join(work, "%s-test.log" % r["runner"])); break

report = {"ok": overall_ok, "app": os.environ.get("APP_NAME", "the app"),
          "runners": runners, "coverage_pct": cov, "log_tail": log_tail}
with open(os.path.join(work, "test-report.json"), "w") as f:
    json.dump(report, f, indent=2)

summary = os.environ.get("GITHUB_STEP_SUMMARY", "")
def w(s):
    if summary:
        with open(summary, "a") as f: f.write(s + "\n")
    print(s)

w("## Test results — %s" % ("✅ passed" if overall_ok else "❌ failed"))
w("")
w("| Runner | Target | Result | Failing | Coverage |")
w("|---|---|---|---|---|")
for r in runners:
    covcol = ("%.1f%%" % r["coverage_pct"]) if r.get("coverage_pct") is not None else "—"
    w("| `%s` | %s | %s | %s | %s |" % (r["runner"], r["target"],
      "✅" if r["ok"] else "❌", (r["failed_count"] if not r["ok"] else 0), covcol))
if gate_msg:
    w(""); w("> ⚠️ %s" % gate_msg)
for r in runners:
    if not r["ok"] and r["failed_tests"]:
        w(""); w("**Failed in `%s`:**" % r["runner"])
        for n in r["failed_tests"][:50]:
            w("- `%s`" % n)

sys.exit(0 if overall_ok else 1)
PY
