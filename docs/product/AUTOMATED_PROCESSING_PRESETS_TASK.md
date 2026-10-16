# VideoText — Automated Processing Presets
## Deferred product specification: one-click end-to-end workflows

**STATUS: DEFERRED — DO NOT EXECUTE BEFORE PR #46 OWNER ACCEPTANCE AND DELIVERY.**

This is a saved product task, not authorization to implement, merge, install, or alter the currently tested Candidate. The execution trigger is explicit confirmation that Integrated Simple UX / PR #46 has passed Product Owner acceptance and completed its governed merge/install lifecycle. On execution, start from the THEN-current canonical main, not a historical SHA.

## Product outcome

The user selects a desired final result, configures applicable options once, presses **«Создать»**, and VideoText autonomously resolves prerequisites, reuses valid existing artifacts, chooses the supported operation order, performs required validations, and produces accessible final files. Do not require the user to manually start every intermediate operation.

Examples:
- RU media → transcription → source subtitles → supported blur/watermark → final MP4.
- RU media → transcription → EN translation → translated subtitles → supported effects → final MP4.
- EN media → transcription → RU translation → translated subtitles → final MP4.
- Existing approved transcription/translation → reuse → output without repeat ASR/translation.

**Do not create a second WorkflowEngine or a universal FFmpeg/effects pipeline.** A preset is a goal/configuration and a thin execution plan over the accepted operations, not a new processing architecture.

## 0. Preflight, governance and lifecycle

1. Confirm PR #46 Owner Test PASS and completed governed merge/installation, including accepted Candidate identity. If this condition is not satisfied, do not start implementation; preserve this document for later.
2. Read current AGENTS.md, applicable PRODUCT_RULES, docs/RELEASE_GATE.md, docs/CI_COST_POLICY.md, docs/agents/TRANSITION.md, applicable engineering references, and PR/worktree ownership rules. Current repository governance takes precedence over this specification.
3. Use Agent Model v2: coordinator in main context, one Application Developer for implementation, independent QA/reviewer and Release Engineer when required by actual risk/rules. Avoid redundant legacy-agent launches.
4. Inspect actual production behavior, supported media combinations, review/approval gates, project schemas, result discovery, and current PR/worktree state before proposing changes. Preserve foreign worktrees and installed accepted app.
5. Produce an internal capability/compatibility matrix (not an Owner checkpoint) and select the smallest viable implementation consistent with accepted Core. Do not invent unsupported effects or language pairs.

## 1. Product surface

Add **«Пакеты обработки»** / **«Быстрая обработка»** to Simple Mode as an additional route; preserve existing four result families and Advanced Mode. A preset exposes:
- final intended result, source media or existing project;
- applicable options and compatible scope;
- automatic vs review-assisted policy where authorized;
- understandable preflight plan and prerequisite/reuse summary;
- one **«Создать»** action for the whole plan;
- unified progress, stop/resume where supported, truthful result state, Open/Reveal.

Hide technical operation ordering and machine artifacts from ordinary Simple results. Do not expose an option if it is irrelevant to the chosen preset.

## 2. Preset catalog

Offer only capabilities actually supported by the accepted application:

| Preset | Intended result |
| --- | --- |
| Расшифровка | readable TXT and source SRT |
| Расшифровка и темы | TXT plus topic timecoding/results |
| Видео с исходными субтитрами | MP4 with source subtitles |
| Перевод текста | EN↔RU translated TXT/SRT |
| Видео с переводными субтитрами | MP4 with approved or explicitly authorized machine-result translated subtitles |
| Обработка видео | MP4 with a supported effect/combination |
| Полная обработка оригинала | transcription, source subtitles and compatible effects |
| Полная обработка с переводом | transcription, EN↔RU translation, translated subtitles and compatible effects |
| Пользовательский пакет | saved configuration of supported outcomes/options only |

Do not pretend arbitrary combinations are executable. Show unsupported combinations and the precise reason *before* starting. A requested combination must not be silently dropped or silently split into a different output.

## 3. Single-start execution and reuse

- Resolve dependencies from actual accepted WorkflowOperation contracts and project state; validate source language and translation direction (RU↔EN only).
- Compute a deterministic plan for the same project state/configuration. Expose meaningful steps and reused artifacts without burdening the user with technical names.
- Run the required steps sequentially in valid order from one initial user action; continue automatically where the selected review policy and current approval contracts permit.
- Reuse valid source SRT, selected timing, approved revisions, translations, topics and cached results. Do not rerun ASR, translation or topic inference merely because a preset was launched.
- Validate timing, provenance, cue IDs, source coverage, output language, model results and file integrity; fail closed on invalid prerequisites/intermediate outputs. No false ready/success.
- Preserve original media and previously accepted project artifacts.

## 4. Human Review policy — explicit safety boundary

Two intended modes:

**С проверкой:** pause at selected *supported* Source/Topic/Translation Human Review checkpoints and resume the same preset after the user completes approval.

**Автоматически:** no routine manual checkpoint *only where authorized by actual product policy and technically safe*. First audit current approval/provenance and downstream publication constraints.

