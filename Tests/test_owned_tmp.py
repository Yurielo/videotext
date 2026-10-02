import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
import sys
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('owned_tmp', Path(__file__).resolve().parents[1] / 'scripts/owned_tmp.py')
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)


class OwnedTMPTests(unittest.TestCase):
    def setUp(self):
        self.parent = tempfile.TemporaryDirectory()
        self.original = owned.namespace
        owned.namespace = lambda: Path(self.parent.name) / 'owned'

    def tearDown(self):
        owned.namespace = self.original
        self.parent.cleanup()

    def test_repeated_success_failure(self):
        for _ in range(12):
            self.assertEqual(0, owned.supervise(['/bin/sh', '-c', 'echo fixture > "$TMPDIR/data"']))
            self.assertEqual(7, owned.supervise(['/bin/sh', '-c', 'echo fixture > "$TMPDIR/data"; exit 7']))
        self.assertEqual([], list(owned.namespace().iterdir()))

    def test_unknown_live_and_tamper_preserved(self):
        workspace = owned.Workspace()
        unknown = owned.namespace() / 'unknown'
        unknown.mkdir()
        owned.recover(owned.namespace())
        self.assertTrue(workspace.path.exists())
        self.assertTrue(unknown.exists())
        marker = workspace.path / 'owner.json'
        marker.write_text('{}')
        workspace.close()
        self.assertTrue(workspace.path.exists())

    def test_stale_and_foreign_open(self):
        workspace = owned.Workspace()
        workspace.lease.close()
        workspace.marker['pid'] = 2147483647
        (workspace.path / 'owner.json').write_text(json.dumps(workspace.marker))
        payload = workspace.path / 'payload'
        payload.write_text('fixture')
        child = subprocess.Popen(['/bin/sh', '-c', 'exec 3<"$1"; sleep 5', 'fixture', str(payload)])
        try:
            time.sleep(.1)
            owned.recover(owned.namespace())
            self.assertTrue(workspace.path.exists())
        finally:
            child.terminate()
            child.wait()
        # Child sleep inherits descriptor; wait for its deterministic exit.
        for _ in range(60):
            owned.recover(owned.namespace())
            if not workspace.path.exists():
                break
            time.sleep(.1)
        self.assertFalse(workspace.path.exists())

    def test_sigterm_supervisor_cleanup(self):
        env = os.environ.copy()
        env['TMPDIR'] = self.parent.name
        runner = Path(owned.__file__)
        child = subprocess.Popen([os.sys.executable, str(runner), '/bin/sleep', '10'], env=env)
        base = Path(self.parent.name) / f'videotext-shell-owned-v1-{os.getuid()}'
        for _ in range(100):
            if base.exists() and list(base.iterdir()):
                break
            time.sleep(.02)
        child.send_signal(signal.SIGTERM)
        self.assertEqual(143, child.wait(timeout=5))
        self.assertEqual([], list(base.iterdir()))


if __name__ == '__main__':
    unittest.main()
