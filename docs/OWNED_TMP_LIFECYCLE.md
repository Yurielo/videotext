# Disposable TMP lifecycle (Issue #10)

Read-only inventory of main `56209e1` identified these producers:

| Producer | Ownership/role | Lifecycle after this change |
| --- | --- | --- |
| `ToolRunner.run` stdout/stderr and subprocess internal scratch | ephemeral, exact new workspace | receipt + lease before use; defer covers launch/read/process failure, success and task cancellation; exact child process group is terminated on cancellation; SIGINT/SIGTERM handler and next-start recovery |
| `AudioEnhancementAdapter` UVR output | ephemeral audio intermediate | owned workspace before separator subprocess, defer all exit paths |
| `SpeechSynthesisAdapter` dubbing intermediates | ephemeral audio intermediate | owned workspace before use, defer all exit paths |
| `MediaAdapters` subtitle/watermark subtitle copies | ephemeral text | owned workspace before atomic write, defer all exit paths |
| every `scripts/test_*.sh`, all Swift probe `temporaryDirectory` calls | ephemeral test fixtures, binaries and child tool scratch | supervisor owns TMPDIR and default work root; success/error/INT/TERM cleanup; next-start recovery after SIGKILL |
| `run_recovery_bounded.sh` timeout marker | ephemeral | supervisor contains marker; existing watchdog remains; children in invocation-owned session |
| `test_e2e.sh` copied source/media/test app | ephemeral unless explicitly retained | supervisor contains work tree, existing traps remain |
| `build_app.sh` app output | persistent build output, caller retained | stable `../work/videotext-build` default, never automatically scavenged |
| `release_gate.sh` candidate/evidence | persistent governance evidence | candidate defaults below release `RUN_DIR`, never auto-deleted; no TMP default |
| layout screenshot, diagnostic evidence | explicitly persistent output | layout default output goes to `../outputs`; optional `VIDEOTEXT_EVIDENCE_DIR=/absolute/path` creates a fresh unique retained work directory |
| workflow project staging, `.partial`, model/cache/export directories | persistent project contract or existing per-operation staging | unchanged; no automatic private-TMP scavenger scans them |
| historical prefix TMP and unmarked directories | unknown/externally owned | retained, never prefix/age scavenged |

The native and shell managers have separate private per-user namespaces because
production is Foundation/Swift and development harnesses are Python-supervised
shell processes. Each directory is a fresh UUID with a versioned receipt,
exact path, UID-owned 0700 directory identity (device/inode), and an exclusive
lease. Recovery scans only its private namespace; requires valid receipt,
matching directory identity, dead owner PID, no live recorded child group,
no pending launch, free lease and no other process's open files (`lsof`). Missing scanner, uncertainty, malformed receipts, live
PIDs, symlink substitution, or foreign open files retain the object. PID reuse
is conservative: a live reused PID retains the workspace. Thirty-two retained
namespace entries block new workspace creation instead of unbounded growth.
This is a count guard, not a bound on an individual media operation's bytes.

Current-process cleanup revalidates exact identity and receipt and checks
foreign open files. SIGKILL cannot run cleanup; safe next-start recovery is the
recovery path. Native signals stop only verified launched process groups;
preexisting application/whisper/ffmpeg/Ollama processes are never targeted by
name. Shell supervisor passes its lease to children and records its exact child
session/group. Normal completion drains background group descendants too.
A pending native launch is an explicit uncertainty that retains its workspace.
Receipt mutation and signal cleanup are serialized; signals drain all children
before closing adapter scratch. Shell recovery also checks nested native
receipts. Missing scanner or a scanner timeout retains objects. POSIX realpath
normalizes only the trusted temp parent; the managed namespace leaf is checked
with lstat so a substituted symlink is rejected. Release-input hashing includes
the newly required supervisor.

No existing `/private/tmp` content, production installation, user projects,
exports, candidates, or recovery archives is manually cleaned by this PR.
Production app deployment remains a separate release task; no `.app` is issued.

## Reproducible lightweight validation

- `scripts/test_owned_tmp.sh`: 12 sequential native success/error cycles, launch
  failure and cancellation, normal background descendants drained, unknown/live
  ownership preserved; actual SIGTERM cleanup; actual SIGKILL owner with a live
  sleeping child holding no TMP file is retained, then recovered after child
  stops. Own count and bytes measured before/after (0/0 → 0/0).
- `python3 -B Tests/test_owned_tmp.py`: shell success/error repetition, launch
  failure, stale + foreign open descriptor, unknown/live/tampered receipt,
  SIGTERM, SIGKILL parent + child lease/session, normal background cleanup,
  pending launch preservation, namespace symlink rejection.
- `scripts/test_fixture_suite.sh`: one temporary testable core library reused
  for 20 existing self-contained probes plus baseline/application lifecycle/
  recovery-watchdog probes. It does not package an app or run/download models.
  History and ETA state are redirected into the owned fixture workspace.
- Real Whisper/UVR/Ollama model jobs, enhanced TTS voices, GUI/notifications and
  packaged-app release E2E remain separate external/release checks. No release
  is claimed or performed by these fixtures.
