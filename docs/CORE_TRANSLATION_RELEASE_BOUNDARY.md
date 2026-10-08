# Core Release Translation Boundary

The current release exposes the core path only: media, bundled SeminarText,
`full.srt`, `transcript.txt`, subtitles, fragments, and persisted projects.

`WorkflowOperation.translateTranscript` and `WorkflowOperation.createDubbing`
are disabled at the release boundary. The workflow rejects either operation
before project creation or provider invocation. The UI removes translation from
the selectable operations and truthfully marks dubbing unavailable because it
depends on translation.

No translation implementation was removed. The retained future entry point is
`WorkflowOperation.translateTranscript`; `TranslationAdapter`, TranslateGemma
providers, selected-timing translation code, cache, artifacts, schema, and
Human Translation Review remain in place. Re-enabling translation requires a
separate product decision, restoring the release-boundary enablement, and
running its own translation-specific acceptance and release gates.
