#!/usr/bin/env python3
"""Fail-closed Topic Engine lifecycle and Dataset D freeze validator."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LIFECYCLE = ROOT / "governance" / "topic_engine_lifecycle.json"
DEFAULT_FREEZE = ROOT / "governance" / "topic_engine_freeze.json"
DEFAULT_DATASETS = ROOT / "governance" / "dataset_registry.json"
REQUIRED_ROLES = {"production_legacy", "experimental_primary", "comparator", "challenger", "frozen_candidate"}
ACTIVE_STATES = {"ACTIVE_IMPLEMENTATION", "EXTERNAL_PINNED_IMPLEMENTATION"}
HISTORICAL_STATES = {"HISTORICAL_IMPLEMENTATION", "SUPERSEDED_REFERENCE", "NON_EXECUTABLE_HISTORICAL_RECORD"}


def _path(explicit: str | Path | None, env_name: str, default: Path) -> Path:
    raw = explicit or os.environ.get(env_name)
    return Path(raw).expanduser().resolve() if raw else default


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _relative_safe(value: Any) -> bool:
    if not isinstance(value, str) or not value or value.startswith("/"):
        return False
    return ".." not in Path(value).parts


def _verify_record(record: dict[str, Any], root: Path, deployed: bool) -> tuple[bool, str]:
    if not isinstance(record, dict):
        return False, "implementation declaration is not an object"
    path = record.get("path")
    expected = record.get("sha256")
    mode = record.get("deployment_mode")
    if not _relative_safe(path) or not isinstance(expected, str) or len(expected) != 64:
        return False, "implementation path/hash is missing or unsafe"
    target_value = record.get("deployed_path") if deployed and mode == "RUNTIME_FILE" else path
    if not _relative_safe(target_value):
        return False, "deployed implementation path is missing or unsafe"
    target = root / target_value
    if target.is_file():
        return (_sha256(target) == expected, "FILE_HASH_MATCH" if _sha256(target) == expected else "FILE_HASH_MISMATCH")
    if deployed and mode == "GOVERNED_HASH_ATTESTATION" and record.get("repository_verification_required_before_deploy") is True:
        return True, "GOVERNED_HASH_ATTESTATION"
    return False, "IMPLEMENTATION_MISSING"


def _verify_optional_file(path_value: Any, expected: Any, root: Path, deployed: bool) -> tuple[bool, str]:
    if not _relative_safe(path_value) or not isinstance(expected, str) or len(expected) != 64:
        return False, "optional provenance path/hash is missing or unsafe"
    target = root / path_value
    if target.is_file():
        return (_sha256(target) == expected, "OPTIONAL_FILE_HASH_MATCH" if _sha256(target) == expected else "OPTIONAL_FILE_HASH_MISMATCH")
    if deployed and root.joinpath("governance", "topic_engine_lifecycle.json").is_file():
        return True, "GOVERNED_HASH_ATTESTATION"
    return False, "OPTIONAL_PROVENANCE_MISSING"


def _verify_external(item: dict[str, Any], root: Path, deployed: bool) -> list[str]:
    errors: list[str] = []
    external = item.get("external")
    if item.get("provenance_state") == "EXTERNAL_PINNED_IMPLEMENTATION":
        if not isinstance(external, dict) or not str(external.get("repository", "")).startswith("https://"):
            errors.append("external repository pin missing")
        if not isinstance(external, dict) or len(str(external.get("commit", ""))) != 40:
            errors.append("external commit pin missing")
        if not isinstance(external, dict) or not external.get("package") or not external.get("version"):
            errors.append("external package/version pin missing")
    lock_path = (item.get("external") or {}).get("lock_path")
    lock_sha = (item.get("external") or {}).get("lock_sha256")
    if lock_path:
        ok, reason = _verify_optional_file(lock_path, lock_sha, root, deployed)
        if not ok:
            errors.append(f"external lock provenance: {reason}")
    return errors


def _verify_model(item: dict[str, Any], role: str) -> list[str]:
    model = item.get("model")
    if not isinstance(model, dict) or not model.get("provider") or not model.get("identity"):
        return [f"model identity missing for {role}"]
    if role in {"experimental_primary", "comparator", "challenger", "frozen_candidate"}:
        digest = model.get("digest")
        if not isinstance(digest, str) or len(digest) != 64:
            return [f"pinned model digest missing for {role}"]
    return []


def _verify_no_absolute_paths(value: Any, prefix: str = "$") -> list[str]:
    errors: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            errors.extend(_verify_no_absolute_paths(child, f"{prefix}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            errors.extend(_verify_no_absolute_paths(child, f"{prefix}[{index}]"))
    elif isinstance(value, str) and value.startswith("/"):
        errors.append(f"absolute personal path is forbidden at {prefix}")
    return errors


def validate_lifecycle(path: str | Path | None = None, *, deployed: bool = False) -> list[str]:
    lifecycle_path = _path(path, "SEMINARTEXT_TOPIC_LIFECYCLE", DEFAULT_LIFECYCLE)
    data = _load(lifecycle_path)
    root = lifecycle_path.parent.parent
    errors = _verify_no_absolute_paths(data)
    engines = data.get("engines", [])
    roles = [item.get("role_id") for item in engines]
    if set(roles) != REQUIRED_ROLES or len(roles) != len(REQUIRED_ROLES):
        errors.append(f"role inventory mismatch: {roles}")
    if data.get("new_custom_family_policy") != "DENY_UNLESS_EXPLICIT_PRODUCT_OWNER_ISSUE":
        errors.append("new custom Boundary family policy is not fail-closed")
    if data.get("deployment_verification", {}).get("mode") != "GOVERNED_HASH_ATTESTATION":
        errors.append("deployment verification mode is not governed hash attestation")
    by_role = {item.get("role_id"): item for item in engines}
    legacy = by_role.get("production_legacy", {})
    if not legacy.get("production_runtime") or legacy.get("production_promoted"):
        errors.append("legacy runtime truth is ambiguous")
    for role, item in by_role.items():
        state = item.get("provenance_state")
        if state not in ACTIVE_STATES | HISTORICAL_STATES:
            errors.append(f"unknown provenance state for {role}")
        if role != "production_legacy" and (item.get("production_runtime") or item.get("production_promoted")):
            errors.append(f"non-legacy role incorrectly promoted: {role}")
        if state in ACTIVE_STATES:
            ok, reason = _verify_record(item.get("implementation", {}), root, deployed)
            if not ok:
                errors.append(f"active implementation provenance for {role}: {reason}")
            implementation = item.get("implementation", {})
            if implementation.get("configuration_path"):
                config_ok, config_reason = _verify_optional_file(
                    implementation.get("configuration_path"),
                    implementation.get("configuration_sha256"),
                    root,
                    deployed,
                )
                if not config_ok:
                    errors.append(f"configuration provenance for {role}: {config_reason}")
        errors.extend(_verify_external(item, root, deployed))
        errors.extend(_verify_model(item, role))
    frozen = by_role.get("frozen_candidate", {})
    primary = by_role.get("experimental_primary", {})
    if frozen.get("engine_id") != primary.get("engine_id"):
        errors.append("frozen candidate does not match experimental primary")
    semantics = data.get("benchmark_segment_semantics", {})
    if semantics.get("semantic_topic_output") is not False:
        errors.append("canonical BenchmarkSegments must remain topic-neutral")
    for item in data.get("historical_implementations", []):
        state = item.get("provenance_state")
        if state not in HISTORICAL_STATES:
            errors.append(f"invalid historical provenance state: {item.get('engine_id')}")
        if item.get("production_runtime") or item.get("production_promoted"):
            errors.append(f"historical implementation incorrectly promoted: {item.get('engine_id')}")
        if state == "NON_EXECUTABLE_HISTORICAL_RECORD":
            artifacts = item.get("provenance_artifacts", [])
            if not artifacts:
                errors.append(f"historical provenance absent: {item.get('engine_id')}")
            if not deployed:
                for artifact in artifacts:
                    ok, reason = _verify_record({"path": artifact.get("path"), "sha256": artifact.get("sha256"), "deployment_mode": "RUNTIME_FILE"}, root, False)
                    if not ok:
                        errors.append(f"historical provenance {item.get('engine_id')}: {reason}")
        elif state in {"HISTORICAL_IMPLEMENTATION", "SUPERSEDED_REFERENCE"}:
            ok, reason = _verify_record(item.get("implementation", {}), root, deployed)
            if not ok:
                errors.append(f"historical implementation {item.get('engine_id')}: {reason}")
    return errors


def freeze_gate(freeze_path: str | Path | None = None, dataset_path: str | Path | None = None, lifecycle_path: str | Path | None = None, *, deployed: bool = False) -> dict[str, Any]:
    resolved_freeze = _path(freeze_path, "SEMINARTEXT_TOPIC_FREEZE", DEFAULT_FREEZE)
    resolved_datasets = _path(dataset_path, "SEMINARTEXT_DATASET_REGISTRY", DEFAULT_DATASETS)
    resolved_lifecycle = _path(lifecycle_path, "SEMINARTEXT_TOPIC_LIFECYCLE", DEFAULT_LIFECYCLE)
    freeze = _load(resolved_freeze)
    datasets = _load(resolved_datasets)
    lifecycle = _load(resolved_lifecycle)
    lifecycle_errors = validate_lifecycle(resolved_lifecycle, deployed=deployed)
    dataset_d = next((item for item in datasets.get("datasets", []) if item.get("id") == "D"), None)
    primary = next((item for item in lifecycle.get("engines", []) if item.get("role_id") == "experimental_primary"), None)
    frozen = next((item for item in lifecycle.get("engines", []) if item.get("role_id") == "frozen_candidate"), None)
    binding = freeze.get("candidate", {}).get("implementation_binding", {})
    config = freeze.get("configuration", {})
    code_record = (primary or {}).get("implementation", {})
    code_ok, code_reason = _verify_record(code_record, resolved_lifecycle.parent.parent, deployed)
    freeze_checks = {
        "product_owner_decision": freeze.get("product_owner_decision") == "APPROVE_CANDIDATE_FREEZE",
        "product_owner_disposition": freeze.get("product_owner_disposition") == "FREEZE_LOCAL_PEAK_FOR_DATASET_D_CANDIDACY",
        "product_owner_authority": freeze.get("decision_recorded_by") == "Product Owner" and bool(freeze.get("decision_recorded_at")),
        "freeze_status": freeze.get("status") == "FROZEN_APPROVED",
        "candidate_frozen": freeze.get("candidate", {}).get("frozen") is True,
        "candidate_selected": freeze.get("candidate", {}).get("engine_id") == (primary or {}).get("engine_id"),
        "candidate_not_promoted": freeze.get("candidate", {}).get("production_promoted") is False,
        "candidate_implementation_binding": binding.get("path") == code_record.get("path") and binding.get("sha256") == code_record.get("sha256"),
        "candidate_code_hash_bound": code_ok,
        "candidate_code_verification": code_reason in {"FILE_HASH_MATCH", "GOVERNED_HASH_ATTESTATION"},
        "candidate_model_digest_bound": binding.get("model_digest") == (primary or {}).get("model", {}).get("digest"),
        "configuration_frozen": config.get("frozen") is True,
        "configuration_hash_bound": config.get("sha256") == _canonical_sha256(config.get("value")),
        "acceptance_criteria_frozen": freeze.get("acceptance_criteria", {}).get("frozen") is True,
        "acceptance_criteria_hash_bound": freeze.get("acceptance_criteria", {}).get("sha256") == _canonical_sha256(freeze.get("acceptance_criteria", {}).get("value")),
        "analysis_plan_frozen": freeze.get("analysis_plan", {}).get("frozen") is True,
        "analysis_plan_hash_bound": freeze.get("analysis_plan", {}).get("sha256") == _canonical_sha256(freeze.get("analysis_plan", {}).get("value")),
        "lifecycle_validation": not lifecycle_errors,
    }
    candidate_complete = all(freeze_checks.values())
    dataset_checks = {
        "dataset_d_locked_test": bool(dataset_d and dataset_d.get("role") == "LOCKED_TEST"),
        "dataset_d_prediction_access_denied": bool(dataset_d and dataset_d.get("topic_engine_access_allowed") is False),
        "dataset_d_source_identity_recorded": bool(dataset_d and dataset_d.get("source_identity_recorded") is True),
        "dataset_d_source_quality_accepted": bool(dataset_d and dataset_d.get("source_quality") == "SUFFICIENT"),
        "single_blind_run_authorized": freeze.get("dataset_d", {}).get("single_blind_run_authorized") is True,
    }
    dataset_open = candidate_complete and all(dataset_checks.values()) and bool(dataset_d and dataset_d.get("topic_engine_access_allowed") is True) and freeze.get("dataset_d", {}).get("open_allowed") is True
    return {
        "status": "PASS" if candidate_complete and dataset_checks["dataset_d_prediction_access_denied"] else "BLOCKED",
        "topic_candidate_freeze": "COMPLETE" if candidate_complete else "INCOMPLETE",
        "dataset_d_access": "OPEN_ALLOWED" if dataset_open else "BLOCKED",
        "dataset_d_open_allowed": dataset_open,
        "checks": freeze_checks,
        "dataset_d_checks": dataset_checks,
        "lifecycle_errors": lifecycle_errors,
        "implementation_verification": code_reason,
        "freeze_path": str(resolved_freeze),
        "freeze_sha256": _sha256(resolved_freeze),
        "dataset_registry_path": str(resolved_datasets),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--lifecycle")
    validate.add_argument("--deployed", action="store_true")
    validate.add_argument("--json", action="store_true")
    gate = subparsers.add_parser("freeze-check")
    gate.add_argument("--freeze")
    gate.add_argument("--dataset-registry")
    gate.add_argument("--lifecycle")
    gate.add_argument("--deployed", action="store_true")
    gate.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "validate":
        try:
            errors = validate_lifecycle(args.lifecycle, deployed=args.deployed)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            errors = [str(exc)]
        payload = {"status": "PASS" if not errors else "FAIL", "errors": errors}
        print(json.dumps(payload, ensure_ascii=False, indent=2) if args.json else payload["status"])
        return 0 if not errors else 2
    try:
        result = freeze_gate(args.freeze, args.dataset_registry, args.lifecycle, deployed=args.deployed)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        result = {"status": "FAIL", "dataset_d_open_allowed": False, "error": str(exc)}
    print(json.dumps(result, ensure_ascii=False, indent=2) if args.json else result["status"])
    return 0 if result["status"] == "PASS" else 3


if __name__ == "__main__":
    raise SystemExit(main())
