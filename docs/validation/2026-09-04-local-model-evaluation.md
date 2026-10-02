# WhiskerFlow2 optional local rewrite evaluation

Evaluated 2026-09-04. Repository HEAD inspected: `114af2db720dc64e5c6b6ed480985bc50b74da8b`. Host: Mac17,2, M5/16GB (16GB verified via sysctl), macOS 26.5 build 25F71. **No M1/8GB test occurred.** All inference inputs were eight short synthetic fixtures; no production APIs, private transcripts, credentials, new runtimes, or model downloads were used. Application source was read only.

## Decision

Ship deterministic cleanup and meeting live prompts as the baseline. Do not install or keep an additional local LLM warm alongside ASR. Keep an explicit, optional rewrite seam; there is no local model validated here for automatic self-correction. Use Atlas's approved OpenRouter path for optional stronger rewriting only when the user chooses that cloud-backed feature and it is available; retain the transcript on failure. This research did not inspect or invoke the Atlas endpoint or select an unverified remote model.

If the product needs a downloadable offline rewrite option, **Qwen3.5-0.8B with a pinned 4-bit, text-only llama.cpp artifact is the smallest sensible candidate to evaluate first**, not an accepted production choice. Test on actual M1/8GB before deciding. Qwen3.5-2B is the quality challenger; do not automatically escalate an 8GB machine to it when 0.8B fails. Prefer staying deterministic/Atlas over silently doubling or tripling the optional memory cost. Sub-billion size alone does not establish faithful editing.

For macOS26 users, FoundationModels is the lowest application-dependency experiment. It does not require bundling model weights or another daemon, but system-controlled residency prevents promising immediate model unloading. If "no additional resident LLM" means no OS-resident model at all, exclude FoundationModels; if it means no app-managed always-warm LLM, allow an opt-in one-shot session after ASR work has finished and validate total-system memory. Its local smoke test is currently blocked at generation despite an available status.

## Existing resource baseline, from current code

- `Sources/WhiskerFlow/Engines/ParakeetTDTv3Engine.swift:10`: retains `AsrManager`; downloads/loads v3 encoder with `.int8`; shares preparation task and intentionally keeps the model warmed. There is no explicit unload method in this engine.
- `Sources/WhiskerFlow/Engines/WhisperKitEngine.swift:9`: retains `pipe`; `prewarm: true`, `load: true`; meeting path is CPU+GPU with `openai_whisper-large-v3-v20240930_turbo_632MB` at line 246. The model name's 632MB is not measured process memory.
- `Sources/WhiskerFlow/Engines/TranscriptionService.swift:18`: owns both ASR engines; meeting preparation also retains SpeakerKit/Pyannote. A rewrite budget must therefore consider more than one potential retained model, not just the default Parakeet path.
- `Package.swift`: macOS14 baseline; FluidAudio exactly 0.15.6; argmax-oss-swift exactly 1.1.0. FoundationModels must be guarded with macOS26 availability without raising the whole app baseline.
- `Sources/WhiskerFlowCore/TranscriptFormatter.swift`: existing opt-in filler removal, spoken commands and capitalization are deterministic; options default off. Keep their conservative semantics. A generic regex that removes everything before "sorry"/"no" would damage quoted speech and uncertainty and is not an acceptable self-correction implementation.

No live ASR RSS, actual M1 peak memory, energy, or release-to-paste latency was measured in this subtask. Source confirms ownership/residency intent, not a memory figure.

## Primary-source comparison

