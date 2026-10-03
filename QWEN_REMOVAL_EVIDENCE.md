# Active Model Migration Evidence

## Current acceptance status

The subsequent v5 source-anchor repair and two real enforcement attempts are
documented in [new execution evidence](analysis/pr9_source_anchor_attempts/README.md).
The joint semantic gate still fails; V4 was not created. Earlier V3 evidence
below is historical, not the new repair result.

`HUMAN_TRANSLATION_REVIEW: FAIL`. The owner rejected semantic outputs from
`a16ae0c016e94c76b78a5bb2f6fb7e05012c4d78`. The structural benchmark results
below are historical engineering evidence, not semantic acceptance. PR #9
remains draft and the previous Candidate must not be promoted. The earlier V2
context experiment was rejected and withdrawn. The later owner-selected
BookText architecture is now implemented, but real V3 validation still flags
unsupported completion in ID 17. V3 human review is pending; semantic PASS is
not claimed. See [current V3 evidence](TRANSLATION_OWNERSHIP_V3_EVIDENCE.md) and
[historical investigation](TRANSLATION_CONTEXT_REPAIR_EVIDENCE.md).

## Active model map

| Operation | Previous active model family | Active replacement |
| --- | --- | --- |
| `ru -> en` and `en -> ru` transcript translation | Qwen | `translategemma:4b` |
| Topic boundary review and topic descriptions | Qwen with Gemma fallback | `gemma3:4b` |
| Topic embeddings | unchanged | `embeddinggemma:latest` |
| Speech recognition | unchanged | Whisper |

Historical manifests, reports and Git commits may retain their original model
provenance. They are not executed by a current VideoText operation.

## Measured local runtime

Measured on the target Mac with Ollama `0.33.1`:

| Model | Digest | Quantization | Parameters |
| --- | --- | --- | --- |
| `translategemma:4b` | `c49d986b0764f5881c476eb21435bb62b7abc62347aab3d4a6071e811be510a1` | `Q4_K_M` | `4.3B` |
| `gemma3:4b` | `a2af6cc3eb7fa8be8504abaf9b04e88f17a119ec3f04a3addf55f92841195f5a` | `Q4_K_M` | `4.3B` |
| `embeddinggemma:latest` | `85462619ee721b466c5927d109d4cb765861907d5417b9109caebc4e614679f1` | `BF16` | `307.58M` |

The translation adapter records the exact translation-model digest and protocol
version in `TranslationReport`. A changed model, digest or protocol invalidates
resume for a new translation run while preserving historical revisions.

## Historical before and after translation evidence

The prior Qwen benchmark completed the five-cue synthetic suite in `82.03 s`
for both directions with `qwen3:8b`. The final TranslateGemma run uses a
twelve-cue conversational set in each direction, including negation, numbers,
names, natural repetition and a sentence split across cue boundaries:

* `ru -> en`: validation pass in `9.76 s`.
* `en -> ru`: validation pass in `6.67 s`.
* Peak resident set size: `678,232,064` bytes; swap: `0`.

The first contextual-cue experiment was rejected: TranslateGemma sometimes
translated the supplied neighbouring context and duplicated text across cues.
The protocol in that snapshot therefore translates one cue at a time, returns plain
text only, and never redistributes a merged answer across timestamps. A failed
cue creates a `Human Review` task; a failed cue cannot silently validate the
remaining batch.

These deterministic checks establish structural preservation and obvious
semantic safety checks. They do not replace independent listening or human
translation review for ambiguous conversation.
