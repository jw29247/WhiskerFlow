# Investigate a freeze or delayed dictation

Ask for the time of the incident, the app version, and the diagnostic ID from **Settings → App → Performance diagnostics**.
The ID is a random identifier for an installation. It contains no account name, hardware identifier, or transcript.

## Search fleet telemetry

In the existing Superlog environment on Railway, select service `whiskerflow.macos`.
Filter resource attribute `installation.id` by the diagnostic ID and restrict the time range to the incident.
Every signal also carries `service.instance.id` for the launch, `service.version`, `app.build`, and `os.version`.
The signed bundle's build stamp supplies the revision when launch environment variables are absent.

Inspect these log attributes:

| `event` | Evidence |
| --- | --- |
| `main_thread_stalled` | The main queue has not answered for at least two seconds while the watchdog continues to run. Includes resource counters, the last interaction context, its age, and a `stall_id`. |
| `main_thread_recovered` | The same `stall_id` and the full observed delay. A stall without recovery may still be ongoing or the process may have exited. |
| `monitoring_gap` | The watchdog itself was unscheduled for at least five seconds. This is an observation gap, not proof of a UI freeze. |
| `interaction_state` | Foreground state, visible app window count, Accessibility trust, and Secure Keyboard Entry state. No window titles or unrelated keystrokes are recorded. |
| `hotkey_transition` | A matched configured shortcut, its local or global source, its pressed state, and dispatch delay. No key values or characters are recorded. |
| `stage_started`, `stage_finished` | Recognition, text processing, persistence, and UI work correlated by `session`. |
| `finish_returned`, `paste_returned` | End-to-end finish and delivery latency. |
| `resource_snapshot` | App and system CPU, resident memory, swap activity, thermal state, and observed memory pressure. |
| `system_sleep`, `system_wake` | Sleep boundaries that reset outstanding main queue probes. |

Use `app.main_thread.stalls` and `app.main_thread.stall.duration` to compare freeze counts and recovered durations across versions.
Use `app.operation.duration` and `app.operation.slow`, grouped by `operation`, to find slow stages.
The slow thresholds are 250 ms for hotkey dispatch, one second for capture startup and most stages, two seconds for finish or paste, and five seconds for recognition.
Recognition time also depends on recording length; the threshold flags an investigation, not a failed transcription.
The existing `dictation.finish` and `transcription.run` traces provide operation context.

There is no new backend service or alert rule to deploy. This uses the existing OTLP intake, collector, and storage.
New fields appear only after users install a release containing these changes.

## Distinguish background input failures

Compare `hotkey_transition` events with `interaction_state` in the same launch.
Local transitions with no global transitions and `accessibility=false` indicate a missing permission required for global keyboard monitoring.
Apple documents this requirement in [Monitoring Events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html).
`secure_input=true` is another input diagnostic clue. These fields do not prove that screen sharing caused a failure.
No transition means the application did not observe a matched shortcut; it does not prove that the user pressed one.
Context captured before a freeze can be stale, so inspect `context_age_ms`.

## Inspect local evidence

Run on the affected Mac:

```sh
python3 script/review_diagnostics.py --hours 2
```

The script reads only `~/Library/Logs/WhiskerFlow/diagnostics*.jsonl`.
It summarizes stalls, slow deliveries and hotkeys, recent permission state, and scheduling gaps.
Local logs use the same IDs as remote telemetry in `installation_id` and `launch`.
Three files of at most 2 MB limit local retention. Offline export retries and diagnostic queues remain bounded.

Stack excerpts remain in `~/Library/Logs/WhiskerFlow/stacks` on the affected Mac.
Stack capture is rate limited and skipped during audio capture or observed memory pressure because sampling can interrupt audio.
Raw sample reports, audio, transcripts, account names, and window titles are not added to performance reporting.

## Verify delivery

```sh
SUPERLOG_LIVE_SMOKE=1 swift test --filter ObservabilitySmokeTests
```

The live smoke verifies HTTP acceptance of traces, logs, and metrics.
It does not by itself prove storage or dashboard visibility. Confirm those by querying the emitted `telemetry.verify` trace in Superlog.

To exercise an intentional 2.5-second main queue delay and export synthetic stage timing, run:

```sh
SUPERLOG_PERFORMANCE_SMOKE=1 swift test --filter ObservabilitySmokeTests
```

This opt-in test verifies paired local stall and recovery records, installation identity, resource context, and HTTP acceptance of logs and metrics.
