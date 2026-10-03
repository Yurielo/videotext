# PR #9: BookText ownership/context implementation and V3

## Decision and actual gate

The Product Owner selected DOCUMENT CONTEXT + LOCAL BEFORE/AFTER OVERLAP +
OWNED CONTENT from prior BookText testing. This continuation implements that
decision, not an architecture comparison or model bake-off.

PR #9 remains DRAFT / NOT MERGED. Human review: AWAITING_HUMAN_REVIEW (no row
accepted). Technical semantic gate: FAIL, `17-unsupported-completion`. The
24-cue structure passes, but the fixture as a whole does NOT pass. No release
E2Es, new final Candidate, installation or merge occurred. Installed app was
not modified. The previous Candidate is not valid for these changed Sources.

## Concrete implementation source

Read-only BookText reference:

- repository HEAD: `6de177884225ee558ce51342f728e72426161346`;
- file: `/Users/yurielokhin/Documents/Codex/2026-10-02/booktext-translategemma-replacement/work/booktext/tools/translation.py`;
- SHA256: `9b955bd072cd127324567838d45586c777b05c46b2da3356801fe8267c9ed057`;
- `_document_context`: bounded document metadata;
- `_translate_ollama`: interpretation-only context and owned text with the
  TranslateGemma translator template;
- execution checkpoints and identity-based ordered assembly.

VideoText keeps its existing adapter and pipeline. Since subtitles must retain
cue identity rather than redistribute a paragraph translation over times, the
provider returns a validated array of `cueId`/`text` records for owned cues.

## Contract and persistence

- Stable output identity is the original cue ID, independent of response order.
  Original count, ordering, start and end times are reconstructed unchanged.
- Context is planned once from the full source before execution chunking.
  Each cue has exactly one output owner; context copies have none.
- Document context contains transcript metadata, not a repeated source excerpt.
  Title derives from actual two parent-folder names and media filename, bounded
  to 160 characters; the document block is under 512 characters. No guessed
  meeting description, specific names or phrase translations are hardcoded.
- Local context contains at most two complete neighboring cues / 600 characters
  per direction. An oversized intervening cue stops expansion. Pending-owner
  context maps retain before/after direction across sparse retries; rows already
  owned by the request are not duplicated as context.
- Default execution group is 32 cues. Groups are checkpoint units, not semantic
  boundaries. The provider receives the owned conversation as one ID envelope.
- JSON schema and post-decode validation require the exact owned ID set, unique
  IDs, correct count and nonempty text. Truncation is rejected. Bounded isolated
  retries retain validated siblings. Unresolved outputs create issues/Human Review
  rather than silent ready status. Structural validation cannot detect arbitrary
  semantic inventions; the remaining ID 17 demonstrates this limitation.
- Protocol: `translategemma-booktext-owned-cues-v4-docmeta512-lineage2-overlap2x600-id-array-grammar2-ctx8k`.
- Context contract: `booktext-owned-cue-context-v1-docmeta512-lineage2-overlap2x600`.
- Model/digest/protocol, languages, source revision, source content/times/order,
  document/overlap identity and owner groupings participate in checkpoint keys.
  Unchanged input resumes from atomic validated prefixes; unknown model digest
  disables persistent checkpoint reuse. Corrupt/non-prefix checkpoints miss.
- Checkpoint write failure is fatal; cancellation cannot publish a cancelled
  final unit. No user data or historical caches are deleted.
- New reports use schema 3 with context identity and SRT/TXT byte hashes.
  Legacy reports still decode, but cannot authorize stale-profile reuse.
  Manual revisions are protected: immutable revision bytes and cycle-safe
  descendant lineage are checked; new profiles cannot silently overwrite edits.
- ASR, Topics, UI, Resources, BuildInfo and installed application are unchanged
  by this continuation. No Qwen requests or fallback were introduced.

## Real fixture and runtime

- Model: `translategemma:4b`, exact tag;
- digest: `c49d986b0764f5881c476eb21435bb62b7abc62347aab3d4a6071e811be510a1`;
- Ollama: `0.33.1`, `Q4_K_M`, 4.3B; temperature 0, context 8192;
- timeout 300 seconds; measured-size output allowance includes the ID envelope;
- source video: `/Users/yurielokhin/Documents/Zoom/2026-09-26 13.00.44 Полнолуние 26 сентября 2026/video2572105971.mp4`;
- source SHA256: `41aaa6fabfb51e8caf1c2af044ef33469deac741c9db6da48d92d3eda7ca2a30`;
- retained source-cue fixture SHA256: `d2bd44d1d08bfb6e85cde70552570f953274d99ee5798ccc879de6b01f1b473b`;
- V3 fixture SHA256: `7027a9cf6d6f2aa966d2692937ac94b839336b8410d337694cda892ece869b23`;
  same 24 cues, with actual source-folder metadata added;