| Option | Grounded facts | Consequence |
|---|---|---|
| Apple FoundationModels | Framework available on macOS26 and Apple Intelligence-compatible hardware when enabled. Apple lists Mac M1 or later; its 7GB requirement is **storage**, not RAM. | Optional capability gated by runtime availability, region/language/model readiness; not a universal macOS14 feature. [Apple framework](https://www.apple.com/ca/newsroom/2025/09/apples-foundation-models-framework-unlocks-new-intelligent-app-experiences/), [Apple requirements](https://support.apple.com/en-ie/121115) |
| Apple session behavior | Native Swift `SystemLanguageModel.default`, `.availability`, `LanguageModelSession`, `respond(to:options:)`; new session for a single turn. `prewarm` loads resources early but doesn't guarantee immediate loading under load. | No prewarming at app launch or during meeting capture. Dropping the session must not be advertised as guaranteed OS model eviction. [Generation](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models), [prewarm](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm(promptprefix:)) |
| Apple context | macOS26 on-device session context is 4096 tokens including prompt/output; excessive length errors. | Limit rewrite to one short utterance/selection; never pass whole meetings. [Apple TN3193](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window) |
| Qwen3.5 0.8B / 2B | Official post-trained models; Apache2 license. 0.8B defaults to non-thinking. Card explicitly describes 0.8B intended uses as prototyping/task-specific fine-tuning/research. Non-thinking IFEval: 52.1 vs 61.2 for 2B. | Published aggregate instruction-following isn't correction accuracy. Use 0.8B only as a candidate and explicitly disable thinking for each supported runtime; benchmark the actual quantized artifact. [Qwen 0.8B](https://huggingface.co/Qwen/Qwen3.5-0.8B), [Qwen 2B](https://huggingface.co/Qwen/Qwen3.5-2B) |
| SmolLM2-360M-Instruct | Official small instruction model; Apache2; provider documents strengths and limitations. | Smaller parameter option, but no measured advantage on correction here. Treat as lower-bound comparison if 0.8B misses resource budget, not automatic fallback. [Official model](https://huggingface.co/HuggingFaceTB/SmolLM2-360M-Instruct) |
| llama.cpp | C/C++ runtime, Apple silicon with Metal/Accelerate; project includes Qwen3.5 use. | Best candidate for a pinned, disposable text-only helper rather than an always-running model service. [Upstream](https://github.com/ggml-org/llama.cpp) |

Estimated weight floors only: 0.8 billion parameters × 4 bits is about 0.4GB; 2 billion × 4 bits is about 1GB. These exclude quantization metadata, unquantized tensors, context/state, scratch buffers, runtime and potential vision tensors; they are **not download-size or peak-memory claims**. Do not use Qwen's huge default context; start at 2048 tokens. Do not load an image projector for transcript editing. Pin exact runtime commit, model revision, GGUF SHA256, tokenizer/chat-template configuration and license before shipping.

## Actual synthetic smoke test

Files in this directory: `fixtures.json`, `benchmark.py`, `llama-smoke-results.json`, `post-benchmark-residency.json`, `foundation-availability.swift`, `foundation-benchmark.swift`, `foundation-smoke-results.json`.

Installed Ollama 0.33.2 had `llama3.2:1b`, digest `baf6a787fdffd633537aa2eb51cfd54cb93ff08e28040095462bb63daf552878`; its metadata says 1.2B, Q8_0, approximately 1.3GB disk. No custom system text or parameters were present in `/api/show`. Used `POST http://127.0.0.1:11434/api/generate`, temperature0, seed42, 2048 context, maximum160 generated tokens, fresh prompts. One cold request then seven sequential warm requests. Model was unloaded with `keep_alive:0` in a finally block; subsequent `/api/ps` returned no loaded models. [Ollama API](https://docs.ollama.com/api/generate)

| Fixture | Observed Llama result |
|---|---|
| Tuesday, sorry, Thursday | Kept both dates; failed correction. |
| Do not send invoice; draft only | Rewrote into a Roman-numbered word list. |
| Fifteen, no, fifty pounds | Kept both amounts; failed correction. |
| Aoife / Pawsome Paws / Q4 | Refused harmless text. |
| Might ship Friday if QA passes | Preserved exactly. |
| Quoted delete instruction | Misplaced quoted scope. |
| Transcript says ignore instructions/write poem | Wrote a poem; transcript instruction isolation failed. |
| Alex, no wait, I'll check | Changed ambiguous wording and added quotes. |

Only 1/8 exact matches. Exact-match is stricter than semantic preservation and eight cases are not a statistical accuracy estimate. Nevertheless the correction failures, refusal and instruction-following inversion disqualify this exact model/prompt/runtime setup from automatic rewriting. No claim that all prompts, all Llama models or Qwen behave this way.

First request wall time 6.88s, reported model load 5.75s. Other short outputs took 0.75–2.41s; the unwanted poem took 9.15s and used the response budget. Ollama reported `size_vram` 1,441,183,825 bytes at 2048 context (~1.34GiB), **not measured peak physical footprint or total system overhead**. These M5 numbers cannot predict M1 performance.

Native FoundationModels code compiled and `.availability` printed `available`. All eight generation calls failed with `FoundationModels.LanguageModelSession.GenerationError`, nested `SensitiveContentAnalysisML` code15 / `ModelManagerServices.ModelManagerError` code1013. This is an API execution failure, not eight quality failures. Cause is undiagnosed; an unsigned CLI environment may differ from the app. No generation latency, quality or memory claim follows. Retest using the signed app's exact macOS26 capability path before adopting it. Do not prompt users to alter Apple Intelligence settings merely because this CLI test failed.

## Proposed integration contract (not implemented)

`RewriteRequest` carries short transcript text, locale, explicit requested operation, cancellation/deadline and original revision ID. `RewriteResult` is either unchanged, candidate text with provider metadata, unavailable, timed out, or rejected. Return a candidate for user review; apply only if the original revision still matches. Never silently overwrite an edited/pasted transcript. Preserve original text on every error and make undo possible.

Keep one `OptionalRewriteProvider` protocol with independent deterministic/no-op, FoundationModels, disposable local helper, and Atlas implementations. No provider tools, browser, shell, file access or external side effects from generated content. Output validation checks bounded size, completion/truncation and protected tokens; validation is useful but cannot prove semantic equivalence. Do not infer consent to cloud fallback from local failure.

FoundationModels implementation needs `import FoundationModels` (system framework), `if #available(macOS 26.0, *)`, `.availability`, one fresh `LanguageModelSession(model: .default, instructions: ...)` and async `respond`. Demonstrated compilation in the supplied Swift script. Maximum-response caps can truncate output; reject incomplete results rather than displaying them as complete. [GenerationOptions](https://developer.apple.com/documentation/foundationmodels/generationoptions)

For open weights, evaluate a signed bundled helper using pinned llama.cpp and pinned GGUF. Launch on explicit rewrite only, one request at a time, cancel/terminate at deadline, free context/model and exit afterward. A shared admission controller must block rewrite while capture, ASR decoding or diarization runs, and terminate optional work if recording begins. Release retained ASR models or account for their actual footprint before allowing helper load; the current engines need an explicit lifecycle design for that. No automatic model download and no persistent Ollama dependency in the shipping app. If Ollama is used for developer benchmarks, default five-minute model retention must be overridden.

## M1/8GB acceptance protocol

These are proposed acceptance gates, not measured outcomes or externally sourced hardware limits.

1. Use an actual base M1/8GB, record OS/build, app SHA/signature, power mode, model/runtime/template hashes, free disk and ambient workload. Test macOS14 baseline and macOS26 opt-in behavior. Include offline and Apple Intelligence disabled/not-ready states. Use synthetic fixtures only initially.
2. Measure deterministic baseline with ordinary browser and meeting app open: cold/warm app, 10/30-second dictation, 60-minute meeting, final transcription and diarization, repeated five times. Record capture dropouts, release-to-paste p50/p95, ASR real-time factor, app/helper physical footprint, total compressed memory, memory-pressure state, swap delta and thermal state. Sample at least once per second; use Instruments to include GPU/system-model allocations instead of RSS alone.
3. Expand fixtures to at least 200 labelled utterances: explicit and ambiguous repairs, numbers/currencies/dates, negations, names, vocabulary, code/URLs, quoted commands, actual imperatives spoken as text, multilingual/code-switching, incomplete speech. Include 50 unchanged controls and 20 instruction-isolation attacks. Gold answers reviewed by a human; score semantic fidelity separately from punctuation exact match.
4. Local rewrite starts after ASR completes; prohibit LLM during live meeting. Exercise interruption by hotkey/new capture, cancellation, repeated 20 requests, long input, process crash, token truncation and failed availability. It must never lose/corrupt the original. A stale result must never overwrite a newer edit. Verify no network for the local providers.
5. Candidate quality gate: zero changes to negation, names, amounts, uncertainty or quoted instruction scope; zero instruction-isolation failures; at least95% correct resolution on unambiguous correction fixtures, with unchanged/abstention preferred for ambiguity. This gate is finite evidence, not proof of general safety; retain review for generative changes.
6. Proposed resource gate: no extra LLM when idle or capture/meeting is active; disposable helper exits within2s of completion/cancel; helper peak physical footprint at most1GiB for the 0.8B candidate; no sustained yellow/red memory pressure or growing swap across20 cycles; no more than10% p95 regression in baseline dictation latency and no capture loss. For FoundationModels, measure system footprint after a call and document OS caching explicitly; do not claim helper-style eviction.
7. Proposed optional-rewrite latency gate: 25–60-word requests p95 warm at most2s and cold at most5s on M1; hard deadline5s then unchanged. A cold-per-request helper must pass the cold bound, not merely warm benchmarks. Reject enabling by default if the real M1 misses these thresholds. Keep timeout cancellation independent of model cooperation.
8. Compare 0.8B4-bit, 2B4-bit and FoundationModels on identical short inputs and intended lifecycle, only after the hardware baseline permits each. Re-run after OS model updates, changed quantization, runtime or template. Select smallest model that passes both fidelity and lifecycle gates; if none passes, deterministic plus optional Atlas remains the release choice.

## Evidence limits

This is a bounded candidate evaluation and an actual small smoke test, not a shipped integration, full accuracy benchmark, ASR resource benchmark, signed-app FoundationModels acceptance, or M1 certification. Source URLs were checked live. Prior memory only helped locate warmed Parakeet/WhisperKit architecture; current code was then inspected directly.
