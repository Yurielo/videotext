# VIDEOTEXT — INTEGRATED RESULT-ORIENTED SIMPLE MODE
## Autonomous batch implementation, governed integration, single comprehensive Owner Test

MISSION
Deliver ONE coherent, usable Simple Mode for VideoText: from choosing/opening a project through selecting a desired outcome, satisfying prerequisites and review checkpoints, generating a real output, opening it, and reopening the project. Preserve the accepted Advanced Mode and all Core behavior. This is a complete user outcome, NOT permission for a broad redesign.

EXECUTION CONTRACT
Act autonomously through discovery, scoped implementation, internal repairs, testing, independent QA/review, CI and final immutable owner-test app. Do not return intermediate reports, request approval for each UI slice, or treat routine engineering/capacity failures as OWNER_ACTION_REQUIRED. Return only (a) READY_FOR_OWNER_TEST: YES with all required evidence and one comprehensive acceptance plan, or (b) OWNER_ACTION_REQUIRED with an objectively indispensable owner decision/action and why permitted alternatives cannot resolve it. Do not claim an unperformed gate passed. Respect tool/session limitations and do not promise asynchronous work outside the actual Codex run.

0. GOVERNANCE AND REPOSITORY TRUTH — FIRST
- Read CURRENT canonical AGENTS.md, PRODUCT_RULES wherever applicable, docs/RELEASE_GATE.md, docs/CI_COST_POLICY.md, docs/agents/TRANSITION.md, relevant docs/agents references, branch/worktree ownership and PR lifecycle rules. Current repository rules override historical task wording. Verify origin/main and branch HEADs, don't assume reported SHA is still current.
- Last reported canonical main: 5944e13026ea73454a307e867ffca7868cc47cf2 (after PR #43). Treat as historical anchor, not as a command to reset current main.
- PR #42 (Swift 5.10 compilation) and PR #43 (agent model v2) were MERGED. Never cherry-pick/reimplement their already merged changes. Determine exact ancestry and diffs before any integration.
- Identify current PRs/worktrees and uncommitted changes, especially SimpleProjectHomeState.swift. Do not overwrite, stash-drop, commit, or transfer work owned by another active worktree without a repository-approved ownership handoff. Keep installed /Users/yurielokhin/Applications/videotext.app unchanged.
- Before implementation, produce an INTERNAL integration inventory (not an owner checkpoint): source commit, merged/unmerged status, owner, scope, dependency and exact inclusion method. Reuse existing work with history-preserving integration where possible; resolve overlaps without duplicating code.

1. AGENT MODEL V2 AND COST CONTROL
- Product Owner/Coordinator operates in the main Codex context and owns goal, scope, acceptance, delegation and governance. Use ONE Application Developer as end-to-end implementation owner across SwiftUI/services where needed. Invoke independent QA, GitHub PR Reviewer and Release Engineer only when required by actual risk and repository governance. They must remain independent when required.
- Do not routinely spawn legacy frontend-developer, backend-developer, database-architect, jira-sprint-planner or confluence-doc-writer. They remain transition-compatible only where existing handoffs/rules require.
- Preserve required gates; avoid duplicate agent runs, duplicate tests and repeated hosted macOS calls. Use deterministic LEVEL_A/LEVEL_B CI policy and required exact-SHA checks. Preserve applicable two-consecutive-clean-E2E rule and reset it when release rules require.
- Observe/record relevant metrics for the first five v2 tasks if docs/agents/TRANSITION.md requires; do not create a separate tracking subsystem.

2. EXISTING PRODUCT BASELINE — FROZEN
Accepted Core includes RU/EN SeminarText transcription, source review, topics and Topic Review, EN↔RU TranslateGemma translation and mandatory Translation Review, original/translated subtitles for whole video and fragments, fragments by time/topic/quote, filler detection and mute, speed, static blur, watermark, audio enhancement, persistence/reopen, result discovery/Open/Reveal. Dubbing/TTS is DEFERRED. No new languages, summary engine, arbitrary effects pipeline, new project database or new topic algorithm.
- Preserve timing, cue IDs, provenance, fail-closed translation, approval semantics, source/project integrity and expensive-work reuse. No repeat ASR/translation/topic inference just because a user opens Simple Mode or an already-approved result.
- Prefer presentation/navigation adapters and minimal UI-level coordination over modifying WorkflowEngine, persistence schemas or media pipelines. Do not build a second workflow engine. If a real prerequisite needs a minimal integration change, prove it is necessary, scope it narrowly, protect with tests and obey governance. Do not change accepted processing semantics merely to simplify UI.

3. EXISTING UX WORK — REUSE, DON'T REBUILD
Investigate and correctly integrate, as applicable:
- Simple Project Home: 620d563030e554e2e0ed5a1f426043321217ebf9.
- Project Browser: b59263cbb8365168a513ac4a96ff118e912dc042.
- Simple user-facing artifact/result work, including any already merged PR #42 changes; determine authoritative current implementation and avoid duplication.
- Issue #41 false topic warning repair: 333e33202478724ae8b0db5d58e766ee4caf5bb6; verify ancestry/PR status before integration. Its Owner Test is PENDING even though focused QA, independent review, two CORE E2E and codesign were reported PASS.
- Preserve unrelated worktree edits in Sources/videotext/Services/SimpleProjectHomeState.swift and other foreign-scope changes.
- Issue #41: during active cutTopic, approved topics must remain visible; no false red “Нет утверждённых тем”, no spurious duplicate Create, progress/Stop remain usable, fragment completes and opens. “Последний фрагмент готов” is expected and NOT a defect. Check whether governance permits Issue #41 Owner Test to be part of the integrated Owner Test; if not, satisfy the mandatory separate gate without falsely marking acceptance. Do not silently merge an unaccepted repair.

4. PRODUCT INFORMATION ARCHITECTURE
Simple Mode primary structure: (a) project identity and current truthful state; (b) what is ready / needs review; (c) “Что хотите получить?”; (d) recent USER results with Open/Reveal. Four outcome families: “Текст и содержание”, “Видео с субтитрами”, “Фрагмент видео”, “Обработать видео”. Each must be an executable end-to-end user journey, not a placeholder card or a mere jump to Advanced controls.
- Keep “Простой | Расширенный” readable, remove redundant “Режим” label, preserve current project and pending review on switching. Advanced retains full accepted technical UI.
- Simple mode should not make a generic “Запустить” the primary action. Label actions by actual outcome. Show why a prerequisite is missing and a clear next action, rather than inexplicable disabled controls.

5. PROJECT BROWSER AND NEW PROJECT
- “Открыть проект” opens VideoText internal browser from EXISTING history, not Finder. Show recent projects on empty home and all known projects in browser. Each item truthfully summarizes name, language, last activity, approved/pending transcription, topics, translation, and available user-facing derivative results. Do not equate file presence with approved status.
- “Новый проект” uses existing source-media picker; “Найти проект на диске…” is secondary manual folder picker. No second project database or arbitrary filesystem scan. Handle stale/missing history entries gracefully. Opening navigation alone must never invoke ASR, model inference or ffmpeg.

6. USER-FACING ARTIFACT RULE
- Simple Mode presents results/entities, not machine files. “Расшифровка → Открыть” opens readable transcript TXT; “Темы → Открыть” opens topics.txt; “Перевод → Открыть” opens approved translated TXT. Never silently fall back to JSON/SRT when readable TXT is missing: show truthful error.
- “Исправить” routes to an EXISTING supported Source/Topic/Translation Review or edit path. Do not invent re-edit-after-approval semantics; where unsupported, display only truthful actions and record limitation.
- Hide JSON, whisper.json, manifests, selected-timing/provenance, caches, technical reports, revision metadata and standalone SRT from Simple results/recent lists. Do NOT delete them or stop producing them. SRT stays available to reviews, subtitle rendering and timing. Advanced/Finder retain explicit technical access.
- Recent results show readable TXT and finished MP4/audio/fragment artifacts, correct language/meaningful labels and Open/Reveal. Pending/failed translation is never shown as approved output.

7. TEXT AND CONTENT — REAL VERTICAL JOURNEY
- From a new or existing project, user can request transcription, open readable TXT, correct/approve when supported, request topics (coarse/normal/detailed), review/edit topics, request the one supported EN↔RU target translation, review/edit translation, and inspect filler candidates. Show state and appropriate next action at each step.
- Reuse approved artifacts; do not repeat ASR, topics or translation without an explicit supported regeneration action. No universal whole-video summary feature. Source/Topic/Translation Review requirements remain exactly those of the accepted application.

8. VIDEO WITH SUBTITLES — REAL VERTICAL JOURNEY
- Choose supported scope: whole video, approved topic or selected time/text fragment; choose original or APPROVED translated subtitle source, and supported style. Show understandable result summary and “Создать видео”.
- If source or translation prerequisite is missing, offer its existing operation and review, then provide a clear way to resume the original goal. Automatic cross-restart intent persistence is NOT required. If safe ephemeral UI coordination is possible, use it; otherwise show explicit “Продолжить создание видео” after approval. Do not alter project schema or create new orchestration architecture for this convenience.
- Output actual MP4 with selected subtitles, correct timing/rebasing, no silent fallback to source language, and Open/Reveal.

9. FRAGMENT — REAL VERTICAL JOURNEY
- Select by approved topic, explicit time range or implemented quote/text matching (with explicit disambiguation where multiple matches). Preview/confirm range using existing media preview where supported. Choose no/source/approved translated subtitles and only compatible fragment-processing options.
- Produce real fragment MP4 and accessible result. Reuse accepted cut/render/timing logic. Do not promise an arbitrary chain of effects or arbitrary derivative-input graph.

10. PROCESSED VIDEO — REAL VERTICAL JOURNEY
- Offer only currently supported scopes and combinations of filler mute, speed, blur, watermark and audio enhancement. Explain unsupported combinations before execution, without silently dropping requested effects. Existing combined fragment renderer may be used for its supported order; standalone full-video operations retain their actual constraints.
- Show intended input, chosen effects, expected output and that original media is preserved. Produce real accessible media and report errors truthfully. No new universal effects engine.

11. HUMAN REVIEW AND CONTINUATION
- Present review as a checkpoint within the chosen goal: what needs approval, why work is waiting, action to open existing editor, and next step after approval. Do not auto-approve or weaken existing checkpoints. Distinguish Source, Topic and Translation review; pending Topic Review may block workflow runs under current semantics, while pending translation must not be falsely presented as ready.
- Reopening a project preserves accepted state. Avoid promising automatic workflow continuation across Quit/reopen unless already supported. Explicit guided continuation is acceptable.

12. BATCH EXECUTION AND TEST STRATEGY
- Work in bounded internal implementation stages and reviewable commits/PRs as governance requires, but keep ONE Product Owner acceptance for the integrated outcome wherever allowed. No intermediate Owner Test for each card, UI fix or routine repair.
- Run focused deterministic tests immediately after each internal stage. Independently verify user-visible semantics, no false-ready artifacts, prerequisite handling, project-history truth, mode switching, Open/Reveal, SRT invisibility in Simple, and safe failure paths.
- Use controlled COPIES of real projects and fixtures; do not alter owner's originals. Cover RU/EN, approved and pending Source/Topic/Translation Review, existing translated subtitles, generated fragments, stale history, resume/reopen, and active cutTopic false-warning case.
- At stabilized integration, execute two end-to-end paths (subject to actual repository release contract): (A) RU video → source review → topics/review → EN translation/review → EN subtitled video → fragment → supported processing; (B) EN video → source review → RU translation/review → RU subtitled video/fragment. Reuse existing approved artifacts where appropriate; prove no unwanted repeat ASR/translation. Include new/existing project navigation, user-facing TXT, mode switch, error handling, normal Quit/reopen and no owned child processes after Quit. Test cancellation/active-processing lifecycle as required by risk/gates.
- Differentiate focused probe PASS from ACTUAL-BUILT-APP GUI evidence. If GUI automation is unavailable, do not fabricate it; follow repository-approved recovery/alternatives and report exact unverified gap. Do not demand owner intervention solely because of a transient agent capacity failure. Required independent QA/reviewer findings must be resolved before READY.
- Run applicable CI/CD and exact-SHA hosted macOS only according to current deterministic policy, not for each intermediate commit. Two consecutive clean real E2E must be on the same unchanged release HEAD as required by docs/RELEASE_GATE.md. Follow release-gate reset rules after changes.

13. ACCEPTANCE DEFINITION — NOT JUST UI CARDS
For each of the four families, demonstrate: Simple UI selection → prerequisite handling → existing operation execution → truthful progress/review → actual finished artifact → Open/Reveal → correct state after Quit/reopen. Test supported negative/failure case. No P0/P1 defects or material accepted-Core regressions. Maintain performance and project safety. If a particular combination is not supported by current Core, clearly exclude it rather than falsely claiming PASS.

14. FINAL APP, OWNERSHIP AND GOVERNANCE
- Build ONE clean, immutable integrated owner-test .app after all applicable gates pass. Record exact source HEAD, canonical base/ancestry, bundle/runtime identities, path-independent content digest, codesign, actual-app launch/normal Quit, process cleanup and evidence paths. No prepopulated Owner project; controlled test fixtures may be provided separately.
- Do not merge unaccepted integrated UX, do not install, do not alter installed accepted app, do not re-sign/substitute accepted bundle later without explicit permission. If repository rules require a particular pre-merge PR lifecycle, comply while preserving Owner Test as mandatory where applicable.
- Include Issue #41 in the comprehensive Owner Test ONLY if repository governance allows it. Clearly mark its Owner acceptance pending until user actually checks it. Do not declare it accepted based on automated E2E alone.
- After the comprehensive Owner Test, collect user findings as one batch; repair noncritical findings together, re-run mandatory gates per changed HEAD and retest affected paths plus regressions, not an unnecessary full manual cycle for every minor issue.

15. STRICT NON-GOALS
No dubbing/TTS, arbitrary language support, new summary engine, broad redesign of WorkflowEngine or persistence, new topic/translation/timing contracts, second project database, new subtitle renderer, arbitrary derivative composition, unrelated refactoring, bypass of independent gates, or automatic installation/merge. No hidden use of foreign worktrees or unowned uncommitted changes.

16. FINAL RETURN — ONLY TWO PERMITTED OUTCOMES
A) INTEGRATED_SIMPLE_UX_READY_FOR_OWNER_TEST
READY_FOR_OWNER_TEST: YES
HEAD: <sha>
CANONICAL_BASE: <sha>
BASE_ANCESTRY: PASS
APP: <exact local path>
PATH_INDEPENDENT_CONTENT_DIGEST: <digest>
AGENT_MODEL: V2
PROJECT_BROWSER: PASS
SIMPLE_PROJECT_HOME: PASS
USER_FACING_TXT_AND_RESULTS: PASS
TEXT_CONTENT_END_TO_END: PASS
SUBTITLED_VIDEO_END_TO_END: PASS
FRAGMENT_END_TO_END: PASS
PROCESSED_VIDEO_END_TO_END: PASS
HUMAN_REVIEW_AND_CONTINUATION: PASS
ADVANCED_MODE_NON_REGRESSION: PASS
ISSUE_41_REPAIR: PASS / OWNER_ACCEPTANCE_PENDING
RU_EN_AND_EN_RU_NON_REGRESSION: PASS
TWO_CLEAN_E2E: PASS or exact governance-approved NOT_APPLICABLE explanation
INDEPENDENT_QA: PASS
INDEPENDENT_REVIEW: PASS
CI: PASS / NOT_REQUIRED with rule evidence
ACTUAL_BUILT_APP_GUI_EVIDENCE: <verified paths, methods, limitations>
CODESIGN: PASS
QUIT_REOPEN_AND_PROCESS_CLEANUP: PASS
UNRELATED_WORKTREES: PRESERVED
INSTALLED_APP: UNCHANGED
CANONICAL_MAIN: UNCHANGED unless a repository-required authorized lifecycle step has already changed it (explain)
OWNER_TEST_PLAN: <one compact comprehensive checklist, including Issue #41>
NEXT: ONE COMPREHENSIVE PRODUCT OWNER ACCEPTANCE
DO NOT MERGE OR INSTALL WITHOUT AUTHORIZATION.

B) OWNER_ACTION_REQUIRED
Return only when continuation objectively requires a specific human action/decision and permitted autonomous recovery cannot resolve it. State the exact blocking requirement, attempted permitted alternatives, preserved state/HEAD, and one concrete owner action. Temporary capacity, ordinary test failure, running jobs, unfinished PR transaction or a fixable defect are NOT by themselves owner-action reasons.

After completing the task or encountering a genuine owner-required blocker, play the audible completion signal as the FINAL action.