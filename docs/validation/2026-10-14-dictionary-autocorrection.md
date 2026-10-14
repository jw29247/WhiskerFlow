# Dictionary autocorrection fix — 14 October 2026

Eligible corrections now save a usable replacement on the first edit. The same
mishearing is repaired on future transcriptions, including Literal style.

## Causes and changes

- Learning previously withheld the replacement when the heard spelling was a
  real word. A saved Word could be only a recogniser hint, with no rule replacing
  the original mishearing. Removed the second-correction gate. Spelling fixes
  keep the heard spelling as a Word variant; other fixes become Replacements.
- Literal style returned raw recognition before applying the dictionary. It now
  applies dictionary rules while preserving whitespace, fillers, punctuation,
  spoken commands and spoken self-corrections. Usage and Insights count its
  replacements too.
- History calculated its manual-add prompts before automatic learning. It now
  calculates them against the updated dictionary, so a saved correction does not
  ask to be added again.
- A failed disk write could still produce a saved-success notice. The notice and
  HUD now distinguish an in-memory correction from a saved one; Undo still works.

A one-time recovery pass attaches saved heard spellings to learned Words that
earlier builds left as hints. It respects rejected pairs, manual entries,
conflicts and common-word checks. It runs only with remembering and automatic
learning enabled, and records completion only after a successful save.

Common-word, conflict, chain and length checks remain. Ordinary lowercase prose
edits are not automatically learned. These corrections remain available for
review in Suggestions. An English lowercase spell-check avoids treating names
and acronyms as ordinary words.

## Automated verification

`swift test` on the final application source passed: 801 XCTest cases with 15
opt-in skips and zero failures, plus 18 Swift Testing cases with zero failures.
The final run finished on 14 October at 08:04:52 BST. Log:
`/tmp/wf-dictionary-full-final.log`.

Regression coverage includes first-fix replacements for real words, names and
acronyms; variants; dictionary reload; persistent Undo; recovery with learning
disabled or a failed save; failure notices; Literal processing and counts; and
the duplicate History prompt. The new regression assertions were observed
failing before their fixes.

`git diff --check`, shell syntax checking and Python compilation passed.

## Native app and recognition verification

The signed DEBUG candidate used a separate `CFFIXED_USER_HOME`, defaults suite
and token-store namespace. Its existing `WHISKERFLOW_SKIP_ATLAS_SIGN_IN=1` test
option allowed offline verification without pairing the candidate. Production
preferences, dictionary and app bundle were not changed.

The microphone attempt returned **No speech detected** from speaker playback.
Microphone-to-paste behaviour was therefore not established in this run. The
successful recognition check used a generated Samantha-voice AIFF and the real
History retry/transcription path with Parakeet:

| Step | Raw recognition | Result |
| --- | --- | --- |
| First transcription | Tell grain the build is ready. | Tell grain the build is ready. |
| One History edit and Save | Unchanged | Tell Grawnya the build is ready. |
| Quit, restart, transcribe a new record from the same audio | Tell grain the build is ready. | Tell Grawnya the build is ready. |

The UI showed `grain` would now be written `Grawnya`. The saved dictionary held
a Replacement with those exact sides. After restart, the UI's Original
recognition still showed `grain`, while the final transcript showed `Grawnya`.
SQLite verification confirmed both raw and final strings, and the replacement's
use count increased to 1. No second correction was made.

Recognition/restart evidence came from candidate build
`2787c1578a62-20261013T214009Z`. The final signed candidate was rebuilt as
`2787c1578a62-20261014T070642Z`. In that final build, a synthetic History fixture
was edited from `Ask Whisper about it.` to `Ask Whisker about it.`. The UI showed
the saved replacement and Undo, with no duplicate Add to Dictionary prompt.

Candidate and isolated data:
`/tmp/wf-dictionary-20261013-2239/WhiskerFlow-E2E.app` and its sibling `home/`.
The updated microphone harness is `script/dictionary_e2e/run.sh`; it requires an
open Chrome profile or Guest window and working speaker-to-microphone playback.

This is local implementation and verification. The installed app remains build
`6f3f83fdfe1b-20261012T154233Z`; this change has not been installed or released.
