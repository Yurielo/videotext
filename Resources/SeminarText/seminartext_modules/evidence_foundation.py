#!/usr/bin/env python3
"""Project-level Evidence Foundation lifecycle and validation commands.

The service is deliberately alignment-only: it consumes a verified transcript
and native alignment evidence, never invokes ASR and never rewrites text.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from schemas.validate_canonical_evidence_v1 import validate_bundle  # noqa: E402


ID_RE = re.compile(r"[^a-z0-9]+")
ZERO_SHA256 = "0" * 64
ACCEPTED_MODEL = "jonatasgrosman/wav2vec2-large-xlsr-53-russian"
ACCEPTED_MODEL_REVISION = "2329100508896c6d9b157019803ab5601e6f3406"
ACCEPTED_MODEL_SHA256 = "d1cdb1a7921de7d363f967a9b0101a713602e109dba62b6f3f9ae2e0b2df0c1c"


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def stable_id(value: str, prefix: str) -> str:
    slug = ID_RE.sub("_", value.lower()).strip("_") or "item"
    return f"{prefix}_{slug}"[:120]


def project_root(value: str | Path) -> Path:
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise ValueError(f"project directory not found: {path}")
    return path


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"{label} cannot be read: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object")
    return value


def atomic_write_json(path: Path, value: Any, *, overwrite: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and not overwrite:
        raise FileExistsError(f"refusing to overwrite immutable artifact: {path}")
    payload = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(payload, encoding="utf-8")
    temporary.replace(path)


def canonical_payload(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def source_record(project: Path, source_id: str) -> tuple[dict[str, Any], str]:
    registry_path = project / "sources.json"
    registry = load_json(registry_path, "sources.json")
    for item in [*registry.get("videos", []), *registry.get("documents", [])]:
        if item.get("source_id") == source_id:
            return item, stable_id(source_id, "source")
    raise ValueError(f"source_id not found in sources.json: {source_id}")


def media_path(project: Path, source: dict[str, Any], override: str | None) -> Path:
    if override:
        path = Path(override).expanduser().resolve()
    else:
        relative = source.get("file")
        if not relative:
            raise ValueError("source has no local media file; pass --media explicitly (YouTube is not downloaded implicitly)")
        path = (project / relative).resolve()
    if not path.is_file():
        raise ValueError(f"source media not found: {path}")
    return path


def revisions_index(project: Path) -> Path:
    return project / "evidence" / "transcript_revisions" / "index.json"


def load_revision(project: Path, revision_id: str) -> dict[str, Any]:
    path = project / "evidence" / "transcript_revisions" / f"{revision_id}.json"
    revision = load_json(path, f"transcript revision {revision_id}")
    if revision.get("revision_id") != revision_id:
        raise ValueError("transcript revision id does not match its filename")
    return revision


def parse_ranges(values: list[str], text_length: int) -> list[dict[str, int]]:
    parsed: list[dict[str, int]] = []
    for value in values:
        match = re.fullmatch(r"(\d+):(\d+)", value)
        if not match:
            raise ValueError(f"invalid --verified-range {value!r}; expected START:END")
        start, end = (int(part) for part in match.groups())
        if end <= start or end > text_length:
            raise ValueError(f"invalid verification range {value!r}")
        if parsed and start < parsed[-1]["char_end"]:
            raise ValueError("verification ranges must be sorted and non-overlapping")
        parsed.append({"char_start": start, "char_end": end})
    return parsed


def changed_outside_ranges(parent_text: str, text: str, ranges: list[dict[str, int]]) -> bool:
    if parent_text == text:
        return False
    matcher = difflib.SequenceMatcher(a=parent_text, b=text, autojunk=False)
    allowed = [(item["char_start"], item["char_end"]) for item in ranges]
    for tag, a_start, a_end, _b_start, _b_end in matcher.get_opcodes():
        if tag == "equal":
            continue
        if not any(a_start >= start and a_end <= end for start, end in allowed):
            return True
    return False


def promote_transcript(args: argparse.Namespace) -> int:
    project = project_root(args.project)
    source, source_canonical_id = source_record(project, args.source_id)
    text_path = Path(args.text_file).expanduser().resolve()
    if not text_path.is_file():
        raise ValueError(f"transcript text not found: {text_path}")
    text = text_path.read_text(encoding="utf-8")
    text_hash = sha256_bytes(text.encode("utf-8"))
    index_path = revisions_index(project)
    index = load_json(index_path, "transcript revision index") if index_path.is_file() else {"schema_version": 1, "revisions": []}
    existing = [item for item in index.get("revisions", []) if item.get("source_id") == source_canonical_id]
    revision_number = max((int(item.get("revision_number", 0)) for item in existing), default=0) + 1
    parent = existing[-1] if existing else None
    if args.parent_revision_id:
        parent = next((item for item in existing if item.get("revision_id") == args.parent_revision_id), None)
        if parent is None:
            raise ValueError(f"parent revision not found for source: {args.parent_revision_id}")
        revision_number = max((int(item.get("revision_number", 0)) for item in existing), default=0) + 1
    if parent and "canonical_text" not in parent:
        parent = load_revision(project, parent["revision_id"])
    revision_id = f"transcript_revision_{source_canonical_id.removeprefix('source_')}_r{revision_number}"
    if any(item.get("revision_id") == revision_id for item in existing):
        raise ValueError(f"revision already exists: {revision_id}; use a new parent or inspect the existing immutable file")
    verification_state = args.verification_state or ("fully_human_verified" if args.state == "verified" else "machine_unverified")
    ranges = parse_ranges(args.verified_range, len(text))
    if verification_state == "fully_human_verified" and not args.reviewer:
        raise ValueError("verified promotion requires --reviewer authority")
    if verification_state == "machine_unverified" and (args.reviewer or ranges):
        raise ValueError("machine_unverified promotion cannot include reviewer or verification ranges")
    if verification_state == "selectively_verified" and (not args.reviewer or not ranges or not parent):
        raise ValueError("selectively_verified promotion requires --parent-revision-id, --reviewer, and --verified-range")
    if verification_state == "selectively_verified" and parent and changed_outside_ranges(parent.get("canonical_text", ""), text, ranges):
        raise ValueError("correction changes text outside the declared verification ranges")
    if args.state == "verified" and verification_state != "fully_human_verified":
        raise ValueError("verified state requires fully_human_verified provenance")
    if verification_state == "fully_human_verified":
        ranges = [{"char_start": 0, "char_end": len(text)}]
    authority = "authoritative" if verification_state == "fully_human_verified" else "candidate"
    lifecycle = "verified" if verification_state == "fully_human_verified" else ("active" if args.state == "review_required" else "draft")
    revision_kind = "verified" if verification_state == "fully_human_verified" else ("corrected" if verification_state == "selectively_verified" else "asr")
    provenance = {
        "origin": "human_verified" if verification_state == "fully_human_verified" else ("human_corrected" if verification_state == "selectively_verified" and parent and text != parent.get("canonical_text") else "machine_generated"),
        "method": args.generation_method,
        "verification_state": verification_state,
        "verification_ranges": ranges,
        "reviewer": args.reviewer,
    }
    revision = {
        "revision_id": revision_id,
        "source_id": source_canonical_id,
        "revision_number": revision_number,
        "revision_kind": revision_kind,
        "parent_revision_id": parent.get("revision_id") if parent else None,
        "parent_text_sha256": parent.get("text_sha256") if parent else None,
        "canonical_text": text,
        "text_sha256": text_hash,
        "authority": authority,
        "reviewer_authority": args.reviewer,
        "state": args.state,
        "lifecycle_status": lifecycle,
        "transcript_provenance": provenance,
        "source_registry_id": args.source_id,
        "source_title": source.get("title", ""),
    }
    atomic_write_json(project / "evidence" / "transcript_revisions" / f"{revision_id}.json", revision)
    index.setdefault("revisions", []).append({key: revision[key] for key in ("revision_id", "source_id", "revision_number", "text_sha256", "state", "authority")})
    index["revisions"] = sorted(index["revisions"], key=lambda item: (item.get("source_id", ""), item.get("revision_number", 0)))
    atomic_write_json(index_path, index, overwrite=True)
    print(json.dumps({"status": args.state, "revision_id": revision_id, "text_sha256": text_hash, "transcript_provenance": provenance}, ensure_ascii=False, sort_keys=True))
    return 0


def read_alignment(path: Path) -> dict[str, Any]:
    payload = load_json(path, "alignment evidence")
    words = payload.get("words")
    if not isinstance(words, list):
        raise ValueError("alignment evidence must contain a words array")
    return payload


def map_words(text: str, evidence_words: list[dict[str, Any]]) -> list[dict[str, Any] | None]:
    tokens = list(re.finditer(r"\S+", text))
    mapped: list[dict[str, Any] | None] = []
    if any("sequence" in item for item in evidence_words):
        if len(evidence_words) != len(tokens):
            raise ValueError("positional alignment must preserve every transcript token")
        for sequence, (token, item) in enumerate(zip(tokens, evidence_words)):
            if item.get("sequence") != sequence or item.get("word") != token.group():
                raise ValueError("positional alignment token identity differs")
            mapped.append(None if item.get("alignment_status") == "unaligned" else item)
        return mapped
    cursor = 0
    for token in tokens:
        item = evidence_words[cursor] if cursor < len(evidence_words) else None
        if isinstance(item, dict) and item.get("word") == token.group(0):
            mapped.append(item)
            cursor += 1
        else:
            mapped.append(None)
    if cursor != len(evidence_words):
        raise ValueError(f"alignment evidence is not an exact subsequence; first extra token: {evidence_words[cursor].get('word')!r}")
    return mapped


def build_bundle(project: Path, revision: dict[str, Any], source: dict[str, Any], source_id: str, media: Path, evidence: dict[str, Any], run_id: str, config_sha: str, model: str, model_revision: str, model_sha: str, aligner: str, aligner_version: str) -> tuple[dict[str, Any], dict[str, Any]]:
    project_id = stable_id(project.name, "project")
    source_canonical_id = revision["source_id"]
    revision_id = revision["revision_id"]
    text = revision["canonical_text"]
    tokens = list(re.finditer(r"\S+", text))
    mapped = map_words(text, evidence["words"])
    duration = source.get("duration_seconds")
    if duration is None:
        ends = [item.get("end") for item in mapped if item and isinstance(item.get("end"), (int, float))]
        duration = max(ends, default=0) + 1
    if not isinstance(duration, (int, float)) or duration <= 0:
        raise ValueError("timed source requires --duration or sources.json duration_seconds")
    cue_id = f"{revision_id}:cue:000000"
    run = {
        "id": run_id,
        "source_id": source_canonical_id,
        "source_registry_id": source_id,
        "source_content_sha256": sha256_file(media),
        "transcript_revision_id": revision_id,
        "transcript_text_sha256": revision["text_sha256"],
        "aligner": aligner,
        "aligner_version": aligner_version,
        "model": model,
        "model_revision": model_revision,
        "model_sha256": model_sha,
        "config_sha256": config_sha,
        "status": "valid",
        "review_status": "verified" if revision.get("transcript_provenance", {}).get("verification_state") == "fully_human_verified" and not any(item is None for item in mapped) else "review_required",
        "unaligned_sequences": [i for i, item in enumerate(mapped) if item is None],
        "input_policy": "transcript_only_no_asr",
    }
    canonical_run = {key: run[key] for key in (
        "id", "source_id", "source_content_sha256", "transcript_revision_id",
        "transcript_text_sha256", "aligner", "aligner_version", "model",
        "model_revision", "model_sha256", "config_sha256", "status"
    )}
    words = []
    for sequence, (token, aligned) in enumerate(zip(tokens, mapped)):
        if aligned is None:
            start = end = confidence = None
            status = "unaligned"
            provenance = {"kind": "unavailable", "alignment_run_id": None, "method": None}
            flags = ["unaligned_review_required"]
        else:
            start, end = aligned.get("start"), aligned.get("end")
            confidence = aligned.get("score")
            if not isinstance(start, (int, float)) or not isinstance(end, (int, float)) or end <= start or start < 0 or end > duration:
                raise ValueError(f"alignment interval invalid for token {sequence}")
            status = "aligned"
            provenance = {"kind": "forced_alignment", "alignment_run_id": run_id, "method": "native_word_intervals"}
            flags = []
        words.append({
            "id": f"{revision_id}:word:{sequence:06d}",
            "source_id": source_canonical_id,
            "transcript_revision_id": revision_id,
            "sequence": sequence,
            "char_start": token.start(),
            "char_end": token.end(),
            "text": token.group(0),
            "normalized_text": None,
            "source_cue_ids": [cue_id],
            "start_seconds": start,
            "end_seconds": end,
            "alignment_status": status,
            "confidence": confidence,
            "speaker_id": None,
            "timing_provenance": provenance,
            "qa_flags": flags,
            "lifecycle_status": "verified" if revision.get("transcript_provenance", {}).get("verification_state") == "fully_human_verified" or (revision.get("authority") == "authoritative" and revision.get("lifecycle_status") == "verified") else "active",
        })
    segments = []
    for sequence, offset in enumerate(range(0, len(words), 50)):
        group = words[offset : offset + 50]
        segments.append({"id": f"benchmark_segment_{revision_id.removeprefix('transcript_revision_')}_{sequence:06d}", "transcript_revision_id": revision_id, "sequence": sequence, "word_start_id": group[0]["id"], "word_end_id": group[-1]["id"], "word_count": len(group), "lifecycle_status": "verified" if revision.get("transcript_provenance", {}).get("verification_state") == "fully_human_verified" else "active"})
    bundle = {
        "schema_version": "1.0.0",
        "artifact_type": "seminartext.canonical_evidence",
        "artifact_id": stable_id(f"{project_id}_{revision_id}", "artifact"),
        "project": {"id": project_id, "title": project.name, "lifecycle_status": "active"},
        "sources": [{"id": source_canonical_id, "project_id": project_id, "sequence": 0, "kind": "video" if source.get("type") in {"youtube", "local"} or source.get("file", "").lower().endswith((".mp4", ".mov", ".mkv")) else "other", "title": source.get("title") or source_id, "content_sha256": run["source_content_sha256"], "duration_seconds": duration, "lifecycle_status": "active"}],
        "transcript_revisions": [{"id": revision_id} | {key: revision[key] for key in ("source_id", "revision_number", "revision_kind", "parent_revision_id", "canonical_text", "text_sha256", "authority", "lifecycle_status", "transcript_provenance")}],
        "cues": [{"id": cue_id, "transcript_revision_id": revision_id, "sequence": 0, "char_start": 0, "char_end": len(text), "text": text, "source_locator": {"type": "time_interval", "start_seconds": 0, "end_seconds": duration}, "lifecycle_status": "verified" if revision.get("transcript_provenance", {}).get("verification_state") == "fully_human_verified" else "active"}],
        "alignment_runs": [canonical_run],
        "words": words,
        "benchmark_segments": segments,
        "topics": [],
        "evidence_refs": [],
    }
    if "cues" in evidence:
        # Optional native SRT cue projection from the media adapter. No timing
        # is inferred: ranges and cue text come from the retained original SRT.
        cues, cursor = [], 0
        for sequence, item in enumerate(evidence["cues"]):
            cue_text = item["text"]
            start = text.find(cue_text, cursor)
            if start < 0 or text[cursor:start].strip():
                raise ValueError("native cue text differs from TranscriptRevision")
            cursor = start
            cue = dict(bundle["cues"][0], id=f"{revision_id}:cue:{sequence:06d}", sequence=sequence,
                       char_start=cursor, char_end=cursor+len(cue_text), text=cue_text,
                       source_locator={"type":"time_interval", "start_seconds":item["start"], "end_seconds":item["end"]})
            cues.append(cue); cursor += len(cue_text)
        if text[min(cursor,len(text)):].strip() or not cues:
            raise ValueError("native cues do not partition TranscriptRevision")
        bundle["cues"] = cues
        for word in bundle["words"]:
            selected = [cue["id"] for cue in cues if cue["char_start"] <= word["char_start"] and word["char_end"] <= cue["char_end"]]
            if len(selected) != 1:
                raise ValueError("Word does not belong to one native cue")
            word["source_cue_ids"] = selected
    errors = validate_bundle(bundle)
    if errors:
        raise ValueError("canonical cross-record validation failed:\n" + "\n".join(errors))
    return bundle, run


def _source_order(project: Path) -> dict[str, int]:
    registry = load_json(project / "sources.json", "sources.json")
    records = [*registry.get("videos", []), *registry.get("documents", [])]
    ordered = sorted(
        records,
        key=lambda item: (int(item.get("order", 10**9)), str(item.get("source_id", ""))),
    )
    return {
        stable_id(str(item["source_id"]), "source"): index
        for index, item in enumerate(ordered)
        if item.get("source_id")
    }


def compose_project_bundle(project: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Compose retained source bundles into one deterministic project artifact."""

    evidence_root = project / "evidence"
    paths = sorted((evidence_root / "sources").glob("*/canonical_bundle.json"))
    if not paths:
        raise ValueError("no retained source-scoped Canonical Evidence bundles found")

    order = _source_order(project)
    loaded: list[tuple[Path, dict[str, Any]]] = []
    project_record: dict[str, Any] | None = None
    source_ids: set[str] = set()
    source_inventory: list[dict[str, Any]] = []
    for path in paths:
        bundle = load_json(path, f"source bundle {path.parent.name}")
        source_errors = validate_bundle(bundle)
        if source_errors:
            raise ValueError(
                f"source bundle is invalid: {path}\n" + "\n".join(source_errors)
            )
        if len(bundle["sources"]) != 1:
            raise ValueError(f"source bundle must contain exactly one source: {path}")
        source_id = bundle["sources"][0]["id"]
        if source_id != path.parent.name:
            raise ValueError(
                f"source bundle directory identity mismatch: {path.parent.name} != {source_id}"
            )
        if source_id in source_ids:
            raise ValueError(f"duplicate retained source identity: {source_id}")
        source_ids.add(source_id)
        if source_id not in order:
            raise ValueError(f"retained source is not present in sources.json: {source_id}")
        source_manifest_path = path.parent / "manifest.json"
        if not source_manifest_path.is_file():
            raise ValueError(f"retained source manifest is missing: {source_manifest_path}")
        source_manifest = load_json(source_manifest_path, f"source manifest {source_id}")
        if source_manifest.get("bundle_path") != path.relative_to(project).as_posix():
            raise ValueError(f"source manifest bundle path mismatch: {source_id}")
        if source_manifest.get("bundle_sha256") != sha256_file(path):
            raise ValueError(f"source manifest bundle hash mismatch: {source_id}")
        revision_ids = {item["id"] for item in bundle["transcript_revisions"]}
        run_ids = {item["id"] for item in bundle["alignment_runs"]}
        if source_manifest.get("transcript_revision_id") not in revision_ids:
            raise ValueError(f"source manifest revision mismatch: {source_id}")
        if source_manifest.get("alignment_run_id") not in run_ids:
            raise ValueError(f"source manifest alignment run mismatch: {source_id}")
        if source_manifest.get("source_content_sha256") != bundle["sources"][0]["content_sha256"]:
            raise ValueError(f"source manifest content hash mismatch: {source_id}")
        retained_revision_path = (
            path.parent
            / "revisions"
            / source_manifest["transcript_revision_id"]
            / "canonical_bundle.json"
        )
        if not retained_revision_path.is_file() or sha256_file(retained_revision_path) != sha256_file(path):
            raise ValueError(f"current source bundle is not the retained immutable revision: {source_id}")
        if project_record is None:
            project_record = bundle["project"]
        elif bundle["project"] != project_record:
            raise ValueError(f"source bundle project identity mismatch: {path}")
        source_inventory.append(
            {
                "bundle_path": path.relative_to(project).as_posix(),
                "bundle_sha256": sha256_file(path),
                "source_id": source_id,
            }
        )
        loaded.append((path, bundle))

    assert project_record is not None
    loaded.sort(key=lambda item: (order[item[1]["sources"][0]["id"]], item[0].as_posix()))
    collection_names = (
        "transcript_revisions",
        "cues",
        "alignment_runs",
        "words",
        "benchmark_segments",
        "topics",
        "evidence_refs",
    )
    aggregate: dict[str, Any] = {
        "schema_version": "1.0.0",
        "artifact_type": "seminartext.canonical_evidence",
        "artifact_id": stable_id(f"{project_record['id']}_multi_source_v1", "artifact"),
        "project": project_record,
        "sources": [],
        **{name: [] for name in collection_names},
    }
    for sequence, (_, bundle) in enumerate(loaded):
        aggregate["sources"].append(bundle["sources"][0] | {"sequence": sequence})
        for name in collection_names:
            aggregate[name].extend(bundle[name])

    sort_keys = {
        "transcript_revisions": lambda item: (item["source_id"], item["revision_number"], item["id"]),
        "cues": lambda item: (item["transcript_revision_id"], item["sequence"], item["id"]),
        "alignment_runs": lambda item: (item["transcript_revision_id"], item["id"]),
        "words": lambda item: (item["transcript_revision_id"], item["sequence"], item["id"]),
        "benchmark_segments": lambda item: (item["transcript_revision_id"], item["sequence"], item["id"]),
        "topics": lambda item: (item["transcript_revision_id"], item["topic_set_id"], item["sequence"], item["id"]),
        "evidence_refs": lambda item: item["id"],
    }
    for name, key in sort_keys.items():
        aggregate[name] = sorted(aggregate[name], key=key)

    errors = validate_bundle(aggregate)
    if errors:
        raise ValueError(
            "multi-source Canonical Evidence composition failed:\n" + "\n".join(errors)
        )
    return aggregate, sorted(source_inventory, key=lambda item: order[item["source_id"]])


