#!/usr/bin/env python3
"""File a Jira issue when the memory-watch workflow detects memory growth.

Generic across apps: the app name and all metrics come from the memory_watch.py report JSON
(`report["process"]`, peak, trend, thresholds, samples) — nothing app-specific is hardcoded.

Follows the LeanBytes Jira integration reference (Confluence: "Jira Integration — Variables, Auth &
API Reference for Agents", https://sarensw.atlassian.net/wiki/x/AgAzCQ):

  * REST API **v2** only (`/rest/api/2/issue`) — not v3.
  * HTTP **Basic** auth, email + API token — not Bearer/OAuth.
  * `description` is a **plain string** in v2 — not ADF, not markdown.

No dedup/search: the workflow's commit gate fires at most once per commit, so a leak yields exactly
one ticket. Pure stdlib so it runs on a self-hosted runner without `pip install`.

Environment (Variables vs Secrets per the Confluence page):
  JIRA_BASE_URL     e.g. https://your-org.atlassian.net          (required for a real run)
  JIRA_PROJECT_KEY  e.g. LB                                       (required for a real run)
  JIRA_USER_EMAIL   Atlassian account email for Basic auth        (required for a real run)
  JIRA_API_TOKEN    API token (starts with ATATT); scopes read:me, read:jira-work, write:jira-work
  JIRA_ISSUE_TYPE   optional, default "Bug"
  COMMIT_SHA, SHORT_SHA, RUN_URL   provided by the workflow (for the description)
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request

LABEL = "auto-memory-leak"


def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        print("ERROR: missing required env var %s" % name, file=sys.stderr)
        sys.exit(1)
    return v


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


def create_issue(base_url, email, token, project, issue_type, summary, description):
    url = base_url.rstrip("/") + "/rest/api/2/issue"
    body = {
        "fields": {
            "project": {"key": project},
            "issuetype": {"name": issue_type},
            "summary": summary,
            "description": description,  # plain string in v2
            "labels": [LABEL],
        }
    }
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), method="POST")
    raw = ("%s:%s" % (email, token)).encode("utf-8")
    req.add_header("Authorization", "Basic " + base64.b64encode(raw).decode("ascii"))
    req.add_header("Accept", "application/json")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))  # 201 -> {"id","key","self"}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        print("ERROR: Jira create returned %s\n%s" % (e.code, detail), file=sys.stderr)
        if e.code in (400, 401, 403, 404):
            print("Hint: the API token needs scopes read:me, read:jira-work, write:jira-work, and "
                  "auth must be HTTP Basic (email:token), not Bearer. See the LeanBytes Jira "
                  "integration reference in Confluence.", file=sys.stderr)
        raise


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", required=True, help="memory_watch.py report JSON")
    ap.add_argument("--dry-run", action="store_true",
                    help="Build and print the request without contacting Jira.")
    args = ap.parse_args()

    with open(args.samples) as f:
        report = json.load(f)

    app = report.get("process") or "the app"
    commit_sha = env("COMMIT_SHA", "")
    short_sha = env("SHORT_SHA", "") or (commit_sha[:7] if commit_sha else "")
    run_url = env("RUN_URL", "")
    project = env("JIRA_PROJECT_KEY", "")
    issue_type = env("JIRA_ISSUE_TYPE", "Bug")

    summary = "Memory-leak watch: %s grew to %s MB (commit %s)" % (
        app, report.get("peak_mb"), short_sha or "?")
    description = build_description(report, app, commit_sha, short_sha, run_url)

    if args.dry_run:
        print("DRY RUN — would POST /rest/api/2/issue creating a %s in %s:"
              % (issue_type, project or "<JIRA_PROJECT_KEY>"))
        print(json.dumps({"fields": {"project": {"key": project or "<JIRA_PROJECT_KEY>"},
                                     "issuetype": {"name": issue_type},
                                     "summary": summary, "labels": [LABEL],
                                     "description": description}}, indent=2))
        return 0

    base_url = env("JIRA_BASE_URL", required=True)
    if not project:
        print("ERROR: missing JIRA_PROJECT_KEY", file=sys.stderr)
        return 1
    email = env("JIRA_USER_EMAIL") or env("JIRA_EMAIL")
    if not email:
        print("ERROR: missing JIRA_USER_EMAIL", file=sys.stderr)
        return 1
    token = env("JIRA_API_TOKEN", required=True)

    created = create_issue(base_url, email, token, project, issue_type, summary, description)
    print("Created %s: %s/browse/%s" % (created.get("key"), base_url.rstrip("/"),
                                         created.get("key")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
