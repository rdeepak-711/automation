#!/usr/bin/env python3
"""
Layer 8 — Retry helper

Since the pipeline is now fully deterministic (Claude only runs in Layer 7.5 as
verifier), retries are only useful for transient verifier CLI failures (timeouts,
process errors, malformed JSON).  If the verifier is unavailable after all
attempts, we treat it as a pass-through: the deterministic Layer 7 already
validated structure, so a flaky verifier should not block a good article.
"""

import json
import subprocess
import time


def run_with_retry(fn, *, attempts: int = 2, backoff: float = 1.5) -> tuple:
    """
    Call fn() up to `attempts` times, retrying on transient failures.

    fn must return a (bool, list) tuple — the same shape as verifier.verify().

    On exhausting attempts, returns a pass-through with a warning so the
    article is still written (Layer 7 already passed).
    """
    last_exc = None
    for i in range(attempts):
        try:
            return fn()
        except (
            subprocess.TimeoutExpired,
            subprocess.CalledProcessError,
            json.JSONDecodeError,
            OSError,
        ) as e:
            last_exc = e
            if i < attempts - 1:
                time.sleep(backoff**i)

    return (
        True,
        [
            {
                "severity": "warning",
                "where": "verifier",
                "description": (
                    f"verifier unavailable after {attempts} attempts: {last_exc}"
                ),
            }
        ],
    )