def write_project_aggregate(project: Path) -> tuple[Path, dict[str, Any]]:
    bundle, source_inventory = compose_project_bundle(project)
    bundle_path = project / "evidence" / "canonical_bundle.json"
    payload = canonical_payload(bundle)
    atomic_write_json(bundle_path, bundle, overwrite=True)
    timeline = {
        "schema_version": "1.0.0",
        "source": "canonical_bundle.json",
        "source_count": len(bundle["sources"]),
        "transcript_revision_ids": [item["id"] for item in bundle["transcript_revisions"]],
        "alignment_run_ids": [item["id"] for item in bundle["alignment_runs"]],
        "words": bundle["words"],
    }
    atomic_write_json(project / "evidence" / "word_timeline.json", timeline, overwrite=True)
    registry = load_json(project / "sources.json", "sources.json")
    registered = [*registry.get("videos", []), *registry.get("documents", [])]
    composed_ids = {item["source_id"] for item in source_inventory}
    registry_coverage = [
        {
            "source_registry_id": item["source_id"],
            "canonical_source_id": stable_id(str(item["source_id"]), "source"),
            "evidence_status": (
                "COMPOSED"
                if stable_id(str(item["source_id"]), "source") in composed_ids
                else "EVIDENCE_UNAVAILABLE"
            ),
        }
        for item in sorted(
            registered,
            key=lambda value: (int(value.get("order", 10**9)), str(value.get("source_id", ""))),
        )
    ]
    manifest = {
        "schema_version": 2,
        "artifact_type": "seminartext.project_evidence_manifest",
        "bundle_path": "evidence/canonical_bundle.json",
        "bundle_sha256": sha256_bytes(payload),
        "source_count": len(bundle["sources"]),
        "registered_source_count": len(registry_coverage),
        "all_registered_sources_composed": all(
            item["evidence_status"] == "COMPOSED" for item in registry_coverage
        ),
        "registry_coverage": registry_coverage,
        "sources": source_inventory,
    }
    atomic_write_json(project / "evidence" / "manifest.json", manifest, overwrite=True)
    return bundle_path, manifest