**Non-negotiable:** never disable guards by force, silently auto-approve, forge human approval, or publish machine-generated text/translation as approved. If automatic downstream use requires a new machine-generated/unreviewed status, consumer eligibility, result labeling or publication policy, determine the minimal explicit contract and seek an indispensable Product Owner policy decision **before implementing that policy change**. Do not treat a request to skip Human Review as blanket permission to weaken the accepted translation fail-closed boundary. If policy approval is needed, return OWNER_ACTION_REQUIRED with concrete alternatives and risks; preserve all safe completed work.

Machine results must be distinguishable from human-approved results. Strict validation/provenance remains mandatory. A review-assisted preset must not lose its plan when pausing; use the smallest compatible continuation mechanism, without broad schema redesign.

## 5. Configurable options and compatibility

Where supported and relevant: source language Auto/RU/EN, translation target RU/EN, source/translated subtitle choice and style, full video or supported fragment scope, topic granularity, speed, blur region/intensity, watermark image/placement/opacity, audio enhancement profile, filler selection/mute, review mode.

Audit actual support for mute, speed, static blur, watermark, enhancement, source/translated subtitle burn, whole-video and fragment rendering, timing adjustments and processing order. Retain existing limitations; no arbitrary derivative chain. When speed affects subtitles, preserve correct retiming. Validate the whole plan before expensive execution.

## 6. Save and reuse custom presets

Support create, save, select, rename, edit, delete and reuse of supported custom configurations (e.g. «Мой YouTube»). Prefer a minimal compatible persistence mechanism, not a new database. Preserve compatibility with existing projects and installations. Saving a preset must not mutate a project or trigger processing.

## 7. Progress, errors, interruption and outputs

- One unified progress display with current stage, completed/pending stages, meaningful progress/ETA when available, Stop/cancel and safe restart/resume where supported.
- Preserve valid completed work on failure/cancellation; no orphan owned processes after Quit; no duplicate execution on reopen.
- Never continue after an invalid mandatory intermediate result or conceal a failed effect.
- Finished outputs are user-facing TXT/MP4/audio and relevant media results with understandable labels, language, applied effects, Open and Reveal. Keep JSON/manifests/provenance/support files out of Simple results; preserve them internally and in Advanced/Finder.
- Do not mark pending/failed/unreviewed translation as human-approved or silently use it where policy forbids.

## 8. Required acceptance matrix

Before claiming completion, create a concrete matrix for each supported preset/scope/option combination: prerequisite state, operation order, expected artifact, negative case, deterministic tests, actual-app evidence. Enumerate unsupported combinations explicitly. At minimum demonstrate:

A. RU video → transcription → source subtitles → final MP4.
B. RU video → EN translation → translated subtitles → final MP4.
C. EN video → RU translation → translated subtitles → final MP4.
D. Reuse approved transcription for subtitle video without second ASR.
E. Reuse approved translation without retranslation.
F. Supported processing combination → final MP4 with *all* selected effects.
G. Custom preset save → Quit/reopen → reuse on another project.
H. Automatic mode with truthful unreviewed state **only if policy explicitly authorizes it**.
I. Review-assisted mode: checkpoint → user approval → continuation.
J. Failure, cancellation, resume/reopen and process cleanup.
K. Unsupported combinations rejected before work; no silent fallback.
L. Advanced Mode and accepted Core non-regression.

Use disposable copies of real media/projects, never alter Product Owner originals. Distinguish deterministic/backend probes from actual built-app GUI evidence.

## 9. Batch implementation and release

Work autonomously in bounded, reviewable internal stages and commits; do not request separate Owner Tests for each preset or minor fix. Fix ordinary blockers and independent QA/reviewer findings internally. Follow the actual governed sequence: stabilize/commit clean HEAD, focused/integration checks, two consecutive governed clean real-video CORE E2E on unchanged release inputs, build exact Candidate, codesign, smoke/actual-app/lifecycle and applicable CI risk gates; respect repository ordering and reset rules. Only use hosted macOS when deterministic LEVEL_B policy requires it. No fabricated PASS.

Produce ONE immutable owner-test Candidate with exact HEAD, canonical base/ancestry, path-independent content digest, runtime identities, QA/review/CI/E2E evidence and a compact comprehensive Owner Test checklist. Do not merge/install/replace accepted VideoText before authorized acceptance. After Owner PASS, follow the repository's governed post-owner delivery chain.

## 10. Scope exclusions

No dubbing/TTS, new translation languages, broad WorkflowEngine rewrite, new topic engine, new universal summary, arbitrary FFmpeg effect graph, second project database, unrelated cleanup, altered human-approval meaning without explicit policy authorization, or changes to foreign worktrees/installed app.

## 11. Return contract

Return only:
- **AUTOMATED_PROCESSING_PRESETS_READY_FOR_OWNER_TEST / READY_FOR_OWNER_TEST: YES**, with HEAD, exact Candidate path and content digest, all supported preset/compatibility matrix verdicts, automatic/review-assisted policy verdict, reuse, save/reopen, RU↔EN, subtitles, processing, QA, independent review, TWO_CLEAN_E2E: PASS, codesign/lifecycle, installed app unchanged, and one integrated Owner Test plan; or
- **OWNER_ACTION_REQUIRED**, only for an objectively indispensable decision/action (especially an unresolved machine-result publication/approval policy), with exact alternatives, risks, attempted permitted workarounds and preserved state.

Do not return for routine compilation failures, tests, intermediate QA, temporary capacity or unfinished repository transactions. At every stop or completion, play an audible completion signal as the FINAL action.
