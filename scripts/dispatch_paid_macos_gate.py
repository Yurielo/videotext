#!/usr/bin/env python3
"""Dispatch the paid macOS gate only for an eligible exact LEVEL_B SHA."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = "topic-regression.yml"
REPOSITORY = "Yurielo/videotext"
ALLOWED_INFRA_FAILURES = {
    "github-outage",
    "runner-capacity",
    "runner-startup",
    "timed-out-before-steps",
}
PROHIBITED_RETRY_WORDS = {"billing", "budget", "spending", "product", "test", "assertion"}
LOCAL_GATE_NAMES = {
    "focused-tests",
    "regression",
    "real-scenarios",
    "independent-qa-review",
    "independent-code-review",
    "core-e2e",
    "candidate-identity",
    "codesign-lifecycle",
    "owner-test",
}
MANDATORY_LOCAL_GATES = {
    "focused-tests",
    "regression",
    "independent-qa-review",
    "independent-code-review",
}


class DispatchError(RuntimeError):
    pass


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, cwd=ROOT, check=False, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise DispatchError(result.stderr.strip() or result.stdout.strip() or "command failed")
    return result


def full_sha(value: str, label: str) -> str:
    if len(value) != 40 or any(character not in "0123456789abcdef" for character in value):
        raise DispatchError(f"{label} must be a full lowercase 40-character SHA")
    resolved = run(["git", "rev-parse", "--verify", f"{value}^{{commit}}"] ).stdout.strip()
    if resolved != value:
        raise DispatchError(f"{label} does not resolve exactly")
    return resolved


def workflow_runs(expected_sha: str) -> list[dict]:
    result = run(
        [
            "gh",
            "api",
            "--method",
            "GET",
            f"repos/{REPOSITORY}/actions/workflows/{WORKFLOW}/runs",
            "-f",
            "event=workflow_dispatch",
            "-f",
            f"head_sha={expected_sha}",
            "-f",
            "per_page=100",
            "--paginate",
            "--slurp",
        ]
    )
    pages = json.loads(result.stdout)
    return [item for page in pages for item in page["workflow_runs"] if item["head_sha"] == expected_sha]


def github_json(path: str) -> dict | list:
    return json.loads(run(["gh", "api", "--method", "GET", path]).stdout)


def classify_prior_failure(run_id: int, expected_sha: str) -> str:
    prior = github_json(f"repos/{REPOSITORY}/actions/runs/{run_id}")
    if prior["head_sha"] != expected_sha or prior["event"] != "workflow_dispatch":
        raise DispatchError("prior run is not a workflow_dispatch for expected_sha")
    if prior["conclusion"] not in {"action_required", "cancelled", "failure", "stale", "timed_out"}:
        raise DispatchError("prior run conclusion is not retryable")

    jobs = github_json(f"repos/{REPOSITORY}/actions/runs/{run_id}/jobs")["jobs"]
    if not jobs:
        raise DispatchError("prior run has no machine-verifiable job failure evidence")
    if any(job.get("steps") for job in jobs):
        raise DispatchError("prior run reached workflow steps and is not infrastructure-retry eligible")

    messages: list[str] = []
    for job in jobs:
        check_run_url = job.get("check_run_url", "")
        match = re.search(r"/repos/[^/]+/[^/]+/check-runs/(\d+)$", check_run_url)
        if not match:
            raise DispatchError("prior job lacks check-run evidence")
        annotations = github_json(
            f"repos/{REPOSITORY}/check-runs/{match.group(1)}/annotations"
        )
        messages.extend(str(annotation.get("message", "")) for annotation in annotations)

    combined = "\n".join(messages).lower()
    if any(word in combined for word in ("billing", "payment", "spending limit", "budget")):
        raise DispatchError("BILLING_HARD_STOP: prior run was blocked by billing/spending")
    patterns = {
        "github-outage": r"github actions.*(outage|incident|unavailable)",
        "runner-capacity": r"(capacity constraint|no hosted runner|failed to acquire.*runner|runner.*unavailable)",
        "runner-startup": r"(runner|machine).*(failed to start|startup|provision|lost connection)",
    }
    for failure_class, pattern in patterns.items():
        if re.search(pattern, combined):
            return failure_class
    if prior["conclusion"] == "timed_out":
        return "timed-out-before-steps"
    raise DispatchError("prior failure is not machine-verifiable infrastructure evidence")


def validate_retry_evidence(
    evidence: dict,
    expected_sha: str,
    prior_runs: list[dict],
    verified_failure_class: str,
) -> dict:
    required = {
        "schemaVersion",
        "expectedSha",
        "priorRunId",
        "failureClass",
        "reason",
        "recordedBy",
        "recordedAt",
    }
    if set(evidence) != required or evidence["schemaVersion"] != 1:
        raise DispatchError("retry evidence has an unexpected schema")
    if evidence["expectedSha"] != expected_sha:
        raise DispatchError("retry evidence SHA does not match expected SHA")
    if evidence["failureClass"] not in ALLOWED_INFRA_FAILURES:
        raise DispatchError("retry is not an allowed infrastructure failure class")
    if evidence["failureClass"] != verified_failure_class:
        raise DispatchError("retry failure class does not match GitHub machine evidence")
    combined = f"{evidence['failureClass']} {evidence['reason']}".lower()
    if any(word in combined for word in PROHIBITED_RETRY_WORDS):
        raise DispatchError("billing/spending or product/test failures are a hard stop")
    matching = [run_info for run_info in prior_runs if run_info["id"] == evidence["priorRunId"]]
    if len(matching) != 1:
        raise DispatchError("prior run was not found for the exact SHA")
    if not all(str(evidence[field]).strip() for field in ("reason", "recordedBy", "recordedAt")):
        raise DispatchError("retry evidence must record reason, actor, and timestamp")
    if evidence["recordedBy"] != "ci-cd-engineer":
        raise DispatchError("retry evidence must be recorded by ci-cd-engineer")
    try:
        recorded_at = dt.datetime.fromisoformat(evidence["recordedAt"].replace("Z", "+00:00"))
    except ValueError as error:
        raise DispatchError("retry evidence timestamp is invalid") from error
    if recorded_at.tzinfo is None:
        raise DispatchError("retry evidence timestamp must include a timezone")
    return evidence


def validate_local_gate_evidence(evidence: dict, expected_sha: str) -> dict:
    required = {
        "schemaVersion",
        "expectedSha",
        "classification",
        "status",
        "completedGates",
        "notApplicableGates",
        "evidenceSha256",
        "recordedBy",
        "recordedAt",
    }
    if set(evidence) != required or evidence["schemaVersion"] != 1:
        raise DispatchError("local gate evidence has an unexpected schema")
    if evidence["expectedSha"] != expected_sha:
        raise DispatchError("local gate evidence SHA does not match expected SHA")
    if evidence["classification"] != "LEVEL_B" or evidence["status"] != "PASS":
        raise DispatchError("local gate evidence must record a passing LEVEL_B verdict")
    completed = evidence["completedGates"]
    not_applicable = evidence["notApplicableGates"]
    if not isinstance(completed, list) or not all(isinstance(item, str) for item in completed):
        raise DispatchError("completedGates must be a string array")
    if len(completed) != len(set(completed)):
        raise DispatchError("completedGates contains duplicates")
    if not isinstance(not_applicable, dict) or not all(
        isinstance(gate, str) and isinstance(reason, str) and reason.strip()
        for gate, reason in not_applicable.items()
    ):
        raise DispatchError("notApplicableGates must map gate names to non-empty reasons")
    completed_set = set(completed)
    not_applicable_set = set(not_applicable)
    if completed_set & not_applicable_set:
        raise DispatchError("a local gate cannot be both completed and not applicable")
    if completed_set | not_applicable_set != LOCAL_GATE_NAMES:
        raise DispatchError("local gate evidence must account for every governed local gate")
    missing_mandatory = MANDATORY_LOCAL_GATES - completed_set
    if missing_mandatory:
        raise DispatchError(
            "mandatory local gates cannot be not applicable: "
            + ", ".join(sorted(missing_mandatory))
        )
    if not re.fullmatch(r"[0-9a-f]{64}", str(evidence["evidenceSha256"])):
        raise DispatchError("local gate evidence digest must be a lowercase SHA-256")
    if evidence["recordedBy"] != "ci-cd-engineer":
        raise DispatchError("local gate evidence must be recorded by ci-cd-engineer")
    try:
        recorded_at = dt.datetime.fromisoformat(str(evidence["recordedAt"]).replace("Z", "+00:00"))
    except ValueError as error:
        raise DispatchError("local gate evidence timestamp is invalid") from error
    if recorded_at.tzinfo is None:
        raise DispatchError("local gate evidence timestamp must include a timezone")
    return evidence


def sha256_evidence_bundle(path: pathlib.Path) -> str:
    if not path.is_file():
        raise DispatchError("local evidence bundle must be an existing regular file")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_local_gate_evidence(
    path: pathlib.Path, expected_sha: str, evidence_bundle: pathlib.Path
) -> dict:
    try:
        evidence = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DispatchError(f"invalid local gate evidence: {error}") from error
    validated = validate_local_gate_evidence(evidence, expected_sha)
    actual_digest = sha256_evidence_bundle(evidence_bundle)
    if validated["evidenceSha256"] != actual_digest:
        raise DispatchError("local evidence bundle digest does not match evidenceSha256")
    return validated


def load_retry_evidence(
    path: pathlib.Path,
    expected_sha: str,
    prior_runs: list[dict],
    verified_failure_class: str,
) -> dict:
    try:
        evidence = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DispatchError(f"invalid retry evidence: {error}") from error
    return validate_retry_evidence(
        evidence, expected_sha, prior_runs, verified_failure_class
    )


@contextlib.contextmanager
def exact_sha_dispatch_lock(expected_sha: str):
    lock_path = pathlib.Path(tempfile.gettempdir()) / f"videotext-paid-macos-{expected_sha}.lock"
    with lock_path.open("w", encoding="utf-8") as lock_file:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise DispatchError("another same-SHA dispatch is already being evaluated") from error
        yield


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("expected_sha")
    parser.add_argument("--ref", required=True, help="remote branch containing expected_sha")
    parser.add_argument("--local-gate-evidence", required=True, type=pathlib.Path)
    parser.add_argument("--local-evidence-bundle", required=True, type=pathlib.Path)
    parser.add_argument("--retry-evidence", type=pathlib.Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    try:
        expected_sha = full_sha(args.expected_sha, "expected_sha")
        local_gate_evidence = load_local_gate_evidence(
            args.local_gate_evidence, expected_sha, args.local_evidence_bundle
        )
        if run(["git", "rev-parse", "HEAD"]).stdout.strip() != expected_sha:
            raise DispatchError("dispatcher checkout HEAD must equal expected_sha")
        if run(["git", "status", "--porcelain"]).stdout.strip():
            raise DispatchError("dispatcher checkout must be clean")
        run(
            [
                "git",
                "fetch",
                "--quiet",
                "origin",
                "refs/heads/main:refs/remotes/origin/main",
                f"refs/heads/{args.ref}:refs/remotes/origin/{args.ref}",
            ]
        )
        remote_ref = f"origin/{args.ref}"
        remote_sha = run(["git", "rev-parse", "--verify", f"{remote_ref}^{{commit}}"] ).stdout.strip()
        if remote_sha != expected_sha:
            raise DispatchError("remote dispatch ref does not point to expected_sha")
        base_sha = run(["git", "merge-base", "origin/main", expected_sha]).stdout.strip()
        with tempfile.TemporaryDirectory(prefix="videotext-ci-policy-") as temp_dir:
            classification_path = pathlib.Path(temp_dir) / "classification.json"
            result = run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "ci_risk_classifier.py"),
                    "--base",
                    base_sha,
                    "--head",
                    expected_sha,
                    "--output",
                    str(classification_path),
                ]
            )
            classification = json.loads(result.stdout)
            if classification["level"] != "LEVEL_B" or not classification["decision"]["hostedMacosEligible"]:
                raise DispatchError(
                    "HOSTED_MACOS_NOT_ELIGIBLE: deterministic classification is not eligible LEVEL_B"
                )
            classification_digest = hashlib.sha256(classification_path.read_bytes()).hexdigest()

        with exact_sha_dispatch_lock(expected_sha):
            matching_runs = workflow_runs(expected_sha)
            if args.retry_evidence is None:
                if matching_runs:
                    raise DispatchError("initial hosted attempt already exists for expected_sha")
                attempt = "initial"
                retry_evidence = {}
            else:
                if len(matching_runs) != 1:
                    raise DispatchError(
                        "exactly one prior same-SHA run is required for the single infrastructure retry"
                    )
                attempt = "infrastructure_retry"
                verified_failure_class = classify_prior_failure(
                    matching_runs[0]["id"], expected_sha
                )
                retry_evidence = load_retry_evidence(
                    args.retry_evidence,
                    expected_sha,
                    matching_runs,
                    verified_failure_class,
                )

            request = {
                "attempt": attempt,
                "classificationSha256": classification_digest,
                "baseSha": base_sha,
                "expectedSha": expected_sha,
                "localGateEvidence": local_gate_evidence,
                "ref": args.ref,
                "retryEvidence": retry_evidence,
                "workflow": WORKFLOW,
            }
            print(json.dumps(request, ensure_ascii=True, indent=2, sort_keys=True))
            if args.dry_run:
                return 0
            run(
                [
                    "gh",
                    "workflow",
                    "run",
                    WORKFLOW,
                    "--ref",
                    args.ref,
                    "-f",
                    f"base_sha={base_sha}",
                    "-f",
                    f"expected_sha={expected_sha}",
                    "-f",
                    f"local_gate_evidence={json.dumps(local_gate_evidence, separators=(',', ':'))}",
                    "-f",
                    f"classification_sha256={classification_digest}",
                    "-f",
                    f"attempt={attempt}",
                    "-f",
                    f"retry_evidence={json.dumps(retry_evidence, separators=(',', ':'))}",
                ]
            )
        return 0
    except DispatchError as error:
        print(f"PAID_MACOS_DISPATCH_BLOCKED: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
