#!/usr/bin/env python3
"""Deterministically classify a VideoText diff as LEVEL_A or LEVEL_B."""

from __future__ import annotations

import argparse
import fnmatch
import json
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Iterable


ROOT = pathlib.Path(__file__).resolve().parents[1]
POLICY_PATH = ROOT / ".ci" / "ci-risk-policy.json"
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
NATIVE_MAGICS = {
    b"\x7fELF",
    b"\xbe\xba\xfe\xca",
    b"\xbf\xba\xfe\xca",
    b"\xca\xfe\xba\xbe",
    b"\xca\xfe\xba\xbf",
    b"\xce\xfa\xed\xfe",
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
    b"\xfe\xed\xfa\xcf",
}
REQUIRED_LEVEL_B_EXACT_PATHS = {
    ".ci/ci-risk-policy.json",
    ".github/workflows/topic-regression.yml",
    "scripts/ci_risk_classifier.py",
    "scripts/dispatch_paid_macos_gate.py",
    "scripts/test_ci_cost_policy.sh",
}
REQUIRED_LEVEL_B_PREFIXES = {".github/workflows/"}


class ClassificationError(RuntimeError):
    pass


@dataclass(frozen=True)
class Change:
    status: str
    path: str
    old_path: str | None = None
    binary: bool = False
    changed_text: str = ""
    mode_changed: bool = False


def load_policy(path: pathlib.Path = POLICY_PATH) -> dict:
    with path.open(encoding="utf-8") as source:
        policy = json.load(source)
    if policy.get("schemaVersion") != 1:
        raise ClassificationError("unsupported policy schema")
    if not REQUIRED_LEVEL_B_EXACT_PATHS.issubset(policy.get("levelBExactPaths", [])):
        raise ClassificationError("policy cannot unprotect classifier, dispatcher, tests, or workflow")
    if not REQUIRED_LEVEL_B_PREFIXES.issubset(policy.get("levelBPrefixes", [])):
        raise ClassificationError("policy cannot unprotect workflow infrastructure")
    return policy


