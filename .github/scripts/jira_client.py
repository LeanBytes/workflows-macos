#!/usr/bin/env python3
"""Shared Jira helpers for the workflows-macos CI ticket scripts.

REST API v2 issue create (HTTP Basic auth) + **active-sprint placement** via the Jira Software
(agile/1.0) API. Imported by `create_jira_ticket.py` (memory-leak) and `create_test_ticket.py`
(test failures); both run as `python3 .shared-ci/.github/scripts/<name>.py`, so this module sits on
`sys.path[0]` next to them.

Auto-created CI tickets go into the board's **current active sprint**, not the backlog.

Env (Variables vs Secrets per the LeanBytes Jira reference,
https://sarensw.atlassian.net/wiki/x/AgAzCQ):
  JIRA_BASE_URL, JIRA_PROJECT_KEY, JIRA_USER_EMAIL (or JIRA_EMAIL), JIRA_API_TOKEN
  JIRA_ISSUE_TYPE   optional, default "Bug"
  JIRA_BOARD_ID     optional; the board whose active sprint receives the ticket
                    (falls back to the project's sole board)

The token uses HTTP Basic (email:token), not Bearer. Issue create needs read:jira-work +
write:jira-work; the sprint write needs Jira-Software scopes (read:board-scope:jira-software,
read:sprint:jira-software, write:sprint:jira-software).
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.request


def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        print("ERROR: missing required env var %s" % name, file=sys.stderr)
        sys.exit(1)
    return v


def _request(method, url, email, token, body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    raw = ("%s:%s" % (email, token)).encode("utf-8")
    req.add_header("Authorization", "Basic " + base64.b64encode(raw).decode("ascii"))
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        text = resp.read().decode("utf-8")
        return json.loads(text) if text.strip() else {}


def create_issue(base_url, email, token, project, issue_type, summary, description, labels):
    """POST /rest/api/2/issue → {"id","key","self"}. Raises on failure (the caller should fail)."""
    url = base_url.rstrip("/") + "/rest/api/2/issue"
    body = {"fields": {
        "project": {"key": project},
        "issuetype": {"name": issue_type},
        "summary": summary,
        "description": description,  # plain string in v2 (not ADF/markdown)
        "labels": labels,
    }}
    try:
        return _request("POST", url, email, token, body)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        print("ERROR: Jira create returned %s\n%s" % (e.code, detail), file=sys.stderr)
        if e.code in (400, 401, 403, 404):
            print("Hint: the API token needs scopes read:me, read:jira-work, write:jira-work, and "
                  "auth must be HTTP Basic (email:token), not Bearer. See the LeanBytes Jira "
                  "integration reference in Confluence.", file=sys.stderr)
        raise


def _resolve_board_id(base_url, email, token, project, board_id):
    if board_id:
        return str(board_id)
    # Derive the project's board; only auto-pick when there's exactly one.
    url = base_url.rstrip("/") + "/rest/agile/1.0/board?projectKeyOrId=" + str(project)
    boards = (_request("GET", url, email, token).get("values") or [])
    if len(boards) == 1:
        return str(boards[0]["id"])
    if not boards:
        print("::warning::No Jira board for project %s — ticket left in the backlog." % project)
    else:
        print("::warning::Project %s has %d boards; set JIRA_BOARD_ID to pick one. Ticket left in the backlog."
              % (project, len(boards)))
    return None


def _active_sprint_id(base_url, email, token, board_id):
    url = base_url.rstrip("/") + ("/rest/agile/1.0/board/%s/sprint?state=active" % board_id)
    sprints = (_request("GET", url, email, token).get("values") or [])
    return str(sprints[0]["id"]) if sprints else None


def add_to_active_sprint(base_url, email, token, project, board_id, issue_key):
    """Best-effort: move issue_key into the board's active sprint. Warns (never raises) on any
    problem — the ticket already exists, so sprint placement must not fail the workflow."""
    try:
        bid = _resolve_board_id(base_url, email, token, project, board_id)
        if not bid:
            return False
        sid = _active_sprint_id(base_url, email, token, bid)
        if not sid:
            print("::warning::Board %s has no active sprint — %s left in the backlog." % (bid, issue_key))
            return False
        url = base_url.rstrip("/") + ("/rest/agile/1.0/sprint/%s/issue" % sid)
        _request("POST", url, email, token, {"issues": [issue_key]})
        print("Added %s to active sprint %s (board %s)." % (issue_key, sid, bid))
        return True
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        print("::warning::Could not add %s to the active sprint (HTTP %s): %s" % (issue_key, e.code, detail))
        print("::warning::The token may need Jira-Software scopes (read:board-scope, read:sprint, write:sprint).")
        return False
    except Exception as e:  # best-effort — any failure leaves the ticket in the backlog
        print("::warning::Could not add %s to the active sprint: %s" % (issue_key, e))
        return False


def file_ticket(summary, description, labels, dry_run=False):
    """Create the issue, then place it in the board's active sprint. Returns the issue key (None on
    dry-run). Raises if the create fails (the workflow should fail); sprint placement is best-effort."""
    if dry_run:
        project = env("JIRA_PROJECT_KEY", "") or "<JIRA_PROJECT_KEY>"
        issue_type = env("JIRA_ISSUE_TYPE", "Bug")
        print("DRY RUN — would POST /rest/api/2/issue creating a %s in %s, then add it to the board's "
              "active sprint:" % (issue_type, project))
        print(json.dumps({"fields": {"project": {"key": project}, "issuetype": {"name": issue_type},
                                     "summary": summary, "labels": labels, "description": description}},
                         indent=2))
        return None

    base_url = env("JIRA_BASE_URL", required=True)
    project = env("JIRA_PROJECT_KEY", "")
    if not project:
        print("ERROR: missing JIRA_PROJECT_KEY", file=sys.stderr); sys.exit(1)
    email = env("JIRA_USER_EMAIL") or env("JIRA_EMAIL")
    if not email:
        print("ERROR: missing JIRA_USER_EMAIL", file=sys.stderr); sys.exit(1)
    token = env("JIRA_API_TOKEN", required=True)
    issue_type = env("JIRA_ISSUE_TYPE", "Bug")
    board_id = env("JIRA_BOARD_ID", "")

    created = create_issue(base_url, email, token, project, issue_type, summary, description, labels)
    key = created.get("key")
    print("Created %s: %s/browse/%s" % (key, base_url.rstrip("/"), key))
    add_to_active_sprint(base_url, email, token, project, board_id, key)
    return key
