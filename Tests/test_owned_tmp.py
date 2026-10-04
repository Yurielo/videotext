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

    def test_launch_failure_cleanup(self):
        with self.assertRaises(FileNotFoundError):
            owned.supervise(['/does-not-exist'])
        self.assertEqual([], list(owned.namespace().iterdir()))

    def test_namespace_symlink_rejected(self):
        external = Path(self.parent.name) / 'external'
        external.mkdir(mode=0o700)
        payload = external / 'user-data'
        payload.write_text('preserve')
        owned.namespace().symlink_to(external, target_is_directory=True)
        with self.assertRaises(ValueError):
            owned.Workspace()
        self.assertEqual('preserve', payload.read_text())

    def test_pending_launch_is_never_recovered(self):
        workspace = owned.Workspace()
        workspace.marker['pid'] = 2147483647
        workspace.marker['launch_pending'] = True
        (workspace.path / 'owner.json').write_text(json.dumps(workspace.marker))
        workspace.close()
        owned.recover(owned.namespace())
        self.assertTrue(workspace.path.exists())

    def test_normal_background_drains(self):
        self.assertEqual(0, owned.supervise(['/bin/sh', '-c', 'sleep 20 >/dev/null 2>&1 &']))
        self.assertEqual([], list(owned.namespace().iterdir()))

    def test_sigkill_parent_preserves_live_no_open_file_child(self):
        env = os.environ.copy()
        env['TMPDIR'] = self.parent.name
        runner = subprocess.Popen([os.sys.executable, owned.__file__, '/bin/sleep', '20'], env=env)
        base = Path(self.parent.name).resolve() / f'videotext-shell-owned-v1-{os.getuid()}'
        path = None
        for _ in range(100):
            if base.exists():
                for candidate in base.iterdir():
                    try:
                        record = json.loads((candidate / 'owner.json').read_text())
                        if record.get('child_group'):
                            path = candidate
                    except (OSError, ValueError):
                        pass
            if path is not None:
                break
            time.sleep(.02)
        self.assertIsNotNone(path)
        group = record['child_group']
        try:
            runner.kill()
            runner.wait()
            owned.recover(base)
            self.assertTrue(path.exists(), 'live child without open scratch was deleted')
        finally:
            os.killpg(group, signal.SIGKILL)
        for _ in range(100):
            owned.recover(base)
            if not path.exists():
                break
            time.sleep(.05)
        self.assertFalse(path.exists())

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

    def test_non_object_unknown_receipts_retain_without_poisoning_startup(self):
        base = owned.namespace()
        base.mkdir(mode=0o700)
        for index, value in enumerate([[], None, 7, 'unknown']):
            path = base / f'unknown-{index}'
            path.mkdir(mode=0o700)
            (path / 'owner.json').write_text(json.dumps(value))
        owned.recover(base)
        self.assertEqual(4, len(list(base.iterdir())))
        self.assertEqual(0, owned.supervise([sys.executable, '-c', 'pass']))
        self.assertEqual(4, len(list(base.iterdir())))

    def test_non_object_nested_receipts_are_busy(self):
        root = Path(self.parent.name) / 'scratch'
        child = root / f'videotext-owned-v1-{os.getuid()}' / 'unknown'
        child.mkdir(parents=True, mode=0o700)
        for value in [[], None, 7, 'unknown']:
            (child / 'owner.json').write_text(json.dumps(value))
            self.assertTrue(owned.nested_native_live(root))

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
        base = Path(self.parent.name).resolve() / f'videotext-shell-owned-v1-{os.getuid()}'
        ready = False
        for _ in range(100):
            if base.exists():
                for path in base.iterdir():
                    try:
                        record = json.loads((path / 'owner.json').read_text())
                    except (OSError, ValueError):
                        continue
                    if record.get('launch_pending') is False and record.get('child_group'):
                        ready = True
                        break
            if ready:
                break
            time.sleep(.02)
        self.assertTrue(ready, 'supervisor did not finish registering its child')
        child.send_signal(signal.SIGTERM)
        self.assertEqual(143, child.wait(timeout=5))
        self.assertEqual([], list(base.iterdir()))


if __name__ == '__main__':
    unittest.main()
