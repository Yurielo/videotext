# PR #9 cross-cue ownership repair

Status: `AWAITING_HUMAN_REVIEW`

This evidence belongs to the production snapshot that introduces translation
protocol
`translategemma-booktext-owned-tasks-v6-docmeta512-lineage2-overlap2x600-source-echo1-ctx8k`.
The final production adapter source used by the probes has SHA-256
`b2fc13f6844b8c55b02a0a0b26094e9f2da59ce73f8167f4d1bfab92c64b36b7`.
It is not release evidence and does not authorize a Candidate, installation,
merge, or final release E2E.

## Confirmed failure layer

The retained EN to RU QA trace showed that semantic migration was already
present in the raw `translategemma:4b` response. The parser decoded the rows it
received, projection retained the returned `cueId`, and final assembly retained
the projected ordering and timestamps. Parser, projection, and assembly did not
originate the migration.

The accepted v5 request contained several jointly owned cues in one flat array
and returned only `cueId` plus translated `text`. Although the prompt asked the
model to preserve cue ownership, there was no independent source identity in
the response with which the adapter could prove the association. The model
repartitioned the target-language clauses while still returning valid IDs,
counts, ordering, and timestamps, so structural checks masked incorrect
semantic ownership.

During repair, adding owner-scoped tasks and `sourceEcho` exposed a second,
mechanically reproducible constraint: `JSONSerialization` emitted the proposed
three-field schema as `sourceEcho -> text -> cueId`. The constrained decoder
then generated content before its identity anchor and produced shifted source
echoes. Validation correctly failed closed. Emitting byte-stable schema order
`cueId -> sourceEcho -> text` removed that ambiguity and made the exact same
owner-scoped request pass in both directions.

## Retained failure trace: EN to RU cues 3-8

| cueId | Source owned by the cue | Raw/final result before repair | Confirmed ownership failure |
| --- | --- | --- | --- |
| 3 | `energy the led has got a big blue spike in it although we tend not to see that and that is` | `энергии. В светодиоде есть большой синий пик, хотя мы обычно этого не замечаем, и это даже относится к тепловым светодиодам...` | Imported the beginning of cue 4. |
| 4 | `even true of warm leds and there is no red the light found in leds when we use them certainly` | `мы будем использовать для изучения сетчатки, наблюдая за мышками...` | Cue 4 meaning was displaced; cue 5 meaning appeared here. |
| 5 | `we'll be using them on the retina looking at mice we can watch the mitochondria gently go downhill` | `не работают очень хорошо... при освещении светодиодами...` | Cue 5 meaning was displaced; cues 6-7 appeared here. |
| 6 | `far less responsive they their membrane potentials are coming down the mitochondria` | `с теми же уровнями энергии, которые мы найдем в домашней или коммерческой обстановке` | Cue 6 meaning was displaced; cue 8 appeared here. |
| 7 | `are not breathing very well watch that in real time under led lighting and led lighting at the` | Empty in the first response; retry reproduced cue 7 content. | Owned content was initially lost, then emitted only by retry. |
| 8 | `same energy levels that we would find in a domestic or a commercial environment` | Empty in the first response; retry reproduced cue 8 content. | Owned content was initially lost, then emitted only by retry. |

The original source, exact requests, responses, and manifest evidence remain in
the retained QA directory:
`/Users/yurielokhin/Documents/Codex/work/release-gate/20261003T214230Z/e2e-2-evidence/real-translation-en-to-ru-CBBB9B0C-65E0-4156-8485-3B5D9827C0B8`.

## Layer-by-layer trace

| Layer | Retained observation | Finding |
| --- | --- | --- |
| Source cue | `source-cues.json` retains IDs, text, and times for all eight cues. | Source ownership is unambiguous at adapter input. |
| Logical unit | The original subtitle cue is the stable logical/ownership unit. | No sentence-level resegmentation is required or permitted. |
| Document context | Document metadata identifies a timecoded spoken transcript. | Metadata contains no cue 3-8 propositions and cannot explain migration. |
| Local overlap | Each owner can see at most two preceding and two following cues. | Needed for continuity, but must remain read-only. |
| Owned content | The old request submitted multiple owned cues in a flat batch. | A prompt instruction alone did not make ownership mechanically strict. |
| Exact provider request | Retained `wire-*.request.json` shows the multi-cue prompt and constrained JSON format. | The request permitted target-language repartition before stable identity anchoring. |
| Raw provider response | Retained `wire-*.response.json` already assigns neighboring semantic material to the wrong IDs and initially leaves IDs 7-8 empty. | Migration originates inside provider generation. |
| Parser | Decoder reads the returned `cueId` and `text` without changing text. | Not causal. It lacked an independent source-identity echo to reject the bad response. |
| Projection | Dictionary lookup projects returned text to the same returned cue ID. | Not causal; it faithfully projected a semantically wrong association. |
| Final assembly | Assembly restores original ordering and timestamps. | Not causal; structural correctness concealed semantic ownership failure. |

