#!/usr/bin/env python3
"""Watch a running process's memory and decide whether it is leaking.

Used by the shared memory-watch workflow (LeanBytes/workflows-macos / memory-watch.yml) to run a
macOS app for an extended period and detect the kind of unbounded growth that pins a machine. Pure
stdlib so it runs on the system python3 of a self-hosted macOS runner (3.8+).

Detection (evaluated on every sample, after a warmup window):
  * HARD CAP   -- resident memory crosses an absolute ceiling. The machine-safety net: we abort
                  long before the app can climb to tens of GB.
  * TREND      -- after warmup, the least-squares slope of RSS vs time exceeds a threshold AND the
                  net growth from the post-warmup baseline exceeds a floor. Both conditions must
                  hold, so a flat-but-noisy footprint does not trip it.

A healthy app stays roughly flat, so a real leak stands out as sustained linear growth.

Exit codes (consumed by the workflow):
  0  healthy   -- ran the full duration, no leak
  2  leak      -- growth detected (the workflow files a ticket)
  3  error     -- could not start, bad arguments, lost the process, or crashed (an infra problem,
                  not a leak — the workflow fails the job and files no ticket)
"""

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timezone

EXIT_HEALTHY = 0
EXIT_LEAK = 2
EXIT_ERROR = 3


class _ArgParser(argparse.ArgumentParser):
    """argparse exits 2 on a bad/missing argument, which would collide with EXIT_LEAK. Make any
    argument error an infra error (3) instead, so a malformed invocation is never mistaken for a
    detected leak."""

    def error(self, message):
        self.print_usage(sys.stderr)
        print("error: %s" % message, file=sys.stderr)
        sys.exit(EXIT_ERROR)


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def rss_mb(pid):
    """Resident set size of `pid` in MB, or None if the process is gone.

    RSS (not phys_footprint) is deliberate: it is trivial to read via `ps`, monotonic enough to
    catch unbounded growth, and our hard cap sits far below the memory-compression regime where RSS
    and phys_footprint diverge — so for leak detection it is both reliable and dependency-free.
    """
    try:
        out = subprocess.run(
            ["ps", "-o", "rss=", "-p", str(pid)],
            capture_output=True, text=True, timeout=15,
        )
    except (subprocess.SubprocessError, OSError):
        return None
    val = out.stdout.strip()
    if out.returncode != 0 or not val:
        return None
    try:
        return int(val) / 1024.0  # ps reports KB
    except ValueError:
        return None


def slope_mb_per_hour(samples):
    """Least-squares slope of rss_mb against elapsed time, in MB/hour. 0 with <2 points."""
    n = len(samples)
    if n < 2:
        return 0.0
    xs = [s["elapsed_s"] / 3600.0 for s in samples]
    ys = [s["rss_mb"] for s in samples]
    sx = sum(xs); sy = sum(ys)
    sxx = sum(x * x for x in xs); sxy = sum(x * y for x, y in zip(xs, ys))
    denom = n * sxx - sx * sx
    if denom == 0:
        return 0.0
    return (n * sxy - sx * sy) / denom


