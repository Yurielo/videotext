#!/usr/bin/env python3
"""Supervise disposable probes. Never scan legacy prefixes or retained outputs."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid


def namespace():
    return Path(tempfile.gettempdir()) / f"videotext-shell-owned-v1-{os.getuid()}"


def identity(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Unsafe owned TMP directory")
    return info.st_dev, info.st_ino


def alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def group_alive(group):
    if group is None:
        return False
    if not isinstance(group, int) or group <= 0:
        return True
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def foreign_open(path):
    scanner = shutil.which('lsof') or '/usr/sbin/lsof'
    try:
        result = subprocess.run([scanner, '-nP', '+D', str(path), '-Fp'], capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return True
    return (bool(result.stderr) or result.returncode not in (0, 1) or
            any(line.startswith(b'p') and line[1:] != str(os.getpid()).encode()
                for line in result.stdout.splitlines()))


def recover(base):
    base.mkdir(mode=0o700, exist_ok=True)
    identity(base)
    for path in base.iterdir():
        try:
            marker = json.loads((path / 'owner.json').read_text())
            if (marker.get('schema') != 1 or marker.get('id') != path.name or
                    marker.get('path') != str(path) or list(identity(path)) != marker.get('identity') or
                    alive(marker.get('pid')) or group_alive(marker.get('child_group'))):
                continue
            with os.fdopen(os.open(path / 'lease', os.O_RDONLY | os.O_NOFOLLOW), 'r') as lease:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if not foreign_open(path) and list(identity(path)) == marker['identity']:
                    shutil.rmtree(path)
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            continue


class Workspace:
    def __init__(self):
        self.base = namespace()
        recover(self.base)
        if len(list(self.base.iterdir())) >= 32:
            raise RuntimeError('Owned TMP capacity exhausted; unsafe objects retained')
        self.path = self.base / str(uuid.uuid4())
        self.path.mkdir(mode=0o700)
        self.token = list(identity(self.path))
        self.lease = open(self.path / 'lease', 'x')
        fcntl.flock(self.lease, fcntl.LOCK_EX)
        self.marker = {'schema': 1, 'id': self.path.name, 'path': str(self.path),
                       'identity': self.token, 'pid': os.getpid()}
        (self.path / 'owner.json').write_text(json.dumps(self.marker))

    def close(self):
        try:
            if (list(identity(self.path)) == self.token and
                    json.loads((self.path / 'owner.json').read_text()) == self.marker and
                    not foreign_open(self.path)):
                shutil.rmtree(self.path)
        finally:
            self.lease.close()


def supervise(command):
    workspace = Workspace()
    child = None
    old_handlers = {}
    caught = []
    def interrupted(signum, _frame):
        caught.append(signum)
        if child is not None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    try:
        env = os.environ.copy()
        env.update(TMPDIR=str(workspace.path), TMP=str(workspace.path), TEMP=str(workspace.path),
                   VIDEOTEXT_TMP_RUNNER='1', VIDEOTEXT_EPHEMERAL_WORK_ROOT=str(workspace.path / 'work'))
        if env.get('VIDEOTEXT_EVIDENCE_DIR'):
            evidence_parent = Path(env['VIDEOTEXT_EVIDENCE_DIR']).expanduser().resolve()
            evidence_parent.mkdir(parents=True, exist_ok=True)
            evidence = evidence_parent / ('videotext-evidence-' + str(uuid.uuid4()))
            evidence.mkdir(mode=0o700)
            (evidence / 'retention.json').write_text(json.dumps({
                'role': 'explicit-diagnostic-evidence', 'command': command,
                'automatic_cleanup': False}))
            env['VIDEOTEXT_EPHEMERAL_WORK_ROOT'] = str(evidence)
        for signum in (signal.SIGINT, signal.SIGTERM):
            old_handlers[signum] = signal.signal(signum, interrupted)
        child = subprocess.Popen(command, env=env, start_new_session=True,
                                 pass_fds=(workspace.lease.fileno(),))
        workspace.marker['child_group'] = child.pid
        marker = workspace.path / 'owner.json'
        pending = workspace.path / 'owner.pending'
        pending.write_text(json.dumps(workspace.marker))
        pending.replace(marker)
        while True:
            try:
                code = child.wait(timeout=0.1)
                break
            except subprocess.TimeoutExpired:
                if caught:
                    try:
                        child.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                    code = 128 + caught[-1]
                    break
        return 128 + caught[-1] if caught else code
    finally:
        if child is not None:
            # The process group is created by this invocation, never a name/prefix match.
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            # Wait for exact session descendants to close files before deletion.
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    os.killpg(child.pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(.02)
            else:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        workspace.close()


if __name__ == '__main__':
    sys.exit(supervise(sys.argv[1:]))
