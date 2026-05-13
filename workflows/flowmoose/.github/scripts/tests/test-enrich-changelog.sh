#!/usr/bin/env bash
#
# Unit tests for .github/scripts/enrich-changelog-with-jira.sh.
#
# Each test starts a fresh python http.server fixture on a random port,
# runs the enrich script against it, and asserts the resulting CHANGELOG.json.

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
ENRICH_SCRIPT="$REPO_ROOT/.github/scripts/enrich-changelog-with-jira.sh"

if [ ! -x "$ENRICH_SCRIPT" ]; then
  chmod +x "$ENRICH_SCRIPT"
fi

TMPDIR=$(mktemp -d)
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if printf '%s' "$haystack" | grep -q -- "$needle"; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "    looking for: '$needle'"
    echo "    in:          '$haystack'"
    FAIL=$((FAIL + 1))
  fi
}

start_mock_server() {
  local mode="$1"
  PORT=$((20000 + RANDOM % 10000))
  MOCK_BASE_URL="http://127.0.0.1:$PORT"

  python3 - "$mode" "$PORT" >/dev/null 2>&1 <<'PY' &
import http.server
import json
import socketserver
import sys
import time

mode = sys.argv[1]
port = int(sys.argv[2])
state = {"calls": 0}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args, **kwargs):
        pass

    def do_GET(self):
        state["calls"] += 1
        if "/rest/api/3/issue/" not in self.path:
            self.send_response(404)
            self.end_headers()
            return
        key = self.path.split("/rest/api/3/issue/")[1].split("?")[0]

        if mode == "happy":
            payload = {"fields": {"summary": f"Mocked summary for {key}"}}
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif mode == "404":
            self.send_response(404)
            self.end_headers()
        elif mode == "5xx_then_200":
            if state["calls"] == 1:
                self.send_response(503)
                self.end_headers()
            else:
                payload = {"fields": {"summary": f"Recovered summary for {key}"}}
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        elif mode == "401":
            self.send_response(401)
            self.end_headers()
        else:
            self.send_response(500)
            self.end_headers()


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", port), Handler) as httpd:
    httpd.serve_forever()
PY
  SERVER_PID=$!

  # Wait until the port is accepting connections.
  for _ in $(seq 1 100); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "$MOCK_BASE_URL/rest/api/3/issue/probe" 2>/dev/null || echo "000")
    if [ "$code" != "000" ]; then
      return 0
    fi
    sleep 0.05
  done
  echo "FAIL: mock server did not start on port $PORT"
  return 1
}

stop_mock_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

write_input_one_entry() {
  local path="$1" title="$2"
  cat >"$path" <<EOF
{
  "product": "FlowMoose",
  "generated_at": "2026-05-08T00:00:00Z",
  "versions": [
    {
      "version": "1.0.2",
      "build": "260508000000",
      "channel": "beta",
      "released_at": "2026-05-08T00:00:00Z",
      "entries": [
        {
          "title": "$title",
          "pr": 99,
          "sha": "abcd1234",
          "merged_at": "2026-05-08T00:00:00Z"
        }
      ]
    }
  ]
}
EOF
}

write_input_empty_entries() {
  local path="$1"
  cat >"$path" <<EOF
{
  "product": "FlowMoose",
  "generated_at": "2026-05-08T00:00:00Z",
  "versions": [
    {
      "version": "1.0.2",
      "build": "260508000000",
      "channel": "beta",
      "released_at": "2026-05-08T00:00:00Z",
      "entries": []
    }
  ]
}
EOF
}

extract_field() {
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
entries = d['versions'][0].get('entries', [])
if not entries:
    print('')
else:
    print(entries[0].get(sys.argv[2], ''))
" "$1" "$2"
}

############################################################################
echo "Test 1: happy path — 200 returns Jira summary, title is replaced"
############################################################################
start_mock_server happy
write_input_one_entry "$TMPDIR/in.json" "LB-397 Generate changelog (LB-397)"
JIRA_BASE_URL="$MOCK_BASE_URL" \
JIRA_USER_EMAIL="bot@example.com" \
JIRA_API_TOKEN="fake-token" \
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out.json" \
"$ENRICH_SCRIPT" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
assert_eq "$(extract_field "$TMPDIR/out.json" title)" "Mocked summary for LB-397" "title replaced with Jira summary"
assert_eq "$(extract_field "$TMPDIR/out.json" jira_key)" "LB-397" "jira_key set"
assert_eq "$(extract_field "$TMPDIR/out.json" jira_url)" "$MOCK_BASE_URL/browse/LB-397" "jira_url set"
stop_mock_server

############################################################################
echo "Test 2: 404 — title kept, ::warning:: emitted"
############################################################################
start_mock_server 404
write_input_one_entry "$TMPDIR/in.json" "LB-999 Some commit title (LB-999)"
JIRA_BASE_URL="$MOCK_BASE_URL" \
JIRA_USER_EMAIL="bot@example.com" \
JIRA_API_TOKEN="fake-token" \
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out.json" \
"$ENRICH_SCRIPT" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
assert_eq "$(extract_field "$TMPDIR/out.json" title)" "LB-999 Some commit title (LB-999)" "title kept on 404"
assert_eq "$(extract_field "$TMPDIR/out.json" jira_key)" "" "jira_key not set on 404"
assert_contains "$(cat "$TMPDIR/stderr")" "::warning::" "::warning:: emitted on 404"
stop_mock_server

