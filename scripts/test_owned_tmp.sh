#!/usr/bin/env bash
set -euo pipefail
if [[ "${VIDEOTEXT_TMP_RUNNER:-}" != "1" ]]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/owned_tmp.py" /bin/bash "$0" "$@"
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swiftc "$ROOT/Sources/videotext/Services/ToolRunner.swift" "$ROOT/Tests/OwnedTMPProbe.swift" -o "$TMPDIR/owned-tmp-probe"
STALE="$($TMPDIR/owned-tmp-probe --abandon)"
"$TMPDIR/owned-tmp-probe"
[[ ! -e "$STALE" ]]
python3 "$ROOT/Tests/test_owned_tmp.py"
python3 - "$TMPDIR/owned-tmp-probe" <<'PYTEST'
import pathlib, signal, subprocess
probe = __import__('sys').argv[1]
child = subprocess.Popen([probe, '--wait'], stdout=subprocess.PIPE, text=True)
path = pathlib.Path(child.stdout.readline().strip())
assert path.exists()
subprocess.run([probe], check=True)  # another live process's workspace is retained
assert path.exists()
child.send_signal(signal.SIGTERM)
assert child.wait(timeout=5) == 143
assert not path.exists(), 'native SIGTERM leaked owned TMP'
print('NATIVE_SIGTERM_AND_FOREIGN_LIVE_PASS')
PYTEST
python3 - "$TMPDIR/owned-tmp-probe" <<'PYTEST'
import os, pathlib, signal, subprocess, sys, time
probe = sys.argv[1]
owner = subprocess.Popen([probe, '--orphan'], stdout=subprocess.PIPE, text=True)
path_text, pid_text = owner.stdout.readline().strip().rsplit(' ', 1)
path, pid = pathlib.Path(path_text), int(pid_text)
try:
    owner.kill()
    owner.wait()
    subprocess.run([probe], check=True)
    assert path.exists(), 'live no-open-file native child was deleted after owner crash'
finally:
    os.killpg(pid, signal.SIGKILL)
time.sleep(.2)
subprocess.run([probe], check=True)
assert not path.exists(), 'stopped native child did not recover'
print('NATIVE_CRASH_LIVE_CHILD_AND_RECOVERY_PASS')
PYTEST
