# Performance diagnostics investigation

The initially connected Mac is an M1 MacBook Pro with 8 GB RAM. Its installed WhiskerFlow is version 1.0, dated May 2026, and was not running. No recent incident evidence was available there. The user subsequently confirmed the affected Mac is their M5 MacBook Pro; its findings are recorded below. Screen sharing is not proven responsible.

The existing Railway `superlog` project has an intake proxy, collector, API, worker, ClickHouse, and Postgres. Its intake was accepting requests. A synthetic log sent using WhiskerFlow's configured public token returned HTTP 200. Read access to stored application telemetry was unavailable in this session; Railway HTTP logs do not establish storage or query visibility.

## Implemented

Extended the existing pipeline with shared installation and launch identity, signed-bundle build metadata, foreground/window/Accessibility/Secure Keyboard Entry context, matched shortcut dispatch timing, and native operation latency metrics. The watchdog now reports two-second delays, catches between-tick recoveries, and separates long scheduling gaps and sleep from UI stalls. The background Fn conflict is addressed by the app reservation described below. No alert, backend deployment, or app release accompanies this change. See the [investigation guide](../performance-diagnostics.md).

The Model the Domain principle led to a typed probe state machine. Fix Root Causes kept the reported incident unresolved instead of assigning it to screen sharing without traces. Prove It Works led to a native integration run against the real compiled support code and configured intake. One owner handled implementation and verification under the repository policy, with no delegated review gate.

## Verification

- Three Python report tests passed. Both JSON resources validated. Pinned SwiftFormat 0.62.1 lint passed.
- A native executable linked the production AppSupport/Core, logging, and OTel objects. Probe scheduling, recovery, installation identity, and duration-model assertions passed. An intentional 2.5-second main queue delay produced paired stall/recovery records with a shared stall ID, installation ID, and resource/interaction context. Native traces, logs, and metrics each returned HTTP 200. Evidence is in `/tmp/whiskerflow-native-performance-smoke.log` and `/tmp/whiskerflow-performance-validation/home/Library/Logs/WhiskerFlow/diagnostics.jsonl` on this Mac.
- The version-source and upgrade-identity shell checks passed.
- A separate native SDK check confirmed that one history-save lifecycle log exported a 1.5-second histogram observation and one slow-operation count, with only the bounded operation attribute. Correction punctuation output also passed. Evidence is in `/tmp/whiskerflow-native-metric-check.log`.
- Standard local Swift commands initially failed because Command Line Tools had stale private module interfaces and duplicate SwiftBridging module maps. A temporary compiler wrapper and file overlay under `/tmp/whiskerflow-manifest-toolchain` allowed Core/AppSupport compilation. Installed system files were unchanged. A one-line explicit String conversion fixed a separate reproducible Swift 5 string-concatenation compile error without changing correction output.
- Full app build, XCTest, rendered UI, and bundle packaging remain locally blocked. Command Line Tools lacks XCTest and the SwiftUI/FoundationModels macro plugins; its SDK also rejects newer FoundationModels APIs used by the unchanged app. Build and test failures are retained in `/tmp/whiskerflow-build-fixed.log` and `/tmp/whiskerflow-support-tests-build.log`. The bundle packaging check exited 1; its script suppresses compiler stdout. The base commit's GitHub CI was green. The PR must pass the full repository workflow on a host with Xcode.
- GitHub CI subsequently passed all four checks on `e4cf8eb` and `e4f8139`, including full build/tests, packaging, JSON validation, pinned lint, and both Socket checks. The initial GitHub Codex review completed without actionable findings. The Fn reservation change needs the same checks on its own commit.

## Affected M5 findings

The M5 runs WhiskerFlow 2.0.2, build 24, revision stamp `f630ef876b8b-20261014T141754Z`. Bounded diagnostic files and saved symbol-only stack excerpts were copied to `/tmp/whiskerflow-incident-20261015` on the M1. No transcripts or audio were read.

The saved October 13 and 14 stacks show `beginRecording → CoreAudioDeviceCatalog.availableInputs → HALB_Mutex::Lock → __psynch_mutexwait` on earlier builds. They match the [CoreAudio lock cycle already fixed in 2.0.2](2026-10-14-audio-freeze.md). The current installed launch has 103 completed finish attempts and no logged main-thread stall, engine timeout, or finish timeout. All observed finish durations are below two seconds. This does not rule out shorter delays or missing keyboard events; the old watchdog only reports delays of at least three seconds. Nine silent/discarded captures and one missing paste destination also appear, and must not be counted as successful dictations.

Current inspection found Accessibility granted for the production app, Secure Keyboard Entry off, and no visible WhiskerFlow window. System counters show substantial active swapping and memory-pressure warnings, which can contribute to delays, but those counters do not prove an app deadlock or its cause.

WhiskerFlow uses Fn in hold-to-talk mode while macOS `AppleFnUsageType` was `3`, mapped to Apple Dictation by `GlobeKeyUsage`. The setting was changed to `0`, Do Nothing, on the affected Mac. Both `defaults` and `CFPreferencesCopyAppValue` confirmed the new value. The user subsequently confirmed normal Fn dictation works on the M5 with WhiskerFlow running and its window closed. That result supports the competing action as the background-input cause; it does not establish that every reported delay had the same cause.

## Product fix for the Fn conflict

`GlobeKeyShortcutOverride` now reserves Fn before the app starts its hotkey monitor. It saves the original macOS action, changes it to Do Nothing, and restores it when the shortcut changes or the app quits normally. The reservation belongs to `AppState`, so closing a window does not release it. Activation rechecks the reservation. Settings and onboarding explain the temporary change and offer the manual fallback if a write fails.

The saved original survives an interrupted process. A reservation left by a crash remains until the next launch; it is then retained for Fn or restored for another shortcut. Restoration checks that the current value is still Do Nothing, preserving a later external choice. The original unset preference is represented explicitly rather than converted to a new permanent choice.

A native harness linked the compiled production AppSupport code and exercised the real macOS preferences service using isolated domains. A second process read the competing Dictation action as `3` before configuration and `0` afterward. Another process recovered the saved original after restart. Shortcut changes, normal-quit restoration, all original choices including an unset value, idempotent setup, and external changes passed. Evidence is in `/tmp/whiskerflow-hotkey-fix/verify.log`. Seven XCTest regressions cover these effects in CI. No system keyboard preference was changed by this harness.

The Model the Domain principle led to the saved optional action, preserving the distinction between an unset preference and no owned reservation. Fix Root Causes led to applying the setting change that worked on the affected M5, rather than replacing keyboard monitoring with an unproven event tap. Prove It Works led to independent-process preference readback and restoration checks. Full app and UI verification still require Xcode; this is not a claim that the updated app has been installed on the M5.

## Remaining evidence

Install and test the updated app on the M5 when a release is authorized. Query remote storage when read access is available. Validate the Settings controls in the rendered app. The app fix and new fleet fields require an authorized app release before existing installations receive them. Investigate any recurring delay using its incident time.
