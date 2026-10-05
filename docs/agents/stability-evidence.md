# Build-specific stability evidence

`script/review_stability.py` persists content-free sessions and faults across log rotation. Each assessment belongs to one exact diagnostic build ID.

After [matching the source](source-selection.md), run from that checkout:

```sh
python3 script/review_stability.py --build '<exact diagnostic build ID>'
```

`--build` saves the selection in the ledger. Without it, the checker uses the saved selection, or the sole observed build. Multiple builds without a selection return `coverage: ambiguous_builds` and cannot pass. `by_build` reports their separate counts and results; it never pools counts towards the threshold.

The existing gate requires at least 50 completed dictations on three active days, no selected-build faults or slow completions, and normal-dictation finish p95 of at most two seconds. Unverified paste receipts remain responsiveness evidence and are counted separately; passing this gate still requires a fresh real microphone-to-paste acceptance check before a release claim.

## Existing ledgers

The checker retains the previous timestamp window and evidence. Retained log rows can backfill build identity in older sessions and faults. Legacy measurements are protected by the ledger's last update time until newer events arrive, so replay cannot replace newer persisted timings with older retained rows. Evidence whose build remains unknown, or a session with conflicting build IDs, returns `coverage: missing_build_identity` and blocks passing. Known faults from another build affect that build's assessment.

Inspect missing-identity counts before deciding on a new window. After a relevant behaviour change, start a fresh window deliberately:

```sh
python3 script/review_stability.py --build '<exact diagnostic build ID>' --reset '<build and reason>'
```

Reset stores the previous window's summary. It does not establish stability for the new build. Older rotated log rows stay outside the new window; later reruns retain evidence already saved even after its log file rotates away.

## Checks without changing the live ledger

Run the regression suite:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s script/tests -p 'test_*.py' -v
```

For a diagnostic replay, use `--state <scratch ledger path>` and `--directory <log directory>`. The command writes only the chosen ledger; logs are read-only. Copy the existing ledger first when preserving its observation window is necessary.