def _git(repo: pathlib.Path, *args: str, text: bool = True) -> str | bytes:
    result = subprocess.run(
        ["git", *args], cwd=repo, check=False, capture_output=True, text=text
    )
    if result.returncode != 0:
        stderr = result.stderr if text else result.stderr.decode("utf-8", "replace")
        raise ClassificationError(stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout


def require_full_commit(repo: pathlib.Path, value: str, label: str) -> str:
    if not FULL_SHA.fullmatch(value):
        raise ClassificationError(f"{label} must be a full lowercase 40-character SHA")
    resolved = _git(repo, "rev-parse", "--verify", f"{value}^{{commit}}").strip()
    if resolved != value:
        raise ClassificationError(f"{label} does not resolve exactly to {value}")
    return resolved


def require_ancestor(repo: pathlib.Path, base: str, head: str) -> None:
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", base, head],
        cwd=repo,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ClassificationError("base must be an ancestor of head")


def _blob_prefix(repo: pathlib.Path, revision: str, path: str) -> bytes:
    result = subprocess.run(
        ["git", "show", f"{revision}:{path}"], cwd=repo, check=False, capture_output=True
    )
    return result.stdout[:4] if result.returncode == 0 else b""


def _is_native_binary(repo: pathlib.Path, base: str, head: str, status: str, path: str) -> bool:
    revision = base if status == "D" else head
    return _blob_prefix(repo, revision, path) in NATIVE_MAGICS


def _changed_text(repo: pathlib.Path, base: str, head: str, path: str) -> str:
    output = _git(repo, "diff", "--unified=0", base, head, "--", path, text=False).decode(
        "utf-8", "replace"
    )
    lines = []
    for line in output.splitlines():
        if line.startswith(("+++", "---")):
            continue
        if line.startswith(("+", "-")):
            lines.append(line[1:])
    return "\n".join(lines)


def collect_changes(repo: pathlib.Path, base: str, head: str) -> list[Change]:
    raw = _git(
        repo,
        "diff",
        "--raw",
        "-z",
        "--find-renames",
        "--no-abbrev",
        base,
        head,
        text=False,
    )
    fields = raw.decode("utf-8", "surrogateescape").split("\0")
    if fields and fields[-1] == "":
        fields.pop()
    changes: list[Change] = []
    index = 0
    while index < len(fields):
        metadata = fields[index].split()
        index += 1
        if len(metadata) != 5 or not metadata[0].startswith(":"):
            raise ClassificationError("unexpected git raw diff record")
        old_mode = metadata[0][1:]
        new_mode = metadata[1]
        status = metadata[4]
        first_path = fields[index]
        index += 1
        if status.startswith(("R", "C")):
            old_path, path = first_path, fields[index]
            index += 1
        else:
            old_path, path = None, first_path
        short_status = status[0]
        changes.append(
            Change(
                status=short_status,
                path=path,
                old_path=old_path,
                binary=_is_native_binary(repo, base, head, short_status, path),
                changed_text=_changed_text(repo, base, head, path),
                mode_changed=(
                    new_mode not in {"100644", "100755"}
                    if short_status == "A"
                    else short_status != "D" and old_mode != new_mode
                ),
            )
        )
    return changes


def _matches_extension(path: str, extensions: Iterable[str]) -> bool:
    return any(path.endswith(extension) or f"{extension}/" in path for extension in extensions)


def _path_reason(path: str, policy: dict) -> tuple[str, str]:
    if path in policy["levelBExactPaths"]:
        return "LEVEL_B", "protected-infrastructure-path"
    if path in policy["knownRuntimeDiscoveryPaths"]:
        return "LEVEL_B", "runtime-discovery-path"
    if any(path.startswith(prefix) for prefix in policy["levelBPrefixes"]):
        return "LEVEL_B", "protected-infrastructure-prefix"
    if _matches_extension(path, policy["levelBExtensions"]):
        return "LEVEL_B", "native-build-extension"
    if path in policy["levelAExactPaths"]:
        return "LEVEL_A", "known-application-or-governance-path"
    if any(path.startswith(prefix) for prefix in policy["levelAPrefixes"]):
        return "LEVEL_A", "known-application-path"
    if any(fnmatch.fnmatch(path, pattern) for pattern in policy["levelAGlobs"]):
        return "LEVEL_A", "known-application-glob"
    return "LEVEL_B", "unknown-path-fail-closed"


def _marker_reasons(change: Change, policy: dict) -> list[str]:
    if any(change.path.startswith(prefix) for prefix in policy["markerScanExcludedPrefixes"]):
        return []
    if not any(change.path.startswith(prefix) for prefix in policy["markerScanPrefixes"]):
        return []
    return [
        marker["code"]
        for marker in policy["infrastructureMarkers"]
        if re.search(marker["pattern"], change.changed_text)
    ]


def classify_changes(changes: Iterable[Change], policy: dict) -> dict:
    ordered = sorted(changes, key=lambda item: (item.path, item.old_path or "", item.status))
    reasons: list[dict] = []
    serialized_changes: list[dict] = []
    level_b = False

    for change in ordered:
        paths = [change.path]
        if change.old_path:
            paths.append(change.old_path)
        path_results = [_path_reason(path, policy) for path in paths]
        path_level = "LEVEL_B" if any(level == "LEVEL_B" for level, _ in path_results) else "LEVEL_A"
        for path, (level, code) in zip(paths, path_results):
            reasons.append({"code": code, "level": level, "path": path})
        marker_codes = _marker_reasons(change, policy)
        for code in marker_codes:
            reasons.append({"code": code, "level": "LEVEL_B", "path": change.path})
        if change.binary:
            reasons.append({"code": "native-binary-content", "level": "LEVEL_B", "path": change.path})
        ambiguous_change_type = change.status in {"C", "D", "R", "T", "U"} or change.mode_changed
        if ambiguous_change_type:
            reasons.append(
                {"code": "ambiguous-change-type-fail-closed", "level": "LEVEL_B", "path": change.path}
            )
        change_level = (
            "LEVEL_B"
            if path_level == "LEVEL_B" or marker_codes or change.binary or ambiguous_change_type
            else "LEVEL_A"
        )
        level_b = level_b or change_level == "LEVEL_B"
        serialized_changes.append(
            {
                "binary": change.binary,
                "classification": change_level,
                "oldPath": change.old_path,
                "path": change.path,
                "status": change.status,
                "modeChanged": change.mode_changed,
            }
        )

    if not ordered:
        reasons.append({"code": "empty-diff-not-eligible", "level": "LEVEL_B", "path": None})
        level_b = True

    level = "LEVEL_B" if level_b else "LEVEL_A"
    return {
        "changes": serialized_changes,
        "decision": {
            "failClosed": level == "LEVEL_B",
            "hostedMacosEligible": level == "LEVEL_B" and bool(ordered),
            "hostedMacosRequired": level == "LEVEL_B" and bool(ordered),
        },
        "level": level,
        "policyVersion": policy["policyVersion"],
        "reasons": reasons,
        "schemaVersion": 1,
    }


def classify_repository(repo: pathlib.Path, base: str, head: str, policy_path: pathlib.Path) -> dict:
    base_sha = require_full_commit(repo, base, "base")
    head_sha = require_full_commit(repo, head, "head")
    require_ancestor(repo, base_sha, head_sha)
    result = classify_changes(collect_changes(repo, base_sha, head_sha), load_policy(policy_path))
    result["baseSha"] = base_sha
    result["headSha"] = head_sha
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--repo", type=pathlib.Path, default=ROOT)
    parser.add_argument("--policy", type=pathlib.Path, default=POLICY_PATH)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    try:
        result = classify_repository(args.repo.resolve(), args.base, args.head, args.policy.resolve())
    except ClassificationError as error:
        print(f"CI_RISK_CLASSIFICATION_ERROR: {error}", file=sys.stderr)
        return 2
    payload = json.dumps(result, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(payload, encoding="utf-8")
    sys.stdout.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
