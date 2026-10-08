# PR #9: first-response causal trace and source-completeness constraint

Status: `PRODUCT_OUTCOME_BLOCKED_NEW_CAUSE`. No production repair is claimed.
Production snapshot: `afe4a79c789349258a504d6348febabc7591a0ed`.
All `Sources`, resources and release inputs remain unchanged from that snapshot.
This continuation adds diagnostics/evidence, not another translation pipeline.

## Finding and remaining constraint

The unwanted location/state assertion originates in **model generation**, before
the production parser, validator or cue assembly. In a newly instrumented
request, the FIRST raw model reply already contains
`{"cueId":17,"text":"Yuri, and I'm still here."}`.
All 24 decoded raw texts, trimmed only at their edges, equal final adapter text.
The application neither copies `here` from a neighboring output nor appends it.

Controlled counterfactuals show that the nearby attendance clause is not a
necessary donor: removing ID 19's attendance clause, and then removing all six
explicit attendance clauses, retains the same completion. Removing only ID 17's
terminal period changes it to `Yuri, and I'm still`, but also changes ID 21 to
the less specific `Something keeps throwing me off today.` This is observed
punctuation-sensitive generation, NOT a safe punctuation-removal repair.
The exact original speech's completeness/continuation relation is **unverified**.
Therefore the causal layer is:

`MODEL_GENERATION_WITH_PUNCTUATION_SENSITIVE_SEMANTIC_EXPANSION`

The next safe-repair constraint is:

`SOURCE_COMPLETENESS_AND_CONTINUATION_NOT_VERIFIED`

Do not relabel this as `TRANSLATEGEMMA_COMPLETES_GENUINELY_INCOMPLETE_SOURCE`:
genuine incompleteness has not been established. Do not claim a particular
neighbor, ASR punctuation error or a cross-cue semantic unit as proven cause.

## Evidence inputs and controls

Read the prior source-anchor README, all three 24-cue reports/logs, failed
implementation paths, earlier exact prompt/reply ablations and current source
path before preparing these diagnostics. None of the rejected v5 self-review
or plain-text enforcement implementations was reintroduced or re-executed.

- Original 24-cue retained fixture: `../pr9_translation_context/v3/source-fixture.json`;
  SHA256 `7027a9cf6d6f2aa966d2692937ac94b839336b8410d337694cda892ece869b23`.
- Context identity: `022950cbaabd0d755af89cf4f85a8b683a7fd1afd66d7da182a7e081c2084b59`.
- Runtime: `translategemma:4b`, digest
  `c49d986b0764f5881c476eb21435bb62b7abc62347aab3d4a6071e811be510a1`;
  Q4_K_M; Ollama `0.33.1` (`ollama-version.json`).
- Actual options: temperature 0, context 8192, output budget 1694.
- Active protocol unchanged:
  `translategemma-booktext-owned-cues-v5-docmeta512-lineage2-overlap2x600-source-anchor1-ctx8k`.
- Four sequential requests, each with all original 24 IDs, the same schema,
  context/instruction prefix and decoding options. One chat per diagnostic,
  checkpoints disabled, maximumAttempts 1, network timeout bounded to 180s.
- Fresh baseline execution is justified by missing FIRST-raw-response evidence,
  not advertised as a new repair or an unchanged replay's semantic progress.
- Three overrides are explicitly artificial counterfactual source inputs.
  Their output is NOT translated original speech and cannot enter a project.
  `*.changes.json` records exact replacements and request hashes. The ID 14
  replacement in the all-attendance ablation is a neutral greeting; it is not
  an assertion that the actual speaker said that greeting.
- The preparation helper proves no-op prompt serialization is byte-identical
  as a string, refuses ambiguous/noncanonical IDs or serialization changes,
  and consumes all requested replacements. Actual recorded requests were
  revalidated against the repaired helper. JSON transport whitespace is not
  model input; schema properties/required/ID arrays and options remain equal.

| Run directory | ID 17 FIRST reply | ID 21 | ID 22 | ID 24 |
| --- | --- | --- | --- | --- |
| `baseline` | Yuri, and I'm still here. | Something keeps disconnecting me today. | It's just awful every minute. | Now definitely distance learners, right? |
| `without-cue19-presence` | Yuri, and I'm still here. | Same as baseline | Same as baseline | Same as baseline |
| `without-presence-clauses` | Yuri, and I'm still here. | Something keeps throwing me off today. | Same as baseline | Same as baseline |
| `without-cue17-period` | Yuri, and I'm still | Something keeps throwing me off today. | Same as baseline | Same as baseline |

