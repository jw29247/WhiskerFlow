# WhiskerFlow 2: voice assistance and meeting coach

Contract: Jacob requested all seven proposed features to be specified, built, and tested, plus a private meeting coach covering preparation, gentle live prompts, and post-meeting review. M1 MacBook with 8 GB unified memory is the minimum hardware target. This is an architectural extension to the existing 2.0 candidate, not a replacement of dictation, capture, or Atlas identity.

Wayfinder: direct path after resolving coaching scope with Jacob. Atlas delivery mode: FACTORY; native development uses isolated work and reviewed packets. Product implementation and local/non-production proof are authorized. Production deployment, real-message sends, and public WhiskerFlow release remain separate delivery boundaries.

## Product principles

Keep Dictate, Meetings, History and Corrections. Add one Assistant surface for selection editing, quick capture and preferences rather than a destination per feature. Meeting preparation, bookmarks and coaching belong inside Meetings. Every generative replacement has a preview and explicit Replace; every Atlas write has an explicit Save draft action and an acknowledged destination. Nothing sends email, Slack messages or publishes a client update. Explain unavailable capabilities without pretending completion.

## AC-1 — Reliable delivery

A completed transcript records its destination and delivery state: delivering, verified, sent-but-unverified, or failed/copied. Do not say Pasted until the editable target value confirms the exact insertion. Unsupported fields may use targeted keyboard delivery but are labeled unverified. Do not retry automatically: retry is explicit and checks the original destination/selection to prevent duplicated or misdirected text. Preserve the user's clipboard unless another copy claims it. Provide Copy and safe Retry from the delivery notice. A stale target offers Copy rather than guessing. Preserve corrections tracking on verified insertions.

## AC-2 — Spoken self-correction

Optional natural self-correction runs locally before vocabulary/formatting. Conservatively resolve explicit corrections such as “Thursday, sorry, Friday” and “Thursday, I mean Friday” within one spoken sentence. Resolve a clearly delimited “scratch that” clause, not an arbitrary earlier document. Preserve ambiguous apologies, negations, quotes and conversational “sorry”. Preserve the original recognition alongside processed output in history so a person can recover it. No generative cleanup is silently applied.

## AC-3 — Voice editing selected text

A dedicated shortcut snapshots selected text from the current supported non-secure field before showing Assistant. Dictate an instruction with the existing capture/transcription engine or choose Shorter, Friendlier, Professional, or Bullet points. Typed instructions are also supported. The preview shows original and proposed text. Replace reactivates the original app, verifies the same field and unchanged selected span/context, and replaces only that selection; stale selection refuses replacement and offers Copy. Cancel performs no text mutation. Generation, cancellation, refusal, timeout, offline and unsupported field states are visible. Input is capped at 8,000 characters and output at 8,000 characters. Voice instructions never paste directly into the original field.

## AC-4 — Writing profiles per app

User-controlled profiles keyed by bundle identifier: Default, Conversational, Polished, Literal. Defaults do not surprise existing users: no automatic profile until selected. Literal bypasses self-correction and formatting while preserving the raw recognizer output. Conversational and Polished apply explicit local formatting preferences; optional AI tone rewriting is an explicit Assistant action, not a hidden network request for every dictation. Settings explain the distinction. Capture the destination profile at recording start so switching apps during transcription cannot change it.

## AC-5 — Client vocabulary profiles

An optional active client profile combines the existing shared vocabulary with client-specific terms and user overrides. Client selection is explicit; never infer a client by scanning documents. Atlas provides only authorized client choices and its existing governed vocabulary projection. Personal client terms persist locally and do not leak between clients. Preserve cached client vocabulary offline, label freshness, and allow clearing a client. Existing personal rules win on conflicts. Show the active client beside dictation.

## AC-6 — Quick capture to Atlas

A dedicated shortcut or Assistant button records a thought into a local draft instead of pasting. Choose Note, Task draft or Client update draft; select an authorized client where needed; edit title/body and explicitly Save to Atlas. Persist pending drafts locally before attempting a write. Use a stable request ID for retry: duplicate requests create one owned draft. Return an acknowledged Atlas reference/link. Reopening/retrying an offline draft preserves content. These are reviewable drafts, never automatically published client updates or tasks assigned to another employee.

## AC-7 — Meeting bookmarks