############################################################################
echo "Test 3: 5xx then 200 — retry succeeds, title replaced"
############################################################################
start_mock_server 5xx_then_200
write_input_one_entry "$TMPDIR/in.json" "LB-100 Original title (LB-100)"
JIRA_BASE_URL="$MOCK_BASE_URL" \
JIRA_USER_EMAIL="bot@example.com" \
JIRA_API_TOKEN="fake-token" \
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out.json" \
"$ENRICH_SCRIPT" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
assert_eq "$(extract_field "$TMPDIR/out.json" title)" "Recovered summary for LB-100" "title replaced after retry"
assert_eq "$(extract_field "$TMPDIR/out.json" jira_key)" "LB-100" "jira_key set after retry"
stop_mock_server

############################################################################
echo "Test 4: 401 — title kept, ::error:: emitted"
############################################################################
start_mock_server 401
write_input_one_entry "$TMPDIR/in.json" "LB-200 Bad auth title (LB-200)"
JIRA_BASE_URL="$MOCK_BASE_URL" \
JIRA_USER_EMAIL="bot@example.com" \
JIRA_API_TOKEN="fake-token" \
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out.json" \
"$ENRICH_SCRIPT" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
assert_eq "$(extract_field "$TMPDIR/out.json" title)" "LB-200 Bad auth title (LB-200)" "title kept on 401"
assert_contains "$(cat "$TMPDIR/stderr")" "::error::" "::error:: emitted on 401"
stop_mock_server

############################################################################
echo "Test 5: missing JIRA_API_TOKEN — script no-ops, exit 0, copies input"
############################################################################
write_input_one_entry "$TMPDIR/in.json" "LB-300 Untouched (LB-300)"
JIRA_BASE_URL="http://127.0.0.1:1" \
JIRA_USER_EMAIL="bot@example.com" \
JIRA_API_TOKEN="" \
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out.json" \
"$ENRICH_SCRIPT" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
rc=$?
assert_eq "$rc" "0" "script exits 0 with empty token"
assert_eq "$(extract_field "$TMPDIR/out.json" title)" "LB-300 Untouched (LB-300)" "title unchanged with empty token"
assert_eq "$(extract_field "$TMPDIR/out.json" jira_key)" "" "jira_key not set with empty token"

############################################################################
echo "Test 6: entry has no LB-NNN key — no API call, title unchanged"
############################################################################
start_mock_server happy
write_input_one_entry "$TMPDIR/in.json" "bump version to 1.0.3"
JIRA_BASE_URL="$MOCK_BASE_URL" \
JIRA_USER_EMAIL="bot@example.com" \
JIRA_API_TOKEN="fake-token" \
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out.json" \
"$ENRICH_SCRIPT" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
assert_eq "$(extract_field "$TMPDIR/out.json" title)" "bump version to 1.0.3" "title unchanged when no LB key"
assert_eq "$(extract_field "$TMPDIR/out.json" jira_key)" "" "jira_key not set when no LB key"
stop_mock_server

############################################################################
echo "Test 7: idempotent — running twice produces the same result"
############################################################################
start_mock_server happy
write_input_one_entry "$TMPDIR/in.json" "LB-397 Generate changelog (LB-397)"
JIRA_BASE_URL="$MOCK_BASE_URL" \
JIRA_USER_EMAIL="bot@example.com" \
JIRA_API_TOKEN="fake-token" \
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out1.json" \
"$ENRICH_SCRIPT" >/dev/null 2>&1
JIRA_BASE_URL="$MOCK_BASE_URL" \
JIRA_USER_EMAIL="bot@example.com" \
JIRA_API_TOKEN="fake-token" \
IN_PATH="$TMPDIR/out1.json" \
OUT_PATH="$TMPDIR/out2.json" \
"$ENRICH_SCRIPT" >/dev/null 2>&1
assert_eq "$(extract_field "$TMPDIR/out2.json" title)" "Mocked summary for LB-397" "title stable across re-runs"
assert_eq "$(extract_field "$TMPDIR/out2.json" jira_key)" "LB-397" "jira_key stable across re-runs"
stop_mock_server

############################################################################
echo "Test 8: empty entries[] — script exits 0, no API call"
############################################################################
start_mock_server happy
write_input_empty_entries "$TMPDIR/in.json"
JIRA_BASE_URL="$MOCK_BASE_URL" \
JIRA_USER_EMAIL="bot@example.com" \
JIRA_API_TOKEN="fake-token" \
IN_PATH="$TMPDIR/in.json" \
OUT_PATH="$TMPDIR/out.json" \
"$ENRICH_SCRIPT" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
rc=$?
assert_eq "$rc" "0" "exits 0 with empty entries"
assert_contains "$(cat "$TMPDIR/stdout")" "entries is empty" "logs that entries is empty"
stop_mock_server

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "FAILED: $PASS passed, $FAIL failed"
  exit 1
fi
echo "OK: all $PASS assertions passed"