All four runs: structural issues 0, original ID/count/order/times preserved,
all raw/final text comparisons true. Simple unchanged controls 1/2/4/5/6/11
retain their meanings (intentional modified sources excluded). Proper-name
spellings in 8/13 vary in the period ablation; no independently listened names
Gold exists. All 24 outputs are retained, not spliced across experiments.
Each trace reports `semanticVerdict=NOT_EVALUATED`; successful capture exit 0
is not the semantic gate. Baseline retains the blocking owner-rejected defect.

## Exact pipeline / A-H

1. Historical source was ASR SRT from the 180-second excerpt, original offset
   600s. The retained JSON supplies exact cue text/times for this trace. The
   original temporary SRT/Whisper JSON was not found in the recorded evidence
   folders, source Zoom folder, task temporary directories or bounded work
   folders. No replacement SRT was reconstructed and Whisper was not rerun.
   Direct byte-to-byte provenance of that missing original SRT is a limitation.
2. `TranslationContextPlan` copies owned `text` unchanged, builds metadata-only
   document context and two neighbors in each direction. See `planned-owned.json`
   and `planned-contexts.json`. Original ID 17 remains `Юрий, а я еще.`.
3. These 24 cues share one default 32-owner execution unit. All before/after
   maps in the wire request are empty because their neighbors are already owned.
   Other owned rows remain available as conversation context. For 17, the
   planned neighbors are before 15/16 and after 18/19.
4. Exact original/sent request bodies are `001-request-*.body.bin`. The HTTP
   JSON response is `001-response.raw.bin`, captured before parsing, with
   status/hash metadata in `001-wire.json`. `001-response-content.txt` is the
   decoded `message.content`, not the final adapter output.
5. The real provider validates done/schema/unique/exact IDs and trims whitespace.
   The real adapter validates numbers/terms/length/language and assembles by ID
   using original time spans. `trace-report.json` contains the comparison chain.

| Question | Evidence-backed answer |
| --- | --- |
| A: `here` in FIRST raw reply? | YES, baseline `001-response.raw.bin`, decoded row 17. |
| B: introduced by post-processing? | NO in this trace; raw row 17 equals final text; all 24 comparisons match after trim. |
| C: copied from context? | Not by application code. The source does not contain English `here`; attendance statements are available to the model, but literal copying and a unique donor are NOT proven. |
| D: exact encouraging neighbor? | 19 `Здравствуйте. Я есть.` is a plausible interpretation cue, not a proven cause. Its removal has no effect. Other attendance clauses are 3/6/9/12/14; removing all six retains the completion. No unique necessary neighbor identified. |
| E: owned source preserves incompleteness? | It preserves exact text, NOT an independently verified completeness fact. There is no speaker/utterance/continuation/completeness annotation. |
| F: normalization makes it complete? | No pretranslation punctuation rewriting found. SRT parsing and context preparation trim whitespace only. The period is already in retained input. Removing it affects generation in the measured counterfactual; its ASR-versus-spoken provenance remains unverified. |
| G: machine-readable ownership/context distinction? | YES: JSON owned ID/text records, separately keyed before/after maps and explicit context labels. NO machine-enforced semantic-slot distinction; schema constrains IDs and strings, not the meanings of those strings. |
| H: model versus parser/assembly? | Proven entry layer: model generation. Parser and assembly preserve the generated expansion. Validation does not detect general unsupported propositions. The deeper audio-level semantic diagnosis remains open. |

## Original audio and the semantic boundary

Original source video is unchanged and its SHA256 was revalidated:
`41aaa6fabfb51e8caf1c2af044ef33469deac741c9db6da48d92d3eda7ca2a30`.
Path: `/Users/yurielokhin/Documents/Zoom/2026-09-26 13.00.44 Полнолуние 26 сентября 2026/video2572105971.mp4`.
Retained 180-second clip SHA256 still matches
`82533ea990d1411c43b21abecdc04e634fe6a59dd81dc5dcad9e55529dab66ec`.

| Cue | Original-video time | Retained source |
| --- | --- | --- |
| 15 | 00:11:37.860-00:11:38.340 | Готова. |
| 16 | 00:11:38.760-00:11:40.000 | Так, сейчас у нас заочники. |
| 17 | 00:11:42.990-00:11:44.170 | Юрий, а я еще. |
| 18 | 00:11:45.070-00:11:45.920 | А, да, Светлана. |
| 19 | 00:11:46.780-00:11:48.160 | Здравствуйте. Я есть. |
| 20 | 00:11:48.160-00:11:49.030 | Здравствуйте. |
| 21 | 00:11:50.120-00:11:52.300 | Меня что-то выбрасывает сегодня. |
| 22 | 00:11:52.440-00:11:54.060 | Прям каждую минуту вообще ужас. |

