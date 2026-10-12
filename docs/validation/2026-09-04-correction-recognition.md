# WhiskerFlow 2.0 correction recognition

## Behavior

WhiskerFlow observes the focused text field immediately around its own automatic paste. It first verifies the exact insertion, then checks that same field for up to two minutes. Stable word substitutions appear under Corrections. Repeated samples from one paste do not inflate counts; returning the pasted text to its original spelling removes that paste's observations. Corrections can be explicitly added to vocabulary, dismissed, or cleared. Tracking can be disabled.

Edits saved in History also produce correction records. History edit baselines are scoped to the running app. Vocabulary suggestions keep their conservative rewrite filter; the correction log additionally recognizes single-word changes in short dictations.

## Privacy and limits

- Only word pairs, a paste/session identifier, application display name, and date are stored locally. No surrounding document text is persisted or sent to Atlas.
- The temporary Accessibility scope is bounded to a 64 Ki UTF-16 field and a 16 Ki pasted span. Invalid Unicode selections are rejected.
- Tracking stops on a new paste, focus/application change, setting disable, shutdown, surrounding-content change, or timeout.
- Secure fields are rejected before reading values, including during asynchronous insertion confirmation.
- Unsupported Accessibility fields and copy-only delivery are skipped. A detected edit must remain stable for 1.5 seconds while the field stays focused. Broad rewrites, additions, deletions, and punctuation-only changes are not vocabulary corrections.
- The last 500 word-pair observations are retained. Storage uses an app-private directory, atomic writes, and user-only file permissions. A corrupt file is preserved and a visible error is shown.

## Verification

Automated cases cover selected Unicode text, unchanged surrounding context, invalid ranges, exact-paste confirmation, short-word corrections versus rewrites, repeated samples, independent paste counts, undo, restart persistence, dismissal, and corruption preservation.

The debug-only `--verify-corrections` launch flag exposes a File command that calls the real AppState delivery path with a known sentence into an already-open TextEdit document. It performs no direct record injection and is absent from release builds.

Live TextEdit verification on September 4, 2026:

- A 45-character sentence passed through AppState → PasteService → TextEdit. Its exact insertion was confirmed through Accessibility.
- Changing `Mark` to `Marc` produced one locally persisted correction, displayed with TextEdit as the source and an Add to vocabulary action.
- Undo restored `Mark` and removed the observation; reapplying the edit restored exactly one record.
- The first live run exposed duplicate delivery through the global HID event stream (45 characters became 90). Targeting key events to the confirmed recipient process produced a single insertion and successful correction tracking. Activation failure also restores the owned clipboard snapshot.
- Final regression run: `swift test --skip DictationPerformanceTests` — 273 tests, 2 existing skips, 0 failures.
- A normal relaunch loaded the saved correction into the Corrections view. The test observation was then dismissed after retaining a local verification copy.
- Developer ID signed local bundle passed codesign validation. This is a local 2.0 candidate, not a public release.

Temporary capture diagnostics were removed after verification.
