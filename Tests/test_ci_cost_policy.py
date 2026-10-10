import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_classifier():
    path = ROOT / "scripts" / "ci_risk_classifier.py"
    spec = importlib.util.spec_from_file_location("ci_risk_classifier", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


classifier = load_classifier()
POLICY = classifier.load_policy()


def load_dispatcher():
    path = ROOT / "scripts" / "dispatch_paid_macos_gate.py"
    spec = importlib.util.spec_from_file_location("dispatch_paid_macos_gate", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


dispatcher = load_dispatcher()


def decision(*changes):
    return classifier.classify_changes(changes, POLICY)


class RiskClassifierTests(unittest.TestCase):
    def assertLevel(self, expected, *changes):
        result = decision(*changes)
        self.assertEqual(result["level"], expected, result)
        return result

    def test_ui_only_is_level_a(self):
        self.assertLevel(
            "LEVEL_A",
            classifier.Change("M", "Sources/videotext/UI/ContentView.swift", changed_text='Text("Ready")'),
        )

    def test_new_ui_file_is_level_a(self):
        self.assertLevel(
            "LEVEL_A",
            classifier.Change("A", "Sources/videotext/UI/NewSimpleView.swift"),
        )

    def test_core_business_logic_is_level_a(self):
        self.assertLevel(
            "LEVEL_A",
            classifier.Change("M", "Sources/videotext/Core/Models.swift", changed_text="let state: State"),
        )

    def test_bundled_dependency_content_is_level_a(self):
        self.assertLevel(
            "LEVEL_A",
            classifier.Change(
                "M",
                "Resources/SeminarText/seminartext_modules/evidence_foundation.py",
                changed_text="def validate(): pass",
            ),
        )

    def test_bundled_dependency_runtime_discovery_marker_is_level_b(self):
        self.assertLevel(
            "LEVEL_B",
            classifier.Change(
                "M",
                "Resources/SeminarText/seminartext_modules/tool_locator.py",
                changed_text='ffmpeg = "/opt/homebrew/bin/ffmpeg"',
            ),
        )

    def test_bundled_launcher_is_protected_level_b(self):
        self.assertLevel(
            "LEVEL_B",
            classifier.Change("M", "Resources/SeminarText/seminartext", changed_text="reorder candidates"),
        )

    def test_xcode_and_build_configuration_are_level_b(self):
        self.assertLevel("LEVEL_B", classifier.Change("M", "VideoText.xcodeproj/project.pbxproj"))
        self.assertLevel("LEVEL_B", classifier.Change("M", "scripts/build_app.sh"))

    def test_signing_notarization_is_level_b(self):
        self.assertLevel(
            "LEVEL_B",
            classifier.Change("M", "scripts/sign_release.sh", changed_text="codesign --sign - app"),
        )

    def test_packaging_is_level_b(self):
        self.assertLevel(
            "LEVEL_B",
            classifier.Change(
                "M", "scripts/package_release.sh", changed_text="mkdir -p App.app/Contents/MacOS"
            ),
        )

    def test_runtime_discovery_is_level_b(self):
        for path in POLICY["knownRuntimeDiscoveryPaths"]:
            with self.subTest(path=path):
                self.assertLevel("LEVEL_B", classifier.Change("M", path))
        self.assertLevel(
            "LEVEL_B",
            classifier.Change(
                "M",
                "Sources/videotext/Services/WorkflowEngine.swift",
                changed_text='let path = "/opt/homebrew/bin/ffmpeg"',
            ),
        )
        for changed_text in (
            'let path = ProcessInfo.processInfo.environment["PATH"]',
            'FileManager.default.isExecutableFile(atPath: candidate)',
            'ffmpeg = shutil.which("ffmpeg")',
            'FileManager.default.fileExists(atPath: "/usr/bin/ffmpeg")',
            'process.launchPath = "/bin/ffmpeg"',
            'let tool = "/usr/sbin/helper"',
        ):
            with self.subTest(changed_text=changed_text):
                self.assertLevel(
                    "LEVEL_B",
                    classifier.Change(
                        "M",
                        "Sources/videotext/Services/WorkflowEngine.swift",
                        changed_text=changed_text,
                    ),
                )

    def test_new_service_or_adapter_file_fails_closed(self):
        for path in (
            "Sources/videotext/Services/NewToolLocator.swift",
            "Sources/videotext/Adapters/NewProcessAdapter.swift",
        ):
            with self.subTest(path=path):
                self.assertLevel("LEVEL_B", classifier.Change("A", path, changed_text="let value = 1"))

    def test_existing_service_business_logic_remains_level_a(self):
        self.assertLevel(
            "LEVEL_A",
            classifier.Change(
                "M",
                "Sources/videotext/Services/WorkflowEngine.swift",
                changed_text="let result = operation.result",
            ),
        )

    def test_native_architecture_and_toolchain_are_level_b(self):
        self.assertLevel(
            "LEVEL_B", classifier.Change("M", "Resources/Runtime/libhelper.dylib", binary=True)
        )
        self.assertLevel(
            "LEVEL_B",
            classifier.Change(
                "M", "Sources/videotext/App/VideoTextApp.swift", changed_text='let architecture = "arm64"'
            ),
        )

    def test_unknown_path_fails_closed(self):
        result = self.assertLevel("LEVEL_B", classifier.Change("A", "automation/mystery"))
        self.assertTrue(result["decision"]["failClosed"])

    def test_mixed_diff_is_level_b(self):
        self.assertLevel(
            "LEVEL_B",
            classifier.Change("M", "Sources/videotext/UI/ContentView.swift"),
            classifier.Change("M", "Resources/Info.plist"),
        )

    def test_rename_and_delete_consider_all_paths(self):
        self.assertLevel(
            "LEVEL_B",
            classifier.Change(
                "R",
                "Sources/videotext/UI/NewName.swift",
                old_path="Sources/videotext/UI/OldName.swift",
            ),
        )
        self.assertLevel(
            "LEVEL_B",
            classifier.Change(
                "R", "Sources/videotext/UI/Build.swift", old_path="scripts/build_app.sh"
            ),
        )
        self.assertLevel("LEVEL_B", classifier.Change("D", "Resources/Info.plist"))

    def test_mode_change_fails_closed(self):
        self.assertLevel(
            "LEVEL_B",
            classifier.Change("M", "Sources/videotext/UI/ContentView.swift", mode_changed=True),
        )

    def test_policy_cannot_unprotect_its_bootstrap_files(self):
        weakened = dict(POLICY)
        weakened["levelBExactPaths"] = [
            path for path in POLICY["levelBExactPaths"] if path != ".ci/ci-risk-policy.json"
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "policy.json"
            path.write_text(json.dumps(weakened), encoding="utf-8")
            with self.assertRaisesRegex(classifier.ClassificationError, "cannot unprotect"):
                classifier.load_policy(path)

    def test_empty_diff_is_not_hosted_eligible(self):
        result = self.assertLevel("LEVEL_B")
        self.assertFalse(result["decision"]["hostedMacosEligible"])

    def test_output_is_deterministic(self):
        left = decision(
            classifier.Change("M", "Sources/videotext/UI/ContentView.swift"),
            classifier.Change("M", "Resources/Info.plist"),
        )
        right = decision(
            classifier.Change("M", "Resources/Info.plist"),
            classifier.Change("M", "Sources/videotext/UI/ContentView.swift"),
        )
        self.assertEqual(left, right)

    def test_malformed_sha_is_rejected_by_cli(self):
        result = subprocess.run(
            ["python3", "scripts/ci_risk_classifier.py", "--base", "main", "--head", "HEAD"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("full lowercase 40-character SHA", result.stderr)


class GitClassifierIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.temporary.name)
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.name", "CI Policy Test"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.email", "ci-policy@example.invalid"], cwd=self.repo, check=True)
        source = self.repo / "Sources" / "videotext" / "UI" / "ContentView.swift"
        source.parent.mkdir(parents=True)
        source.write_text("let title = \"before\"\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "base"], cwd=self.repo, check=True)
        self.default_branch = subprocess.check_output(
            ["git", "branch", "--show-current"], cwd=self.repo, text=True
        ).strip()
        self.base = self.sha()

    def tearDown(self):
        self.temporary.cleanup()

    def sha(self):
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo, text=True).strip()

    def commit(self, message):
        subprocess.run(["git", "add", "-A"], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", message], cwd=self.repo, check=True)
        return self.sha()

    def test_real_git_diff_collects_level_a_change(self):
        source = self.repo / "Sources" / "videotext" / "UI" / "ContentView.swift"
        source.write_text("let title = \"after\"\n", encoding="utf-8")
        head = self.commit("ui")
        result = classifier.classify_repository(self.repo, self.base, head, classifier.POLICY_PATH)
        self.assertEqual(result["level"], "LEVEL_A")
        self.assertEqual(result["changes"][0]["status"], "M")

    def test_real_git_mode_change_fails_closed(self):
        source = self.repo / "Sources" / "videotext" / "UI" / "ContentView.swift"
        source.chmod(0o755)
        head = self.commit("mode")
        result = classifier.classify_repository(self.repo, self.base, head, classifier.POLICY_PATH)
        self.assertEqual(result["level"], "LEVEL_B")
        self.assertTrue(result["changes"][0]["modeChanged"])

    def test_added_symlink_fails_closed(self):
        link = self.repo / "Sources" / "videotext" / "UI" / "Injected.swift"
        link.symlink_to("/tmp/outside-snapshot.swift")
        head = self.commit("symlink")
        result = classifier.classify_repository(self.repo, self.base, head, classifier.POLICY_PATH)
        self.assertEqual(result["level"], "LEVEL_B")
        self.assertTrue(result["changes"][0]["modeChanged"])

    def test_modified_symlink_fails_closed(self):
        link = self.repo / "Sources" / "videotext" / "UI" / "Injected.swift"
        link.symlink_to("first-target.swift")
        subprocess.run(["git", "add", "-A"], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "tracked symlink"], cwd=self.repo, check=True)
        symlink_base = self.sha()
        link.unlink()
        link.symlink_to("second-target.swift")
        head = self.commit("retarget symlink")
        result = classifier.classify_repository(
            self.repo, symlink_base, head, classifier.POLICY_PATH
        )
        self.assertEqual(result["level"], "LEVEL_B")
        self.assertTrue(result["changes"][0]["modeChanged"])

    def test_fat64_native_binary_fails_closed(self):
        binary = self.repo / "Resources" / "SeminarText" / "native-helper"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"\xca\xfe\xba\xbf" + b"native")
        head = self.commit("fat64")
        result = classifier.classify_repository(self.repo, self.base, head, classifier.POLICY_PATH)
        self.assertEqual(result["level"], "LEVEL_B")
        self.assertTrue(result["changes"][0]["binary"])

    def test_non_ancestor_base_is_rejected(self):
        subprocess.run(["git", "checkout", "-qb", "side"], cwd=self.repo, check=True)
        side_file = self.repo / "side.txt"
        side_file.write_text("side\n", encoding="utf-8")
        side = self.commit("side")
        subprocess.run(["git", "checkout", "-q", self.default_branch], cwd=self.repo, check=True)
        main_file = self.repo / "main.txt"
        main_file.write_text("main\n", encoding="utf-8")
        main = self.commit("main")
        with self.assertRaises(classifier.ClassificationError):
            classifier.classify_repository(self.repo, side, main, classifier.POLICY_PATH)


class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (
            ROOT / ".github" / "workflows" / "topic-regression.yml"
        ).read_text(encoding="utf-8")
        cls.dispatcher = (
            ROOT / "scripts" / "dispatch_paid_macos_gate.py"
        ).read_text(encoding="utf-8")

    def test_paid_workflow_has_only_manual_trigger(self):
        trigger_section = self.workflow.split("permissions:", 1)[0]
        self.assertIn("workflow_dispatch:", trigger_section)
        for forbidden in ("push:", "pull_request:", "schedule:", "workflow_call:"):
            self.assertNotIn(forbidden, trigger_section)

    def test_workflow_has_exact_sha_level_b_and_cost_guards(self):
        for expected in (
            "expected_sha:",
            "base_sha:",
            "classification_sha256:",
            "local_gate_evidence:",
            "timeout-minutes: 20",
            "cancel-in-progress: false",
            "videotext-paid-macos-${{ inputs.expected_sha }}",
            "github.run_attempt == 1",
            "github.sha == inputs.expected_sha",
            "canonical merge-base",
            "grep -Eq 'Mach-O.*(arm64|x86_64|universal)'",
            "hostedMacosEligible",
            '"LEVEL_B"',
            "checks: read",
            "validate_local_gate_evidence",
        ):
            self.assertIn(expected, self.workflow)

    def test_no_automatic_rerun_or_budget_mutation(self):
        combined = f"{self.workflow}\n{self.dispatcher}".lower()
        self.assertNotIn("gh run rerun", combined)
        self.assertNotIn("spending_limit", combined)
        self.assertNotIn("billing_limit", combined)
        self.assertIn(
            "billing/spending or product/test failures are a hard stop", self.dispatcher
        )

    def test_retry_contract_is_single_same_sha_infrastructure_only(self):
        for expected in (
            "len(matching_runs) != 1",
            "ALLOWED_INFRA_FAILURES",
            "priorRunId",
            "expectedSha",
            "infrastructure_retry",
            "--paginate",
            "--slurp",
            'run(["git", "status", "--porcelain"])',
        ):
            self.assertIn(expected, self.dispatcher)

    def test_no_automatic_linux_job(self):
        self.assertNotIn("ubuntu-", self.workflow)


class RetryEvidenceTests(unittest.TestCase):
    SHA = "a" * 40
    PRIOR_RUNS = [{"id": 123, "conclusion": "failure", "head_sha": SHA}]

    def write_evidence(self, directory, *, failure_class="runner-capacity", reason="No runner allocated"):
        path = pathlib.Path(directory) / "retry.json"
        path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "expectedSha": self.SHA,
                    "priorRunId": 123,
                    "failureClass": failure_class,
                    "reason": reason,
                    "recordedBy": "ci-cd-engineer",
                    "recordedAt": "2026-10-11T12:00:00Z",
                }
            ),
            encoding="utf-8",
        )
        return path

    def test_allowlisted_same_sha_infrastructure_retry_is_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = dispatcher.load_retry_evidence(
                self.write_evidence(directory), self.SHA, self.PRIOR_RUNS, "runner-capacity"
            )
        self.assertEqual(evidence["priorRunId"], 123)

    def test_billing_retry_is_hard_stopped(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_evidence(
                directory,
                failure_class="runner-capacity",
                reason="Runner blocked by billing spending limit",
            )
            with self.assertRaises(dispatcher.DispatchError):
                dispatcher.load_retry_evidence(
                    path, self.SHA, self.PRIOR_RUNS, "runner-capacity"
                )

    def test_product_failure_cannot_be_reclassified_as_infrastructure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_evidence(
                directory,
                failure_class="runner-capacity",
                reason="Product test assertion failed",
            )
            with self.assertRaises(dispatcher.DispatchError):
                dispatcher.load_retry_evidence(
                    path, self.SHA, self.PRIOR_RUNS, "runner-capacity"
                )

    def test_machine_capacity_annotation_authorizes_retry_class(self):
        responses = [
            {"head_sha": self.SHA, "event": "workflow_dispatch", "conclusion": "failure"},
            {"jobs": [{"steps": [], "check_run_url": "https://api.github.com/repos/Yurielo/videotext/check-runs/456"}]},
            [{"annotation_level": "failure", "message": "No hosted runner is available due to capacity constraints"}],
        ]
        with mock.patch.object(dispatcher, "github_json", side_effect=responses):
            self.assertEqual(dispatcher.classify_prior_failure(123, self.SHA), "runner-capacity")

    def test_machine_billing_annotation_is_hard_stop(self):
        responses = [
            {"head_sha": self.SHA, "event": "workflow_dispatch", "conclusion": "failure"},
            {"jobs": [{"steps": [], "check_run_url": "https://api.github.com/repos/Yurielo/videotext/check-runs/456"}]},
            [{"annotation_level": "failure", "message": "The job was not started because recent account payments have failed"}],
        ]
        with mock.patch.object(dispatcher, "github_json", side_effect=responses):
            with self.assertRaisesRegex(dispatcher.DispatchError, "BILLING_HARD_STOP"):
                dispatcher.classify_prior_failure(123, self.SHA)

    def test_prior_run_that_reached_product_steps_is_not_retryable(self):
        responses = [
            {"head_sha": self.SHA, "event": "workflow_dispatch", "conclusion": "failure"},
            {"jobs": [{"steps": [{"name": "Build", "conclusion": "failure"}]}]},
        ]
        with mock.patch.object(dispatcher, "github_json", side_effect=responses):
            with self.assertRaisesRegex(dispatcher.DispatchError, "reached workflow steps"):
                dispatcher.classify_prior_failure(123, self.SHA)


class LocalGateEvidenceTests(unittest.TestCase):
    SHA = "a" * 40

    def evidence(self):
        return {
            "schemaVersion": 1,
            "expectedSha": self.SHA,
            "classification": "LEVEL_B",
            "status": "PASS",
            "completedGates": sorted(dispatcher.LOCAL_GATE_NAMES),
            "notApplicableGates": {},
            "evidenceSha256": "b" * 64,
            "recordedBy": "ci-cd-engineer",
            "recordedAt": "2026-10-11T12:00:00Z",
        }

    def test_all_local_gates_are_required_before_dispatch(self):
        evidence = self.evidence()
        self.assertEqual(
            dispatcher.validate_local_gate_evidence(evidence, self.SHA), evidence
        )

    def test_not_applicable_gate_requires_a_reason(self):
        evidence = self.evidence()
        evidence["completedGates"].remove("core-e2e")
        evidence["notApplicableGates"] = {"core-e2e": ""}
        with self.assertRaisesRegex(dispatcher.DispatchError, "non-empty reasons"):
            dispatcher.validate_local_gate_evidence(evidence, self.SHA)

    def test_missing_local_gate_blocks_dispatch(self):
        evidence = self.evidence()
        evidence["completedGates"].remove("owner-test")
        with self.assertRaisesRegex(dispatcher.DispatchError, "every governed local gate"):
            dispatcher.validate_local_gate_evidence(evidence, self.SHA)

    def test_mandatory_local_gate_cannot_be_not_applicable(self):
        evidence = self.evidence()
        evidence["completedGates"].remove("independent-qa-review")
        evidence["notApplicableGates"] = {
            "independent-qa-review": "attempted to waive review"
        }
        with self.assertRaisesRegex(dispatcher.DispatchError, "mandatory local gates"):
            dispatcher.validate_local_gate_evidence(evidence, self.SHA)

    def test_local_evidence_bundle_digest_is_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            bundle = directory / "release-evidence.json"
            bundle.write_text('{"status":"PASS"}\n', encoding="utf-8")
            evidence = self.evidence()
            evidence["evidenceSha256"] = dispatcher.sha256_evidence_bundle(bundle)
            summary = directory / "local-gates.json"
            summary.write_text(json.dumps(evidence), encoding="utf-8")
            self.assertEqual(
                dispatcher.load_local_gate_evidence(summary, self.SHA, bundle), evidence
            )
            bundle.write_text('{"status":"CHANGED"}\n', encoding="utf-8")
            with self.assertRaisesRegex(dispatcher.DispatchError, "digest does not match"):
                dispatcher.load_local_gate_evidence(summary, self.SHA, bundle)

    def test_local_gate_evidence_is_bound_to_exact_sha(self):
        with self.assertRaisesRegex(dispatcher.DispatchError, "SHA does not match"):
            dispatcher.validate_local_gate_evidence(self.evidence(), "c" * 40)


if __name__ == "__main__":
    unittest.main()
