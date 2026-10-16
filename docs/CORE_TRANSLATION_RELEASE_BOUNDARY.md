# Core Release Translation Boundary

The accepted release supports an explicit bidirectional EN↔RU translation
operation for an approved source revision. `WorkflowOperation.translateTranscript`
is enabled by `translationEnabledForCurrentRelease = true`. The translated
transcript and subtitle artifacts become user-facing only after Translation
Review approves them; pending or failed translation must never be presented as
approved output or silently substituted with the source language.

Translation reuses the existing `TranslationAdapter`, TranslateGemma providers,
selected-timing translation code, cache, artifacts, schema and Human Translation
Review. It preserves source timing, cue IDs, provenance and project integrity.
The supported targets are EN→RU and RU→EN only. Translation is requested
explicitly; opening Simple Mode or an approved project does not repeat it.

`WorkflowOperation.createDubbing` remains disabled through
`dubbingEnabledForCurrentRelease = false`. Dubbing/TTS is outside the accepted
product scope and the UI must describe it as unavailable rather than treating
translation as a substitute.

Earlier core-only releases disabled both translation and dubbing at this
boundary. That historical restriction no longer describes the current
translation setting; it remains relevant only when interpreting older release
evidence.
