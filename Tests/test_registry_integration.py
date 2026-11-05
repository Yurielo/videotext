"""Isolated VideoText registry-adapter tests; no product install or network remote."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


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
        central_patch = mock.patch.object(adapter, "central_module", side_effect=lambda root: self.load_fake())
        central_patch.start(); self.addCleanup(central_patch.stop)
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

    def test_build_refuses_stale_preparation_without_touching_target(self):
        prepared = self.root / "prepared"
        adapter.prepare(self.registry, self.material, prepared)
        manifest = prepared / "FOUR_PRODUCT_REGISTRY_DEPENDENCY.json"
        metadata = json.loads(manifest.read_text())
        metadata["activation_event"] = "sha256:" + "0" * 64
        manifest.write_text(json.dumps(metadata))
        app = self.root / "existing.app"; app.mkdir()
        marker = app / "must-survive"; marker.write_text("stable app")
        result = subprocess.run([str(ROOT / "scripts/build_app.sh")], cwd=ROOT, env={
            "VIDEOTEXT_APP_PATH": str(app), "VIDEOTEXT_SEMINARTEXT_PREPARED": str(prepared),
            "VIDEOTEXT_REGISTRY_ROOT": str(self.registry), "VIDEOTEXT_REGISTRY_PYTHON": os.sys.executable,
            "PATH": os.environ["PATH"]}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("Prepared SeminarText bundle is not the current registered activation", result.stderr)
        with self.assertRaisesRegex(adapter.Rejected, "metadata differs"):
            adapter.verify_bundle(prepared, adapter.resolve(self.registry))
        self.assertEqual(marker.read_text(), "stable app")

    def delivery_inputs(self):
        prepared = self.root / "prepared"
        dependency = adapter.prepare(self.registry, self.material, prepared)
        app = self.root / "installed.app"; app.mkdir()
        (app / "payload").write_text("installed")
        bundled = app / "Contents/Resources/SeminarText"
        shutil.copytree(prepared, bundled)
        digest = adapter.file_list_digest(app)
        evidence = self.root / "release.env"
        evidence.write_text("\n".join((
            "status=PASS", "promoted=true", "source_commit=" + "2" * 40,
            "candidate_sha256=" + digest, "final_sha256=" + digest,
            "seminartext_dependency_sha256=" + adapter.sha256((prepared / "FOUR_PRODUCT_REGISTRY_DEPENDENCY.json").read_bytes()),
            "seminartext_dependency_manifest=" + str(prepared / "FOUR_PRODUCT_REGISTRY_DEPENDENCY.json"),
            "post_install_smoke_status=PASS", "post_install_smoke_log=/fixture/post-install.log",
            "completed_at=20261027T010000Z", "candidate_version=0.6.9", "candidate_build=fixture", "\n")))
        return prepared, app, evidence, dependency

    def test_delivery_without_native_receipt_is_rejected(self):
        _, app, evidence, _ = self.delivery_inputs()
        with self.assertRaisesRegex(adapter.Rejected, "native post-owner delivery receipt is required"):
            adapter.delivery_receipt(self.root, self.registry, evidence,
                                     "https://owner.example/pass", app, self.root / "receipt.json")

    def test_native_delivery_binds_exact_accepted_candidate(self):
        _, app, evidence, _ = self.delivery_inputs()
        candidate = self.root / "candidate.app"
        shutil.copytree(app, candidate)
        digest = adapter.file_list_digest(app)
        evidence.write_text(evidence.read_text().replace("promoted=true", "promoted=false")
                            + f"candidate_path={candidate}\n")
        owner = self.root / "owner-pass.json"
        owner.write_text(json.dumps({"status": "PASS", "acceptedHead": "2" * 40,
                                     "candidatePath": str(candidate),
                                     "candidatePathIndependentContentSha256": digest}))
        smoke = self.root / "post-install.log"; smoke.write_text("PASS\n")
        native = self.root / "post-owner-delivery.json"
        record = {"kind": "videotext-native-post-owner-delivery", "status": "DELIVERED",
                  "prState": "MERGED", "mergeTreeEqualsAcceptedHead": True,
                  "acceptedHead": "2" * 40, "candidatePath": str(candidate),
                  "contentDigest": digest, "installedContentDigest": digest,
                  "installedPath": str(app), "postInstallLifecycle": "PASS",
                  "codesignStrictDeep": "PASS", "installedVersion": "0.6.9",
                  "installedBuild": "fixture", "mergeCommit": "3" * 40,
                  "ownerPassReceipt": str(owner),
                  "ownerPassReceiptSha256": adapter.sha256(owner.read_bytes()),
                  "postInstallLifecycleLog": str(smoke),
                  "postInstallLifecycleLogSha256": adapter.sha256(smoke.read_bytes()),
                  "recordedAt": "2026-10-27T01:00:00+00:00"}
        native.write_text(json.dumps(record))
        original_git = adapter.git
        def delivery_git(root, *arguments):
            if arguments and arguments[0] == "merge-base": return ""
            if arguments and arguments[0] == "rev-parse": return "a" * 40
            return original_git(root, *arguments)
        with mock.patch.object(adapter, "git", side_effect=delivery_git), \
             mock.patch.object(adapter, "video_remote_main", return_value="a" * 40):
            receipt = adapter.delivery_receipt(self.root, self.registry, evidence,
                                               "https://owner.example/pass", app,
                                               self.root / "native-receipt.json", native)
            self.assertEqual(receipt, adapter.delivery_receipt(
                self.root, self.registry, evidence, "https://owner.example/pass", app,
                self.root / "native-receipt.json", native))
        self.assertEqual(receipt["native_delivery_evidence"], str(native.resolve()))
        self.assertEqual(receipt["installed_app_sha256"], digest)
        self.assertTrue(all(item["location"].startswith(str(app.resolve()))
                            for item in receipt["bundled_dependency"]["artifacts"]))
        changed = dict(record); changed["contentDigest"] = "0" * 64
        native.write_text(json.dumps(changed))
        with mock.patch.object(adapter, "git", side_effect=delivery_git), \
             mock.patch.object(adapter, "video_remote_main", return_value="a" * 40), \
             self.assertRaisesRegex(adapter.Rejected, "differs from accepted candidate"):
            adapter.delivery_receipt(self.root, self.registry, evidence,
                                     "https://owner.example/pass", app,
                                     self.root / "rejected.json", native)

    def test_publish_rejects_receipt_without_native_delivery(self):
        _, app, evidence, _ = self.delivery_inputs()
        receipt = self.root / "forged-receipt.json"
        receipt.write_text(json.dumps({"product": "videotext", "status": "DELIVERED",
                                       "release_gate_evidence": str(evidence),
                                       "owner_pass_reference": "https://owner.example/pass",
                                       "installed_app": str(app)}))
        with self.assertRaisesRegex(adapter.Rejected, "native post-owner delivery receipt is required"):
            adapter.publish(self.registry, receipt, self.root / "outbox")

    def test_publication_binds_exact_dependency_and_is_retained(self):
        dependency=adapter.resolve(self.registry)
        bundled = dict(dependency["dependency"])
        bundled["artifacts"] = [{**item, "location": "/fixture/videotext.app/Contents/Resources/SeminarText/" + component["repository_path"]}
                                for item, component in zip(dependency["release"]["artifacts"], self.components)]
        bundled["manifest"] = "/fixture/videotext.app/Contents/Resources/SeminarText/FOUR_PRODUCT_REGISTRY_DEPENDENCY.json"
        receipt={"product":"videotext","status":"DELIVERED","delivered_at":"2026-10-27T01:00:00+00:00",
                 "source_commit":"2"*40,"release_gate_evidence":str(self.root / "release.env"),
                 "owner_pass_reference":"https://owner.example/pass",
                 "native_delivery_evidence":str(self.root / "native.json"),
                 "version":"0.6.9","build":"fixture",
                 "installed_app":"/fixture/videotext.app","installed_app_sha256":"a"*64,
                 "seminartext_dependency":dependency,"bundled_dependency":bundled}
        (self.root / "release.env").write_text("candidate_version=0.6.9\ncandidate_build=fixture\n")
        outbox=self.root / "outbox"; central, head, event=adapter.publication_event(self.registry,receipt,outbox)
        self.assertEqual(event["dependencies"],[bundled])
        self.assertTrue(all(item["location"].startswith("/fixture/videotext.app/Contents/Resources/SeminarText/")
                            for item in event["dependencies"][0]["artifacts"]))
        self.assertEqual(event["predecessor"],None)
        self.assertEqual(event["release"]["source_commit"],"2"*40)
        self.assertEqual(event["evidence"][0]["path"],"evidence/videotext-activation-"+hashlib.sha256((outbox / "publication-evidence.json").read_bytes()).hexdigest()+".json")
        (self.root / "receipt.json").write_text(json.dumps(receipt))
        with mock.patch.object(adapter, "delivery_receipt", return_value=receipt):
            self.assertEqual(adapter.publish(self.registry, self.root / "receipt.json", outbox)["status"], "PUBLISHED")
            self.assertEqual(adapter.publish(self.registry, self.root / "receipt.json", outbox)["status"], "PUBLISHED")
        (outbox / "publication-event.json").unlink()
        _, _, recovered = adapter.publication_event(self.registry, receipt, outbox)
        self.assertEqual(recovered, event)
        (outbox / "publication-evidence.json").unlink()
        _, _, recovered = adapter.publication_event(self.registry, receipt, outbox)
        self.assertEqual(recovered, event)
        _, _, retry = adapter.publication_event(self.registry,receipt,outbox)
        self.assertEqual(retry,event)


def read_current(registry):
    return json.loads((registry / "registry.json").read_text())["products"]["seminartext"]["current"]


if __name__ == "__main__":
    unittest.main()
