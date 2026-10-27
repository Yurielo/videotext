"""Isolated VideoText registry-adapter tests; no product install or network remote."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("registry_integration", ROOT / "scripts/registry_integration.py")
adapter = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(adapter)


FAKE_REGISTRY = '''import hashlib, json
SCHEMA = "schemas/registry.schema.json"
def decode(data): return json.loads(data)
def encode(value): return (json.dumps(value, sort_keys=True, indent=2)+"\\n").encode()
def _body(event, subject=False):
    excluded = {"event_id"} | ({"evidence"} if subject else set())
    return {k:v for k,v in event.items() if k not in excluded}
def event_id(event): return "sha256:"+hashlib.sha256(json.dumps(_body(event),sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
def subject_hash(event): return hashlib.sha256(json.dumps(_body(event,True),sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
def remote_head(root): return "a"*40
def at(root, head, path): return (root/path).read_bytes()
def validate(*args): return None
def publish(root,event,head): return {"status":"PUBLISHED", "head":"b"*40,"event_id":event["event_id"],"current":event["event_id"]}
'''


class RegistryIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="videotext-registry-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.registry = self.root / "central"; self.registry.mkdir()
        (self.registry / "schemas").mkdir(); (self.registry / "evidence").mkdir()
        (self.registry / "registry.py").write_text(FAKE_REGISTRY)
        (self.registry / "schemas/registry.schema.json").write_text("{}\n")
        self.git(self.registry, "init", "-b", "main")
        self.git(self.registry, "config", "user.name", "Fixture")
        self.git(self.registry, "config", "user.email", "fixture@example.invalid")
        self.git(self.registry, "remote", "add", "origin", "https://github.com/Yurielo/four-product-architecture.git")
        self.material = self.root / "material"; (self.material / "seminartext_modules").mkdir(parents=True)
        (self.material / "seminartext").write_text("#!/bin/sh\nexit 0\n"); (self.material / "seminartext").chmod(0o755)
        (self.material / "SEMINARTEXT_VERSION").write_text("4.0.0\n")
        self.components = [
            self.component("cli", "seminartext"), self.component("version", "SEMINARTEXT_VERSION")]
        self.write_state(registered=True)

    def git(self, root, *args):
        return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()

    def component(self, role, relative):
        return {"id": role, "repository_path": relative, "deployed_path": "/fixture/" + relative,
                "sha256": hashlib.sha256((self.material / relative).read_bytes()).hexdigest()}

    def write_state(self, registered):
        release = {"native_ref":"fixture://receipt", "version":"4.0.0", "build":None,
                   "source_commit":"1" * 40, "artifacts":[
                       {"role": item["id"], "location":item["deployed_path"], "source_commit":"1" * 40,
                        "digest":{"algorithm":"sha256-file","value":item["sha256"]}} for item in self.components]}
        event = {"product":"seminartext", "generation":1, "predecessor":None, "action":"activate", "rollback_of":None,
                 "target":"fixture", "activated_at":"2026-10-27T00:00:00+00:00", "recorded_at":"2026-10-27T00:00:01+00:00",
                 "release":release, "dependencies":[]}
        module = self.load_fake()
        proof = {"kind":"native_activation", "status":"SUCCEEDED", "subject_sha256":module.subject_hash(event),
                 "native_reference":"fixture://receipt", "native_evidence":{"installation":{"source_commit":"1" * 40,
                 "components":self.components}}}
        payload = module.encode(proof); path="evidence/seminartext-fixture.json"
        event["evidence"]=[{"path":path,"sha256":hashlib.sha256(payload).hexdigest()}]
        event["event_id"]=module.event_id(event)
        products={name:{"repository":"Yurielo/"+name,"current":None,"unregistered_reason":"fixture"}
                  for name in ("seminartext","videotext","booktext","integra")}
        if registered: products["seminartext"]={"repository":"Yurielo/seminartext","current":event["event_id"],"unregistered_reason":None}
        state={"schema_version":1,"products":products,"history":[event] if registered else []}
        (self.registry / path).write_bytes(payload)
        (self.registry / "registry.json").write_text(json.dumps(state))
        self.git(self.registry,"add",".")
        if not self.git(self.registry,"status","--porcelain") == "": self.git(self.registry,"commit","-m","fixture")

    def load_fake(self):
        spec=importlib.util.spec_from_file_location("fixture_registry",self.registry / "registry.py")
        module=importlib.util.module_from_spec(spec); assert spec.loader; spec.loader.exec_module(module); return module

    def test_resolves_registered_event_and_exact_inventory(self):
        resolved=adapter.resolve(self.registry)
        self.assertEqual(resolved["activation_event"], read_current(self.registry))
        self.assertEqual(resolved["release"]["source_commit"], "1" * 40)
        self.assertEqual([item["path"] for item in resolved["components"]], ["SEMINARTEXT_VERSION","seminartext"])

    def test_rejects_unregistered_provider_without_stale_fallback(self):
        self.write_state(registered=False)
        with self.assertRaisesRegex(adapter.Rejected,"no centrally registered activation"):
            adapter.resolve(self.registry)

    def test_prepares_only_exact_registered_material(self):
        output=self.root / "prepared"
        resolved=adapter.prepare(self.registry,self.material,output)
        adapter.verify_bundle(output,resolved)
        self.assertTrue((output / "FOUR_PRODUCT_REGISTRY_DEPENDENCY.json").is_file())
        self.assertEqual(adapter.prepare(self.registry,self.material,output), resolved)

    def test_rejects_mismatched_material_before_bundle_exists(self):
        (self.material / "seminartext").write_text("wrong")
        with self.assertRaisesRegex(adapter.Rejected,"differs from registered"):
            adapter.prepare(self.registry,self.material,self.root / "prepared")

    def test_build_refuses_missing_preparation_without_touching_target(self):
        app = self.root / "existing.app"; app.mkdir()
        marker = app / "must-survive"; marker.write_text("stable app")
        result = subprocess.run([str(ROOT / "scripts/build_app.sh")], cwd=ROOT,
                                env={"VIDEOTEXT_APP_PATH": str(app), "PATH": os.environ["PATH"]},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("Missing prepared registered SeminarText bundle", result.stderr)
        self.assertEqual(marker.read_text(), "stable app")

    def test_publication_binds_exact_dependency_and_is_retained(self):
        dependency=adapter.resolve(self.registry)
        receipt={"product":"videotext","status":"DELIVERED","delivered_at":"2026-10-27T01:00:00+00:00",
                 "source_commit":"2"*40,"release_gate_evidence":str(self.root / "release.env"),
                 "installed_app":"/fixture/videotext.app","installed_app_sha256":"a"*64,
                 "seminartext_dependency":dependency}
        (self.root / "release.env").write_text("candidate_version=0.6.9\ncandidate_build=fixture\n")
        outbox=self.root / "outbox"; central, head, event=adapter.publication_event(self.registry,receipt,outbox)
        self.assertEqual(event["dependencies"],[dependency["dependency"]])
        self.assertEqual(event["predecessor"],None)
        self.assertEqual(event["release"]["source_commit"],"2"*40)
        self.assertEqual(event["evidence"][0]["path"],"evidence/videotext-activation-"+hashlib.sha256((outbox / "publication-evidence.json").read_bytes()).hexdigest()+".json")
        self.assertEqual(central.publish(self.registry,event,head)["status"],"PUBLISHED")
        _, _, retry = adapter.publication_event(self.registry,receipt,outbox)
        self.assertEqual(retry,event)


def read_current(registry):
    return json.loads((registry / "registry.json").read_text())["products"]["seminartext"]["current"]


if __name__ == "__main__":
    unittest.main()
