#!/usr/bin/env python3
"""Prepare a persistent SeminarText group from files and directories.

This helper owns only discovery, content-based de-duplication, and the group
project skeleton.  Transcription stays in the established project workflow.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path


MEDIA_EXTENSIONS = {
    ".m4a", ".mp3", ".wav", ".aac", ".flac", ".ogg", ".opus",
    ".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def default_group_dir(first_input: str) -> Path:
    first = Path(first_input).expanduser()
    return (first if first.is_dir() else first.parent) / "group"


def existing_hashes(group: Path) -> dict[str, str]:
    registry = group / "sources.json"
    if not registry.is_file():
        return {}
    try:
        data = json.loads(registry.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Ошибка чтения group sources.json: {exc}") from exc

    result: dict[str, str] = {}
    for item in data.get("videos", []):
        if item.get("type") != "local" or not item.get("source_id"):
            continue
        source = group / str(item.get("file", ""))
        if source.is_file():
            result.setdefault(sha256(source), str(item["source_id"]))
    return result


def discover(inputs: list[str], group: Path) -> list[Path]:
    group_resolved = group.resolve()
    candidates: list[Path] = []
    seen_paths: set[Path] = set()

    def add(path: Path) -> None:
        resolved = path.resolve()
        if resolved not in seen_paths:
            seen_paths.add(resolved)
            candidates.append(resolved)

    for raw in inputs:
        source = Path(raw).expanduser()
        if not source.exists():
            print(f"[ОШИБКА] Не найдено: {source}", file=sys.stderr)
            continue
        if source.is_file():
            if source.suffix.lower() not in MEDIA_EXTENSIONS:
                print(f"[ПРОПУСК] Неподдерживаемый файл: {source}", file=sys.stderr)
                continue
            add(source)
            continue
        if not source.is_dir():
            print(f"[ПРОПУСК] Неподдерживаемый источник: {source}", file=sys.stderr)
            continue

        for root, names, files in os.walk(source):
            directory = Path(root)
            if is_within(directory.resolve(), group_resolved):
                names[:] = []
                continue
            names[:] = sorted(name for name in names if not name.startswith("."))
            for name in sorted(files):
                item = directory / name
                if not name.startswith(".") and item.suffix.lower() in MEDIA_EXTENSIONS:
                    add(item)
    return candidates


def initialise_group(group: Path) -> None:
    group.mkdir(parents=True, exist_ok=True)
    for relative in (
        "source/video", "transcript", "topics", "presentation", "analysis",
        "marketing", "clips",
    ):
        (group / relative).mkdir(parents=True, exist_ok=True)

    metadata = group / "seminar.yaml"
    if not metadata.exists():
        title = group.name.replace("\\", "\\\\").replace('"', '\\"')
        metadata.write_text(
            f'title: "{title}"\nlanguage: ru\n\nvideos: []\n\ndocuments: []\n',
            encoding="utf-8",
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare SeminarText group sources")
    parser.add_argument("sources", nargs="+", help="Media files or directories")
    parser.add_argument("--output", help="Persistent group directory")
    parser.add_argument("--list", action="store_true", help="Do not change files")
    parser.add_argument("--result", required=True, help="JSON result path")
    args = parser.parse_args()

    group = Path(args.output).expanduser() if args.output else default_group_dir(args.sources[0])
    group = group.resolve()
    registry = group / "sources.json"
    if group.exists() and not registry.is_file() and not args.list:
        raise RuntimeError(
            f"Ошибка: папка уже существует, но это не группа SeminarText: {group}. "
            "Выберите пустую папку или --output с существующей группой."
        )

    known = existing_hashes(group)
    candidates = discover(args.sources, group)
    additions: list[dict[str, str]] = []
    seen_hashes = set(known)
    duplicates = 0
    for source in candidates:
        digest = sha256(source)
        if digest in known:
            duplicates += 1
            print(f"[ПОВТОР] {source} -> {known[digest]}")
        elif digest in seen_hashes:
            duplicates += 1
            print(f"[ПОВТОР] {source} -> дубликат в текущем выборе")
        else:
            seen_hashes.add(digest)
            additions.append({"path": str(source), "sha256": digest})
            print(f"[НОВЫЙ] {source}")

    print()
    print(f"Найдено медиафайлов: {len(candidates)}")
    print(f"Новых уникальных: {len(additions)}")
    print(f"Повторов: {duplicates}")
    print(f"Группа: {group}")

    if not args.list:
        initialise_group(group)

    result = {
        "schema_version": 1,
        "group_dir": str(group),
        "list_only": args.list,
        "candidate_count": len(candidates),
        "duplicate_count": duplicates,
        "new_sources": additions,
    }
    Path(args.result).write_text(json.dumps(result, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(exc, file=sys.stderr)
        raise SystemExit(2)
