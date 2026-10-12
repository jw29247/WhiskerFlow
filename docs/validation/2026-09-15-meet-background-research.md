# Meet speaker identity without captions

Jacob requires speaker identity with CC off. Caption matching is not an acceptable dependency. CC was disabled through the native Meet UI and the Turn on captions control verified at approximately 11:29 BST on 15 September 2026.

## Findings

Google documents real-time audio and participant metadata in its Meet Media API, including CSRC identity across virtual streams. Its current documentation requires the Cloud project, OAuth principal and every participant to enrol in Developer Preview. This is not an immediately usable default for ordinary client calls.

Source: https://developers.google.com/workspace/meet/media-api/guides/overview (accessed 2026-09-15).

The Kuali browser integration supplies an independently inspectable example of a caption-free mechanism. Its page-capture.js observes Meet collection data-channel messages and the SyncMeetingSpaceCollections response. meet-protocol.js decodes user device IDs and display/full names plus device-output stream mappings. The capture layer correlates these with receiver contributing sources and encoded frame metadata. It also has DOM roster/active-speaker fallbacks and guards against recycled media lanes and already-mixed frames. This is an unofficial implementation, not a stable Google API guarantee or evidence that it works on Jacob's current call.

Sources:
- https://github.com/igarrux/kuali/blob/main/browser-extension/src/page-capture.js
- https://github.com/igarrux/kuali/blob/main/browser-extension/src/meet-protocol.js

## Product direction

Use a narrowly scoped Chrome companion to collect timestamped participant/media identity for the current Meet and associate it with WhiskerFlow capture. Prefer direct audio-source identity over visual speaking indicators. Recycled lanes, mute/unmute, overlapping speakers and gaps must invalidate stale attribution. The participant roster alone must never assign a name. The app must continue recording/transcribing if the bridge is unavailable, with honest generic labels.

The existing native capture supplies microphone/system/mixed audio but no remote participant media identity. It cannot recover this mapping merely by changing the audio diarization labels. The new bridge remains unimplemented and unverified. Do not claim the issue is fixed or install an unrelated third-party recording app as a substitute.

## Live evidence and limitations

Native AX exposes the four participant names but no active-speaker identity in the inspected tree. Browser DOM inspection failed with a debugger-unattached error after reconnection/claim attempts; native UI access still works. No permission was broadened and no meeting reload was performed. A Chrome bridge injected before connection may need a fresh meeting connection for its WebRTC hooks; verify this before deployment.

Latest caption-on replay, session D9905CFC-FA1B-4DC9-8B22-4687BE70AFA9, 180000–200000 ms: two turns, both generic diarized, zero named. This disproves completion of the interim caption fix. The source recording remains preserved. The noon Atlas acceptance is still required for both capture sessions; do not conflate Google/Gemini artifacts with WhiskerFlow delivery.


## Implementation candidate

Implemented caption-free collection/audio-source observer, bounded native messaging host, ephemeral encrypted inbox, encrypted per-recording activity evidence and conservative temporal matcher. Disabled automatic caption reader and caption matching in the capture/processor path. Client sends Meet observations as google_meet provider with unknown server resolution. Signed candidate: `.build/WhiskerFlow 2 Meet Bridge.app`; extension ID `oemjlmbeodnoolklpnndedcgjibgjnii`. No Chrome registration/installation yet; new browser access requires confirmation. Existing running app preserved.

34 selected Swift tests executed, one opt-in caption probe skipped, zero failures; no-CC JS observer test passed; signed helper framing/rejection smoke passed. Atlas isolated worktree `/Users/jacob/.codex/worktrees/atlas-meet-speaker-provenance`:75 relevant tests and typecheck passed, independent checker PASS. Neither component is live-verified; Atlas not deployed. Bridge requires a fresh Meet connection to install pre-connection hooks. This is implementation proof, not four-speaker acceptance.


## Production direction correction — 15 September, 12:41 BST

Jacob requires one WhiskerFlow installation with no separately installed Chrome extension and no CC requirement. The extension prototype remains uninstalled and is not the production plan. Do not ask for its pending approval again.

Recall documents that its desktop SDK uses operating-system accessibility APIs for call state, participants and speaker timelines: https://docs.recall.ai/docs/desktop-recording-sdk-faq (read 15 September). This is primary evidence that a native approach is viable, not proof of our reader against the current Meet accessibility tree. Meet detection in that SDK requires the shown Meet tab or picture-in-picture. Validate foreground, covered, other-tab, minimized and PiP cases before promising background names. Do not infer speaker identity from roster order. No Recall dependency has been added.

Chrome also now documents opt-in remote debugging connections for existing sessions in M144: https://developer.chrome.google.cn/blog/chrome-devtools-mcp-debug-your-browser-session?hl=en . Earlier conclusions based solely on M136 command-line restrictions were incomplete. This still requires browser configuration and per-connection permission, so it is not our frictionless production installation path. Apple Events JavaScript likewise needs an explicit browser setting: https://www.chromium.org/developers/applescript/ .

Next native acceptance requires a live Meet with captions off and actual attributable speaker-state evidence. The ended WAR ROOM roster alone does not supply it.
