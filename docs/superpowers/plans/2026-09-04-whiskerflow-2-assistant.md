# WhiskerFlow 2 Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or Atlas implement-spec for the corresponding reviewed packets. Track completed steps and proof below.

**Goal:** Deliver the seven approved voice features and private before/during/after meeting coaching.
**Architecture:** Native deterministic core and bounded audio metrics; an optional on-demand local generator; paired-device Atlas tools for cloud inference and owned draft/meeting persistence. Existing capture and identity remain the owners.
**Tech Stack:** Swift 5.10+, SwiftUI/AppKit, optional availability-gated FoundationModels, TypeScript/Convex and existing Atlas AI registry.
**Spec:** `docs/superpowers/specs/2026-09-04-whiskerflow-2-assistant.md`

## Global Constraints

- Keep macOS 14 minimum deployment target. M1 with 8 GB is the minimum hardware target.
- Preserve the snapshotted 2.0 baseline, recording/meeting/corrections behavior and unrelated main checkouts.
- Never claim M1 validation from the current M5/16 GB host.
- Explicit preview/Replace for AI text; explicit Save draft for Atlas writes; private owner-scoped coaching.
- No generative inference during recording/capture; one bounded inference request at a time.
- No production mutation, credential changes, public release or real-message sends in packet verification.
- Native new worktree `/Users/jacob/.codex/worktrees/whiskerflow-2-assistant`, baseline `41455a7`.
- Atlas candidate `/Users/jacob/.codex/worktrees/atlas-whiskerflow-2-assistant`, fetched baseline `9719ef10`.

## Task graph and ownership

| Packet | Result | Depends on | Owned files/interfaces |
|---|---|---|---|
| 1 | Deterministic assistant core | Baseline | New `Sources/WhiskerFlowCore/Assistant/` files and corresponding core tests |
| 2 | Confirmed paste/selection transactions | 1 | `Services/PasteService.swift`, `PasteCorrectionMonitor.swift`, new `SelectionEditService.swift`, app delivery wiring and tests |
| 3 | Atlas authenticated assistant contract | Settled spec | Atlas `http/notetaker.ts`, focused new meeting assistant module/schema, registry and runtime tests |
| 4 | Native Assistant and inference | 1,2,3 contracts | New native Assistant services/views, AppState capture-purpose routing, shortcuts, profiles and settings |
| 5 | Meeting bookmarks and coaching | 1,3 contracts | Meeting capture audio metrics/coordinator, Meetings view and persistent private coach state |
| 6 | Integrated E2E, resource proof, review | 2–5 | Verification harness, tests and validation docs; no unrelated refactoring |

### Task 1: Deterministic assistant core

Create `Sources/WhiskerFlowCore/Assistant/SpokenSelfCorrection.swift`, `WritingProfile.swift`, `MeetingCoachMetrics.swift`, `AssistantInferencePolicy.swift`, `AssistantRecords.swift` and `Tests/WhiskerFlowCoreTests/AssistantCoreTests.swift`.

Interfaces:
```swift
public enum SpokenSelfCorrection { public static func resolve(_ text: String) -> String }
public enum WritingStyle: String, Codable, CaseIterable, Sendable { case standard, conversational, polished, literal }
public struct WritingProfile: Codable, Equatable, Sendable { public var bundleIdentifier: String; public var style: WritingStyle }
public enum AssistantRecordKind: String, Codable, CaseIterable, Sendable { case note, taskDraft, clientUpdateDraft }
```
Expose public Codable/Equatable/Sendable records for pending quick-capture drafts, client vocabulary profiles and meeting bookmarks with UUID/string identity, timestamps and explicit sync state. Publish exact initializers in the report so integration consumes one interface. Use existing Vocabulary/VocabularyRule rather than a new correction format.

- [ ] Write conservative behavioral fixtures including:
```swift
XCTAssertEqual(SpokenSelfCorrection.resolve("Meet on Thursday, sorry, Friday."), "Meet on Friday.")
XCTAssertEqual(SpokenSelfCorrection.resolve("I am sorry about Friday."), "I am sorry about Friday.")
XCTAssertEqual(SpokenSelfCorrection.resolve("Do not remove the backup."), "Do not remove the backup.")
```
- [ ] Implement explicit bounded correction-marker parsing, preserving ambiguous clauses and original raw text at integration boundary.
- [ ] Add pure 60-second bounded own-mic/system activity accumulation, uncertain overlap/missing-track results and >=60-second prompt cooldown. Accept elapsed/duration/activity inputs, not text or audio storage. Write missing-source and overlap fixtures.
- [ ] Add pure inference admission policy: deny local generation while dictation/meeting recording, model unavailable, excessive input or memory pressure; no hidden cloud fallback. Test all denials.
- [ ] Run `swift test --filter AssistantCoreTests`; report actual failures/pass and commit only owned paths. Do not run whole suite or mutate main checkout.

