# Meeting Hub Design

## Goal

Make Meeting Mode understandable and actionable by showing Atlas meetings around the user’s current date and providing clear scheduled and ad hoc recording controls.

## User flow

After Atlas pairing, the Meeting Mode area shows upcoming Atlas events for the next seven days and recent events from the previous seven days. An upcoming event can be started manually before its automatic capture window. A user can also start an ad hoc recording when no calendar event exists. Active and completed capture state is shown in plain language.

## Acceptance criteria

- AC-1: Meeting Mode displays upcoming Atlas events in a seven-day future window with title, local date/time, and a recording action.
- AC-2: Meeting Mode displays previous Atlas events in a seven-day past window with capture state when known.
- AC-3: A user can manually start an upcoming event and the capture retains its Atlas event ID.
- AC-4: A user can start and stop an ad hoc recording; the existing Atlas creation flow creates the meeting without an event ID.
- AC-5: The UI replaces “Uncovered” with plain-language idle/status copy and exposes refresh behavior.
- AC-6: Paired, unpaired, offline, recording, uploading, and error states remain distinguishable.

## Non-goals

- NG-1: No Atlas backend or calendar provider changes.
- NG-2: No changes to recording encryption, audio capture, upload, or transcription behavior.
- NG-3: No support for editing or creating calendar events from WhiskerFlow.
- NG-4: No Atlas PR CI bypass or production deployment action.

## Window and data rules

- Fetch schedule from `now - 7 days` through `now + 7 days`.
- Keep the existing cached schedule as the offline fallback.
- Sort upcoming ascending and previous descending.
- Use the existing `AtlasCaptureScheduleIntent` event identity for scheduled recording.
- Use the existing `startCapture(intent: nil)` path for ad hoc capture.
