# WhiskerFlow Meet bridge (development candidate)

Captions stay off. This extension observes the current Meet connection's participant collection and audio contributing-source metadata, then relays timestamped names through Chrome native messaging. It does not transcribe audio, send data to a remote service, enable CC, or join a call.

The companion app arms an encrypted inbox only while recording. Names enter the encrypted recording store; no speech text or names are added to diagnostic logs. Only sustained, unique remote activity names a transcript segment. Mixed speakers, microphone overlap, missing metadata and uncertain intervals retain generic labels. Browser-observed names are not verified Atlas contact identities.

## Local installation

This is not a Chrome Web Store release. Granting the extension access to Meet and native messaging requires the user's approval.

1. Build/sign the latest candidate using `script/bundle_app.sh`. The current verified bundle is `.build/WhiskerFlow 2 Meeting Recovery.app`; use that bundle when registering the helper.
2. Run `python3 script/register_meet_bridge.py '<absolute bundle path>'` to validate the package without changing registration.
3. After approval, run the same command with `--install`.
4. In Chrome's extensions page, load this directory as an unpacked extension and verify its ID matches the registration script's output. Chrome may require enabling developer mode.
5. Open a fresh Meet connection after loading the extension. Hooks attach before Meet creates its WebRTC connection; existing connections cannot be recovered by merely enabling the extension mid-call. Do not reload an ongoing call without authority.
6. Start WhiskerFlow recording. After the bridge has observed only one connected Meet tab for five seconds, metadata forwarding starts. Keep CC off.

The host registration points to the signed bundle path: register again after moving/replacing that bundle. Removing the extension and its `agency.thatworks.whiskerflow.meet.json` native-host registration disconnects the bridge; saved recordings remain intact.

## Verification

`node --test browser-extension/observe.test.cjs`

`swift test --filter 'MeetingSpeakerEvidenceTests|MeetingCaptionIntegrationTests|MeetingAtlasAcknowledgementTests|MeetingCoordinatorTests'`

These are synthetic and integration checks, not a substitute for a live four-speaker Meet acceptance. The undocumented protocol may change. Unsupported shapes fail closed; a Chrome connection after installation and a named transcript in Atlas are required before claiming live completion.
