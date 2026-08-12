# Meeting capture benchmark

This benchmark is the release gate for changes to local meeting transcription,
diarization, or speaker-name alignment. It is intentionally a dataset contract,
not a checked-in recording: real meeting audio and participant names must not be
committed to the repository.

## Dataset format

Each consented, locally stored fixture has a stable fixture identifier and a
lossless source recording kept outside Git. Its annotation file contains:

```json
{
  "fixtureId": "team-call-001",
  "sampleRate": 16000,
  "channels": 1,
  "segments": [
    {
      "startMs": 0,
      "endMs": 2400,
      "text": "Example sentence.",
      "speaker": "You"
    },
    {
      "startMs": 2500,
      "endMs": 5100,
      "text": "Reply from another participant.",
      "speaker": "Speaker 1"
    }
  ]
}
```

Annotations use `You` only for the microphone owner. Other voices use stable
`Speaker N` labels; a segment that cannot be assigned reliably uses `Unknown
speaker`. A separate optional mapping file can record the expected Google Meet
participant name, but it must never replace the diarized label without a
high-confidence timestamp and text match.

## Measurements and release gates

The benchmark runner should report, per fixture and in aggregate:

- WhisperKit word error rate (WER) against the reference text.
- SpeakerKit diarization error rate (DER), including missed speech and false
  speaker changes.
- Segment boundary overlap and the percentage of turns with a non-unknown
  speaker label.
- Google Meet identity alignment precision and coverage, counting only exact
  one-to-one high-confidence matches as correct.
- Processing time, peak local storage, and upload bytes.

Model or capture changes are eligible for release only when they do not regress
the agreed WER/DER and alignment thresholds for the labeled set. Thresholds are
maintained with the private benchmark data and should be recorded in the release
report; the repository must contain only synthetic examples and aggregate
results.

## Privacy and reproducibility

Fixtures require participant consent and must be de-identified before entering
the benchmark store. The benchmark runs entirely on the Mac with the same
WhisperKit/SpeakerKit versions and model identifiers used by Meeting Mode. It
must not upload source audio to a cloud ASR provider, emit transcript text to
logs or telemetry, or store biometric voice profiles.
