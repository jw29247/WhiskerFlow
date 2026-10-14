# Audio freeze: WhiskerFlow 2.0.2

## Observed failure

The installed 2.0.0 (build 22) app froze on a second short C920 microphone
capture on macOS 26.6.2. A five-second live `sample` captured all three
blocked stacks throughout the sample:

```text
main thread: beginRecording -> availableInputs -> CoreAudio HAL mutex wait
capture-engine queue: PreparedCapture.dispose -> AudioUnitUninitialize -> I/O wait
audio I/O thread: halRunningListener -> AudioUnitGetProperty -> audio-unit mutex wait
```

The running-state listener re-entered the audio unit on its I/O thread while
teardown waited for that thread. Device enumeration then propagated the audio
lock cycle to the main thread. The original local sample is retained outside
the repository; no transcripts or recorded audio are included here.

## Change

- The running-state listener only queues a query. A lifetime lock prevents
  queries after invalidation; disposal invalidates before stopping the unit.
- The watchdog reads cached state using a separate lock, so a blocked query
  cannot stall it.
- Dictation device enumeration, selection resolution, and preparation use the
  existing engine queue and six-second deadline. The reuse policy is computed
  when the capture is built, rather than querying CoreAudio on release.
- Version 2.0.2, build 24, follows the already published 2.0.1, build 23.

## Verification

`swift test --jobs 4 --filter AudioUnitRunningStateTests` reproduced the lock
pattern before deferring the query: two failures, including a callback timeout
with the simulated audio-unit lock held. After the change, all three tests
passed. They cover callback return, invalidation before queued queries, and a
responsive watchdog during a blocked query. All waits release their simulated
locks on failure.

The full suite passed: 804 XCTest cases, zero failures, 15 optional tests
skipped; another 18 Swift Testing cases passed. SwiftFormat lint passed.

The signed DEBUG bundle used the production identity, isolated preferences and
data, and the existing debug dictation trigger. Hardware stress passed:

- 40 C920 start/stop cycles, all rebuilding the unit and exercising disposal.
- 20 system-default start/stop cycles.
- Each run started another capture after the counted rounds, proving the last
  counted teardown returned on the serial engine queue. Both candidates quit
  gracefully. No main-thread stalls or engine/finish timeouts were logged.

Reproduce on an unlocked Mac with a signed DEBUG app bundle:

```sh
python3 script/audio_lifecycle_e2e.py /path/to/WhiskerFlow.app \
  --output-dir /tmp/whiskerflow-audio-check --rounds 40
```

Add `--input-uid <microphone-uid>` to exercise a specific device. The output
directory must be new. Microphone permission must already be granted.

An independent read-only concurrency review found no production blocker. Its
test-boundedness suggestion was applied. Hardware validation covers this Mac's
available routes; it does not establish behavior on every Bluetooth device.

Apple API reference: [AudioUnitAddPropertyListener](https://developer.apple.com/documentation/audiotoolbox/audiounitaddpropertylistener(_:_:_:_:)).