During an active meeting, a button/shortcut records a timestamp plus optional label. The UI confirms the bookmark without stopping capture. Persist bookmarks against the encrypted/local session identity, upload with stable IDs after the meeting identity is known, and preserve through retry/relaunch. Bookmarks link to the same meeting and timestamp in Atlas; cross-owner or invalid timestamps are rejected. Bookmarks are not evidence of words spoken by themselves.

## AC-8 — Meeting coach

Coach is opt-in and private to the owner. Preparation shows the person's objective, agenda/checklist, and optional Atlas-generated prompts based only on authorized meeting/client context. A local template works offline.

During a call, provide an unobtrusive, dismissible coach panel with elapsed time, the user's own sustained-speaking estimate, breaks/turn-taking reminders, and time-to-wrap reminders from the selected objective/end time. Use microphone versus system-audio activity windows already available from capture; bound the window to 60 seconds and update no faster than once per second. Mark estimates as estimates: shared speakers, echo, silence, missing tracks and overlap make attribution uncertain. Do not name who interrupted whom or compute a “performance score”. Avoid filler/pacing claims without actual timed transcript evidence. Cool down prompts for at least 60 seconds; pause/hide stops coaching analysis without stopping recording. No generative model or cloud request runs continuously during capture.

Post-meeting review includes deterministic observable metrics and optional AI feedback with transcript-backed examples/timestamps, limited to the owner's meeting. State when evidence is incomplete; do not invent quotes or attribute statements to an identity without provenance. Focus on clarity, structure, questions, next steps and the user's chosen objective. No emotion, personality, health, protected-trait, employee-ranking or hiring assessment. The owner can save/delete coaching; it is not automatically shared with the team.

## Inference and M1/8 GB constraints

- Keep macOS 14 minimum deployment target. An optional Apple Foundation Models implementation may be availability-gated to macOS 26 and Apple Intelligence availability.
- Deterministic first: delivery validation, self-correction, formatting, vocabulary, bookmarking and live coach metrics do not require an LLM.
- Optional local short-form rewriting is on demand, one request at a time, with bounded input/output and cancellation. No additional always-resident downloaded LLM; no inference during recording/capture. Release the generation session after use. If the system model is unavailable, expose that state and use Atlas only when cloud assistance is explicitly enabled.
- Atlas owns OpenRouter credentials, model selection, cost/usage logging, persisted rate limits and owner authorization. The client never receives an OpenRouter API key, chooses an arbitrary provider/model, supplies employee identity, or executes model-suggested tools.
- Cloud sends only the selection/instruction or an explicitly selected meeting/draft. No continuous screen, clipboard or unrelated document capture. Use structured responses and validate all fields after generation. Preserve refusal/offline/error states.
- Target added idle memory under 50 MiB and bounded live coach state under 1 MiB. Target normal native-process peak under 2.5 GiB for the end-to-end 8 GB workflow, with no simultaneous generative/ASR jobs. These are acceptance targets, not claims until measured. Record native RSS/physical footprint and external system-model service limitations separately.
- Validate M1/8 GB with a 30-minute meeting, browser/video call active, consecutive dictations, selected-text editing after recording, and offline retries. Current M5/16 GB testing cannot stand in for this hardware acceptance.

## States and proof

Pure fixtures cover safe/unsafe self-corrections, profile precedence, scope changes/Unicode, coach missing-source/overlap/cooldown, invalid durations and inference admission. Native integration covers delivery receipt/clipboard ownership, actual external selection replacement, voice-instruction routing, persisted pending drafts/bookmarks and opt-out. Atlas runtime tests cover authentication, revoked/foreign device and owner denial, bounds, duplicate requests, provider timeout/refusal, validated output, private coaching and authorized client scope. Use synthetic content for inference evaluations; report content preservation as well as latency.

User-visible acceptance requires the real native journey plus an acknowledged non-production Atlas record/result, not only mocks. Record code-only, local-runtime, staging and production proof separately. Preserve current 2.0 UI and meeting/correction regressions. Independent review precedes final quality gates and any release action.

## NG — Non-goals

No autonomous publishing/messaging, changing permissions or credentials, arbitrary agent/tool execution, always-on screen capture, cloud transcription of every dictation, silently training/fine-tuning on corrections, large bundled default LLM, or claiming M1 performance from this M5 host.
