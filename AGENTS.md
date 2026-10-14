# Agent Notes

## Delivery policy

This is the canonical workflow policy for this repository. Read it for routine,
Poteto/pstack, bedtime, autonomous and multi-PR work. It overrides upstream
playbook defaults for model selection, delegation, review gates, shipping
verdicts, decision-trail audits and polling. Keep installed or vendored pstack
files unchanged. Explicit user instructions take precedence.

### Ownership and scope

- Use GPT-6.1 Sol when available unless the user chooses another model.
- Give one owner responsibility for implementation, verification, PR feedback
  and completion. Delegation does not transfer that responsibility.
- Inspect the existing implementation and make routine decisions directly.
  Start with the smallest useful, independently landable change. Merge completed
  units, when authorised, before continuing dependent work.
- Delegate only independent work or a concrete unresolved question. Do not
  automatically spawn exploration, design, comment-cleanup, audit or review
  agents. A local Codex/Sol subagent review is optional, distinct from the GitHub
  Codex review below, and never an additional mandatory gate.
- Parallelise independent work with explicit ownership and one writer per
  checkout. Serialise heavy checks on each device, including across checkouts.
- Keep decision trails compact: decisions, evidence, remaining work and blockers.
  The owner checks the trail directly; no separate audit-review agent is needed.
- If an item is externally blocked, record the exact dependency and continue
  independent work. Leave blocked items visibly incomplete.

### Verification and PR feedback

- Run the repository's required checks and appropriate behavioural verification
  for the change. The CI definition in [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
  remains authoritative: JSON resource validation, Swift build and tests, shell
  packaging tests and pinned SwiftFormat lint. Preserve existing testing,
  security, data, CI and deployment requirements; do not import another
  repository's restrictions or weaken verification to move faster.
- Repeat checks when relevant changes, failures or integration conflicts justify
  it, rather than for reassurance. Verify repairs directly and retain failed or
  skipped results with their reasons.
- Use one initial **GitHub Codex PR review** per PR. Inspect existing review
  activity, timeline and checks first. Prefer the automatic review triggered
  when the PR opens. Request `@codex review` once only if no initial review has
  completed and no automatic review is queued or running. Record the review
  status and any request so another turn does not request it again. If that
  review is unavailable, record the dependency rather than substituting a local
  subagent review or declaring the review clear.
- Address actionable findings and verify the repairs directly. Do not routinely
  request a second Codex review, independent review swarm or cross-model audit.
  Read new feedback that arrives automatically and address genuine defects.
  The review limit never justifies ignoring a known problem.
- Use the host's PR watcher when available and resume on its notifications
  instead of running polling loops.

### Authority and completion

- Carry explicit merge authority forward across turns and PRs within its granted
  scope. Merge authorised work once CI, review findings and required discussions
  are clear, without repeatedly asking. Without merge authority, leave the PR
  ready for the user. Bedtime or autonomous execution alone grants neither merge
  nor deployment authority.
- Apply this same workflow to each PR in bedtime, autonomous and multi-PR runs.
  Upstream instructions must not restore redundant local reviews, second review
  rounds, swarms or independent shipping/audit gates.
- Preserve the distinction between **implemented**, **verified**, **merged**,
  **deployed** and **live-proven** in records and handoffs. Merge authority does
  not grant deployment or release authority. Follow the release procedure below
  only when that action is authorised; green CI or a merged PR is not proof of
  deployment or live behaviour.

## WhiskerFlow Release And Auto-Update Flow

WhiskerFlow auto-updates through Sparkle. The trigger users see is not merely a
GitHub tag or release: Sparkle reads `appcast.xml` from `main`, then downloads
the `.zip` enclosure referenced there.

For a real release:

1. Start from the code intended for release, normally after the feature PR has
   landed on `main`.
2. Bump the version in the one place that defines it:

   ```bash
   script/bump_version.sh <version>
   ```

   `Resources/Info.plist` is the single source of the version; the script sets
   `CFBundleShortVersionString` and increments `CFBundleVersion`, which must
   increase every release.
3. Run the signed local release command. Do not pass `VERSION` — it is read
   from `Resources/Info.plist`, and an override that disagrees is rejected:

   ```bash
   NOTES="Short release note" script/notarize.sh
   ```

   This requires a Developer ID Application certificate, the
   `WhiskerFlow-Notary` notarytool profile, and the Sparkle private key
   available to `sign_update`.
4. Publish both generated assets:

   ```bash
   gh release create "v<version>" \
     "dist/WhiskerFlow-<version>.dmg" \
     "dist/WhiskerFlow-<version>.zip" \
     --title "WhiskerFlow <version>" \
     --notes "Short release note"
   ```

   The `.dmg` is for fresh installs. The `.zip` is the Sparkle update payload.
5. Commit and push the tracked release metadata generated by `notarize.sh`:
   `Resources/Info.plist`, `appcast.xml`, and `Casks/whiskerflow.rb`.
6. Once the `appcast.xml` commit is on `main`, installed apps on the Sparkle
   update track can discover the release automatically.

Important gotcha: `.github/workflows/release.yml` is verification-only. It builds
unsigned, un-notarized packaging artifacts on tags and does not publish release
assets. Do not use a tag-only GitHub Actions run as the user-facing release
unless signing/notarization secrets have been deliberately added to CI.
