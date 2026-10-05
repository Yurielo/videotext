#!/usr/bin/env python3
"""Fail-closed Dataset Registry policy guard for benchmark/experiment tooling."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import unicodedata
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REGISTRY = ROOT / "governance" / "dataset_registry.json"


class DatasetPolicyError(RuntimeError):
    """Raised when registry identity or policy denies an operation."""


@dataclass(frozen=True)
class PolicyDecision:
    allowed: bool
    dataset_id: str | None
    operation: str
    reason: str
    role: str | None = None
    lock_status: str | None = None
    registry_path: str | None = None


def _normalized(value: str | Path | None) -> str:
    if value is None:
        return ""
    text = Path(value).name if isinstance(value, Path) else Path(str(value)).name
    return unicodedata.normalize("NFC", text).strip().casefold()


def registry_path(explicit: str | Path | None = None) -> Path:
    raw = explicit or os.environ.get("SEMINARTEXT_DATASET_REGISTRY")
    return Path(raw).expanduser().resolve() if raw else DEFAULT_REGISTRY


def load_registry(path: str | Path | None = None) -> tuple[Path, dict[str, Any]]:
    resolved = registry_path(path)
    try:
        data = json.loads(resolved.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise DatasetPolicyError(f"Dataset Registry missing: {resolved}") from exc
    except json.JSONDecodeError as exc:
        raise DatasetPolicyError(f"Dataset Registry invalid JSON: {resolved}: {exc}") from exc
    if data.get("default_policy") != "DENY_UNREGISTERED":
        raise DatasetPolicyError("Dataset Registry must be fail-closed (DENY_UNREGISTERED)")
    datasets = data.get("datasets")
    if not isinstance(datasets, list) or not datasets:
        raise DatasetPolicyError("Dataset Registry has no datasets")
    return resolved, data


def resolve_dataset(
    registry: dict[str, Any],
    *,
    dataset_id: str | None = None,
    project: str | Path | None = None,
    source_id: str | None = None,
) -> dict[str, Any]:
    wanted_id = (dataset_id or "").strip().upper()
    wanted_project = _normalized(project)
    matches = []
    for entry in registry["datasets"]:
        if wanted_id and str(entry.get("id", "")).upper() != wanted_id:
            continue
        if wanted_project and _normalized(entry.get("project")) != wanted_project:
            continue
        registered_source = entry.get("source_id")
        if source_id and registered_source and registered_source != source_id:
            continue
        matches.append(entry)
    if len(matches) != 1:
        identity = f"dataset_id={dataset_id!r}, project={str(project)!r}, source_id={source_id!r}"
        if not matches:
            raise DatasetPolicyError(f"unregistered or mismatched dataset identity: {identity}")
        raise DatasetPolicyError(f"ambiguous dataset identity: {identity}")
    return matches[0]


def evaluate(
    operation: str,
    *,
    dataset_id: str | None = None,
    project: str | Path | None = None,
    source_id: str | None = None,
    path: str | Path | None = None,
) -> PolicyDecision:
    resolved, registry = load_registry(path)
    if operation not in registry.get("operations", {}):
        return PolicyDecision(
            False,
            None,
            operation,
            f"unknown governed operation: {operation}",
            registry_path=str(resolved),
        )
    try:
        entry = resolve_dataset(
            registry,
            dataset_id=dataset_id,
            project=project,
            source_id=source_id,
        )
    except DatasetPolicyError as exc:
        return PolicyDecision(
            False,
            None,
            operation,
            str(exc),
            registry_path=str(resolved),
        )
    allowed = operation in entry.get("allowed_operations", [])
    reason = (
        "operation explicitly allowed by Dataset Registry"
        if allowed
        else f"operation denied for dataset role {entry.get('role')} and lock {entry.get('lock_status')}"
    )
    return PolicyDecision(
        allowed,
        str(entry["id"]),
        operation,
        reason,
        role=entry.get("role"),
        lock_status=entry.get("lock_status"),
        registry_path=str(resolved),
    )


def enforce(operation: str, **identity: Any) -> PolicyDecision:
    decision = evaluate(operation, **identity)
    if not decision.allowed:
        raise DatasetPolicyError(
            f"DATASET GOVERNANCE DENY: {decision.reason}; "
            f"dataset={decision.dataset_id or 'UNREGISTERED'} operation={operation}"
        )
    return decision


def enforce_benchmark_artifact(
    operation: str,
    *,
    dataset_id: str,
    benchmark_path: str | Path,
    path: str | Path | None = None,
) -> PolicyDecision:
    """Authorize first, then bind an allowed operation to a frozen benchmark hash."""
    decision = enforce(operation, dataset_id=dataset_id, path=path)
    _, registry = load_registry(path)
    entry = resolve_dataset(registry, dataset_id=dataset_id)
    expected = entry.get("benchmark_sha256")
    if not expected:
        raise DatasetPolicyError(
            f"DATASET GOVERNANCE DENY: dataset {dataset_id} has no governed benchmark hash"
        )
    benchmark = Path(benchmark_path)
    try:
        actual = hashlib.sha256(benchmark.read_bytes()).hexdigest()
    except FileNotFoundError as exc:
        raise DatasetPolicyError(f"governed benchmark missing: {benchmark}") from exc
    if actual != expected:
        raise DatasetPolicyError(
            f"DATASET GOVERNANCE DENY: benchmark identity mismatch for dataset {dataset_id}; "
            f"expected={expected} actual={actual}"
        )
    return decision


def enforce_project_benchmark(
    operation: str,
    *,
    project: str | Path,
    benchmark_path: str | Path,
    path: str | Path | None = None,
) -> PolicyDecision:
    resolved, registry = load_registry(path)
    entry = resolve_dataset(registry, project=project)
    return enforce_benchmark_artifact(
        operation,
        dataset_id=str(entry["id"]),
        benchmark_path=benchmark_path,
        path=resolved,
    )


def validate_registry(path: str | Path | None = None) -> list[str]:
    _, registry = load_registry(path)
    errors = []
    required = {
        "id",
        "project",
        "role",
        "role_status",
        "source_quality",
        "gold_state",
        "tuning_permission",
        "validation_permission",
        "lock_status",
        "topic_engine_access_allowed",
        "allowed_operations",
        "references",
    }
    ids = []
    for entry in registry["datasets"]:
        dataset_id = str(entry.get("id", ""))
        ids.append(dataset_id)
        missing = sorted(required - entry.keys())
        if missing:
            errors.append(f"{dataset_id or '<missing-id>'}: missing {', '.join(missing)}")
        unknown = sorted(set(entry.get("allowed_operations", [])) - set(registry["operations"]))
        if unknown:
            errors.append(f"{dataset_id}: unknown operations {', '.join(unknown)}")
    if len(ids) != len(set(ids)):
        errors.append("duplicate dataset IDs")
    if ids != ["A", "B", "C", "D", "E", "F", "G1", "G2"]:
        errors.append(f"unexpected dataset inventory/order: {ids}")
    return errors


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    check = subparsers.add_parser("check", help="evaluate one operation")
    check.add_argument("--operation", required=True)
    check.add_argument("--dataset-id")
    check.add_argument("--project")
    check.add_argument("--source-id")
    check.add_argument("--registry")
    check.add_argument("--json", action="store_true")
    benchmark = subparsers.add_parser(
        "check-benchmark", help="authorize and bind a benchmark to its frozen hash"
    )
    benchmark.add_argument("--operation", required=True)
    benchmark.add_argument("--project", required=True)
    benchmark.add_argument("--benchmark", required=True)
    benchmark.add_argument("--registry")
    benchmark.add_argument("--json", action="store_true")
    validate = subparsers.add_parser("validate", help="validate Registry structure")
    validate.add_argument("--registry")
    validate.add_argument("--json", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "validate":
        try:
            errors = validate_registry(args.registry)
        except DatasetPolicyError as exc:
            errors = [str(exc)]
        payload = {"status": "PASS" if not errors else "FAIL", "errors": errors}
        if args.json:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
        elif errors:
            print("DATASET REGISTRY: FAIL", file=sys.stderr)
            for error in errors:
                print(f"- {error}", file=sys.stderr)
        else:
            print("DATASET REGISTRY: PASS")
        return 0 if not errors else 2

    if args.command == "check-benchmark":
        try:
            decision = enforce_project_benchmark(
                args.operation,
                project=args.project,
                benchmark_path=args.benchmark,
                path=args.registry,
            )
        except DatasetPolicyError as exc:
            decision = PolicyDecision(False, None, args.operation, str(exc))
    else:
        decision = evaluate(
            args.operation,
            dataset_id=args.dataset_id,
            project=args.project,
            source_id=args.source_id,
            path=args.registry,
        )
    if args.json:
        print(json.dumps(asdict(decision), ensure_ascii=False, indent=2))
    elif decision.allowed:
        print(
            f"DATASET GOVERNANCE: ALLOW dataset={decision.dataset_id} "
            f"operation={decision.operation} role={decision.role}"
        )
    else:
        print(
            f"DATASET GOVERNANCE: DENY dataset={decision.dataset_id or 'UNREGISTERED'} "
            f"operation={decision.operation}: {decision.reason}",
            file=sys.stderr,
        )
    return 0 if decision.allowed else 3


if __name__ == "__main__":
    raise SystemExit(main())
