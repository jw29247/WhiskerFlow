# Device performance work — 4 September 2026

Measure the installed WhiskerFlow 0.8.5 (build 19) before changing the app, then replay identical saved audio on a release-mode candidate. Preserve existing meeting-capture work and real history. The initial benchmark phase did not publish a release; the subsequent authorized release is tracked below.

Installed executable SHA-256: `241d51d012e3fb517984932b654d10b33109f525c145eff919300a2032312e75`.

Baseline runs use `/Applications/WhiskerFlow.app` with `CFFIXED_USER_HOME` pointing to a disposable home under `/private/tmp`. Four existing recordings (2.6, 11.5, 31.4 and 143.5 seconds) are copied there, three replay records per audio file. The model cache is shared; microphone capture and meeting mode are not used. Retry is invoked through the actual app UI, with Parakeet TDT v3, medium preference, English, copy-only delivery, and Apple fallback disabled. Timing uses filesystem modification timestamps between the app's transcribing and transcribed store writes; it excludes click/tool overhead and clipboard delivery. Raw results remain local under `.build/performance`, including transcript text for exact-output comparison; do not commit them.

Investigate: capture-to-file work on the main actor; model preparation reentrancy; duplicate text processing during copy/history rendering; file transcription's disk-backed conversion; editor stale state following retry. Keep the same recognition model and verify output, rather than trading accuracy for speed.

## Implementation and verification plan

- Preserve Parakeet TDT v3 int8 model/decoder settings. Coalesce concurrent warm-up and transcription preparation into one model-loading task.
- Initial candidate: decode captured 16 kHz samples directly and persist after delivery. Release review superseded that ordering: save the WAV and retryable record before decoding, encoding the WAV off the main actor. Then decode existing samples without reading/converting the file again. Preserve durable file retry and Apple fallback for failures.
- Fast-path already-normalized ASCII clipboard text and cache regexes for other text; count word boundaries without allocating normalized text and word arrays. Differential Unicode/whitespace tests compare against the old implementation.
- Guard delayed clipboard restoration with the pasteboard change count so newer Copy actions win. Test with a private pasteboard.
- UI draft-state corrections are owned by the concurrent UI task, not this change.

For isolated tests, the source snapshot is `/private/tmp/whiskerflow-performance-work`. It preserves pre-existing meeting changes but excludes the concurrent UI task's unfinished draft test. SwiftPM checkout/artifact caches are copied; absolute-path-dependent compiler products must be rebuilt. The opt-in real-audio XCTest uses `WHISKERFLOW_BENCHMARK_MANIFEST` and `WHISKERFLOW_BENCHMARK_OUTPUT`. Model execution stays local.

## Results on Jacob's Apple M5 MacBook Pro, 16 GB

UI replays: three trials per clip per run. Values below are milliseconds between the actual app's transcribing and transcribed history writes (not full key-release-to-paste time). The unchanged installed binary was rerun after the candidate to check workload/cache effects.

| Saved audio | Original initial median | Candidate median | Original control median |
|---|---:|---:|---:|
| 2.6 s | 89.2 ms | 73.1 ms | 519.8 ms |
| 11.5 s | 215.0 ms | 113.3 ms | 498.0 ms |
| 31.4 s | 1457.8 ms | 258.2 ms | 499.9 ms |
| 143.5 s | 2944.5 ms | 671.3 ms | 1181.3 ms |

The candidate was faster than both original-run medians for all four clips, with 12/12 candidate transcripts exactly matching the original. The original showed substantial variation (up to 3.62 seconds for a 2.6-second clip in the control), so the large initial-to-candidate ratios must not be presented as pure neural-model acceleration. Against the better original median, the 31.4-second clip improved about 48% and the 143.5-second clip about 43%. This is a local, small-corpus UI comparison, not a statistical guarantee across workloads.

The paired production-engine test alternated file and captured-sample paths six times on each clip (48 transcriptions / 24 pairs). All texts matched exactly. Median file/captured timings were 75.5/67.6 ms (2.6 s), 171.6/171.3 ms (11.5 s), 333.7/304.9 ms (31.4 s), and 759.7/789.8 ms (143.5 s). These modest, mixed recognition results are why file replay retains the original disk-backed threshold. Captured samples avoid WAV encoding and history writes before delivery; that removes UI-thread work independently of decoder time.

Text microbenchmark: 100 operations on the existing 367-word transcript, then on 100 repetitions of that text. Per-operation normalization improved from 0.204 ms to 0.031 ms for the actual transcript and 23.78 ms to 0.50 ms for the large stress case. Word counting improved from 0.251 ms to 0.038 ms and 14.06 ms to 0.574 ms respectively. These are text-preparation timings, not total mouse-click-to-clipboard timings. Checksums matched, and differential tests cover 2,744 combinations of ASCII/Unicode text and whitespace.

Validation: final isolated release suite passed 252 tests, with two opt-in tests skipped and no failures. Real-audio validation was run separately with its environment flags enabled. Model preparation tests cover concurrent callers and retry after failure; pasteboard tests cover restoration and a newer copy superseding an older paste. Existing capture coordination, pending persistence, retention, and formatting tests pass. The first full test run failed five glossary checks because the isolated snapshot omitted the root glossary; copying the unchanged fixture resolved those environment failures. Existing WhisperKit Swift 6 sendability warnings remain.

The release candidate was assembled from the tested optimized executable and the installed app's matching resources/frameworks. Nested Sparkle components and the app were signed locally with an ad-hoc signature; `codesign --verify --deep --strict` passed. Candidate: `.build/performance/WhiskerFlow Performance.app`. It uses a separate bundle ID, so this benchmark proves stored-audio replay and copy, not microphone/global-hotkey permissions or auto-paste into another application. No public release or installed-app replacement was performed. The original installed executable hash remained unchanged.

Concurrent UI work is preserved in the shared checkout. The benchmark snapshot includes its release-disabled preview helper needed by the shared AppState, but retains the original UI for comparison. It does not claim end-to-end QA of the concurrently redesigned UI.

Local raw evidence (contains private transcript text; ignored by git): `.build/performance/installed-baseline.json`, `candidate-ui.json`, `installed-control.json`, `production-capture.json`, `file-v-memory.json`, `final-tests.log`, and `build-evidence.json`.

## Release 0.8.7

The performance changes were integrated onto released 0.8.6 in an isolated checkout, preserving its cleanup and excluding unfinished meeting and UI changes in the shared checkout. Version 0.8.7 uses build 21. The measurements above remain measurements of the initial benchmark candidate against installed 0.8.5. Release integration receives a fresh release-mode test suite and real-audio equivalence check before signing and publication.

Release review found that persistence after decoding could lose captured audio if the app exited during model preparation or recognition. The shipping integration restores durable WAV and retryable-record creation before decoding; encoding and transcript formatting run off the main actor. Sample decoding shares the existing history, telemetry, and fallback lifecycle. Consequently, the earlier candidate timing table must not be treated as a measured speedup for the final release. The model-loading and text-processing changes remain; the same recordings are checked for exact-output equivalence on the integrated release.
