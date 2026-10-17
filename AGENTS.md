# WhiskerFlow

For runtime bugs, diagnostics, UI validation or release work, first match the app build to its source checkout using [source selection](docs/agents/source-selection.md).

For stability reviews, use [build-specific evidence](docs/agents/stability-evidence.md). The automated observation gate and a real microphone-to-paste check provide different evidence.

Shared skills live in `.agents/skills`; Claude and legacy locations link there. See the [skill catalogue and maintenance instructions](docs/engineering-skills.md). For automated checks, read `.github/workflows/ci.yml`.

Keep discovery output bounded: inventory paths once, then read exact entrypoints and targeted excerpts.

## Agent skills

### Issue tracker

Use this repository's GitHub Issues. See [tracker conventions](docs/agents/issue-tracker.md).

### Triage labels

Use the five default triage roles. See [label mapping](docs/agents/triage-labels.md).

### Domain docs

Use one root glossary and `docs/adr/`, created when terms or decisions are resolved. See [domain conventions](docs/agents/domain.md).
