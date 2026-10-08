# PR #9: Contextual Translation Repair

## Historical checkpoint / current continuation

This document records the rejected V2 experiment at `e6586460e6323a650f6bb139654ee87b1e6fce02`.
Statements below about active a16 production bytes apply to that checkpoint,
not the subsequent BookText-architecture implementation. The failed artifacts
remain unchanged. Current implementation, V3 results and the remaining ID 17
semantic failure are in [V3 evidence](TRANSLATION_OWNERSHIP_V3_EVIDENCE.md).

## Owner gate

`HUMAN_TRANSLATION_REVIEW: FAIL` applies to the previously reviewed
`a16ae0c016e94c76b78a5bb2f6fb7e05012c4d78` snapshot. Structural validation did
not detect a medical invention in cue 21, a lost student referent in cue 24,
or the ambiguity of the unfinished cue 17. The previous Candidate and its two
E2Es are invalid for changed production behavior. PR #9 remains draft; this
document grants neither merge nor installation authority.

## Reproduced cause

WorkflowEngine supplies the source-language SRT to TranslationAdapter. The
adapter batches up to 32 targets, but the v2 Ollama provider makes a separate
request for each cue. Each request contains only that target's text. Adjacent
source dialogue is neither sent nor available to the model. Retries further
reduce targets to failing IDs. Cue IDs and timestamps are reconstructed by
the adapter; they do not require semantic context to be removed.

The v2 request was replayed against the installed `translategemma:4b` digest
`c49d986b0764f5881c476eb21435bb62b7abc62347aab3d4a6071e811be510a1`
(`Q4_K_M`, Ollama `0.33.1`). It reproduced the stomach invention for cue 21
and referent loss for cue 24. Decoder randomness was held at temperature zero.
The tested snippets are retained ASR evidence, not independently verified
audio-Gold.

## Controlled prompt experiments

`Tests/TranslationContextExperiment.py` runs sequential requests and prints
exact prompts, outputs, token counts and completion reasons. It is an
investigation tool, not production evidence or a human-quality evaluator.

| Variation | Observed result | Decision |
| --- | --- | --- |
| Original isolated v2 | Stomach invention in 21; student referent missing in 24 | Reproduces owner failure |
| Context before target | 21 expresses disconnection; 24 retains student referent; 17 sometimes invents `here` | Context helps but is insufficient |
| Context after target | 21 mentions connection; 24 changes meaning to agreement | Reject |
| XML target/context rows | Translates or copies multiple context rows, including Russian output | Reject |
| Stronger incomplete-speech instruction | Does not reliably prevent invented completion; 21 sometimes changes to feeling unwell | Reject as complete fix |
| Official-template wording with context | 21 loses disconnection; 17 gains completion | Reject as complete fix |
| Bounded local window before target | 21 expresses disconnection; 24 retains student referent; 17 still gains `here`; 22 remains `terrifying` | Bounded repair remains gated by real semantic regression |

There is no fixture-specific translation rule in production. Prompt choice is
not declared successful merely because one output improves. All mandatory
owner-reviewed failure classes must pass together.

## Rejected bounded implementation

The bounded patch was exercised through the real production adapter/provider,
then withdrawn from active Sources because it introduced additional semantic
regressions. It is retained as `analysis/pr9_translation_context/rejected-context-candidate.patch.gz`
for reproduction, not as an accepted production repair. Active production
bytes remain equal to the previously reviewed a16 snapshot, whose owner
semantic gate remains FAIL.

Each target carries an immutable window built from the full source before
batching. The window uses at most eight source positions in either direction
and 1200 characters of complete source rows. It never incorporates translated
output. Expansion stops at an oversized intervening row rather than silently
joining dialogue across a gap. Targets larger than the context budget still
receive an explicit incomplete-speech instruction.

The provider distinguishes interpretation-only context from target TEXT and
still requests one translation per original cue. ID, count, order and start/end
times remain owned by the adapter. A token-limit completion invalidates only
that cue for an isolated retry rather than accepting a truncated answer or
discarding successful siblings. Duplicate source IDs are rejected.

Protocol identity is `translategemma-context-cue-safe-v3-r8-c1200`. Existing
model/digest/protocol comparisons therefore reject v2 translation caches.
Source revision identity already covers changes in surrounding source text.
Historical translation revisions retain their original provenance. No schema,
Topic engine, Whisper, installed application or global Ollama model changes
are included in this repair.

## Observed real-model verdict

The 24-cue contextual production-adapter probe returned exit 1. It improved
cue 21 to `Something is making me disconnect today.` and cue 24 to
`Now definitely part-time students, right?`, but cue 17 remained
`Yuri, and I'm still here.` and cue 22 remained
`It's absolutely terrifying every minute.`. Structural issue count was zero.

The broader set revealed additional context leakage: cue 13's single name
acquired the next two utterances, and cue 23's `Ну, готова.` became
`Okay, now we have part-time students.`. A further bounded aligned-target
JSON experiment corrected the negative evaluation in 22, but still invented
`here` in 17. None of the tested protocols satisfied all mandatory classes.

This is a product blocker, not a CI or media-fixture blocker. None of these
tested prompt changes can be presented as a proven repair. Do not run release E2Es or
prepare a Candidate for the rejected behavior. No replacement model or new
translation architecture was selected in this task.

## Verification boundary

The archived experimental structural probe covered original cue alignment, cross-batch context,
selective retries, context character limits, omitted-row continuity and
duplicate source IDs. `Tests/TranslationSemanticReviewProbe.swift` runs the
real production adapter/provider against an external approved review fixture.
It persists all 24 outputs even when mandatory semantic failure-class checks
fail. On the active a16 production path these checks are intentionally expected
to fail until a proven repair is implemented. They are regression alarms, not
independent translation Gold.

The authoritative human review is still required. A failed semantic probe
blocks Candidate preparation and final E2Es; it must not be relabelled PASS.
Registered named-role invocations currently return
`agent type is currently not available`. Generic agents can perform independent
contract reviews, but they do not satisfy the named-role release requirement.
This limitation is recorded separately from product correctness.

## Final active-code recheck

After withdrawing only this task's production changes, a second real adapter
run on the same 24-cue fixture returned exit 1. The active v2 path reproduced
the exact owner-rejected outputs for 21, 22 and 24. Cue 17 remained incomplete
(`Yuri, and I am still.`); it did not gain the experimental `here`. ID/count/
order/start/end were unchanged and structural issue count was zero. The known
bad/good controls inside the semantic probe passed; this does not make the real
translation pass.

- Real contextual adapter probe: **FAIL** (17/22; broader review also finds 13/23).
- Real active-v2 adapter probe: **FAIL** (21/22/24).
- Active-model guard: **PASS**; no Qwen request was made by these experiments.
- Experimental structural adapter probe: **PASS**, on the subsequently rejected patch only.
- Shell syntax and `git diff --check`: **PASS**.
- New Candidate, final topic regression and two release E2Es: **NOT RUN**,
  because the mandatory real semantic gate failed.
- Installed application, Topic engine and Whisper: **UNCHANGED**.

Independent generic-agent static review and QA were performed under the role
contracts. QA agrees that zero structural issues do not imply semantic safety
and that the context patch must not be released. The reviewer's structural
assessment of the patch is not approval of its real model output.

The retained `analysis/pr9_translation_context/` artifacts record exact prompts,
raw model replies, token counts and the rejected patch. Human Review Package V2
is diagnostic evidence of a failed experiment, not a request to accept known
defects. No independent human V2 PASS, independent-material PASS, new Candidate
fingerprint or final E2E PASS exists. This task must not be represented as a
completed semantic repair.
