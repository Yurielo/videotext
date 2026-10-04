# Repository evidence policy

VideoText keeps source code, deterministic tests, small intentional fixtures, and compact final reports in Git.

Do not commit generated investigation output such as raw model responses, wire captures, temporary logs, binary captures, intermediate experiments, rejected generated outputs, or release/candidate artifacts. Store those outside the repository in the governed local evidence/archive location when they must be retained.

## Allowed in Git

- production source
- deterministic tests and scripts
- small, intentional test fixtures
- compact Markdown documentation or final reports that are deliberately reviewed

## Keep outside Git

- raw/wire model traces
- temporary diagnostic logs
- generated analysis directories
- binary captures
- intermediate model experiments
- rejected generated candidates/patch archives
- application/release artifacts

The ignore rules prevent new untracked generated evidence from being added accidentally. They do not delete or rewrite evidence that is already tracked in repository history; any history cleanup must be a separate, explicitly reviewed operation.
