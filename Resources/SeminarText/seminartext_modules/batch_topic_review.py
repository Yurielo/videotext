"""Explicit batch orchestration for source-bound automatic Topic review.

This module deliberately has no semantic authority.  It validates an explicit
manifest, delegates each selected source to ``automatic_topic_review``, and
keeps an immutable batch journal whose successful entries remain
``REVIEW_REQUIRED``.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager, redirect_stdout
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from seminartext_modules import automatic_topic_review as auto
from seminartext_modules import human_review_workflow as review
from seminartext_modules.reviewed_knowledge_admission import persist_revision


ARTIFACT = "seminartext.batch_topic_review"
MANIFEST_ARTIFACT = "seminartext.topic_review_batch_manifest"
VERSION = "1.0.0"
RUN_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*$")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(value):
    return hashlib.sha256(review.canonical_bytes(value)).hexdigest()


def file_digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read(path):
    return json.loads(Path(path).read_bytes())


def _safe_path(value, label, *, directory=False):
    path = Path(value)
    require(path.is_absolute(), f"{label} must be an absolute path")
    require(not path.is_symlink(), f"{label} symlink unsupported")
    require(path.is_dir() if directory else path.is_file(), f"{label} unavailable")
    return path.resolve()


def load_manifest(path):
    path = _safe_path(path, "manifest")
    try:
        value = read(path)
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid manifest: {exc}") from exc
    require(isinstance(value, dict) and set(value) == {"artifact_type", "schema_version", "entries"},
            "unsupported manifest fields")
    require(value["artifact_type"] == MANIFEST_ARTIFACT and value["schema_version"] == VERSION,
            "unsupported manifest contract version")
    require(isinstance(value["entries"], list) and value["entries"], "manifest entries required")
    expected = {"id", "project", "source", "source_id", "revision_id", "run_directory"}
    entries, seen_ids, seen_sources, seen_runs = [], set(), set(), set()
    for raw in value["entries"]:
        require(isinstance(raw, dict) and set(raw) == expected, "unsupported manifest entry fields")
        entry_id, run_name = raw["id"], raw["run_directory"]
        require(isinstance(entry_id, str) and RUN_NAME.fullmatch(entry_id), "invalid manifest entry id")
        require(isinstance(run_name, str) and RUN_NAME.fullmatch(run_name) and run_name not in {".", ".."},
                "invalid run directory")
        require(all(isinstance(raw[k], str) and raw[k] for k in ("source_id", "revision_id")),
                "source and revision IDs required")
        project = _safe_path(raw["project"], "project", directory=True)
        source = _safe_path(raw["source"], "source")
        source_key = (str(project), raw["source_id"], raw["revision_id"])
        require(entry_id not in seen_ids and source_key not in seen_sources and run_name not in seen_runs,
                "duplicate manifest entry, source/revision, or run directory")
        seen_ids.add(entry_id); seen_sources.add(source_key); seen_runs.add(run_name)
        entries.append(dict(id=entry_id, project=str(project), source=str(source), source_id=raw["source_id"],
                            revision_id=raw["revision_id"], run_directory=run_name))
    return path, entries


def _binding(entry):
    return auto.context(Path(entry["project"]), entry["source_id"], entry["revision_id"], Path(entry["source"]))[3]


@contextmanager
def lock(batch):
    batch = Path(batch)
    require(not batch.is_symlink() and not batch.parent.is_symlink(), "symlink batch output unsupported")
    batch.mkdir(parents=True, exist_ok=True)
    fd = os.open(batch / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def _snapshots(batch):
    values = sorted(Path(batch).glob("state-*.json"))
    require(values, "batch has not been prepared")
    expected_parent = None
    for number, path in enumerate(values):
        state = read(path)
        require(path.name.startswith(f"state-{number:08d}-"), "non-contiguous batch journal")
        actual = digest({k: v for k, v in state.items() if k != "state_sha256"})
        require(state.get("state_sha256") == actual and path.stem == f"state-{number:08d}-{actual}",
                "batch state snapshot changed")
        require(state.get("parent_sha256") == expected_parent, "batch state chain changed")
        expected_parent = actual
    return values, state


def _write_state(batch, state):
    paths, previous = _snapshots(batch) if list(Path(batch).glob("state-*.json")) else ([], None)
    if previous:
        state["parent_sha256"] = previous["state_sha256"]
    else:
        state["parent_sha256"] = None
    state["state_sha256"] = digest({k: v for k, v in state.items() if k != "state_sha256"})
    destination = Path(batch) / f"state-{len(paths):08d}-{state['state_sha256']}.json"
    persist_revision(destination, state)
    return state


def _validate_state(state):
    require(state.get("artifact_type") == ARTIFACT and state.get("schema_version") == VERSION,
            "unsupported batch state contract")
    require(isinstance(state.get("manifest"), str) and isinstance(state.get("manifest_sha256"), str),
            "incomplete manifest binding")
    require(isinstance(state.get("entries"), list) and state["entries"], "invalid batch entries")
    for entry in state["entries"]:
        require(entry.get("status") in {"PENDING", "REVIEW_REQUIRED", "FAILED"}, "invalid batch entry status")
        require(set(entry) >= {"id", "project", "source", "source_id", "revision_id", "run_directory", "binding", "status"},
                "incomplete batch entry")


def _load_current(batch):
    _, state = _snapshots(batch)
    _validate_state(state)
    return state


def _preflight(state):
    for entry in state["entries"]:
        try:
            current = _binding(entry)
        except (ValueError, OSError, KeyError, TypeError) as exc:
            raise ValueError(f"stale or unavailable input: {entry['id']}: {exc}") from exc
        require(current == entry["binding"], f"stale or unavailable input: {entry['id']}")


def _manifest_current(state):
    path = _safe_path(state["manifest"], "manifest")
    require(file_digest(path) == state["manifest_sha256"], "manifest changed after preparation")


def prepare(batch, manifest):
    batch, manifest = Path(batch).absolute(), Path(manifest)
    manifest_path, entries = load_manifest(manifest)
    bindings = [_binding(entry) for entry in entries]
    with lock(batch):
        existing = list(batch.glob("state-*.json"))
        if existing:
            state = _load_current(batch)
            require(state["manifest"] == str(manifest_path) and state["manifest_sha256"] == file_digest(manifest_path),
                    "prepared batch is bound to a different manifest")
            require([entry["binding"] for entry in state["entries"]] == bindings, "prepared inputs changed")
            return state
        require(not [path for path in batch.iterdir() if path.name != ".lock"], "batch directory is not empty")
        state = dict(artifact_type=ARTIFACT, schema_version=VERSION, manifest=str(manifest_path),
                     manifest_sha256=file_digest(manifest_path), entries=[])
        for entry, binding in zip(entries, bindings):
            state["entries"].append({**entry, "binding": binding, "status": "PENDING"})
        return _write_state(batch, state)


def _auto_args(command, entry, batch):
    return argparse.Namespace(command=command, run=Path(batch) / entry["run_directory"],
                              project=Path(entry["project"]), source=Path(entry["source"]),
                              source_id=entry["source_id"], revision_id=entry["revision_id"])


def _receipt(entry, batch):
    run = Path(batch) / entry["run_directory"]
    receipt = read(run / "receipt.json")
    require(receipt.get("binding") == entry["binding"], "source receipt binding changed")
    hashes = receipt.get("hashes")
    require(isinstance(hashes, dict) and hashes, "incomplete source receipt")
    for name, expected in hashes.items():
        require(Path(name).name == name and file_digest(run / name) == expected, "source review artifact changed")
    package = run / "review_package.json"
    review.load_package(Path(entry["project"]), package)
    response = read(run / "response.json")
    return dict(run=str(run), package=str(package), receipt_sha256=file_digest(run / "receipt.json"),
                package_sha256=file_digest(package), topics=len(read(run / "drafts.json")["topics"]),
                fallback_count=len(response.get("fallbacks", [])), model_digest=response["model_digest"])


def _reconcile_existing(entry, batch):
    run = Path(batch) / entry["run_directory"]
    if (run / "receipt.json").exists():
        with redirect_stdout(io.StringIO()):
            auto.execute(_auto_args("status", entry, batch))
        return "REVIEW_REQUIRED", _receipt(entry, batch)
    if (run / "response.json").exists():
        with redirect_stdout(io.StringIO()):
            auto.execute(_auto_args("replay", entry, batch))
        return "REVIEW_REQUIRED", _receipt(entry, batch)
    if (run / "attempt.json").exists() or (run / "failure.json").exists():
        failure = read(run / "failure.json") if (run / "failure.json").exists() else {"error": "interrupted before producer response"}
        return "FAILED", {"error": failure.get("error", "unknown source failure"), "run": str(run)}
    return None, None


def _summary(state):
    values = {name: sum(entry["status"] == name for entry in state["entries"])
              for name in ("PENDING", "REVIEW_REQUIRED", "FAILED")}
    status = "REVIEW_REQUIRED" if values["PENDING"] == values["FAILED"] == 0 else "PARTIAL_FAILURE" if values["FAILED"] else "PENDING"
    return dict(status=status, entries=len(state["entries"]), **{k.lower(): v for k, v in values.items()})


def run(batch):
    batch = Path(batch).absolute()
    with lock(batch):
        state = _load_current(batch)
        _manifest_current(state)
        _preflight(state)  # all selected inputs pass before the first model call
        changed = False
        for index, entry in enumerate(state["entries"]):
            if entry["status"] != "PENDING":
                continue
            try:
                status, result = _reconcile_existing(entry, batch)
                if status is None:
                    with redirect_stdout(io.StringIO()):
                        auto.execute(_auto_args("generate", entry, batch))
                    status, result = "REVIEW_REQUIRED", _receipt(entry, batch)
            except (ValueError, OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
                status, result = "FAILED", {"error": str(exc), "run": str(batch / entry["run_directory"])}
            state["entries"][index] = {**entry, "status": status, "result": result}
            state = _write_state(batch, state)
            changed = True
        return state, changed


def status(batch):
    state = _load_current(batch)
    _manifest_current(state)
    _preflight(state)
    for entry in state["entries"]:
        if entry["status"] == "REVIEW_REQUIRED":
            with redirect_stdout(io.StringIO()):
                auto.execute(_auto_args("status", entry, batch))
            require(entry.get("result") == _receipt(entry, batch), "batch result receipt changed")
    return state


def inspect(batch):
    state = status(batch)
    lines = ["# Пакетная проверка тем", "", "Все автоматически сформированные темы ожидают проверки. Решений не применено.", ""]
    for entry in state["entries"]:
        lines.append(f"## {entry['id']}")
        lines.append(f"Состояние: {entry['status']}")
        if entry["status"] == "REVIEW_REQUIRED":
            lines.append(f"Пакет: {entry['result']['package']}")
            lines.append(f"Черновиков тем: {entry['result']['topics']}; решений: 0.")
        elif entry.get("result"):
            lines.append(f"Ошибка: {entry['result']['error']}")
        lines.append("")
    return "\n".join(lines)


def execute(args):
    if args.command == "prepare":
        state = prepare(args.batch, args.manifest)
    elif args.command in {"run", "resume"}:
        state, _ = run(args.batch)
    elif args.command == "status":
        state = status(args.batch)
    else:
        print(inspect(args.batch))
        return 0
    print(json.dumps(_summary(state), ensure_ascii=False))
    return 1 if _summary(state)["status"] == "PARTIAL_FAILURE" else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="command", required=True)
    for command in ("prepare", "run", "resume", "status", "inspect"):
        sub = subs.add_parser(command)
        sub.add_argument("batch", type=Path)
        if command == "prepare":
            sub.add_argument("--manifest", required=True, type=Path)
    try:
        raise SystemExit(execute(parser.parse_args()))
    except (ValueError, OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print(json.dumps({"status": "INVALID_OR_UNAVAILABLE", "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
