# Local meeting transcription reproducer

17:32 BST: retained C80739A1 190000–200000ms isolated replay fails on mixed track in6.968s. AppPID92075 CPU0 and all retained nonempty sessions failed before replay. No source mutation or upload.

Command: `WHISKERFLOW_LOCAL_REPLAY_SESSION=C80739A1-BB1E-40E0-BC27-508A54025B52 WHISKERFLOW_LOCAL_REPLAY_MIN_MS=190000 WHISKERFLOW_LOCAL_REPLAY_MAX_MS=200000 swift test --skip-build --filter MeetingLocalReplayTests`

Log: /tmp/wf-c807-190s-replay.log.160000samples pertrack; RMS microphone0.009483,system0.045597,mixed0.023218. Nonzero audio does not prove speech. This reproduces independently of the live recovery queue; it does not establish decoder cause.

Next discriminators: (1) same audio with adjacent context tests segmentation sensitivity; (2) same bounded input with alternate local decoder settings tests filtering; (3) local speech-activity evidence distinguishes nonspeech rejected by decoder from lost speech. Do not skip failed audible chunks solely to complete a meeting. No behavior change or app restart in this review.

##19:32BST context experiment
Same retained session, minimum180000 and maximum210000, same local replay command/model passed with6turns. Original190–200s alone failed. No competing active app processing at launch; original source retained, no upload. This supports investigating decode boundary/context sensitivity, but aggregate success does not establish whether central190–200s speech was recovered. Next: measure central-window timed coverage, then test bounded context retries with timestamp ownership and deduplication before changing production. Log/tmp/wf-c807-context-replay.log. Gate remains14completions/1day/0faults; no restart or behavior change.

##21:33BST timed coverage
Added content-free turn start/end output to opt-in replay test. Build passed; same180–210s replay passed in12.975s with3turns:[182080,190700],[202720,206080],[208600,209900]. Only700ms overlaps target190–200s;9.3seconds have no timed text. Prior aggregate success does not prove central-window recovery; turn count changed6to3 across runs. Do not ship a context retry based on this evidence. Next distinguish actual speech from background sound locally, before changing empty-window guard. Production app unchanged, no restart.
