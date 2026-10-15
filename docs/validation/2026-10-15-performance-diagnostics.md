# Performance diagnostics investigation

The connected Mac is an M1 MacBook Pro with 8 GB RAM. Its installed WhiskerFlow is version 1.0, dated May 2026, and was not running. No WhiskerFlow diagnostic files, crash reports, or unified-log entries from the preceding two days were available. The affected Mac remains unconfirmed. The reported freezes and background-only failure therefore have no established cause. Screen sharing is not proven responsible.

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

## Remaining evidence

Obtain access to the affected Mac or its diagnostic ID and incident time, query the stored telemetry, and reproduce background dictation with and without screen sharing. Validate the Settings diagnostic-ID control in the rendered app. New fleet fields require an authorized app release before existing installations can emit them.
