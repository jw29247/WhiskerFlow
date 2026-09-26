# Dictionary learning: end-to-end fix (26 Sep 2026)

The Dictionary never learned from corrections. The installed app last wrote
`Corrections/corrections.json` on 17 Sep. Since then it has pasted about 150
dictations, and every one was logged `unverified` or `copied`. The correction
monitor only starts after a verified paste, so no correction was ever seen.

## Causes found

1. **Electron apps expose no text field.** T3 Code, Slack and Claude answer
   `kAXFocusedUIElement` with nothing until a client sets
   `AXManualAccessibility`. WhiskerFlow never set it, so pastes into them
   could not be verified and corrections made there were never observed.
   Most dictation goes to these apps.
2. **Empty Chromium composers read as `"\n"`.** Once text lands the value is
   just the text, so the expected `text + "\n"` never matched and the paste
   stayed unverified even after (1) was fixed. Measured in Claude desktop.
3. **An empty Messages composer has no value** (`AXValue` nil,
   `AXNumberOfCharacters` 0), so the snapshot before the paste failed.
4. **The monitor never ran after an unverified paste**, even though it checks
   the exact insertion itself.
5. **One correction did nothing visible.** A pair went into the Dictionary
   only after being fixed in two separate dictations.
6. The migration turned a blank legacy rule into an empty Dictionary entry
   (present in the installed app's `dictionary.json`).

## Changes

- The destination's accessibility tree is exposed when dictation starts
  (`TextFieldSnapshot.exposeAccessibilityTree`), with a retry when the text
  is captured.
- `PastedTextScope` treats a lone `"\n"` with the caret at 0 as an empty
  editor. An empty field with no value but zero characters counts as `""`.
- The correction monitor also watches unverified pastes.
- Learning (`DictionaryLearning.learn`):
  - The first correction adds the written term as a Word straight away. This
    matches Wispr Flow.
  - The rewrite (heard → written) is added at once when the heard text is not
    a real word per `NSSpellChecker`.
  - When the heard text *is* a real word ("grain" for Gráinne), the rewrite
    waits for a second fix. The same Word then gains it as a variant.
  - If the user keeps editing the same paste or History record, whatever that
    session learned earlier is replaced, so a half-typed fix is not kept.
- Diagnostics: `paste_returned` now carries `paste_detail` (for example
  `no_text_field` or `insertion_not_seen`). New events: `correction_watch`,
  `correction_observed` and `dictionary_learned`. They carry counts only,
  never words.
- Blank legacy rules are no longer migrated, and a blank migrated entry is
  dropped on load.

## End-to-end runs

Setup:
- DEBUG candidate signed with the Developer ID, keeping the production
  bundle ID so the TCC grants apply.
- Launched with `CFFIXED_USER_HOME` and `--e2e-defaults-suite=…`, so it has
  its own data and preferences.
- `--debug-dictation-trigger`: dictation is started by a distributed
  notification, not fn, so the installed app was left alone.
- Speech is macOS `say` through the MacBook speakers into the MacBook mic,
  transcribed by Parakeet.
- The user's fix is simulated by selecting the word via AX and typing real
  key events.

| Destination | Pasted | Fix | Result |
| --- | --- | --- | --- |
| TextEdit | "…invoice to Siobhan before Friday." | Siobhan → Shivaun | verified; learned; next dictation pasted "Shivaun" |
| Claude desktop (Electron), before fix 2 | "…note to Neve about…" | | `unverified insertion_not_seen`, watch unconfirmed |
| Claude desktop, after | same | Neve → Neeve | verified; Word "Neeve" (variant Neve) learned |
| Chrome textarea | "Please look in AFA from the design team." | AFA → Eefa | verified; learned |
| Chrome chat box that clears on Enter | "Tell grain the build is ready." | grain → Grawnya, Enter inside the debounce | verified; learned via the end-of-session flush |

Some runs failed with `not_frontmost` or `no_text_field`. Each time another
app, or the candidate's own window, had come to the front mid-run. The new
`paste_detail` field is what showed this.
