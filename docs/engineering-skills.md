# Project engineering skills

Installed from [mattpocock/skills](https://github.com/mattpocock/skills/tree/24fe0ef7737efae15c87225755e9f6f5965e4888) on 4 October 2026, pinned to `24fe0ef7737efae15c87225755e9f6f5965e4888`.

All 37 skill folders are ordinary project files in `.agents/skills/`: 20 engineering, seven productivity, four miscellaneous and six in progress. Existing OpenTelemetry and Superlog skills were preserved. Codex can discover the new skills on the next turn in this checkout.

All 101 upstream skill files, including references, templates, scripts and `agents/openai.yaml` invocation metadata, were verified byte for byte. The [lock file](agents/matt-pocock-skills.lock.json) records source paths and SHA-256 hashes. The [MIT licence](../.agents/skills/MATTPOCOCK-LICENSE) accompanies the installation.

The upstream files are preserved without edits. Invocation does not configure hooks, install extra tools or contact another service unless the selected skill requires it and the task authorises it.

## Skills

| Skill | Category |
| --- | --- |
| [ask-matt](../.agents/skills/ask-matt/SKILL.md) | engineering |
| [code-review](../.agents/skills/code-review/SKILL.md) | engineering |
| [codebase-design](../.agents/skills/codebase-design/SKILL.md) | engineering |
| [diagnosing-bugs](../.agents/skills/diagnosing-bugs/SKILL.md) | engineering |
| [domain-modeling](../.agents/skills/domain-modeling/SKILL.md) | engineering |
| [grill-with-docs](../.agents/skills/grill-with-docs/SKILL.md) | engineering |
| [implement](../.agents/skills/implement/SKILL.md) | engineering |
| [implement-spec](../.agents/skills/implement-spec/SKILL.md) | engineering |
| [improve-codebase-architecture](../.agents/skills/improve-codebase-architecture/SKILL.md) | engineering |
| [pr](../.agents/skills/pr/SKILL.md) | engineering |
| [prototype](../.agents/skills/prototype/SKILL.md) | engineering |
| [research](../.agents/skills/research/SKILL.md) | engineering |
| [retro](../.agents/skills/retro/SKILL.md) | engineering |
| [setup-matt-pocock-skills](../.agents/skills/setup-matt-pocock-skills/SKILL.md) | engineering |
| [tdd](../.agents/skills/tdd/SKILL.md) | engineering |
| [to-spec](../.agents/skills/to-spec/SKILL.md) | engineering |
| [to-tickets](../.agents/skills/to-tickets/SKILL.md) | engineering |
| [triage](../.agents/skills/triage/SKILL.md) | engineering |
| [wayfinder](../.agents/skills/wayfinder/SKILL.md) | engineering |
| [wizard](../.agents/skills/wizard/SKILL.md) | engineering |
| [claude-handoff](../.agents/skills/claude-handoff/SKILL.md) | in-progress |
| [loop-me](../.agents/skills/loop-me/SKILL.md) | in-progress |
| [setup-ts-deep-modules](../.agents/skills/setup-ts-deep-modules/SKILL.md) | in-progress |
| [writing-beats](../.agents/skills/writing-beats/SKILL.md) | in-progress |
| [writing-fragments](../.agents/skills/writing-fragments/SKILL.md) | in-progress |
| [writing-shape](../.agents/skills/writing-shape/SKILL.md) | in-progress |
| [git-guardrails-claude-code](../.agents/skills/git-guardrails-claude-code/SKILL.md) | misc |
| [migrate-to-shoehorn](../.agents/skills/migrate-to-shoehorn/SKILL.md) | misc |
| [scaffold-exercises](../.agents/skills/scaffold-exercises/SKILL.md) | misc |
| [setup-pre-commit](../.agents/skills/setup-pre-commit/SKILL.md) | misc |
| [grill-me](../.agents/skills/grill-me/SKILL.md) | productivity |
| [grilling](../.agents/skills/grilling/SKILL.md) | productivity |
| [handoff](../.agents/skills/handoff/SKILL.md) | productivity |
| [teach](../.agents/skills/teach/SKILL.md) | productivity |
| [to-questionnaire](../.agents/skills/to-questionnaire/SKILL.md) | productivity |
| [wait-what](../.agents/skills/wait-what/SKILL.md) | productivity |
| [writing-for-agents](../.agents/skills/writing-for-agents/SKILL.md) | productivity |

The six `in-progress` skills are upstream beta material. The TypeScript and Claude-specific skills are included in the full collection; select skills relevant to the current task.

## Repository setup

`retro` works without tracker configuration and was run for this installation. Repository configuration uses GitHub Issues (`jw29247/WhiskerFlow`), the five default triage labels and a single root glossary/ADR layout. [AGENTS.md](../AGENTS.md) points to the [tracker](agents/issue-tracker.md), [labels](agents/triage-labels.md) and [domain conventions](agents/domain.md). These choices configure the skills; labels are created on GitHub only when an authorised task needs them.

The installation is versioned with the project. Claude entries in `.claude/skills` and older entries under `agent/skills` link to the canonical `.agents/skills` directories. Other clones and existing worktrees receive it by checking out or integrating the installation commit.

For updates, select an upstream revision, preserve local edits, update per-file hashes in the lock file and run `python3 script/verify_agent_skills.py`. CI checks the same inventory and links. The skill files are editable; intentional local changes also require updated lock hashes.

See the [4 October retrospective](retros/2026-10-04-skills-and-agent-environment.md) for recommended environment improvements.
