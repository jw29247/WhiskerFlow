# Investigate a freeze or delayed dictation

WhiskerFlow sends no telemetry, crash reports or diagnostics anywhere. Everything below is on the affected Mac, so the evidence has to come from that Mac.
Ask for the time of the incident and the app version.

## Inspect local evidence

Run on the affected Mac:

```sh
python3 script/review_diagnostics.py --hours 2
```

The script reads only `~/Library/Logs/WhiskerFlow/diagnostics*.jsonl`.
It summarizes stalls, slow deliveries and hotkeys, recent permission state, and scheduling gaps.
Every row carries `launch` (a random ID for that launch, not persisted), `build`, `pid`, `timestamp` and `uptime`.
Three files of at most 2 MB limit local retention, and the write queue is bounded.
The same events also go to the macOS unified log under the app's bundle identifier.

Each row has an `event`:

| `event` | Evidence |
| --- | --- |
| `main_thread_stalled` | The main queue has not answered for at least two seconds while the watchdog continues to run. Includes resource counters, the last interaction context, its age, and a `stall_id`. |
| `main_thread_recovered` | The same `stall_id` and the full observed delay. A stall without recovery may still be ongoing or the process may have exited. |
| `monitoring_gap` | The watchdog itself was unscheduled for at least five seconds. This is an observation gap, not proof of a UI freeze. |
| `interaction_state` | Foreground state, visible app window count, Accessibility trust, Secure Keyboard Entry state, and the macOS Globe-key action. No window titles or unrelated keystrokes are recorded. |
| `hotkey_transition` | A matched configured shortcut, its local or global source, its pressed state, and dispatch delay. No key values or characters are recorded. |
| `globe_key_override_applied`, `globe_key_override_restored` | WhiskerFlow reserved Fn for dictation or restored the previous macOS Globe-key action. |
| `stage_started`, `stage_finished` | Recognition, text processing, persistence, and UI work correlated by `session`. |
| `finish_returned`, `paste_returned` | End-to-end finish and delivery latency. |
| `resource_snapshot` | App and system CPU, resident memory, swap activity, thermal state, and observed memory pressure. |
| `system_sleep`, `system_wake` | Sleep boundaries that reset outstanding main queue probes. |
| `diagnostic_error`, `diagnostic_breadcrumb` | A failure or lifecycle step recorded by the app: an allow-listed `category` (`recording`, `audio`, `model`, `storage`, `glossary`, `network`), an `error_code` where there is one, and fixed-vocabulary fields such as `phase`. Error descriptions are never written. |

The `elapsed_ms` of `hotkey_transition`, `capture_start_timing`, `stage_finished`, `finish_returned` and `paste_returned` gives each operation's duration.
As a rule of thumb, look into hotkey dispatch over 250 ms, capture startup and most stages over one second, finish or paste over two seconds, and recognition over five seconds.
Recognition time also depends on recording length; a long recognition is a reason to investigate, not a failed transcription.

## Distinguish background input failures

Compare `hotkey_transition` events with `interaction_state` in the same launch.
Local transitions with no global transitions and `accessibility=false` indicate a missing permission required for global keyboard monitoring.
Apple documents this requirement in [Monitoring Events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html).
`secure_input=true` is another input diagnostic clue. These fields do not prove that screen sharing caused a failure.
No transition means the application did not observe a matched shortcut; it does not prove that the user pressed one.
Context captured before a freeze can be stale, so inspect `context_age_ms`.
When Fn/Globe is the configured shortcut, WhiskerFlow sets the competing macOS Globe-key action to **Do Nothing** before starting the hotkey monitor. This reservation stays active with the app window closed. Choosing another shortcut or quitting normally restores the previous action. Settings and onboarding explain the reservation.

The original value is saved before macOS is changed. After a crash or force quit, the reservation can remain until the next launch. The next launch retains the original backup while Fn remains selected, or restores it if another shortcut is selected. An external action that differs from **Do Nothing** is preserved on quit.

Inspect `globe_key_action`. A value such as `dictation`, `emoji`, or `change_input_source` while Fn is selected means macOS still assigns a competing action. If the automatic change fails, use **Keyboard settings → Press 🌐 key to → Do Nothing**, or select another WhiskerFlow shortcut. The diagnostics monitor itself only reads this setting.

## Stack excerpts

Stack excerpts remain in `~/Library/Logs/WhiskerFlow/stacks` on the affected Mac.
Stack capture is rate limited and skipped during audio capture or observed memory pressure because sampling can interrupt audio.
Raw sample reports, audio, transcripts, account names, and window titles are never written to these logs.
