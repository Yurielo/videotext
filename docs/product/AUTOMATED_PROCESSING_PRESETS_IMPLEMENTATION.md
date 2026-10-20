# Automated Processing Presets — implementation matrix

Implementation branch: `codex/automated-processing-presets`. This document records the current source contract for QA; actual-app and release evidence must be attached by independent gates before Owner Test.

## Policy and execution

Only **С проверкой** is executable. A source transcript, topic variant, and translation pause at their existing Human Review checkpoint and continue the saved project-local plan after approval. Opening a project never starts work; `Support/Preset/execution.json` offers explicit Resume. The automatic mode remains unavailable because existing consumers require approved translation and no policy authorizes publication of an unreviewed machine translation.

Plans are deterministic for a project/configuration snapshot and run through the existing `WorkflowEngine`. Source revision, approved translation, and selected topic revision are pinned as stages complete. A changed revision or unrelated review checkpoint makes Resume fail closed. Ready/reuse also rechecks the original media fingerprint and the watermark image content digest. Completed video uses the exact output kind and stage timestamp, requires the workflow's current ffprobe report, and persists a SHA-256 content binding; a changed file cannot reopen as Ready. Text completion requires the approved revision's actual TXT, or the selected approved topic variant's user-facing TXT matching its canonical snapshot.

## Supported catalog

| Goal | Scope | Stages when dependencies are absent | Reusable approved input | Expected user result | Focused checks |
| --- | --- | --- | --- | --- | --- |
| Расшифровка | whole text | source transcription → Source Review | approved source SRT/revision | TXT + SRT | `ProcessingPresetProbe` planner, existing Simple transcription probes |
| Расшифровка и темы | whole text | source → Source Review → selected granularity topics → Topic Review | approved source; approved selected topic variant | TXT + topic results | `ProcessingPresetProbe` granularity, `SimpleTopicsProbe` |
| Видео с исходными субтитрами | full video / time fragment / approved Normal topic | source → Source Review → render | approved source; Normal topic for topic fragment | MP4 with source subtitles | planner, `SimpleSourceSubtitlesProbe`, actual-app QA pending |
| Перевод текста | whole text, RU↔EN | source → Source Review → translation → Translation Review | approved source and provenance-matched approved translation | target TXT + SRT | planner and A→B source revision negative probe; actual-app QA pending |
| Видео с переводными субтитрами | full video / time fragment / approved Normal topic | source → translation → reviews → render | approved source, approved translation, Normal topic when selected | MP4 with target subtitles | planner/provenance; actual-app QA pending |
| Обработка видео | full video / time fragment | prerequisite source for speed or any fragment → render | approved source for speed/fragment | MP4 with selected supported effect | planner and run-settings probes; actual media QA pending |
| Полная обработка оригинала | full video watermark+source subtitles / time fragment none, speed or blur | source → review → render | approved source | MP4 with source subtitles and effect | planner; actual media QA pending |
| Полная обработка с переводом | full video watermark+target subtitles / time fragment none, speed or blur | source → translation → reviews → render | approved source and translation | MP4 with target subtitles and effect | planner/provenance; actual media QA pending |
| Пользовательский пакет | same as saved supported goal | same as selected goal | project-independent configuration | selected goal result | save/rename/delete/load probe; actual-app QA pending |

The full-video watermark operation is the only existing combined full-video contract for subtitle burn plus blur and watermark. The processed time fragment operation supports filler mute, speed, blur, and subtitle burn in its existing order. A topic fragment uses the accepted `.cutTopic` path with an approved canonical Normal topic and subtitles; it does not offer effect chaining. Coarse and Detailed do not substitute for Normal in topic fragment selection. The topic-generation goal uses the explicitly chosen Coarse/Normal/Detailed variant.

## Unsupported before Create

- Translation with Auto source on a new project, a source/target language mismatch, or languages outside RU↔EN.
- A text-only goal scoped to a video fragment; topic fragment for a goal other than source/translated subtitle video.
- Full-video source/translated subtitle effect chaining outside the existing combined watermark operation; full-video `fullOriginal/fullTranslated` speed, standalone blur, and audio enhancement.
- Watermark or audio enhancement in a processed time fragment; topic fragment with arbitrary effect chaining.
- Manual watermark coordinates in a preset; use one of the four supported named positions. The Advanced manual control is unchanged.
- Filler mute outside a time fragment; invalid fragment range, speed factor, blur rectangle/intensity, watermark image or opacity.
- Missing or corrupted canonical approved source, translation, topic snapshot, ffprobe evidence, or output content binding.

The preflight panel names the expected TXT/MP4, language, scope and effects, lists reusable artifacts and remaining steps, and displays the specific blocker. Hidden Advanced settings do not enter a preset run; direct Advanced runs keep their own settings and do not advance a saved preset.

## Verification mapping

`scripts/test_processing_presets.sh` covers goal/stage order, RU↔EN direction, selected granularity, unsupported combinations, source prerequisite for speed, custom store, portable topic selection, project identity and corrupt plan, A→B translation provenance, exact output kind, corrupt nonempty output, missing transcript TXT, selected topic TXT path, changed source bytes at one path, changed watermark PNG bytes at one path, review checkpoint A/B mismatch, hidden-option normalization, run token isolation, filler flag and full-video source override. `swiftc -typecheck` covers the complete Sources tree. Existing Simple/translation/fragment probes and actual-app GUI/media scenarios remain independent QA obligations. No GUI or real-media PASS is claimed by this document.
