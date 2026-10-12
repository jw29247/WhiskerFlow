# Native Meet speaker reader

Signed build `3c91b3d28f68-20260915T115446Z` launched, Ready verified; existing capture was idle/saved before normal switch.

Implemented `MeetingAccessibilityCapture` and `MeetingAccessibilityReader`, replacing `MeetingBrowserCapture` in the production coordinator. Polling and encrypted writes run off main, only during capture. Each AX scan has a 200ms budget, 15ms per-call timeout, 700-node cap, and skips non-Meet web areas, captions and editable/static text. Incomplete scans return no evidence. Expected calendar Meet path is checked; multiple web areas or different calls fail closed. No extension, Recall SDK, cloud ASR or browser settings changes.

`MeetingAccessibilityEvidence` currently recognises explicit English `NAME is speaking` labels on AXImage/AXGroup elements. **This grammar is a supported adapter shape tested with synthetic trees, not yet an observed contract for Jacob's current Meet.** Actual live naming remains unverified and may require changing the parser once a live native tree is available. Unknown/localised status formats produce no names.

Two consecutive observations of the same element/name form an interval; gaps >1.5s, unavailable snapshots, name changes and different calls break continuity. Existing matcher requires 80% interval coverage and rejects competing speakers; microphone overlap is already excluded by the local processor. Product evidence is encrypted; names/text are not written to diagnostic logs. UI reports detected activity, unavailable information or permissions rather than asserting names from the roster.

Validation: 38 tests passed, 1 opt-in live caption test skipped. Tests cover explicit activity, captions/roster rejection, origin isolation, multiple calls, stale intervals, overlap, encryption and local processor name attribution without changing transcript text. Signed bundle strict verification passed. Current app includes the prior main-thread system-probe fix.

Next: during an actual Meet with CC off verify the exposed status grammar and transitions, marker identity stability, poll budget, hidden-window/PiP behavior, all named speakers and Atlas display. Do not present synthetic tests or local launch as four-speaker end-to-end acceptance.
