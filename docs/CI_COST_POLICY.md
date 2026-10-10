# CI cost policy

This policy separates product confidence from hosted-runner spending. It does
not remove any applicable local product gate.

## Risk levels

`LEVEL_A` covers application behavior: UI, workflow/orchestration, Core and
Services business logic, text/timing processing, normal fixes and features, and
ordinary bundled dependency content updates that do not change packaging,
runtime discovery, native architecture, signing, or toolchain behavior.

Applicable focused tests, regression, real scenarios, independent QA/review,
governed CORE E2E, Candidate identity, codesign/lifecycle, and Owner Test remain
mandatory. GitHub-hosted macOS is not required.

`LEVEL_B` covers build/platform/distribution infrastructure: Xcode or build
settings, packaging, runtime discovery, signing/notarization, native binary
architecture/loading, toolchain changes, and compatibility-sensitive build
infrastructure. It requires all applicable local gates plus one clean,
independent GitHub-hosted macOS build/toolchain validation of the exact SHA.

Release is not a third risk level. Promotion uses the level of the actual diff
and its separate release checks.

## Deterministic classification

Run:

```bash
python3 scripts/ci_risk_classifier.py --base <full-base-sha> --head <full-head-sha>
```

Rules live in `.ci/ci-risk-policy.json`. The JSON result records changed paths,
change types, reasons, exact SHAs, and hosted-macOS eligibility. Protected paths,
native files, infrastructure markers, mixed diffs, and unknown paths classify
as `LEVEL_B`. Added symlinks and other non-regular modes, FAT/FAT64 native
binaries, policy self-changes, and runtime-discovery markers are also
fail-closed B inputs. The policy loader refuses a policy that removes protection
from its classifier, dispatcher, tests, or paid workflow. An empty diff is
fail-closed and not eligible for a hosted run.
Classification uses the changed lines, not the identity of a file that happens
to contain runtime code elsewhere. An ordinary bundled dependency content
update, a timing-validation-only edit, or a presentation-only service is
`LEVEL_A` when its changed lines do not alter packaging, runtime discovery,
executable selection, bundle lookup, PATH/environment resolution, native
dependency loading, architecture, signing, or toolchain behavior. Explicit
machine-readable markers cover those mechanisms. A newly added Service is A
only when its filename matches the explicit presentation-only allowlist
(`*Presentation.swift`) and its changed lines have no infrastructure marker.
All other new Services and all new Adapters remain fail-closed `LEVEL_B`.
Runtime-discovery markers include bundle lookup, executable APIs, system,
home-relative (including parameter expansion), and Application Support/user-domain executable paths,
`PATH`/environment resolution, dynamic-loader paths, command-array/direct
relative launcher selection (including branch-local `tools/...` invocations), shell executable-variable assignment/invocation,
and command lookup. Existing business-logic edits remain A unless
another protected path, marker, native file, or ambiguous change rule applies.
Five specialized discovery owners (`MediaAdapters`, `SpeechSynthesisAdapter`,
`Diagnostics`, `ToolRunner`, and `WhisperModelLocator`) remain exact-path B
because their complete files define runtime resolution. Test-harness files
under `scripts/test_*` are excluded from marker scanning: their temporary app
or tool invocations do not alter production packaging or runtime discovery.

The classifier is a policy input. LLM judgment may explain a result but cannot
replace or downgrade it. Ambiguous infrastructure-sensitive changes stay B
until the deterministic rules are deliberately changed and reviewed.

## Paid macOS dispatch

The paid workflow has no push, pull-request, schedule, or reusable-workflow
trigger. The supported entry point is:

```bash
python3 scripts/dispatch_paid_macos_gate.py \
  <full-expected-sha> --ref <remote-branch> \
  --local-gate-evidence <exact-sha-local-gates.json> \
  --local-evidence-bundle <machine-readable-evidence-file>
```

