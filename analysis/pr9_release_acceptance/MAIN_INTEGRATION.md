# PR #9 canonical-main integration

## Recorded parents

- PR #9 before integration: `074913f13b43449d5caff28991a376778043b3a5`.
- Canonical main: `cd5cee591f89a52c7e9db4d26fe4d066d4258507`.
- Merge base: `56209e1c2160e0c9e1d75d6e747e3271327f9d94`.
- History-preserving integration merge:
  `0e1de82e1e9c454c823b3a8b8aa0bda8f20812c6`.
- Merge parents are exactly the pre-integration PR head and canonical main.

Main-only commits integrated:

```text
f5ea45d Bound owned temporary workspaces and supervise probe scratch
197c49a Honor supervisor TMPDIR for native workspace isolation
23da075 Contain Foundation probe scratch and retain live child sessions
08288ea Protect live child groups across crash and serialize bounded cleanup
dc8b485 Keep adapter cohorts until every child stops and authority is complete
202c4be Retain non-object ownership receipts without crashing recovery (#10)
9ef98ca Use portable Python fixture for recovery startup regression
cd5cee5 Merge pull request #11 from Yurielo/codex/bounded-owned-tmp
```

PR-only commits retained:

```text
a16ae0c Replace active Qwen paths with TranslateGemma and Gemma
e658646 test: record failed human translation review and context ablations
c37c1c1 Implement BookText-owned translation context and retain V3 semantic blocker
afe4a79 Enforce source-span prompt contract and document rejected semantic guards
bda98b8 Trace first translation response and document source-completeness gate
074913f Record accepted human semantics and exact-snapshot release blocker
```

## Semantic conflict review

The merge completed without textual conflicts. A separate semantic comparison
found no differences between the pre-integration PR snapshot and the merge in:

- `TranslationAdapter.swift` and `TranslationContextPlan.swift`;
- translation paths in `WorkflowEngine.swift`;
- artifact/project provenance models;
- active topic provider/model selection;
- cache/resume, diagnostics, memory management and UI model selection.

Accordingly, the accepted prompt, TranslateGemma invocation, BookText document
context, local overlap, owned-content contract, source-anchor post-processing,
cue ownership and cache identity did not change. The retained Human Translation
Review remains applicable to the same bounded evidence set.

The accepted main implementations of `ToolRunner`, owned temporary workspaces,
process-group cancellation, child cleanup and recovery are byte-identical to
canonical main after the integration. Main's media/tool adapters, recovery
supervisor, build/test wrappers, probes and CI lifecycle coverage are retained.

## Release-evidence corrections

The prior GitHub Quality Gate checked a synthetic merge and was not standalone
PR-source evidence. The workflow now has two explicit jobs:

- `Quality Gate`: merge-snapshot regression coverage;
- `PR Head Build`: explicit PR-head checkout, source-identity assertion,
  process-lifecycle and translation-contract checks, standalone app build and
  bundle verification.

The E2E harness now exercises `.translateTranscript` through `WorkflowEngine`
and the production `OllamaTranslationProvider` request path. It checks the real
model identity, BookText context/ownership, exact cue identity and times,
cancel/resume checkpoints, cache replay and persisted provenance. A deterministic
wire self-test covers two ownership groups before real model execution.

The release gate now includes the translation and process-lifecycle focused
tests in its hashed input set and executes them before E2E. Its order is focused
tests, two sequential E2Es, Candidate build, codesign and smoke, matching the
Product Owner's explicit sequence.

No installed app, user project or historical result was modified by integration.
Final E2E, Candidate and GitHub check results are recorded separately against
the eventual frozen release HEAD.
