# WhiskerFlow agent-environment retrospective — 4 October 2026

The highest-value improvements are to make source selection explicit and make the stability evidence belong to a specific build. Existing CI already covers Swift compilation, tests, formatting, JSON resources and packaging scripts.

## Scope and evidence

Applied the installed [retro](../../.agents/skills/retro/SKILL.md) and [writing-for-agents](../../.agents/skills/writing-for-agents/SKILL.md) skills. The current installation session is the primary scope, supplemented by a targeted review of the 1 October stability session and current files in the WhiskerFlow 2 worktree. This is an environment retrospective, rather than a new application stability audit.

Sources inspected:

- Current `git status`, `git worktree list --porcelain`, commit history, skill directories and installed app `Info.plist`.
- The 1 October stability review's actual messages, particularly lines 42, 128 and 169 of `/Users/jacob/.codex/sessions/2026/10/01/rollout-2026-10-01T22-43-37-01a0f96c-4407-7a90-919f-f11b7d830d41.jsonl`.
- CI and packaging workflows in this checkout and `/Users/jacob/.codex/worktrees/whiskerflow-2-assistant`.
- The development worktree's `script/review_stability.py`, `script/review_diagnostics.py`, `script/build_and_run.sh`, `README.md`, reliability-loop notes and 2.0 release brief.
- Upstream skills at revision `24fe0ef7737efae15c87225755e9f6f5965e4888`.

## 1. High: make the correct source discoverable at session start

**Observed:** `/Users/jacob/WhiskerFlow` is on `main` at `114af2d`, an August commit, with substantial existing uncommitted work. The development worktree is on `codex/whiskerflow-2-assistant` at `27b2c8a`, dated 2 October. `/Applications/WhiskerFlow.app` reports version `0.8.7` and build revision `dcb6f3883a63-20261002T183508Z`; that source is in the development branch. Neither checkout contains an `AGENTS.md` or `CLAUDE.md` navigation file. The 1 October review encountered the same source mismatch.

**Consequence:** a fresh agent can inspect, test or change an old source tree while believing it represents the installed app. It also spends time recovering the same worktree and build relationships.

**Recommendation:** add a small project instruction file pointing runtime investigations to a source-selection guide. The guide should require checking worktree, HEAD, dirty state and the installed/logged build before selecting a source tree. Treat the path observed here as a starting point that must be verified, rather than a permanent hard-coded instruction. Include the existing reliability-loop and release-brief pointers and prefer the bundled app workflow for UI validation.

**Completion criterion:** an agent can name the exact app build and matching source before changing code or interpreting logs, while preserving unrelated edits.

## 2. High: partition stability evidence by build and test the assessment

**Observed:** [review_stability.py:35](/Users/jacob/.codex/worktrees/whiskerflow-2-assistant/script/review_stability.py:35) starts a window by timestamp and keys sessions by launch/session. It neither retains nor filters `build`. Its `assess` function pools all sessions in that window.

A read-only synthetic probe supplied 50 sessions across three days, split evenly between two build IDs, with 100 ms finishes and no faults. The assessment returned `passing: true`, even though neither build had 50 sessions. This probe imported the existing module with bytecode writing disabled and did not read or modify the live reliability ledger.

**Consequence:** a build switch inside an observation window can mix old and new evidence. A later summary can look sufficient for the candidate without demonstrating that candidate's accepted observation period.

**Recommendation:** persist build identity, filter or partition assessment by the selected build, and report missing identity as incomplete evidence. Add dependency-free Python regression tests to the existing CI workflow for mixed builds, missing builds, window resets and rotated logs. The current CI runs Swift tests and `script/test_*.sh`; it has no Python assessment-test step.

**Completion criterion:** the mixed-build probe fails the candidate threshold, while a single-build fixture with the accepted sample count and duration passes. Each result names its build and coverage.

**Existing distinction to retain:** unverified paste receipts currently count towards the responsiveness window and are reported separately. The reliability notes explicitly require a fresh microphone-to-paste journey as additional release evidence. The probe used unverified receipts; that is not a newly discovered insertion-success claim.

## 3. Medium: provide one short navigation route to the new skills

**Observed:** all 37 skills are now in `.agents/skills`, but the project has no agent instruction file or tracker/domain configuration. Existing OpenTelemetry and Superlog material is duplicated under `agent/skills` and `.agents/skills`; the copies inspected differ in skill frontmatter. Claude's existing links point to `.agents/skills`.

**Consequence:** future sessions can rediscover configuration gaps or update one copy while leaving another stale. These new files are local and uncommitted, so existing worktrees and other clones do not yet receive them.

**Recommendation:** use `.agents/skills` as the shared location, link the installation catalogue from the eventual project instruction file, and use the installed setup skill when choosing tracker/label/domain conventions. Review references before consolidating the older telemetry copies. Share a focused commit containing only the installation and its documentation, without absorbing the pre-existing application changes.

**Completion criterion:** a fresh project checkout discovers the same skills and source revision, and there is one documented location for configuration and skill maintenance.

## 4. Low: keep discovery and evidence output bounded

**Observed:** this session's initial broad tool-catalogue search and a later bulk source read produced truncated output. Two initial skill reads assumed the older upstream layout; upstream now groups skills under `skills/engineering`, `skills/productivity`, `skills/misc` and `skills/in-progress`.

**Consequence:** irrelevant output consumes context and makes missing evidence easy to overlook.

**Recommendation:** inventory paths once, then read exact entrypoints; filter tool metadata by exact tool name and print only the matching descriptions; extract line-numbered session messages and narrow source excerpts. Prefer structured counts and summaries over complete tool catalogues or diagnostic files.

**Completion criterion:** the next installation and retro obtain the relevant inventory and evidence without truncated output or layout guesses.

## What worked and what was completed

- The installation helper installed all 37 upstream skills without replacing existing skills. All 101 files were verified byte for byte, including invocation metadata and supporting resources.
- The upstream revision, per-file hashes, categories and MIT licence are preserved in the [installation catalogue](../engineering-skills.md) and [lock file](../agents/matt-pocock-skills.lock.json). Six skills remain labelled as upstream in-progress material.
- Source/build correlation prevented a review of the August checkout from being presented as a review of the installed app.
- Existing CI was inspected before recommending checks. The newer worktree already fixes the older checkout's formatter-installation issue by downloading a pinned, checksum-verified SwiftFormat binary; duplicating that fix is unnecessary.
- The 1 October review distinguished reproduced risks from unresolved stall causes and used focused tests and isolated probes. Its reported test results are historical evidence, not a new test run or a claim about today's app stability.

The initial retro run produced the installation and this ordered improvement list. Application code, CI, agent steering and tracker configuration were not changed. No app was built, stopped, installed or released, and no commit or push was made.


## Authorised follow-up

Jacob approved implementing these recommendations on 4 October 2026. The follow-up adds a short `AGENTS.md`, source-selection and stability-evidence guides, GitHub/default-label/domain configuration, and one canonical skill location with compatibility links. The stability checker now stores build identity, assesses each build separately, blocks ambiguous or missing identity, and preserves prior-window summaries. CI runs dependency-free Python regression tests and a deterministic skill-file/link check.

The work is isolated from the existing app edits. It changes agent guidance and diagnostic assessment, without rebuilding or switching the installed app.
