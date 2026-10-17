# Select the source before runtime work

An installed WhiskerFlow app can come from a different worktree and commit than the current chat's checkout. Match them before diagnosing runtime behaviour, building a replacement or editing application code.

1. Inventory the checkouts with `git worktree list --porcelain`. For each candidate, inspect `git -C <checkout> branch --show-current`, `git -C <checkout> rev-parse HEAD` and `git -C <checkout> status --short`.
2. Read the installed bundle's identity. On macOS:

   ```sh
   /usr/libexec/PlistBuddy -c 'Print :WhiskerFlowBuildRevision' /Applications/WhiskerFlow.app/Contents/Info.plist
   /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/WhiskerFlow.app/Contents/Info.plist
   ```

   Use the actual bundle path if it differs. For historical diagnostics, use the emitting row's `build`, launch and PID; the currently installed app may be newer.
3. Resolve the revision prefix from the build ID in the candidate checkout. Check whether its HEAD is that revision or contains it. A later HEAD is useful for comparison but does not describe the emitting source exactly; inspect the recorded revision for attribution. Record dirty state because HEAD alone does not identify uncommitted source.
4. State the selected checkout, branch, HEAD, app/log build and any mismatch before continuing. Preserve unrelated edits and existing diagnostic ledgers. Use an isolated checkout when the selected source has unrelated changes.

On 4 October 2026, `/Users/jacob/.codex/worktrees/whiskerflow-2-assistant` was the development checkout and `/Users/jacob/WhiskerFlow` contained older, uncommitted work. This is a discovery hint, not a permanent checkout assignment.

## Runtime validation and release evidence

Use the selected checkout's app-bundle scripts for GUI validation. Check their behaviour before invoking them; building, signing, launching and installing are distinct actions. Before replacing a running app, verify it is idle and has no pending recording, transcription or save.

For the detailed monitoring workflow, read `docs/validation/2026-09-08-reliability-loop.md` in the selected development source if present. For a release, read that source's current release brief, such as `docs/release-2.0.0.md`. Treat statements in dated records as historical until verified against current state.

Compilation, CI, packaging, a stability window, microphone-to-paste acceptance, merge and publication each prove different things. Report which were actually exercised.

Inspect content-free diagnostics and sanitised stacks for monitoring. Transcript, audio and clipboard content are unnecessary for source selection and routine stability assessment.
