#!/usr/bin/env python3
"""Create a disposable, isolated central-registry fixture for CI packaging checks.

This never contacts or publishes to the real Four-Product Architecture registry.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys


FAKE_REGISTRY = '''import hashlib, json
SCHEMA = "schemas/registry.schema.json"
def decode(data): return json.loads(data)
def encode(value): return (json.dumps(value, sort_keys=True, indent=2)+"\\n").encode()
def _body(event, subject=False):
    return {k:v for k,v in event.items() if k not in ({"event_id"} | ({"evidence"} if subject else set()))}
def event_id(event): return "sha256:"+hashlib.sha256(json.dumps(_body(event),sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
def subject_hash(event): return hashlib.sha256(json.dumps(_body(event,True),sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
def remote_head(root): return "a"*40
def at(root, head, path): return (root/path).read_bytes()
def validate(*args): return None
def publish(root,event,head): raise RuntimeError("fixture never publishes")
'''


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    spec = importlib.util.spec_from_file_location("fixture_registry", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--material-root", type=Path, required=True)
    parser.add_argument("--prepared-output", type=Path, required=True)
    parser.add_argument("--github-env", type=Path, required=True)
    args = parser.parse_args()
    root, material = args.root.resolve(), args.material_root.resolve()
    if root.exists():
        raise SystemExit("fixture root already exists")
    if not material.is_dir() or material.is_symlink() or not (material / "seminartext").is_file():
        raise SystemExit("fixture material is incomplete")
    (root / "schemas").mkdir(parents=True); (root / "evidence").mkdir()
    (root / "registry.py").write_text(FAKE_REGISTRY); (root / "schemas/registry.schema.json").write_text("{}\n")
    components = []
    for path in sorted((item for item in material.rglob("*") if item.is_file() and not item.is_symlink()), key=str):
        relative = str(path.relative_to(material))
        components.append({"id": "component-" + hashlib.sha256(relative.encode()).hexdigest()[:16],
                           "repository_path": relative, "deployed_path": "/fixture/" + relative, "sha256": digest(path)})
    release = {"native_ref": "fixture://receipt", "version": "fixture", "build": "fixture", "source_commit": "1" * 40,
               "artifacts": [{"role": item["id"], "location": item["deployed_path"], "source_commit": "1" * 40,
                              "digest": {"algorithm": "sha256-file", "value": item["sha256"]}} for item in components]}
    event = {"product": "seminartext", "generation": 1, "predecessor": None, "action": "activate", "rollback_of": None,
             "target": "isolated-fixture", "activated_at": "2026-01-01T00:00:00+00:00", "recorded_at": "2026-01-01T00:00:00+00:00",
             "release": release, "dependencies": []}
    registry = load(root / "registry.py")
    proof = {"kind": "native_activation", "status": "SUCCEEDED", "subject_sha256": registry.subject_hash(event),
             "native_reference": "fixture://receipt", "native_evidence": {"installation": {"source_commit": "1" * 40, "components": components}}}
    payload = registry.encode(proof); proof_path = "evidence/seminartext-fixture.json"
    event["evidence"] = [{"path": proof_path, "sha256": digest_bytes(payload)}]; event["event_id"] = registry.event_id(event)
    products = {name: {"repository": "Yurielo/" + name, "current": None, "unregistered_reason": "fixture"}
                for name in ("seminartext", "videotext", "booktext", "integra")}
    products["seminartext"] = {"repository": "Yurielo/seminartext", "current": event["event_id"], "unregistered_reason": None}
    (root / proof_path).write_bytes(payload)
    (root / "registry.json").write_text(json.dumps({"schema_version": 1, "products": products, "history": [event]}))
    run("git", "init", "-b", "main", str(root)); run("git", "-C", str(root), "config", "user.name", "Fixture")
    run("git", "-C", str(root), "config", "user.email", "fixture@example.invalid"); run("git", "-C", str(root), "add", ".")
    run("git", "-C", str(root), "commit", "-m", "isolated fixture"); run("git", "-C", str(root), "remote", "add", "origin", "https://github.com/Yurielo/four-product-architecture.git")
    adapter = Path(__file__).with_name("registry_integration.py")
    run(sys.executable, str(adapter), "prepare", "--registry-root", str(root), "--material-root", str(material), "--output", str(args.prepared_output.resolve()))
    with args.github_env.open("a", encoding="utf-8") as env:
        env.write(f"VIDEOTEXT_REGISTRY_ROOT={root}\nVIDEOTEXT_REGISTRY_PYTHON={sys.executable}\nVIDEOTEXT_SEMINARTEXT_PREPARED={args.prepared_output.resolve()}\n")


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


if __name__ == "__main__":
    main()
