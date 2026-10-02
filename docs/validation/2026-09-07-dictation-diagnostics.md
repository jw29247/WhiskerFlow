# Dictation delivery diagnostics — 7 September 2026

Worktree: `/Users/jacob/.codex/worktrees/whiskerflow-2-assistant`, branch `codex/whiskerflow-2-assistant`, base HEAD `3c91b3d28f687d79c1d910e6b8a4fa07b6ee6854`. Changes remain local and unmerged. Pre-existing validation/editor/resource-monitor changes were preserved.

## Findings and changes

Jacob reports text arriving immediately but Transcribing remaining for minutes and preventing further use. The exact multi-minute episode was not reproduced or sampled: the earlier process/build was no longer available. A real AppState delivery regression reproduced recognition flags staying busy while a controlled destination verification remained pending. A second failing regression reproduced an old receipt overwriting a newer delivery. Both pass after the fixes.

Recognition retires its active work before awaiting delivery. Delivery has a separate non-blocking Pasting status; a delivery token prevents late receipts from overwriting newer delivery/recording state. Post-paste AX verification now runs on a worker with a 0.9-second caller deadline, keeping synchronous destination IPC off the main actor. It retains the minimum clipboard-consumption window and reports unverified delivery truthfully. Preparation before posting (activation, clipboard snapshot and AX selection capture) still uses the existing main-actor path and is not claimed universally bounded.

The existing logging bootstrap now also writes only allowlisted lifecycle fields to `~/Library/Logs/WhiskerFlow/diagnostics*.jsonl`. Message bodies, transcript/audio content, arbitrary metadata and source paths are omitted. Writes run on a utility queue with a capped backlog; three files of at most 2 MB bound retention. A main-thread probe emits stalls/recovery and a minute heartbeat. Logs include per-launch identity and build stamp. Local logging was verified; this task does not independently certify remote telemetry ingestion.

## Verification

- Red lifecycle assertions: `/tmp/whiskerflow-sept7-red4.log`.
- Red late-receipt assertions: `/tmp/whiskerflow-sept7-stale-red.log`.
- Final focused suite: 31 tests passed, `/tmp/whiskerflow-sept7-final-tests.log`. Covers delivery lifecycle, blocked verification/main actor, deadline, clipboard restoration, privacy, rotation, HUD, recording coordinator, diagnostic privacy and pasted-text scope. This is not a claim that the entire native suite passes.
- Signed final app: `.build/WhiskerFlow 2 Diagnostics.app`, build stamp `3c91b3d28f68-20260907T180243Z`, launched through the project build/run script; signature validated.
- Fresh final-build UI check: existing opt-in verification command pasted the exact synthetic sentence into the isolated acceptance editor. App showed Ready, then verified paste receipt; diagnostic duration approximately 476 ms. Earlier candidate was 483 ms. No stall events observed during these checks. Fixture was closed afterward.
- These checks exercise the real paste path, not a fresh microphone-to-recognition journey. Continued ordinary use is needed to verify the reported intermittent multi-minute episode is resolved.

## Ongoing review

Automation `review-whiskerflow-diagnostics` is active every two hours in this task. It runs `python3 script/review_diagnostics.py --hours 2`, remains quiet unless actionable, correlates suspected stale states with the matching live process, and does not restart the app, change settings/code or read transcripts. No recent evidence is not a successful-use verdict.

The worktree Run action rebuilds and launches this signed candidate. Monitoring state belongs in `.codex/diagnostic-review-state.json`, not user memory.