def main():
    p = _ArgParser(description="Watch a process for memory leaks.")
    p.add_argument("--pid", type=int, required=True, help="PID to watch (the launched app).")
    p.add_argument("--process-name", default="", help="Name, for reporting only.")
    p.add_argument("--duration-seconds", type=int, required=True)
    p.add_argument("--interval-seconds", type=int, default=300)
    p.add_argument("--warmup-seconds", type=int, default=900,
                   help="Ignore growth before this — lets caches/SQLite settle.")
    p.add_argument("--hard-cap-mb", type=float, default=2048.0)
    p.add_argument("--slope-mb-per-hour", type=float, default=150.0)
    p.add_argument("--min-growth-mb", type=float, default=400.0)
    p.add_argument("--min-trend-samples", type=int, default=4,
                   help="Post-warmup samples required before trusting the trend verdict.")
    p.add_argument("--out", default="memory-samples.json")
    args = p.parse_args()

    config = {
        "duration_seconds": args.duration_seconds,
        "interval_seconds": args.interval_seconds,
        "warmup_seconds": args.warmup_seconds,
        "hard_cap_mb": args.hard_cap_mb,
        "slope_mb_per_hour": args.slope_mb_per_hour,
        "min_growth_mb": args.min_growth_mb,
        "min_trend_samples": args.min_trend_samples,
    }
    report = {
        "process": args.process_name,
        "pid": args.pid,
        "started_at": now_iso(),
        "ended_at": None,
        "config": config,
        "verdict": "error",
        "reason": "did not start",
        "tripped_metric": None,
        "baseline_mb": None,
        "peak_mb": None,
        "final_slope_mb_per_hour": None,
        "samples": [],
    }

    def flush():
        report["ended_at"] = now_iso()
        try:
            with open(args.out, "w") as f:
                json.dump(report, f, indent=2)
        except OSError as e:
            print("[mem] WARN could not write %s: %s" % (args.out, e), file=sys.stderr)

    def finish(code, verdict, reason, tripped=None):
        report["verdict"] = verdict
        report["reason"] = reason
        report["tripped_metric"] = tripped
        flush()
        print("[mem] === %s: %s ===" % (verdict.upper(), reason), flush=True)
        return code

    print("[mem] watching pid=%s (%s) for %ss, sampling every %ss, warmup %ss, "
          "hard cap %sMB, trend %sMB/h + %sMB growth"
          % (args.pid, args.process_name or "?", args.duration_seconds, args.interval_seconds,
             args.warmup_seconds, args.hard_cap_mb, args.slope_mb_per_hour, args.min_growth_mb),
          flush=True)

    start = time.monotonic()
    next_tick = start
    peak = 0.0

    while True:
        loop_now = time.monotonic()
        elapsed = loop_now - start
        if elapsed > args.duration_seconds:
            break

        mb = rss_mb(args.pid)
        if mb is None:
            # The process we were told to watch is gone. Treat as an error (likely a crash or the
            # app was closed) rather than silently passing — but don't file a leak ticket for it.
            return finish(EXIT_ERROR, "error",
                          "process %s (pid %s) is no longer running after %ds"
                          % (args.process_name or "?", args.pid, int(elapsed)))

        peak = max(peak, mb)
        sample = {"elapsed_s": int(round(elapsed)), "wall": now_iso(), "rss_mb": round(mb, 1)}
        report["samples"].append(sample)
        report["peak_mb"] = round(peak, 1)

        post = [s for s in report["samples"] if s["elapsed_s"] >= args.warmup_seconds]
        baseline = post[0]["rss_mb"] if post else None
        report["baseline_mb"] = baseline
        growth = (mb - baseline) if baseline is not None else 0.0
        slope = slope_mb_per_hour(post)
        report["final_slope_mb_per_hour"] = round(slope, 1)

        print("[mem] t=+%5ds rss=%7.0fMB peak=%7.0fMB slope=%+8.1fMB/h growth=%+7.0fMB"
              % (sample["elapsed_s"], mb, peak, slope, growth), flush=True)
        flush()  # persist after every sample so the artifact survives a timeout/kill

        # --- decide -----------------------------------------------------------------------------
        if mb >= args.hard_cap_mb:
            return finish(EXIT_LEAK, "leak",
                          "RSS %.0fMB crossed the hard cap of %.0fMB" % (mb, args.hard_cap_mb),
                          {"kind": "hard_cap", "rss_mb": round(mb, 1), "cap_mb": args.hard_cap_mb})

        if len(post) >= args.min_trend_samples and \
                slope >= args.slope_mb_per_hour and growth >= args.min_growth_mb:
            return finish(EXIT_LEAK, "leak",
                          "sustained growth: %.1fMB/h (>= %.0f) with %.0fMB net growth (>= %.0f) "
                          "over %d post-warmup samples"
                          % (slope, args.slope_mb_per_hour, growth, args.min_growth_mb, len(post)),
                          {"kind": "trend", "slope_mb_per_hour": round(slope, 1),
                           "growth_mb": round(growth, 1), "baseline_mb": baseline,
                           "samples": len(post)})

        next_tick += args.interval_seconds
        sleep_for = next_tick - time.monotonic()
        if sleep_for > 0:
            time.sleep(sleep_for)

    return finish(EXIT_HEALTHY, "healthy",
                  "no leak over %ds; peak %.0fMB, final trend %.1fMB/h"
                  % (args.duration_seconds, peak, report["final_slope_mb_per_hour"] or 0.0))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise  # argparse / explicit exit codes pass through unchanged
    except BaseException as e:  # any unexpected crash is an infra error, never a "leak"
        print("[mem] FATAL %s: %s" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(EXIT_ERROR)