The dispatcher resolves the remote branch, runs the classifier, rejects A,
requires its own checkout to be clean and exactly at the expected SHA, records
the classification digest, verifies exact-SHA machine-readable evidence for
every governed local gate, and refuses a second initial attempt across the
complete exact-SHA run history. A local exact-SHA lock prevents concurrent
dispatches from the governed owner Mac. The
workflow checks out `expected_sha`, verifies exact identity, recomputes the
canonical merge-base against the current default branch, recomputes the
classification, and validates the digest before its bounded build/toolchain
check. It uses read-only permissions, SHA-scoped concurrency, no automatic
rerun, and a 20-minute timeout. The read-only token includes `checks: read`
only so the single controlled retry can inspect machine check annotations.

Local-gate evidence uses this schema. Every governed gate must appear exactly
once, either in `completedGates` or in `notApplicableGates` with a non-empty
reason. Focused tests, regression, independent QA, and independent code review
are never optional. `evidenceSha256` is recomputed from the supplied underlying
local evidence file before dispatch; the summary itself is exact-SHA-bound and
recorded by `ci-cd-engineer`.

```json
{
  "schemaVersion": 1,
  "expectedSha": "<full-sha>",
  "classification": "LEVEL_B",
  "status": "PASS",
  "completedGates": [
    "focused-tests",
    "regression",
    "real-scenarios",
    "independent-qa-review",
    "independent-code-review",
    "core-e2e",
    "candidate-identity",
    "codesign-lifecycle",
    "owner-test"
  ],
  "notApplicableGates": {},
  "evidenceSha256": "<sha256-of-local-evidence-bundle>",
  "recordedBy": "ci-cd-engineer",
  "recordedAt": "2026-10-11T12:00:00Z"
}
```

A single same-SHA retry is possible only with a JSON evidence file containing:

```json
{
  "schemaVersion": 1,
  "expectedSha": "<full-sha>",
  "priorRunId": 123,
  "failureClass": "runner-capacity",
  "reason": "GitHub did not allocate a runner",
  "recordedBy": "ci-cd-engineer",
  "recordedAt": "2026-10-11T12:00:00Z"
}
```

Allowed classes are `github-outage`, `runner-capacity`, `runner-startup`, and
`timed-out-before-steps`. Billing/spending failures and product/test failures
are hard stops. They cannot authorize a retry. Codex and automation may not
change budgets, spending limits, or bypass the policy.

The failure class is not accepted on operator text alone. The dispatcher and
workflow read the prior GitHub run, require that no workflow step started, and
classify allowlisted runner/service annotations. Billing/payment annotations
always win and produce `BILLING_HARD_STOP`. A failed build, assertion, exact-SHA
check, classifier, signature check, or other started step is not retryable.

Direct GitHub UI dispatch is an administrative escape hatch, not the governed
entry point. It cannot be triggered by an ordinary PR or push, and the workflow
still fails closed unless its exact-SHA Level B evidence matches. A person with
repository write access can deliberately create repeated fresh dispatches; that
is an administrative spending action, not an automatic retry loop, and cannot
be rejected before runner allocation without an external preflight or protected
environment. Repository access control, branch protection, and Owner review
remain the control for such administrative actions.

Without a Linux preflight, protected environment, or external GitHub App, the
repository cannot execute the classifier before GitHub allocates the explicitly
requested macOS runner. Therefore the hard pre-allocation controls available in
this repository are manual-only dispatch, exact `github.sha`, rejection of UI
reruns, and SHA-scoped concurrency. Deterministic eligibility and retry-history
validation run as the first bounded steps. Adding a hosted Linux preflight is a
separate policy decision and is intentionally not part of this change.

## Evidence and Candidate validity

For A, machine-readable local release evidence is valid CI/CD evidence. A
billing/capacity failure is infrastructure evidence and does not erase product
evidence already produced locally. Governance-only changes do not invalidate a
Candidate when the release-input identity is unchanged.

The Owner approves this policy. Individual hosted runs are technical execution
of the approved B rules, not recurring product-policy decisions.

## Local policy verification

```bash
scripts/test_ci_cost_policy.sh
```

This test does not dispatch GitHub Actions or allocate any hosted runner.