A new 18-second, mono 16kHz PCM excerpt was extracted directly from ORIGINAL
video at 698s, without ASR, to
`/Users/yurielokhin/Documents/Codex/work/pr9-id17-original-audio.wav`.
SHA256: `8c2a69e30b530aad12d604a385528aad8862d0e0504ef9188fa0a8e8d42d96fb`.
The extraction command was:

```bash
ffmpeg -nostdin -v error -ss 698 -i '<original video above>' \
  -t 18 -vn -ac 1 -ar 16000 -n '<audio path above>'
```

Read-only timing/energy inspection at -40dB/0.25s reports a pause region
approximately 704.316-705.192s; the two threshold-adjacent intervals are
retained in `original-audio-silence-diagnostic.log`. This is NOT diarization,
utterance completeness or a quiet-speech deletion threshold. Nothing was
removed from the audio. A video frame shows the instructor, not a complete
speaker/turn annotation. The copied diagnostic log trims terminal progress-line
trailing whitespace only; raw model HTTP response files remain byte-exact.

Attempted audio input explicitly returned **"audio content omitted because you
do not support audio input"**. No human listening or speech verification is
claimed. An asynchronous, single source-boundary question and the actual
original audio excerpt were presented to the owner. No answer had arrived when
this report was prepared. This is not a repeat GUI/baseline acceptance request.

The text/timing sequence plausibly represents an independent elliptical
reminder that a participant has not yet been called. It could instead be
interrupted or have a continuation; audio verification must distinguish them.
Absence of a finite verb is not a diagnosis: `Я дома.`, `Готова.` and `А я завтра.`
can be complete conversational turns. These are linguistic counterexamples,
not production rules. Prior attempts improperly treated the incomplete-source
classification as established. The owner-rejected translation remains FAIL;
this finding does not retrospectively approve it or change the alarms.

## Guard/projection decision

No reliable, GENERAL deterministic `INCOMPLETE` label can currently be derived
for 17 from the retained features. Missing speaker/continuation metadata,
punctuation alone and the previously unreliable local POS tagger are inadequate.
The safe classification is `UNKNOWN`, not a fixture-driven assertion. An explicit
ellipsis can be recorded as an observable text feature, but does not prove
whether continuation follows. No names, phrase templates, English expected
words, deletion dictionaries, or TranslateGemma self-verification guard added.

An `INCOMPLETE` marker was therefore NOT tested using an invented source label.
The focused real diagnostics establish the causal layer and show why the
punctuation-only candidate is not integrated: it does not pass the joint gate.
They are not misrepresented as a successful evidence-derived guard probe.
There is no repair eligible for production integration or V4 yet.

SRT cue boundaries are stable alignment/output identities, not proven semantic
utterance boundaries. The current metadata's "logical source units" statement
does not establish otherwise. A multi-cue translation unit needs independently
verified continuation/speaker relations and validated source-to-target ownership
alignment accounting for target-language reordering. Simply concatenating
17-19 would combine a possible reply/new turn and still not authorize filling
17's missing proposition. No equal-length, punctuation or other approximate
output splitting was implemented. If an actual cross-cue unit is established,
safe deterministic projection remains a separate prerequisite.

## Verification / publication boundary

- New trace harness self-test: PASS on exact compiled sources, including exact
  request/response bytes, reversed nonfixture IDs, stable times, genuine scripted
  fragments AND scripted inventions passing structural validation, malformed
  HTTP/JSON, pin failure, override isolation and cancellation. No network in QA.
- Python ablation self-test: PASS; canonical-ID/no-op/serialization repairs
  made after independent review; recorded live requests revalidated unchanged.
- Four live captures: successful structural diagnostics, not semantic PASS.
- Independent reviewer/PO: model ownership is not semantic-slot enforcement;
  completeness cannot be inferred from these cue fields alone. Generic agents
  applied the contracts; no registered named-role or release approval claimed.
- The runner's shared-binary race was repaired by using unique build directories.
  Original captures were run sequentially after the initial build completed;
  their binary/source evidence remains retained. Final local QA and publication
  HEAD/CI are recorded in the PR audit and adjacent logs.
- Existing Quality Gate was PASS at afe4 before this evidence update. Do not
  reuse it as a verdict for a new publication HEAD; current CI is reported in
  the final PR audit. Semantic gate remains blocking regardless of green CI.
- No production protocol/cache/persistence change, user-project change, new
  source ASR, V4, release E2Es, Candidate, merge, installation or model deletion.

To reproduce only the fresh first-response diagnostic:

```bash
bash scripts/test_translation_causal_trace.sh \
  analysis/pr9_translation_context/v3/source-fixture.json \
  /absolute/new/trace-directory
```

Controlled overrides are generated by `Tests/TranslationCausalAblations.py`
from the retained first request and the separate replacement JSONs, then passed
to the same harness with `--request-override`. Do not use their artificial input
or output as a production result or source Gold.