The v6 trace in `wire-en-to-ru/002.request.json` makes every source cue an
owner-first task with its own complete overlap. The matching raw response in
`wire-en-to-ru/002.response.json` returns each exact source echo before its
translation, allowing the adapter to prove and enforce the association before
assembly.

## Hypothesis experiments

| Hypothesis / change | Focused real-model result | Conclusion |
| --- | --- | --- |
| Prompt-only ownership wording is sufficient. | Improved some rows but did not simultaneously retain the accepted RU to EN contextual behavior. | Rejected as insufficient. |
| Owner tokens around flat multi-cue input prevent migration. | EN context leaked into owned output. | Rejected. |
| Keyed output plus flat owned input is sufficient. | EN to RU migration persisted. | Rejected. |
| One task per cue with `sourceEcho`, but schema emitted in serializer-selected field order. | Validation failed closed because the model shifted source/text before assigning the neighboring ID. | Useful containment, but not a successful translation contract. |
| Owner-first tasks plus byte-stable constrained schema `cueId -> sourceEcho -> text`. | Real EN to RU and RU to EN probes returned exact ID/source pairs; no proposition was lost or duplicated by the automated fixture checks. | Accepted for production integration, pending human semantic review. |
| Split at an estimated 7,680-token ceiling. | The 24-cue RU fixture was split and contextual meanings at 21/22/24 regressed. | Rejected as over-conservative. |
| Split only above an estimated 7,936-token ceiling, retaining a 256-token reserve. | The 24-cue accepted RU fixture remained one request; deliberately oversized synthetic input still split with complete ID/order/overlap preservation. | Accepted bounded execution policy. |

## Minimal production repair

- Preserve document context and complete local overlap context.
- Represent every owned cue as an independent task with immutable `cueId`, its
  exact `source`, and read-only `contextBefore` / `contextAfter`.
- Require one response object per task with `cueId`, exact `sourceEcho`, and
  translated `text`.
- Build the Ollama request bytes directly so both task and constrained-schema
  field order are stable and identity precedes generated translation.
- Split oversized execution batches deterministically before the 8K model
  context safety boundary while retaining each cue's complete precomputed
  overlap. A single cue that cannot fit is rejected explicitly for Human
  Review rather than published as successful output.
- Reject the entire provider response when row count, IDs, uniqueness, or exact
  source echo does not match. No approximate projection or textual reflow is
  allowed.
- Bump the protocol from v5 to v6 so existing cache/checkpoint material cannot
  be reused under the new ownership contract.

## Real-model validation

Model: `translategemma:4b`

Ollama: `0.33.1`

Model digest:
`c49d986b0764f5881c476eb21435bb62b7abc62347aab3d4a6071e811be510a1`

### EN to RU

The production adapter translated all eight retained cues with exact ID/source
pairing. Cues 3-8 retained their own propositions with no automated evidence of
cross-cue migration, loss, or duplication. Result:
[`en-to-ru-output.json`](en-to-ru-output.json). Exact wire:
[`wire-en-to-ru`](wire-en-to-ru/).

### RU to EN

The production adapter translated all 24 retained cues with exact ID/source
pairing. The accepted contextual readings for presence turns, IDs 21/22, ID 24,
and the Product Owner's ID 17 decision remain represented. Result:
[`ru-to-en-output.json`](ru-to-en-output.json). Exact wire:
[`wire-ru-to-en`](wire-ru-to-en/).

These probes establish structural ownership and bounded semantic alarm checks.
They do not self-approve translation quality. The changed production semantics
require the separate bidirectional Human Review package.

## Deterministic regression

`scripts/test_translation_ownership.sh` passed on the final source snapshot.
It verifies source-echo rejection, context-only leakage containment, stable
schema bytes, adaptive context-safe batching, duplicate/lost ownership handling,
selective retry, cancellation, checkpoint resume, v5 to v6 cache invalidation,
provenance identity, and legacy report decoding. The semantic fixture controls
also contain explicit negative cases for migration, loss, duplication, and
context-only leakage.

The compile-and-run `EndToEnd.swift --translation-wire-self-test` mock forces
the production provider to split a checkpoint unit, verifies a contiguous and
complete sequence of transport batches, rejects reordered/lost ownership, and
confirms checkpoint replay adds no chat. This is deterministic mock coverage,
not a final release E2E.

Final release E2Es and Candidate creation are deliberately deferred until the
new Human Review is accepted.

## Infrastructure status

PR #9 required checks are not executing. GitHub run `37156042095`, job
`111302732385`, reports `runner_id=0`, `steps=[]`, and the annotation:
`The job was not started because recent account payments have failed or your
spending limit needs to be increased.` This is
`GITHUB_ACTIONS_INFRA_BLOCKED`; it is independent of the product repair and was
not worked around in production code or workflow configuration.
