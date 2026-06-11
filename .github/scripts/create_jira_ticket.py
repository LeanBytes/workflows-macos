#!/usr/bin/env python3
"""File a Jira issue when the memory-watch workflow detects memory growth.

Generic across apps: the app name and all metrics come from the memory_watch.py report JSON
(`report["process"]`, peak, trend, thresholds, samples) — nothing app-specific is hardcoded.

Jira mechanics (create + active-sprint placement, HTTP Basic auth, REST v2 plain-string description)
live in the shared `jira_client` module; this script just builds the leak summary/description. The
ticket lands in the board's current active sprint. Pure stdlib so it runs on a self-hosted runner.

Env: JIRA_BASE_URL, JIRA_PROJECT_KEY, JIRA_USER_EMAIL, JIRA_API_TOKEN, JIRA_ISSUE_TYPE (opt),
JIRA_BOARD_ID (opt), COMMIT_SHA, SHORT_SHA, RUN_URL.
"""

import argparse
import json
import sys

import jira_client

LABEL = "auto-memory-leak"


def build_description(report, app, commit_sha, short_sha, run_url):
    """Plain-text description (v2 takes a string, not ADF)."""
    tripped = (report.get("tripped_metric") or {}).get("kind", "n/a")
    cfg = report.get("config", {})
    lines = [
        "The memory-leak watch detected abnormal memory growth in %s while it ran. A healthy build "
        "stays roughly flat; sustained growth — or crossing the hard cap — indicates a leak." % app,
        "",
        "Verdict: %s" % report.get("reason", ""),
        "",
        "Key metrics:",
        "- Peak RSS: %s MB" % report.get("peak_mb"),
        "- Post-warmup baseline: %s MB" % report.get("baseline_mb"),
        "- Final trend: %s MB/hour" % report.get("final_slope_mb_per_hour"),
        "- Tripped: %s" % tripped,
        "",
        "Suspect commit: %s (%s)" % (short_sha or "?", commit_sha or "?"),
        "Workflow run: %s" % (run_url or "(unknown)"),
        "",
        "Detection thresholds: hard cap %s MB, trend >= %s MB/h with >= %s MB net growth, "
        "warmup %s s, sampling every %s s."
        % (cfg.get("hard_cap_mb"), cfg.get("slope_mb_per_hour"), cfg.get("min_growth_mb"),
           cfg.get("warmup_seconds"), cfg.get("interval_seconds")),
        "",
        "Memory samples (elapsed -> RSS MB):",
    ]
    samples = report.get("samples", [])
    if samples:
        for s in samples:
            lines.append("  %6ds -> %.0f" % (s["elapsed_s"], s["rss_mb"]))
    else:
        lines.append("  (none recorded)")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", required=True, help="memory_watch.py report JSON")
    ap.add_argument("--dry-run", action="store_true",
                    help="Build and print the request without contacting Jira.")
    args = ap.parse_args()

    with open(args.samples) as f:
        report = json.load(f)

    app = report.get("process") or "the app"
    commit_sha = jira_client.env("COMMIT_SHA", "")
    short_sha = jira_client.env("SHORT_SHA", "") or (commit_sha[:7] if commit_sha else "")
    run_url = jira_client.env("RUN_URL", "")

    summary = "Memory-leak watch: %s grew to %s MB (commit %s)" % (
        app, report.get("peak_mb"), short_sha or "?")
    description = build_description(report, app, commit_sha, short_sha, run_url)

    jira_client.file_ticket(summary, description, [LABEL], dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
