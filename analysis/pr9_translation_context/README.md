# Failed semantic-repair evidence

Base production snapshot: `a16ae0c016e94c76b78a5bb2f6fb7e05012c4d78`.
Owner result: `HUMAN_TRANSLATION_REVIEW: FAIL`.
Model: `translategemma:4b`, Q4_K_M, Ollama 0.33.1.
Digest: `c49d986b0764f5881c476eb21435bb62b7abc62347aab3d4a6071e811be510a1`.

These artifacts contain retained ASR text and actual model outputs. They are
not audio-Gold. The context patch was rejected and is NOT active production.
The V2 document is a diagnostic comparison, not an accepted release package.

## Contents

- `videotext-pr9-review-fixture.json`: the same 24 original cue records.
- `videotext-pr9-active-v2-output.json` and `...regression.log`: real active
  adapter replay; exit 1, rejected outputs 21/22/24, structural issues 0.
- `videotext-pr9-human-review-v2-output.json` and `...semantic-recheck.log`:
  real experimental adapter replay; exit 1, 17/22 defects plus observed 13/23
  leakage. The report predates adding explicit alarms for 13/23; its original
  failure list is retained without retroactive rewriting.
- `videotext-pr9-context-experiment*.jsonl`: exact requests and replies for
  isolated/context-before/context-after/XML and subsequent bounded ablations.
- `videotext-pr9-aligned-context-experiment.json`: an additional aligned JSON
  experiment; it still invented completion in 17 and was not adopted.
- `rejected-context-candidate.patch.gz`: the withdrawn implementation and its
  structural tests; apply only to the base snapshot for isolated reproduction.
- `videotext-pr9-human-translation-review-v2.md`: all 12 original items, old
  and experimental translations, changed outputs and adjacent source context.

## Reproduction

On the active production snapshot, with the pinned model present:

```bash
scripts/test_translation_semantic_review.sh --check-alarms
scripts/test_translation_semantic_review.sh \
  analysis/pr9_translation_context/videotext-pr9-review-fixture.json \
  /absolute/path/to/new-output.json
python3 Tests/TranslationContextExperiment.py isolated_v2 context_before
python3 Tests/TranslationAlignedContextExperiment.py \
  analysis/pr9_translation_context/videotext-pr9-review-fixture.json
```

The first command checks known good/bad fixture controls without a model call.
The second command is expected to fail on the retained active v2 behavior.
Keyword alarms are limited failure-class checks, not complete semantic grading.
No prompt replay establishes independent human acceptance.

## Identity

SHA-256 of active `TranslationAdapter.swift`:
`44060dcbfafc1bc6feee71dba543419bea7f854ddc5dfac02da43a8761652ba8`.

SHA-256 of the rejected experimental adapter at real-model execution:
`393fd533f2782b30ce52ff10eee87488c6e3c8fc5597a800742b77c51f49e83a`.

SHA-256 of the retained rejected patch after decompression (gzip preserves
the exact original diff, including blank context lines):
`4f9695b58d9cf758800dd6abff96a2232003d64b3bfdca70886b0c5e13dd8a0e`.

SHA-256 of shared input fixture:
`d2bd44d1d08bfb6e85cde70552570f953274d99ee5798ccc879de6b01f1b473b`.

SHA-256 of active-v2 output:
`81eff62b2ed00c2f120dfe5c6b9a321d07dd742368f62975d76f22b31831b6da`.

SHA-256 of rejected contextual output:
`51fd2dab7dfde6303920247fca43332292184bbf78e40659c69025f89edc591d`.

No Candidate was built. No release E2E was run. Installed app unchanged.