### Task 2: Delivery and selected-text transactions

- [ ] Introduce an async delivery receipt with `verified`, `unverified`, `failed` and concrete retry eligibility. Use the exact insertion confirmation already proven by PasteCorrectionMonitor.
- [ ] Snapshot supported selected text plus exact prefix/suffix and AX identity; reject secure/unsupported/oversized fields before value reads.
- [ ] Add a selection replacement transaction that checks app, field and unchanged original range before changing anything. AX-selected-text write or targeted paste must preserve undo and verify output. Test Unicode, changed context, app termination, disabled permission and clipboard takeover.
- [ ] Wire AppState to real completion instead of treating an enqueued paste as success. Expose Copy and explicit Retry from the latest receipt without automatic repeated paste.
- [ ] Prove in TextEdit with known text, failed/stale replacement and undo; preserve existing correction observation tests. Commit narrow changes and provide review diff.

### Task 3: Atlas assistant contract

- [ ] Use the discovery report to extend existing paired-device dispatch, authorization, rate-limit and vocabulary owners. Write a versioned transport contract before native networking implementation.
- [ ] Implement allowlisted rewrite operations, authorized client list/profile, idempotent private quick drafts, owner-scoped bookmarks and before/after coach. Reuse registry/OpenRouter/usage helpers and existing tables where semantically correct; widen schema only for genuinely new private draft/bookmark state.
- [ ] Implement all server validators and runtime allow/deny/idempotency/refusal/timeout tests. Bound inputs and output schema; no provider key or arbitrary model/tool selection crosses to native.
- [ ] Use synthetic non-production API proof. Run only focused packet checks, then independent review and serialized Atlas quality gates in coordinator. Keep deployment proof distinct.

### Task 4: Assistant UI and inference

- [ ] Add Assistant coordinator/model, versioned Atlas client and optional macOS26 FoundationModels adapter. Session is on-demand and serial; cancellation/timeout and recording admission apply to both backends.
- [ ] Add one Assistant view: selected-text preview/action, quick capture draft, client selector, app writing preferences and cloud/local capability state. Reuse FlowStyle and accessible controls.
- [ ] Extend recording purpose so normal dictation pastes, voice editing records an instruction, quick capture records a draft; retain target/style/client snapshots at capture start. Put new shortcuts in the app menu with clear defaults and no collision with existing dictation/meeting hotkeys.
- [ ] Preserve raw recognition in history; apply safe self-correction and destination formatting before delivery. Client vocabulary merges with existing shared/personal precedence.
- [ ] Persist pending drafts locally before Atlas calls and show only acknowledged completion. Test relaunch/offline/duplicate retry, cancellation and stale selection using fake network only for failure injection; prove success against non-production Atlas.

### Task 5: Meetings integration

- [ ] Add bounded source activity callbacks to existing capture; do not retain new PCM buffers or run live LLM/ASR just for coaching.
- [ ] Add coach objective/preparation, private live panel/pause/hide, bookmark shortcut and timestamps to Meetings. Wire metrics to actual active capture start/stop/source gaps.
- [ ] Persist bookmarks and private review against capture session, upload idempotently after Atlas meeting acknowledgement, expose actual links/times.
- [ ] Generate post-review through the bounded Atlas owner endpoint, render evidence/timestamps and incomplete-source labels. Offline deterministic summary remains usable.
- [ ] Test fixture activity/cooldown, actual local capture path, restart/retry and Atlas owner denial. No automatic team sharing.

### Task 6: Completion proof

- [ ] Run new regression fixtures plus existing 2.0 suite once integrated.
- [ ] Walk actual native shortcuts, selected-text instruction/preview/replace/undo, quick draft offline/relaunch/save, profile isolation, bookmarks and coach before/during/after.
- [ ] Run synthetic local/cloud rewrite quality fixtures and record latency, content preservation and refusal behavior. Record optional model availability truthfully.
- [ ] Measure idle and peak native physical footprint/RSS, bounded live state and memory-pressure behavior. Publish an executable M1/8GB acceptance protocol; mark real hardware test pending unless that hardware is actually available.
- [ ] Independent whole-feature review, repair findings, final relevant checks, signed local build and outcome packet with exact native/Atlas SHAs and live deployment state.

## Ledger

- Baseline: native working changes preserved as `41455a7` in isolated worktree. Existing main checkout untouched.
- Architecture decision: generation is on-demand; live coaching is deterministic and private. The M1 budget is a release acceptance requirement, not inferred from model parameter count.
- Interface preflight: packet 1 publishes core types to packets 2/4/5; packet 2 owns paste/selection; packet 3 publishes transport to 4/5. AppState changes are serialized between packets 2 and 4; Meetings coordinator belongs to packet 5. No shared-file parallel writes.