def align_project(args: argparse.Namespace) -> int:
    project = project_root(args.project)
    source, source_canonical_id = source_record(project, args.source_id)
    revision = load_revision(project, args.revision_id)
    if revision.get("lifecycle_status") not in {"active", "verified"} or revision.get("authority") not in {"candidate", "authoritative"}:
        raise ValueError("alignment requires an authoritative verified or active assured TranscriptRevision; provisional text may not be aligned")
    media = media_path(project, source, args.media)
    evidence_path = Path(args.alignment_json).expanduser().resolve() if args.alignment_json else None
    if evidence_path is None or not evidence_path.is_file():
        raise ValueError("native alignment evidence is required; WhisperX ASR is never run as a semantic replacement")
    evidence = read_alignment(evidence_path)
    config = evidence.get("config", {"mode": "native_alignment_evidence"})
    config_sha = sha256_bytes(canonical_json(config))
    model = evidence.get("model", ACCEPTED_MODEL)
    model_revision = evidence.get("model_revision", ACCEPTED_MODEL_REVISION)
    model_sha = evidence.get("model_sha256", ACCEPTED_MODEL_SHA256)
    if not isinstance(model_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", model_sha):
        raise ValueError("alignment model_sha256 must be lowercase SHA-256")
    evidence_hash = sha256_file(evidence_path)
    run_id = f"alignment_{source_canonical_id.removeprefix('source_')}_{revision['revision_id'].removeprefix('transcript_revision_')}_{evidence_hash[:12]}"
    run_path = project / "evidence" / "alignment_runs" / f"{run_id}.json"
    source_root = project / "evidence" / "sources" / source_canonical_id
    revision_bundle_path = source_root / "revisions" / revision["revision_id"] / "canonical_bundle.json"
    source_bundle_path = source_root / "canonical_bundle.json"
    resumed = run_path.is_file() and revision_bundle_path.is_file()
    bundle, run = build_bundle(project, revision, source, args.source_id, media, evidence, run_id, config_sha, model, model_revision, model_sha, evidence.get("aligner", "whisperx"), evidence.get("aligner_version", "3.8.6"))
    # Published source projections may only be replaced when their prior
    # manifest still validates, or when they already equal this exact pending
    # deterministic import. Never overwrite a corrupted published projection.
    pending_projection = False
    published_manifests = list((project / "evidence" / "sources").glob("*/manifest.json"))
    for manifest_path in published_manifests:
        published_manifest = load_json(manifest_path, "source evidence manifest")
        published_path = project / published_manifest["bundle_path"]
        published = load_json(published_path, "published source evidence")
        if sha256_bytes(canonical_payload(published)) != published_manifest["bundle_sha256"]:
            if published_path != source_bundle_path or published != bundle:
                raise ValueError("source manifest bundle hash mismatch")
            pending_projection = True
    pending_projection = pending_projection or (source_bundle_path.exists() and not (source_root / "manifest.json").exists())
    if published_manifests and not pending_projection:
        compose_project_bundle(project)  # preserve existing cross-record diagnostics
    if source_bundle_path.exists() and not (source_root / "manifest.json").exists():
        if load_json(source_bundle_path, "pending source evidence") != bundle:
            raise ValueError("incomplete source projection differs from current import")
    # Recover an interrupted deterministic import without deleting or changing
    # any retained immutable record. Existing bytes must equal recomputation.
    for destination, expected in ((run_path, run), (revision_bundle_path, bundle)):
        if destination.exists():
            if load_json(destination, "retained alignment") != expected:
                raise ValueError("incomplete retained alignment differs from current inputs")
        else:
            atomic_write_json(destination, expected)
    atomic_write_json(source_bundle_path, bundle, overwrite=True)
    source_timeline = {
        "schema_version": "1.0.0",
        "source": "canonical_bundle.json",
        "transcript_revision_id": revision["revision_id"],
        "alignment_run_id": run_id,
        "words": bundle["words"],
    }
    atomic_write_json(source_root / "word_timeline.json", source_timeline, overwrite=True)
    source_payload = canonical_payload(bundle)
    source_manifest = {
        "schema_version": 1,
        "bundle_path": source_bundle_path.relative_to(project).as_posix(),
        "bundle_sha256": sha256_bytes(source_payload),
        "transcript_revision_id": revision["revision_id"],
        "alignment_run_id": run_id,
        "source_content_sha256": run["source_content_sha256"],
        "review_status": run["review_status"],
    }
    atomic_write_json(source_root / "manifest.json", source_manifest, overwrite=True)
    bundle_path, manifest = write_project_aggregate(project)
    bindings_path = project / "evidence" / "output_bindings.json"
    previous_bindings = (
        load_json(bindings_path, "output bindings").get("bindings", [])
        if bindings_path.is_file()
        else []
    )
    by_path = {item["path"]: item for item in previous_bindings if isinstance(item, dict) and item.get("path")}
    for candidate in (
        project / "transcript" / args.source_id / "transcript.txt",
        project / "transcript" / args.source_id / "transcript.srt",
        project / "transcript" / f"{args.source_id}.json",
        project / "transcript" / "combined.json",
    ):
        if candidate.is_file():
            relative = candidate.relative_to(project).as_posix()
            by_path[relative] = {
                "path": relative,
                "sha256": sha256_file(candidate),
                "transcript_revision_id": revision["revision_id"],
                "canonical_bundle_sha256": manifest["bundle_sha256"],
            }
    for binding in by_path.values():
        binding["canonical_bundle_sha256"] = manifest["bundle_sha256"]
    atomic_write_json(
        bindings_path,
        {"schema_version": 1, "bindings": sorted(by_path.values(), key=lambda item: item["path"])},
        overwrite=True,
    )
    print(json.dumps({"status": "RESUMED" if resumed else run["review_status"], "alignment_run_id": run_id, "bundle": str(bundle_path), "unaligned_words": run["unaligned_sequences"]}, ensure_ascii=False, sort_keys=True))
    return 0


def evidence_check(args: argparse.Namespace) -> int:
    project = project_root(args.project)
    bundle_path = Path(args.bundle).expanduser().resolve() if args.bundle else project / "evidence" / "canonical_bundle.json"
    try:
        bundle = load_json(bundle_path, "canonical bundle")
    except ValueError as exc:
        result = {"status": "FAIL", "errors": [str(exc)], "bundle": str(bundle_path)}
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) if args.json else "FAIL: " + str(exc))
        return 1
    errors = validate_bundle(bundle)
    manifest_path = project / "evidence" / "manifest.json"
    if manifest_path.is_file():
        manifest = load_json(manifest_path, "evidence manifest")
        actual_hash = sha256_file(bundle_path)
        if manifest.get("bundle_sha256") != actual_hash:
            errors.append("manifest bundle_sha256 does not match canonical bundle")
        if manifest.get("transcript_revision_id") is not None and manifest.get("transcript_revision_id") not in {item.get("id") for item in bundle.get("transcript_revisions", [])}:
            errors.append("manifest transcript_revision_id is not present in canonical bundle")
    bindings_path = project / "evidence" / "output_bindings.json"
    if bindings_path.is_file():
        bindings = load_json(bindings_path, "output bindings")
        bundle_revision_ids = {item.get("id") for item in bundle.get("transcript_revisions", [])}
        for binding in bindings.get("bindings", []):
            output = project / binding.get("path", "")
            if not output.is_file():
                errors.append(f"bound output is missing: {binding.get('path')}")
                continue
            if binding.get("sha256") != sha256_file(output):
                errors.append(f"bound output hash mismatch: {binding.get('path')}")
            if binding.get("transcript_revision_id") not in bundle_revision_ids:
                errors.append(f"bound output references unknown revision: {binding.get('path')}")
            if binding.get("canonical_bundle_sha256") != sha256_file(bundle_path):
                errors.append(f"bound output canonical hash mismatch: {binding.get('path')}")
    schema_status = "SKIPPED_BY_OPTION"
    if not args.cross_record_only:
        try:
            from jsonschema import Draft202012Validator
            schema = json.loads((ROOT / "schemas" / "canonical_evidence_v1.schema.json").read_text(encoding="utf-8"))
            schema_errors = sorted(Draft202012Validator(schema).iter_errors(bundle), key=lambda item: list(item.path))
            errors.extend(f"JSON Schema: {error.message}" for error in schema_errors)
            schema_status = "PASS" if not schema_errors else "FAIL"
        except ImportError:
            errors.append("JSON Schema validator unavailable; install requirements-dev.txt in an isolated environment")
            schema_status = "UNAVAILABLE"
    result = {"status": "PASS" if not errors else "FAIL", "bundle": str(bundle_path), "cross_record": "PASS" if not validate_bundle(bundle) else "FAIL", "json_schema": schema_status, "errors": sorted(set(errors))}
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(f"{result['status']}: {bundle_path}")
        print(f"  cross-record={result['cross_record']} json-schema={schema_status}")
        for error in result["errors"]:
            print(f"  - {error}")
    return 0 if result["status"] == "PASS" else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    promote = sub.add_parser("promote-transcript")
    promote.add_argument("project")
    promote.add_argument("--source-id", required=True)
    promote.add_argument("--text-file", required=True)
    promote.add_argument("--state", choices=["provisional", "review_required", "verified", "superseded"], default="provisional")
    promote.add_argument("--reviewer")
    promote.add_argument("--parent-revision-id")
    promote.add_argument("--verification-state", choices=["machine_unverified", "selectively_verified", "fully_human_verified"])
    promote.add_argument("--verified-range", action="append", default=[])
    promote.add_argument("--generation-method", default="existing_machine_transcript_import")
    align = sub.add_parser("align")
    align.add_argument("project")
    align.add_argument("--source-id", required=True)
    align.add_argument("--revision-id", required=True)
    align.add_argument("--media")
    align.add_argument("--alignment-json")
    check = sub.add_parser("evidence-check")
    check.add_argument("project")
    check.add_argument("--bundle")
    check.add_argument("--cross-record-only", action="store_true")
    check.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "promote-transcript":
            return promote_transcript(args)
        if args.command == "align":
            return align_project(args)
        return evidence_check(args)
    except (ValueError, FileExistsError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
