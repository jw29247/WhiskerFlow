# WhiskerFlow 2 assistant candidate

The candidate implements the seven approved voice features and private preparation, live prompts and post-meeting coaching. It is a signed local development build, not a production release. Original working checkouts were preserved; implementation lives on `codex/whiskerflow-2-assistant` in isolated native and Atlas worktrees.

## What is implemented

| Capability | Delivered behavior |
|---|---|
| Spoken corrections | Conservative explicit word repairs and bounded scratch-that clauses; ambiguous, quoted or negated examples remain unchanged. Raw recognition stays recoverable in History. |
| Voice editing | Capture a supported external text selection, dictate or type an instruction, request an Atlas preview, then explicitly Replace or Copy. Replacement requires the original field and contents still to match. |
| App writing profiles | Standard, conversational, polished and literal profiles, captured for the destination app at recording start. Literal preserves raw recognition. |
| Client vocabulary | Authorized Atlas client vocabulary cached locally, explicit client selection and private per-client terms; personal correction rules take precedence. Account changes clear client-scoped caches and consent. |
| Quick capture | Note, task draft and client update draft, durable on this Mac, editable before first submission and explicitly saved to Atlas with idempotent acknowledgement. No assignment, publishing or external message send. |
| Meeting bookmarks | Local durable timestamps with stable UUIDs; bounded storage, restart/retry, and idempotent Atlas sync after meeting finalization. |
| Paste recovery | Observed delivery status, clipboard ownership protection, Copy on uncertainty, and safe Retry only when no paste event was sent and the original target remains valid. |
| Meeting coach | Local goal/agenda preparation; opt-in live prompts using bounded mic/system activity, pause/hide and cooldown; offline recap; explicit private Atlas post-review with validated evidence timestamps and incomplete-source labels. |

Assistant is in the sidebar (Command-5). Dedicated hold shortcuts are Option-Shift-Command-E for voice editing and Option-Shift-Command-N for a draft; Option-Shift-Command-B bookmarks an active meeting. The app preserves a conflicting user-configured main shortcut. A new draft uses the selected capture kind and client at recording start.

Cloud AI is off until explicitly enabled. The native app uses the paired Atlas device contract; provider credentials and model selection remain server-side. Live coaching has no additional transcription pipeline or language model. No extra resident LLM, FoundationModels adapter or model download is shipped. The optional local-model experiment did not qualify a model: see [evaluation and M1 protocol](2026-09-04-local-model-evaluation.md).

## Executed proof

All runs below occurred on M5/16GB, macOS 26.5. They do not establish M1/8GB acceptance.

- Native final source suite: `swift test --skip DictationPerformanceTests` — 288 XCTest tests, 3 skips, zero failures; another 10 Swift Testing meeting tests passed. The opt-in localhost integration test is one expected skip without its environment file. Log: `/tmp/whiskerflow-assistant-merged-tests.log`.
- Native actual HTTP integration: `WHISKERFLOW_ASSISTANT_ACCEPTANCE_FILE=... swift test --filter AssistantAtlasAcceptanceTests` — one test passed in 2.781 seconds against final Atlas modules `a4ed03ea`. It exercised authorized client vocabulary, all three draft types, duplicate identity/read/discard, rewrite enqueue/poll, real native bookmark finalize/sync/restart and typed private post-coach. Log: `/tmp/whiskerflow-assistant-atlas-acceptance.log`.
- Atlas packet: 57 focused Convex/HTTP tests, package typecheck and eight registry tests passed. Explicit localhost schema dry-run passed. Exact backend code commit: `a4ed03ea580a697076c84e5b5a3c5a0384f31585`; settled contract document commit: `d324eed1`.
- The integration target was a real disposable Convex backend on localhost, including device authentication, mutations, scheduler, canonical inference and usage ledger. Only its provider network boundary returned synthetic AI responses; fixture-only seed and disabled unrelated crons were confined to the disposable runtime. This is not live OpenRouter quality proof or a production deployment.
- Signed app UI: inspected Assistant and Meetings; created a local draft, confirmed persistence after relaunch, edited title/body and removed the synthetic draft; saved/reset an application profile; verified shortcut menu; generated local preparation with cloud consent off and cleared the synthetic inputs.
- Actual external edit: the disposable AppKit editor changed exactly once from `Please send the report to Mark before Friday.` to `Please send the summary to Marc before Thursday.` using the real guarded paste path. A second trial changed the document after capture; Replace refused and the changed text remained intact. The debug-only preview supplied synthetic output without calling AI. TextEdit was unresponsive, so it was not force-quit or used as acceptance evidence. Undo and secure-field behavior are not claimed as complete native UI acceptance.
- Final Developer ID development bundle passed code-sign verification. Build log: `/tmp/whiskerflow-assistant-bundle.log`. The build is not notarized or published as a 2.0 release.

Review repairs cover account switching during queued requests, durable-write failure, encoded storage size, stale asynchronous completion, selection recapture, quick-draft lifecycle, private vocabulary isolation, terminal result permissions, bounded coach output and retention idempotency. Pattern guards and exact quotes cannot prove arbitrary model semantic safety; previews and live provider evaluation remain necessary.

## Resource evidence and remaining acceptance

A short final-build snapshot during existing model/meeting preparation showed physical footprint 524.4 MB, process high-water mark 853.3 MB and RSS about 501 MiB. This is neither idle memory nor a complete meeting peak. The trace is `/tmp/whiskerflow-assistant-memory.txt`. Local live coaching retains at most 60 activity inputs and does not retain additional PCM buffers.

The machine ran almost out of disk space during UI checks. Regenerable module/index caches created by this task were removed, the build was reopened, and local preparation was rechecked successfully. The test app was then closed. No application data or original source checkout was deleted.

Release acceptance still required:

1. Actual M1/8GB run of the published resource/latency protocol, including a long meeting, final transcription and ordinary browser/meeting workload. The current host cannot provide this proof.
2. Fresh real meeting journey through microphone/system capture, voice shortcuts, bookmark, final Atlas transcript and private review. Fixtures and earlier recording history do not replace this.
3. Live OpenRouter structured-output and semantic-quality evaluation, including names, negation, amounts, uncertainty, quoted instructions and refusal behavior. The local integration used synthetic provider results.
4. Authorized Atlas deployment, authenticated app-to-deployed-Atlas acceptance, and release signing/notarization. No production merge/deployment or public app release was performed.

The local build is at `.build/arm64-apple-macosx/debug/WhiskerFlow 2.app` in this native worktree. The backend must be deployed before its new tools are available on the user's production Atlas connection. Local deterministic features remain available without those tools.


## Upstream integration

Remote main advanced to `b04a2c7` during this work. The final native candidate merges that cleanup/performance release, preserving durable WAV recovery before final decoding and adopting parameterless Parakeet preparation and current audio-device APIs. Meeting delivery retains the transport protocol required by its new dependency seam; guarded paste, raw recognition, activity metrics and reliable delivery remain intact. The merged suite passed 288 XCTest tests (3 skips) plus 10 Swift Testing tests. The reduction from the earlier 295 is upstream removal of low-value tests, not suppression of failures.
