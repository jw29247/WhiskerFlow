# Expanded stall diagnostics — 8 September 2026

Build `3c91b3d28f68-20260908T074533Z` runs from `.build/WhiskerFlow 2 Resource Diagnostics.app`. Prior signed candidate remains available. Restart was performed only after the previous app logged idle/success with recording and transcribing false. Native UI verified Ready.

Added paired per-session stage events around recognition, text processing, history persistence, UI updates and completion sound. An active stage during a stall identifies an operation interval, not necessarily the exact blocked stack frame. No automatic stack sampling is implemented.

Native resource sampling on the existing utility queue runs every 15 seconds, at stalls/recovery and memory-pressure notifications. Captures app CPU percentage (100% is one core), whole-system CPU percentage, one-minute load and CPU count, app resident memory, swap occupancy and per-sample swap-in/out deltas, compressed page count/page size, thermal state, and observed pressure level. Initial CPU/deltas are omitted until there is a baseline; memory pressure is unknown until macOS sends a notification. There are no shell subprocesses or process-content capture in the sampler. Existing 3 x 2MB file rotation and field allowlisting remain.

Eight focused Swift tests passed in `/tmp/whiskerflow-expanded-final-tests.log`, including native counter reads and privacy filtering; summary stage/resource correlation assertions passed. Signed build verified and live resource snapshots observed from the new running process. A fresh microphone journey with these new stage events has not yet been observed; ordinary use supplies that evidence.

The two-hour review automation retains its 07:30–21:30 Europe/London schedule and now examines stage/resource correlation. High swap occupancy alone does not prove active memory pressure or causation. Historical freezes on the previous build cannot be retrospectively assigned resource readings.