- local recreated 180-second clip, offset 600 seconds: `source-10m-13m.mp4`;
  SHA256 `82533ea990d1411c43b21abecdc04e634fe6a59dd81dc5dcad9e55529dab66ec`;
- final production output SHA256:
  `aaec460f74bfa365abcdd31b37f611bc9817c0bd40760a02b717ff36f556bf0f`;
- final context identity:
  `022950cbaabd0d755af89cf4f85a8b683a7fd1afd66d7da182a7e081c2084b59`.

The final real adapter/provider probe used the V3 fixture with the protocol
above and exited 1. All 24 cue IDs/count/order/times match, structural issues 0.
Observed mandatory failure-class results:

| Cue | Actual final output | Technical alarm |
| --- | --- | --- |
| 17 | Yuri, and I'm still here. | FAIL: unsupported completion `here` |
| 21 | Something keeps disconnecting me today. | PASS: conferencing meaning |
| 22 | It's just awful every minute. | PASS: negative evaluation |
| 24 | Now definitely distance learners, right? | PASS: student referent |
| 13 | Tatiana. | No earlier neighbor contamination observed |
| 23 | Well, I'm ready. | No earlier neighbor contamination observed |

These bounded alarms are not human semantic acceptance. Russian ASR is not
audio-Gold. No guarantee of absence of all additions/omissions is made. Names
and ambiguous source fragments require listening. The real 24-cue input fits
one default execution unit; cross-unit continuity is proven by deterministic
tests, not by a new long-form model run. EN -> RU and independent-material
quality were not revalidated in this bounded stage.

## Deterministic verification

- `bash scripts/test_translation_ownership.sh`: PASS, exit 0. Compile-input
  hashes unchanged before/after. Evidence: `analysis/pr9_translation_context/v3/ownership-test.log`
  and `ownership-source-hashes.txt`.
- Covers unique ownership, context-only exclusion, response identity/order,
  unchanged timestamps, boundaries at group sizes 1/2/3/32, partial retries,
  completed-prefix resume, no unnecessary recomputation, cancellation, fatal
  checkpoint writes, corrupt/tampered checkpoints, context/source/title/model/
  protocol invalidation, legacy reports and immutable human-revision lineage.
- Covers short wrong-language echoes without rejecting protected terms/numbers,
  sparse context direction, quoted metadata and bounded output budgets.
- `bash scripts/test_translation.sh`: PASS on final Sources; adapter mock probe.
- `bash scripts/test_no_retired_translation_models.sh`: PASS (active-code guard,
  not exhaustive instrumentation of every historical operation).
- `git diff --check`: PASS before publication.
- Real semantic probe: FAIL, exit 1, only `17-unsupported-completion` remains.
- GitHub CI is reported separately against the publication HEAD; earlier green
  CI must not be reused as evidence for this changed snapshot.

Independent read-only generic reviewer found no additional production blockers
and explicitly retained the semantic failure. Independent QA produced the mock
ownership tests and ran them on final Sources. Contracts were applied, but
registered role invocation returned `agent type is currently not available`;
these are NOT claimed as registered named-role executions or a release verdict.

## Human Review Package V3 / stop

Durable local directory: `/Users/yurielokhin/Documents/videotext-pr9-human-review-v3`.

- `human-translation-review-v3.html`: player and interval buttons;
- `human-translation-review-v3.md`: readable equivalent;
- `source-10m-13m.mp4`: unchanged-source excerpt (local only, not in Git);
- `source-fixture.json`, `production-output.json`: exact inputs and outputs.

Repository copies are in `analysis/pr9_translation_context/v3/`. V1 and failed
V2 artifacts remain unchanged. All original 12 review rows include source RU,
local RU context, actual V1/V2/new output, changed indicator and technical note.
All 24 production cues are included. No row is self-approved.

Stop here as requested. No final release E2Es or Candidate until semantic
acceptance; do not merge or install. The remaining ID 17 failure prevents
claiming `Semantic regression technical checks: PASS` or `Real fixture: PASS`.
