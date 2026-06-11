#!/usr/bin/env python3
"""File a Jira issue when the test workflow (run-tests.sh) reports failing tests.

Reads run-tests.sh's `test-report.json`. The Jira mechanics (create + active-sprint placement, HTTP
Basic auth, REST v2 plain-string description) live in the shared `jira_client` module; this script
just builds the test-failure summary/description. The ticket lands in the board's current active
sprint. Pure stdlib.

Env: JIRA_BASE_URL, JIRA_PROJECT_KEY, JIRA_USER_EMAIL, JIRA_API_TOKEN, JIRA_ISSUE_TYPE (opt),
JIRA_BOARD_ID (opt), COMMIT_SHA, SHORT_SHA, RUN_URL.

Expected test-report.json (written by run-tests.sh):
  {"ok": false, "app": "MyApp",
   "runners": [{"runner": "swift", "ok": false, "target": "Core (package)",
                "failed_tests": ["…"], "failed_count": 1, "coverage_pct": 78.5}, …],
   "coverage_pct": 78.5, "log_tail": "…"}
"""

import argparse
import json
import sys

import jira_client

LABEL = "auto-test-failure"


def build_description(report, commit_sha, short_sha, run_url):
    app = report.get("app") or "the app"
    runners = report.get("runners") or []
    lines = [
        "The test workflow found failing tests in %s." % app,
        "",
        "Suspect commit: %s (%s)" % (short_sha or "?", commit_sha or "?"),
        "Workflow run: %s" % (run_url or "(unknown)"),
        "",
        "Results by runner:",
    ]
    for r in runners:
        status = "ok" if r.get("ok") else "FAILED"
        target = r.get("target") or r.get("runner")
        line = "- %s [%s]: %s" % (r.get("runner"), target, status)
        if r.get("failed_count"):
            line += " — %d failing" % r["failed_count"]
        if r.get("coverage_pct") is not None:
            line += " — coverage %.1f%%" % r["coverage_pct"]
        lines.append(line)
        for name in (r.get("failed_tests") or [])[:50]:
            lines.append("    • %s" % name)
    if report.get("log_tail"):
        lines += ["", "Log tail:", report["log_tail"]]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True, help="run-tests.sh test-report.json")
    ap.add_argument("--dry-run", action="store_true",
                    help="Build and print the request without contacting Jira.")
    args = ap.parse_args()

    with open(args.report) as f:
        report = json.load(f)

    app = report.get("app") or "the app"
    commit_sha = jira_client.env("COMMIT_SHA", "")
    short_sha = jira_client.env("SHORT_SHA", "") or (commit_sha[:7] if commit_sha else "")
    run_url = jira_client.env("RUN_URL", "")

    runners = report.get("runners") or []
    total_failed = sum((r.get("failed_count") or 0) for r in runners)
    failed_runners = [r.get("runner") for r in runners if not r.get("ok")]
    summary = "Tests failed: %s failure(s) in %s (%s; commit %s)" % (
        total_failed or "?", app, "+".join(failed_runners) or "test", short_sha or "?")
    description = build_description(report, commit_sha, short_sha, run_url)

    jira_client.file_ticket(summary, description, [LABEL], dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
