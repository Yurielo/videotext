# PR #9: executed source-anchor repair / failed enforcement evidence

Base: `c37c1c144f77907c821153ab4793e88d46cacf87`. This is a new repair execution,
not an unchanged V3 replay. BookText architecture and `translategemma:4b`
remain fixed; no alternate model or architecture comparison occurred.

## Actual change and tests of enforcement

The V3 prompt allowed completing speech if neighboring context explicitly
supplied a continuation. The new rule removes that exception and anchors every
output to its own cue's source span: context may disambiguate an expression or
referent already present but cannot add a predicate, object, location, action,
state or completion. Other owned cues are not content donors either.

All three changed protocols were compiled and executed sequentially through
the real production adapter/provider, using the same retained 180-second,
24-cue input and pinned model. No failed attempt is claimed as a repair PASS.

| Actual attempt | Enforcement | Real outcome / exit |
| --- | --- | --- |
| `source-anchor1` | Explicit per-cue no-completion contract; grouped JSON | 17 still adds completion; 21/22/24 pass bounded alarms; exit 1 |
| `source-anchor-revision1` | Contextual draft, then same-model independent per-cue JSON source-anchored revision, quoted untrusted draft | 17 still adds completion; 21/22/24 pass; exit 1 |
| `source-anchor-plain1` | Contextual draft, then single-owned-span plain translation; original immutable context retained, draft excluded | 17 still adds completion AND 21/22/24 regress; exit 1 |

For all attempts: exact 24 cue IDs/count/order/start/end preserved; structural
issues 0. This does not imply translation quality or exclusion of semantic
context leakage. The JSON revision had no draft fallback; only the second
stage's outputs could be published. Its extra requests provided no observed
fix and amplified retry cost. The plain variant was also rejected because it
damaged the contextual meanings the task requires us to retain.

## Actual outputs, not proposed wording

| Cue | Source-anchor prompt | JSON anchored revision | Plain anchored translation |
| --- | --- | --- | --- |
| 17 | Yuri, and I'm still here. | Yuri, and I am still here. | Yuri, and I'm still here. |
| 21 | Something keeps disconnecting me today. | Something keeps disconnecting me today. | I seem to be having some issues today. |
| 22 | It's just awful every minute. | It's just awful every minute. | It's absolutely terrifying every minute. |
| 24 | Now definitely distance learners, right? | Now definitely distance learners, right? | Now, definitely, the targets? |

All 24 outputs are retained in the three `*-result.json` files; no successful
rows were spliced from other attempts. They include runtime digest, protocol,
context identity, structural issues and failure lists. The logs contain actual
probe failures and all 24 output lines. Proper-name spellings differ between
runs (for example ID 8 `Margerita`); names are not independently verified.
No claim of absence of all other defects is made. No obvious earlier 13/23
neighbor-content additions were observed, but the known semantic failures above
are sufficient to reject both enforcement variants.

## Input/runtime identity

- Fixture: `../pr9_translation_context/v3/source-fixture.json`;
  SHA256 `7027a9cf6d6f2aa966d2692937ac94b839336b8410d337694cda892ece869b23`.
- Retained source ASR, clip offset 600 seconds, no Whisper rerun. Source and clip
  hashes are recorded in `../../TRANSLATION_OWNERSHIP_V3_EVIDENCE.md`.
- Context identity: `022950cbaabd0d755af89cf4f85a8b683a7fd1afd66d7da182a7e081c2084b59`.
- Model: `translategemma:4b`, Ollama `0.33.1`, Q4_K_M, temperature 0;
  digest `c49d986b0764f5881c476eb21435bb62b7abc62347aab3d4a6071e811be510a1`.
- Prompt result SHA256: `715bd2a2669528518cf021901b17fc177a82f13f01d11445f1b2ae1564100433`.
- JSON revision result SHA256: `777d3197a8a0c689725a9d0736f8731c252ce077d7775edb0b7cbd7d853c58cb`.
- Plain result SHA256: `01e9ed8c723b1092fd003ba066e233a3e579408a5c781a70103bcd89c6c2b7af`.

