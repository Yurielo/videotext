# PR #9 release gate: new baseline blocker

> Historical stop record. The Product Owner subsequently authorized integration,
> and canonical main was merged into PR #9 by
> `0e1de82e1e9c454c823b3a8b8aa0bda8f20812c6`. See
> [`MAIN_INTEGRATION.md`](MAIN_INTEGRATION.md). The baseline discrepancy is
> resolved; fresh exact-snapshot release evidence is still required.

Status on 2026-10-03: `PRODUCT_OUTCOME_BLOCKED_NEW_CAUSE`.
Human semantic review: PASS; this is not another translation-semantic failure.

## Exact snapshots

- Reviewed PR source: `bda98b88efe3581f88657e394f746b6ceff346c6`.
- Accepted canonical main: `cd5cee591f89a52c7e9db4d26fe4d066d4258507`.
- CI checkout: `d64ef78cbd043fb1676bc952aeb1596548e89359`, the synthetic merge
  of these two snapshots.
- [Quality Gate run 37128599185](https://github.com/Yurielo/videotext/actions/runs/37128599185):
  SUCCESS for that synthetic merge, not proof of a standalone PR-source build.

The run API's `head_sha` is the PR source SHA; the actual checkout log states:

```text
HEAD is now at d64ef78 Merge bda98b88efe3581f88657e394f746b6ceff346c6 into cd5cee591f89a52c7e9db4d26fe4d066d4258507
git log -1 --format=%H
d64ef78cbd043fb1676bc952aeb1596548e89359
```

## Why release is blocked

The standalone PR source predates accepted owned-temporary-workspace protection,
verified process-group cancellation, descendant cleanup and recovery from main.
These safeguards are present in CI's merged checkout but absent in a Candidate
built directly from the reviewed PR source. A green PR check cannot certify
those absent safeguards. Static independent review established this discrepancy;
no new runtime reproduction of orphan creation was performed in this turn.

Accepted main's production changes are in:

- `Sources/videotext/Services/ToolRunner.swift`;
- `Sources/videotext/Adapters/AudioEnhancementAdapter.swift`;
- `Sources/videotext/Adapters/MediaAdapters.swift`;
- `Sources/videotext/Adapters/SpeechSynthesisAdapter.swift`.

Related accepted changes also cover build/test/release/recovery scripts,
`scripts/owned_tmp.py`, lifecycle probes and CI. Integrating only ToolRunner
would not preserve the complete accepted safety mechanism.

The named GitHub PR Reviewer returned this blocker. The named Product Owner
confirmed that this human-interpretation/release continuation does not authorize
production branch integration. No merge/rebase/cherry-pick was performed.

## Work preserved, not represented as completed

The QA role identified that the existing main E2E does not actually execute
translation. Its proposed enhancement is retained verbatim as
[`proposed_e2e_harness.NOT_VALIDATED.patch`](proposed_e2e_harness.NOT_VALIDATED.patch).
It is not applied to the executable harness. It requires compile repairs around
throwing/asynchronous expressions in synchronous assertion autoclosures,
compilation and runtime validation. It is not release evidence.

`Tests/EndToEnd.swift` and `scripts/test_e2e.sh` remain identical to the reviewed
HEAD. No Sources, Resources, production/build code or installed app was changed.
Two final real-media E2Es: NOT RUN (0/2). New Candidate/codesign/smoke: NOT RUN.
Heavy model execution was not started; no owned test sessions remained running.

Checks actually performed: baseline preflight PASS, `git diff --check` PASS,
source-fixture hash verified, PR still OPEN/DRAFT, CI checkout identity verified,
installed binary and Info.plist hashes unchanged, target process list empty.

Installed binary SHA256:
`23d53ae1c5d5255dcc0f18c454b7c04cadf5c0f0647c7ca161e60bd0afe237a3`.
Installed Info.plist SHA256:
`145c157a911140cea89f329cdf6bdc496703d3065af038a5724ab1431f21ab7f`.

## Bounded next action requiring authorization

Integrate accepted canonical main into PR #9 non-destructively, preserving both
the translation work and the complete owned-TMP/process safeguards. Finish and
validate the retained E2E enhancement, freeze a new clean release HEAD, then
obtain fresh independent review and exact-snapshot CI/QA evidence. E2E count
starts at zero; run two sequential clean real-media E2Es before building the
new Candidate. No installation or PR merge is authorized by this proposal.

The human decision and historical experimental failures remain as documented in
[`OWNER_SEMANTIC_DECISION.md`](OWNER_SEMANTIC_DECISION.md).
