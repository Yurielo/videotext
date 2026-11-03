#!/usr/bin/env python3
"""Persistent CLI orchestration of the existing exact-fragment admission v1.

No semantic producer or compiler lives here. Prepared admission-v1 proposals
retain their declared producer; all semantic validation/admission is delegated.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import copy
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from seminartext_modules import reviewed_knowledge_admission as admission

TYPE = "seminartext.semantic_workflow"
VERSION = "1.0.0"
ROLES = ("evidence", "fragments", "proposals", "source", "notebook", "producer_runtime")
EVENT = re.compile(r"^[0-9]{8}-[a-f0-9]{64}\.json$")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_path(value):
    path = Path(os.path.abspath(Path(value).expanduser()))
    for part in (path, *path.parents):
        if part.exists() or part.is_symlink():
            require(not part.is_symlink(), f"symlink path is unsupported: {part}")
    return path


def read_file(value):
    path = safe_path(value)
    require(path.is_file() and stat.S_ISREG(path.stat().st_mode), f"input unavailable: {path}")
    return path.read_bytes()


def sha(payload):
    return hashlib.sha256(payload).hexdigest()


def fingerprint(value):
    path = safe_path(value)
    require(path.is_file() and stat.S_ISREG(path.stat().st_mode), f"input unavailable: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inputs(bindings):
    require(set(bindings) == set(ROLES), "workflow input roles differ")
    payloads = {}
    for role, item in bindings.items():
        if role in {"source", "producer_runtime"}:
            actual_hash = fingerprint(item["path"])
        else:
            payloads[role] = read_file(item["path"])
            actual_hash = sha(payloads[role])
        require(actual_hash == item["sha256"], f"stale {role} input")
    return payloads


def validate_inputs(state):
    payloads = inputs(state["inputs"])
    original = json.loads(payloads["proposals"])
    package = state["package"]
    require(original == state["original_package"], "original proposal snapshot changed")
    require(package["source_binding"] == original["source_binding"] and
            package["k1_binding"] == original["k1_binding"] and
            package["producer"] == original["producer"] and
            package["contract"] == original["contract"], "workflow package identity changed")
    original_by_id = {p["id"]: p for p in original["proposals"]}
    require(all(p == original_by_id.get(p["id"]) for p in package["proposals"]),
            "workflow changed a source proposal")
    require(state["inputs"]["source"]["sha256"] == package["source_binding"]["source_sha256"],
            "source bytes differ from Evidence")
    require(sha(payloads["notebook"]) == package["k1_binding"]["notebook_sha256"] and
            json.loads(payloads["notebook"])["notebook_id"] == package["k1_binding"]["notebook_id"],
            "notebook identity/hash differs")
    require(state["inputs"]["producer_runtime"]["sha256"] == package["producer"]["runtime_sha256"],
            "producer runtime bytes differ")
    require(package["k1_binding"]["review_state"] == admission.MACHINE_DERIVED_REVIEW_STATE,
            "workflow v1 requires non-authoritative machine-derived fragments")
    fragments = json.loads(payloads["fragments"])
    binding = package["source_binding"]
    require(all(f["source_id"] == binding["source_id"] and
                f["transcript_revision_id"] == binding["transcript_revision_id"]
                for f in fragments["fragment_lineage"]), "workflow supports one source/revision")
    require(all(p["operation"] == "CREATE" for p in original["proposals"]),
            "workflow v1 supports new proposals only; existing UPDATE admission is unchanged")
    return payloads


def ledger(state, *, preview=False):
    """Missing choices are system-only validation placeholders, never persisted."""
    package, choices = state["package"], state["choices"]
    ids = sorted(p["id"] for p in package["proposals"])
    missing = set(ids) - set(choices)
    require(preview or not missing, "explicit decisions are still missing")
    mode = ("SYSTEM_NONAUTHORITATIVE_DEFER" if not choices else
            "HUMAN_REVIEW_WITH_SYSTEM_DEFER" if missing else "HUMAN_REVIEW")
    system = {"actor_type": "system_validator", "actor_id": "integra_system"}
    reviewer = state["reviewer"] if choices else system
    decisions = []
    for proposal in sorted(package["proposals"], key=lambda p: p["id"]):
        chosen = proposal["id"] in choices
        choice = copy.deepcopy(choices[proposal["id"]]) if chosen else {
            "proposal_id": proposal["id"], "proposal_sha256": admission.digest(proposal),
            "action": "DEFER", "reason": "Non-persisted mechanical validation placeholder",
            "timestamp": "2000-01-01T00:00:00Z"}
        if mode == "HUMAN_REVIEW_WITH_SYSTEM_DEFER":
            choice["decision_actor"] = reviewer if chosen else system
        decisions.append(choice)
    return {"schema_version": VERSION, "package_id": package["artifact_id"],
            "package_sha256": admission.digest(package), "reviewer": reviewer,
            "execution_mode": mode, "explicit_confirmation": bool(choices),
            "confirmed_proposal_ids": ids, "decisions": decisions}


def compile_state(state, *, preview=False):
    payloads = validate_inputs(state)
    return admission.compile_revision(payloads["evidence"], payloads["fragments"],
                                      state["package"], ledger(state, preview=preview),
                                      parent=state["parent"])


@contextmanager
def locked(directory, *, create=False):
    root = safe_path(directory)
    if create:
        root.mkdir(parents=True, exist_ok=True)
    require(root.is_dir(), "workflow directory is unavailable")
    flags = os.O_RDWR | (os.O_CREAT if create else 0) | os.O_NOFOLLOW
    descriptor = os.open(root / ".lock", flags, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield root
    finally:
        os.close(descriptor)


def load(root):
    files = sorted(p for p in root.iterdir() if EVENT.fullmatch(p.name))
    require(files, "workflow has no committed snapshot; retry prepare")
    previous, last = None, None
    for number, path in enumerate(files):
        event = json.loads(read_file(path))
        require(event["schema_version"] == VERSION and event["artifact_type"] == TYPE,
                "unsupported workflow snapshot version/type")
        expected = admission.digest(event)
        require(path.name == f"{number:08d}-{expected}.json" and event["previous"] == previous,
                "workflow history is corrupt or forked")
        previous, last = expected, event
    return last["state"], len(files), previous


def append(root, state, number, previous):
    inputs(state["inputs"])  # Recheck after compilation and immediately before publication.
    event = {"artifact_type": TYPE, "schema_version": VERSION, "previous": previous, "state": state}
    path = root / f"{number:08d}-{admission.digest(event)}.json"
    # The admission module's no-overwrite atomic JSON writer is also suitable
    # for our non-canonical snapshot. The snapshot itself grants no authority.
    admission.persist_revision(path, event)


def summary(state):
    choices = state["choices"]
    pending = sorted(p["id"] for p in state["package"]["proposals"] if p["id"] not in choices)
    deferred = sorted(key for key, choice in choices.items() if choice["action"] == "DEFER")
    result = state["result"]
    return {"status": "APPLIED" if result else "REVIEW_REQUIRED",
            "package_id": state["package"]["artifact_id"],
            "package_sha256": admission.digest(state["package"]), "pending": pending,
            "deferred": deferred, "decisions": len(choices),
            "parent_revision_sha256": state["parent"]["revision_sha256"] if state["parent"] else None,
            "revision_sha256": result["revision_sha256"] if result else None,
            "canonical_entity_count": sum(len(result["canonical_knowledge"][k])
                                          for k in ("topics", "concepts", "relations")) if result else 0}


def prepare(directory, paths):
    bindings = {role: {"path": str(safe_path(path)), "sha256": fingerprint(path)}
                for role, path in paths.items()}
    package = json.loads(read_file(paths["proposals"]))
    require(package["parent_revision_sha256"] is None, "initial workflow requires a new admission")
    state = {"inputs": bindings, "original_package": copy.deepcopy(package), "package": package,
             "choices": {}, "reviewer": None, "parent": None, "result": None}
    compile_state(state, preview=True)  # Validation only: no decision/result persisted.
    with locked(directory, create=True) as root:
        if any(EVENT.fullmatch(p.name) for p in root.iterdir()):
            current, _, _ = load(root)
            require(current["inputs"] == bindings and current["original_package"] == package,
                    "workflow already belongs to different inputs")
            validate_inputs(current)
            return summary(current)
        require(all(p.name == ".lock" or p.name.startswith(".admission-") for p in root.iterdir()),
                "destination contains unrelated files")
        append(root, state, 0, None)
    return summary(state)


def submit(state, submission):
    package = state["package"]
    require(isinstance(submission, dict), "submission must be a JSON object")
    require(set(submission) - {"execution_mode"} == {"schema_version", "package_id", "package_sha256", "reviewer",
                              "explicit_confirmation", "confirmed_proposal_ids", "decisions"},
            "unsupported submission fields")
    require(submission.get("execution_mode", "HUMAN_REVIEW") == "HUMAN_REVIEW", "human submission mode required")
    require(submission["schema_version"] == VERSION and submission["package_id"] == package["artifact_id"]
            and submission["package_sha256"] == admission.digest(package), "stale submission package")
    require(submission["explicit_confirmation"] is True, "explicit human confirmation required")
    reviewer = submission["reviewer"]
    require(reviewer["actor_type"] in {"human_domain_reviewer", "product_owner"}, "human reviewer required")
    require(state["reviewer"] in (None, reviewer), "one explicit reviewer per round required")
    entries = submission["decisions"]
    ids = [item["proposal_id"] for item in entries]
    known = {p["id"] for p in package["proposals"]}
    require(ids and len(set(ids)) == len(ids) and set(ids) <= known, "unknown/duplicate/empty decisions")
    require(submission["confirmed_proposal_ids"] == sorted(ids), "confirmation must enumerate exactly submitted IDs")
    for item in entries:
        require("decision_actor" not in item, "submission cannot supply system or per-decision actors")
        old = state["choices"].get(item["proposal_id"])
        require(old is None or old == item, "conflicting historical decision")
    updated = copy.deepcopy(state)
    updated["reviewer"] = reviewer
    updated["choices"].update({item["proposal_id"]: item for item in entries})
    compile_state(updated, preview=True)  # Entire batch before a single snapshot.
    require(not state["result"] or updated == state, "already applied; reopen deferred items in a new round")
    return updated


def next_round(state):
    result = state["result"]
    if result is None and state["parent"] and not state["choices"]:
        return state  # Exact retry immediately after opening the deferred round.
    require(result is not None, "apply the explicitly reviewed round first")
    deferred = {key for key, choice in state["choices"].items() if choice["action"] == "DEFER"}
    require(deferred, "no deferred proposals to reopen")
    updated = copy.deepcopy(state)
    package = updated["package"]
    package["proposals"] = [p for p in package["proposals"] if p["id"] in deferred]
    package["parent_revision_sha256"] = result["revision_sha256"]
    package["artifact_id"] = "review_" + admission.digest(package)
    updated.update(parent=result, result=None, choices={}, reviewer=None)
    compile_state(updated, preview=True)
    return updated


def inspect_text(state, payloads):
    bundle = json.loads(payloads["evidence"])
    fragments = {f["id"]: f for f in json.loads(payloads["fragments"])["fragment_lineage"]}
    lines = ["# Проверка предложений знаний", "", json.dumps(summary(state), ensure_ascii=False),
             "", "Исходные предложения остаются provisional; принятый результат хранится отдельной ревизией. "
             "Отсутствующее решение остаётся отсутствующим.",
             json.dumps({"source_binding": state["package"]["source_binding"],
                         "producer": state["package"]["producer"],
                         "transcript_assurance": [r.get("transcript_provenance") for r in bundle["transcript_revisions"]
                            if r["id"] == state["package"]["source_binding"]["transcript_revision_id"]]},
                        ensure_ascii=False, sort_keys=True)]
    for proposal in state["package"]["proposals"]:
        record = proposal["record"]
        lines += ["", f"## {proposal['id']}", json.dumps(record, ensure_ascii=False, sort_keys=True),
                  json.dumps(proposal["generation_provenance"], ensure_ascii=False, sort_keys=True),
                  f"Решение: {state['choices'].get(proposal['id'], {}).get('action', 'REVIEW_REQUIRED')}"]
        for ref in proposal["fragment_refs"]:
            evidence = admission._span(fragments[ref["id"]], bundle)
            lines += ["", evidence["quote"], json.dumps({k: evidence[k] for k in
                       ("canonical_source_id", "canonical_transcript_revision_id", "precision", "locator")},
                       ensure_ascii=False, sort_keys=True)]
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("workflow", type=Path)
    for role in ROLES:
        prepare_parser.add_argument("--" + role.replace("_", "-"), type=Path, required=True)
    for name in ("status", "inspect", "submit", "decide", "apply", "validate", "next-round", "result"):
        sub = commands.add_parser(name)
        sub.add_argument("workflow", type=Path)
        if name == "submit":
            sub.add_argument("--decisions", type=Path, required=True)
        if name == "decide":
            sub.add_argument("--proposal", required=True)
            sub.add_argument("--action", choices=("ACCEPT", "EDIT", "REJECT", "DEFER"), required=True)
            sub.add_argument("--reason", required=True)
            sub.add_argument("--reviewer", required=True)
            sub.add_argument("--confirm-package-sha256", required=True)
            sub.add_argument("--timestamp", default=None)
            sub.add_argument("--edited-fields", type=Path)
    args = parser.parse_args(argv)
    if args.command == "prepare":
        print(json.dumps(prepare(args.workflow, {r: getattr(args, r) for r in ROLES}), sort_keys=True))
        return
    with locked(args.workflow) as root:
        state, number, previous = load(root)
        payloads = validate_inputs(state)
        compile_state(state, preview=True)
        if state["result"]:
            require(compile_state(state) == state["result"], "persisted result differs from explicit decisions")
        updated = copy.deepcopy(state)
        if args.command == "submit":
            updated = submit(state, json.loads(read_file(args.decisions)))
        elif args.command == "decide":
            proposal = next((p for p in state["package"]["proposals"] if p["id"] == args.proposal), None)
            require(proposal is not None, "unknown proposal")
            choice = {"proposal_id": args.proposal, "proposal_sha256": admission.digest(proposal),
                      "action": args.action, "reason": args.reason,
                      "timestamp": args.timestamp or state["choices"].get(args.proposal, {}).get("timestamp")
                      or datetime.now(timezone.utc).isoformat()}
            if args.edited_fields:
                choice["edited_fields"] = json.loads(read_file(args.edited_fields))
            updated = submit(state, {"schema_version": VERSION, "package_id": state["package"]["artifact_id"],
                "package_sha256": args.confirm_package_sha256,
                "reviewer": {"actor_type": "human_domain_reviewer", "actor_id": args.reviewer},
                "explicit_confirmation": True, "confirmed_proposal_ids": [args.proposal], "decisions": [choice]})
        elif args.command == "apply":
            updated["result"] = compile_state(state)
        elif args.command == "next-round":
            updated = next_round(state)
        elif args.command in {"validate", "result"}:
            require(state["result"] is not None, "no applied canonical result")
            admission.validate_revision(state["result"], payloads["evidence"])
        if updated != state:
            append(root, updated, number, previous)
        if args.command == "inspect":
            print(inspect_text(state, payloads), end="")
        elif args.command == "result":
            print(admission.canonical_bytes(state["result"]).decode(), end="")
        else:
            print(json.dumps(summary(updated), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
        print(json.dumps({"status": "INVALID_OR_UNAVAILABLE", "error": str(error)}), file=sys.stderr)
        raise SystemExit(1)