## Reproduction boundary

`rejected-plain-provider.swift` captures the failed plain implementation before
it was withdrawn. `rejected-json-revision-provider.swift` reconstructs the
preceding JSON revision implementation from the recorded edits. The latter
was NOT source-hashed before its original model run and is not advertised as a
byte-attested historical snapshot. Both are evidence-only files, outside
`Sources`; neither is an active alternate pipeline. Do not copy them into a
user installation. An isolated reproduction uses the base tree plus that
provider and the same fixture, with:

```bash
bash scripts/test_translation_semantic_review.sh \
  analysis/pr9_translation_context/v3/source-fixture.json \
  /absolute/path/to/attempt-result.json
```

The active request contract is the measured `source-anchor1` version. Failed
enforcement code is not shipped in the active source path. The only later
active-provider additions are a default-nil HTTP test seam and shared
cancellation/error handling; these do not alter the measured translation
prompt, schema or decoding parameters. No unchanged extra model replay was
run to present the same failure as new progress.

## Source-grammar enforcement investigated and rejected

Apple NaturalLanguage advertised Russian lexical tags on this Mac, but the
actual local check tagged `Я` as Conjunction, `Меня` as Adjective and
`выбрасывает` as Noun. Such tags cannot safely authorize deletion of target
meaning or classify incomplete Russian speech. No POS heuristic, deletion rule,
name list, fixture dictionary or hardcoded translation entered production.

## Current gate / stop

The new rule is implemented and protocol-versioned, but enforcement of the
joint semantic constraint is NOT proven. The tested model-mediated guard did
not remove unsupported completion; the stricter response interface additionally
lost required contextual disambiguation/referents. This is the observed blocker,
not a proof that every possible general enforcement is impossible.

Deterministic contract/transport/ownership/cache tests can prove prompt and data
handling, not force a model to respect semantic instructions. Real semantic
gate remains FAIL. V4 must not be generated or presented for acceptance.
The review generator now refuses V4 creation when failure alarms or structural
issues are present. Historical V1/V2/V3 artifacts are unchanged.

PR stays DRAFT. No release E2Es, final Candidate, merge or installation.
Installed app unchanged. Independent review/QA results and exact publication
HEAD / GitHub CI are reported in the PR audit, not inferred from old green CI.

## Final bounded engineering checks

- Independent QA: `bash scripts/test_translation_ownership.sh`, exit 0,
  compile-input hashes unchanged. See `ownership-test.log` and
  `ownership-source-hashes.txt` for the final active Sources/tests.
- Added general scripted cases: incomplete owned spans with likely neighboring
  completions, ambiguous expressions with different context, explicit referents,
  context-only material exclusion from owned input, exact alignment and ownership.
  These prove routing/contract wiring, NOT live semantic enforcement.
- Actual production provider with scripted HTTP: one batch, exact JSON schema,
  original IDs independent of response order, retained document/overlap metadata,
  truncation/ID errors and cancellation/error normalization; PASS.
- v4 -> v5 checkpoint invalidation and unchanged-input resume: PASS. Existing
  cache schema, revision/provenance fields and migration paths remain unchanged.
- Active retired-model guard: PASS; no Qwen calls in the real repair attempts.
- Existing `bash scripts/test_translation.sh`: PASS on final active Sources;
  see `adapter-test.log`. `git diff --check`: PASS before publication.
- V4 refusal even under Python `-O`: expected exit 1 (`ValueError`), output
  directory not created. See `v4-gate-refusal.log`.
- Independent read-only reviewer: no remaining engineering blocker in the final
  active diff; semantic failure remains explicitly blocking.
- Product Owner contract review: tested enforcement justifies this bounded
  blocked stop, without declaring universal impossibility or approving bad output.

Registered named-role invocation still reports `agent type is currently not
available`; generic independent agents applied the contracts. No registered
named-role execution or release verdict is claimed.
