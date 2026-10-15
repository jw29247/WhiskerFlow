# Performance diagnostics investigation

The initially connected Mac is an M1 MacBook Pro with 8 GB RAM. Its installed WhiskerFlow is version 1.0, dated May 2026, and was not running. No recent incident evidence was available there. The user subsequently confirmed the affected Mac is their M5 MacBook Pro; its findings are recorded below. Screen sharing is not proven responsible.

The existing Railway `superlog` project has an intake proxy, collector, API, worker, ClickHouse, and Postgres. Its intake was accepting requests. A synthetic log sent using WhiskerFlow's configured public token returned HTTP 200. Read access to stored application telemetry was unavailable in this session; Railway HTTP logs do not establish storage or query visibility.

## Implemented

Extended the existing pipeline with shared installation and launch identity, signed-bundle build metadata, foreground/window/Accessibility/Secure Keyboard Entry context, matched shortcut dispatch timing, and native operation latency metrics. The watchdog now reports two-second delays, catches between-tick recoveries, and separates long scheduling gaps and sleep from UI stalls. No alert, backend deployment, app release, or claim that the original freeze is fixed accompanies this change. See the [investigation guide](../performance-diagnostics.md).

The Model the Domain principle led to a typed probe state machine. Fix Root Causes kept the reported incident unresolved instead of assigning it to screen sharing without traces. Prove It Works led to a native integration run against the real compiled support code and configured intake. One owner handled implementation and verification under the repository policy, with no delegated review gate.

## Verification

- Three Python report tests passed. Both JSON resources validated. Pinned SwiftFormat 0.62.1 lint passed.
- A native executable linked the production AppSupport/Core, logging, and OTel objects. Probe scheduling, recovery, installation identity, and duration-model assertions passed. An intentional 2.5-second main queue delay produced paired stall/recovery records with a shared stall ID, installation ID, and resource/interaction context. Native traces, logs, and metrics each returned HTTP 200. Evidence is in `/tmp/whiskerflow-native-performance-smoke.log` and `/tmp/whiskerflow-performance-validation/home/Library/Logs/WhiskerFlow/diagnostics.jsonl` on this Mac.
- The version-source and upgrade-identity shell checks passed.
- A separate native SDK check confirmed that one history-save lifecycle log exported a 1.5-second histogram observation and one slow-operation count, with only the bounded operation attribute. Correction punctuation output also passed. Evidence is in `/tmp/whiskerflow-native-metric-check.log`.
- Standard local Swift commands initially failed because Command Line Tools had stale private module interfaces and duplicate SwiftBridging module maps. A temporary compiler wrapper and file overlay under `/tmp/whiskerflow-manifest-toolchain` allowed Core/AppSupport compilation. Installed system files were unchanged. A one-line explicit String conversion fixed a separate reproducible Swift 5 string-concatenation compile error without changing correction output.
- Full app build, XCTest, rendered UI, and bundle packaging remain locally blocked. Command Line Tools lacks XCTest and the SwiftUI/FoundationModels macro plugins; its SDK also rejects newer FoundationModels APIs used by the unchanged app. Build and test failures are retained in `/tmp/whiskerflow-build-fixed.log` and `/tmp/whiskerflow-support-tests-build.log`. The bundle packaging check exited 1; its script suppresses compiler stdout. The base commit's GitHub CI was green. The PR must pass the full repository workflow on a host with Xcode.
- GitHub CI subsequently passed all four checks on `e4cf8eb`, including full build/tests, packaging, JSON validation, pinned lint, and both Socket checks. The initial GitHub Codex review completed without actionable findings. The later Globe-key diagnostic addition requires a fresh CI run.

## Affected M5 findings

The M5 runs WhiskerFlow 2.0.2, build 24, revision stamp `f630ef876b8b-20261014T141754Z`. Bounded diagnostic files and saved symbol-only stack excerpts were copied to `/tmp/whiskerflow-incident-20261015` on the M1. No transcripts or audio were read.

The saved October 13 and 14 stacks show `beginRecording → CoreAudioDeviceCatalog.availableInputs → HALB_Mutex::Lock → __psynch_mutexwait` on earlier builds. They match the [CoreAudio lock cycle already fixed in 2.0.2](2026-10-14-audio-freeze.md). The current installed launch has 103 completed finish attempts and no logged main-thread stall, engine timeout, or finish timeout. All observed finish durations are below two seconds. This does not rule out shorter delays or missing keyboard events; the old watchdog only reports delays of at least three seconds. Nine silent/discarded captures and one missing paste destination also appear, and must not be counted as successful dictations.

Current inspection found Accessibility granted for the production app, Secure Keyboard Entry off, and no visible WhiskerFlow window. System counters show substantial active swapping and memory-pressure warnings, which can contribute to delays, but those counters do not prove an app deadlock or its cause.

There is a concrete shortcut conflict: WhiskerFlow uses Fn in hold-to-talk mode while macOS `AppleFnUsageType` was `3`, mapped to Apple Dictation by `GlobeKeyUsage`. The setting was changed to `0`, Do Nothing, on the affected Mac. Both `defaults` and `CFPreferencesCopyAppValue` confirmed the new value. This removes the competing stored action; normal background shortcut use still needs confirmation. The app itself only reads this setting, and new fleet context includes its bounded `globe_key_action` category so support can identify the same conflict elsewhere.

## Remaining evidence

Confirm background Fn use after the setting change and reproduce any remaining delay with an incident time. Query remote storage when read access is available. Validate the Settings diagnostic-ID control in the rendered app. New fleet fields require an authorized app release before existing installations can emit them.
