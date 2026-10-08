#!/usr/bin/env python3
"""Compile explicit project knowledge into a safe Obsidian derived view.

The bridge is deliberately non-semantic: Topics, Concepts, Relations and
ReviewDecisions must be supplied explicitly.  It only validates references,
derives evidence quotes/locators from Canonical Evidence, and renders a
deterministic managed view.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from schemas.validate_canonical_evidence_v1 import validate_bundle  # noqa: E402
from schemas.validate_canonical_knowledge_v1 import validate_knowledge  # noqa: E402


INPUT_TYPE = "seminartext.project_knowledge_input"
INPUT_VERSION = "1.0.0"
INPUT_SCHEMA = ROOT / "schemas" / "project_knowledge_input_v1.schema.json"
EXPORT_VERSION = "1.0.0"
MANIFEST_NAME = ".seminartext-export.json"
ID_RE = re.compile(r"^[a-z][a-z0-9._:-]{2,127}$")
ALLOWED_TOPIC_ORIGINS = {"gold", "verified_manual", "semi_automatic"}
ALLOWED_COVERAGE = {"COVERED", "SEMANTIC_INPUT_UNAVAILABLE", "NOT_IN_SCOPE"}
RESOLVER_STATES = {"AVAILABLE", "MOVED", "PROJECT_MOVED", "MISSING", "RESOLVER_UNAVAILABLE"}
INPUT_KEYS = {
    "schema_version",
    "artifact_type",
    "artifact_id",
    "project",
    "seminars",
    "topics",
    "concepts",
    "relations",
    "review_decisions",
    "relation_type_registry",
    "topic_sources",
    "evidence",
    "coverage",
}


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"{label} cannot be read: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object")
    return value


def stable_id(value: str, prefix: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_") or "item"
    return f"{prefix}_{slug}"[:120]


def require_id(value: Any, path: str) -> str:
    if not isinstance(value, str) or ID_RE.fullmatch(value) is None:
        raise ValueError(f"{path}: invalid stable ID")
    return value


def require_exact_keys(value: Any, required: set[str], path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected object")
    missing = sorted(required - value.keys())
    unexpected = sorted(value.keys() - required)
    if missing or unexpected:
        raise ValueError(f"{path}: missing={missing} unexpected={unexpected}")
    return value


def project_relative(project: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(project.resolve()).as_posix()
    except ValueError as exc:
        raise ValueError(f"generated canonical artifact escapes project: {path}") from exc


def validate_input_shape(document: dict[str, Any]) -> None:
    try:
        from jsonschema import Draft202012Validator
    except ModuleNotFoundError as exc:
        raise ValueError(
            "jsonschema is required for project knowledge input validation; "
            "use the supported core/dev_test runtime"
        ) from exc
    schema = load_json(INPUT_SCHEMA, "project knowledge input schema")
    schema_errors = sorted(
        Draft202012Validator(schema).iter_errors(document),
        key=lambda error: (tuple(str(part) for part in error.path), error.message),
    )
    if schema_errors:
        raise ValueError(
            "project knowledge input schema validation failed:\n"
            + "\n".join(f"{error.json_path}: {error.message}" for error in schema_errors)
        )
    require_exact_keys(document, INPUT_KEYS, "$")
    if document["schema_version"] != INPUT_VERSION or document["artifact_type"] != INPUT_TYPE:
        raise ValueError("knowledge input must use seminartext.project_knowledge_input v1.0.0")
    require_id(document["artifact_id"], "$.artifact_id")
    for name in (
        "seminars",
        "topics",
        "concepts",
        "relations",
        "review_decisions",
        "relation_type_registry",
        "topic_sources",
        "evidence",
        "coverage",
    ):
        if not isinstance(document[name], list):
            raise ValueError(f"$.{name}: expected array")
    if not isinstance(document["project"], dict):
        raise ValueError("$.project: expected object")


def _index(records: list[dict[str, Any]], label: str) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for index, record in enumerate(records):
        if not isinstance(record, dict):
            raise ValueError(f"{label}[{index}]: expected object")
        item_id = require_id(record.get("id"), f"{label}[{index}].id")
        if item_id in result:
            raise ValueError(f"{label}: duplicate ID {item_id}")
        result[item_id] = record
    return result


def _word_span(
    evidence: dict[str, Any],
    words: dict[str, dict[str, Any]],
    revisions: dict[str, dict[str, Any]],
    sources: dict[str, dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, Any], str, list[str]]:
    required = {
        "id",
        "claim",
        "source_id",
        "transcript_revision_id",
        "word_start_id",
        "word_end_id",
    }
    require_exact_keys(evidence, required, f"$.evidence[{evidence.get('id', '?')}]")
    evidence_id = require_id(evidence["id"], "$.evidence.id")
    if not isinstance(evidence["claim"], str) or not evidence["claim"].strip():
        raise ValueError(f"{evidence_id}: claim must be a non-empty supplied string")
    source = sources.get(evidence["source_id"])
    revision = revisions.get(evidence["transcript_revision_id"])
    first = words.get(evidence["word_start_id"])
    last = words.get(evidence["word_end_id"])
    if source is None or revision is None or first is None or last is None:
        raise ValueError(f"{evidence_id}: orphan canonical evidence range")
    if revision["source_id"] != source["id"]:
        raise ValueError(f"{evidence_id}: transcript belongs to another source")
    if any(
        item["source_id"] != source["id"]
        or item["transcript_revision_id"] != revision["id"]
        for item in (first, last)
    ):
        raise ValueError(f"{evidence_id}: cross-source or cross-revision Word range")
    if last["sequence"] < first["sequence"]:
        raise ValueError(f"{evidence_id}: inverted Word range")
    selected = sorted(
        (
            item
            for item in words.values()
            if item["transcript_revision_id"] == revision["id"]
            and first["sequence"] <= item["sequence"] <= last["sequence"]
        ),
        key=lambda item: item["sequence"],
    )
    if [item["sequence"] for item in selected] != list(range(first["sequence"], last["sequence"] + 1)):
        raise ValueError(f"{evidence_id}: non-contiguous Word range")
    aligned = [item for item in selected if item["alignment_status"] != "unaligned"]
    if not aligned:
        raise ValueError(f"{evidence_id}: exact locator unavailable for fully unaligned range")
    if source["kind"] not in {"video", "audio"}:
        raise ValueError(f"{evidence_id}: Word-derived time locator is unsupported for {source['kind']}")
    locator = {
        "type": "time_interval",
        "start_seconds": aligned[0]["start_seconds"],
        "end_seconds": aligned[-1]["end_seconds"],
    }
    unaligned = [item["id"] for item in selected if item["alignment_status"] == "unaligned"]
    timing_status = "aligned_word_range" if not unaligned else "aligned_envelope_with_explicit_unaligned_words"
    return selected, locator, timing_status, unaligned


def compile_documents(
    project: Path,
    input_document: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any]]:
    validate_input_shape(input_document)
    canonical_path = project / "evidence" / "canonical_bundle.json"
    canonical = load_json(canonical_path, "project Canonical Evidence")
    canonical_errors = validate_bundle(canonical)
    if canonical_errors:
        raise ValueError("project Canonical Evidence is invalid:\n" + "\n".join(canonical_errors))
    if input_document["project"].get("id") != canonical["project"]["id"]:
        raise ValueError("knowledge input project ID does not match Canonical Evidence")

    sources = _index(canonical["sources"], "$.canonical.sources")
    revisions = _index(canonical["transcript_revisions"], "$.canonical.transcript_revisions")
    words = _index(canonical["words"], "$.canonical.words")
    segments = _index(canonical["benchmark_segments"], "$.canonical.benchmark_segments")
    topics = _index(input_document["topics"], "$.topics")
    concepts = _index(input_document["concepts"], "$.concepts")

    coverage: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(input_document["coverage"]):
        require_exact_keys(item, {"source_id", "status", "reason"}, f"$.coverage[{index}]")
        source_id = require_id(item["source_id"], f"$.coverage[{index}].source_id")
        if source_id not in sources:
            raise ValueError(f"$.coverage[{index}]: unknown source {source_id}")
        if source_id in coverage:
            raise ValueError(f"$.coverage: duplicate source {source_id}")
        if item["status"] not in ALLOWED_COVERAGE:
            raise ValueError(f"$.coverage[{index}]: unsupported status {item['status']}")
        if not isinstance(item["reason"], str) or not item["reason"].strip():
            raise ValueError(f"$.coverage[{index}].reason: required")
        coverage[source_id] = item
    if set(coverage) != set(sources):
        raise ValueError("coverage must name every canonical source exactly once")

    topic_sources: dict[str, dict[str, Any]] = {}
    canonical_topics: list[dict[str, Any]] = []
    for index, item in enumerate(input_document["topic_sources"]):
        require_exact_keys(
            item,
            {
                "topic_id",
                "topic_set_id",
                "sequence",
                "origin",
                "transcript_revision_id",
                "word_start_id",
                "word_end_id",
            },
            f"$.topic_sources[{index}]",
        )
        topic_id = require_id(item["topic_id"], f"$.topic_sources[{index}].topic_id")
        if topic_id not in topics or topic_id in topic_sources:
            raise ValueError(f"$.topic_sources[{index}]: missing or duplicate Topic {topic_id}")
        if item["origin"] not in ALLOWED_TOPIC_ORIGINS:
            raise ValueError(f"{topic_id}: Topic origin is not allowed: {item['origin']}")
        if not isinstance(item["sequence"], int) or item["sequence"] < 0:
            raise ValueError(f"{topic_id}: sequence must be a non-negative integer")
        require_id(item["topic_set_id"], f"{topic_id}.topic_set_id")
        revision = revisions.get(item["transcript_revision_id"])
        first, last = words.get(item["word_start_id"]), words.get(item["word_end_id"])
        if revision is None or first is None or last is None:
            raise ValueError(f"{topic_id}: orphan canonical Topic range")
        if first["transcript_revision_id"] != revision["id"] or last["transcript_revision_id"] != revision["id"]:
            raise ValueError(f"{topic_id}: cross-revision Topic range")
        selected_segments = sorted(
            (
                segment
                for segment in segments.values()
                if segment["transcript_revision_id"] == revision["id"]
                and words[segment["word_start_id"]]["sequence"] >= first["sequence"]
                and words[segment["word_end_id"]]["sequence"] <= last["sequence"]
            ),
            key=lambda segment: segment["sequence"],
        )
        if (
            not selected_segments
            or selected_segments[0]["word_start_id"] != first["id"]
            or selected_segments[-1]["word_end_id"] != last["id"]
        ):
            raise ValueError(f"{topic_id}: Topic range must align to complete BenchmarkSegments")
        knowledge_topic = topics[topic_id]
        scope = knowledge_topic.get("source_scope", {})
        expected_source_id = revision["source_id"]
        if scope.get("source_ids") != [expected_source_id] or scope.get("transcript_revision_ids") != [revision["id"]]:
            raise ValueError(f"{topic_id}: Canonical Knowledge source scope disagrees with Topic range")
        canonical_topics.append(
            {
                "id": topic_id,
                "transcript_revision_id": revision["id"],
                "topic_set_id": item["topic_set_id"],
                "sequence": item["sequence"],
                "title": knowledge_topic["title"],
                "benchmark_segment_ids": [segment["id"] for segment in selected_segments],
                "word_start_id": first["id"],
                "word_end_id": last["id"],
                "origin": item["origin"],
                "lifecycle_status": "verified" if item["origin"] in {"gold", "verified_manual"} else "active",
            }
        )
        topic_sources[topic_id] = item
    if set(topic_sources) != set(topics):
        raise ValueError("topic_sources must map every supplied Topic exactly once")

    source_topics = {source_id: [] for source_id in sources}
    for item in canonical_topics:
        source_topics[revisions[item["transcript_revision_id"]]["source_id"]].append(item["id"])
    for source_id, topic_ids in source_topics.items():
        expected = "COVERED" if topic_ids else coverage[source_id]["status"]
        if topic_ids and coverage[source_id]["status"] != "COVERED":
            raise ValueError(f"coverage for {source_id} hides supplied Topics")
        if not topic_ids and expected == "COVERED":
            raise ValueError(f"coverage for {source_id} claims COVERED without Topics")

    source_evidence_records: list[dict[str, Any]] = []
    canonical_evidence_refs: list[dict[str, Any]] = []
    seen_evidence: set[str] = set()
    for item in input_document["evidence"]:
        selected, locator, timing_status, unaligned = _word_span(item, words, revisions, sources)
        evidence_id = item["id"]
        if evidence_id in seen_evidence:
            raise ValueError(f"$.evidence: duplicate ID {evidence_id}")
        seen_evidence.add(evidence_id)
        revision = revisions[item["transcript_revision_id"]]
        source_evidence_records.append(
            {
                "id": evidence_id,
                "claim": item["claim"],
                "canonical_source_id": item["source_id"],
                "canonical_transcript_revision_id": revision["id"],
                "canonical_word_start_id": selected[0]["id"],
                "canonical_word_end_id": selected[-1]["id"],
                "quote": revision["canonical_text"][selected[0]["char_start"] : selected[-1]["char_end"]],
                "locator": locator,
                "timing_status": timing_status,
                "unaligned_word_ids": unaligned,
            }
        )
        canonical_evidence_refs.append(
            {
                "id": evidence_id,
                "project_id": canonical["project"]["id"],
                "source_id": item["source_id"],
                "transcript_revision_id": revision["id"],
                "target": {"entity_type": "word", "entity_id": selected[0]["id"]},
                "locator": locator,
                "lifecycle_status": "verified",
            }
        )

    referenced_evidence = {
        evidence_id
        for topic in topics.values()
        for evidence_id in topic.get("evidence_refs", [])
    } | {
        evidence_id
        for concept in concepts.values()
        for evidence_id in concept.get("evidence_refs", [])
    } | {
        evidence_id
        for relation in input_document["relations"]
        for evidence_id in relation.get("evidence_refs", [])
    }
    if referenced_evidence != seen_evidence:
        raise ValueError(
            "supplied Evidence and Knowledge references differ: "
            f"unreferenced={sorted(seen_evidence - referenced_evidence)} "
            f"missing={sorted(referenced_evidence - seen_evidence)}"
        )

    enriched = copy.deepcopy(canonical)
    if enriched["topics"] or enriched["evidence_refs"]:
        raise ValueError("project Canonical Evidence already contains semantic Topics/Evidence; explicit merge policy is required")
    enriched["artifact_id"] = stable_id(f"{canonical['project']['id']}_knowledge_bridge_v1", "artifact")
    enriched["topics"] = sorted(
        canonical_topics,
        key=lambda item: (item["transcript_revision_id"], item["topic_set_id"], item["sequence"], item["id"]),
    )
    enriched["evidence_refs"] = sorted(canonical_evidence_refs, key=lambda item: item["id"])
    enriched_errors = validate_bundle(enriched)
    if enriched_errors:
        raise ValueError("compiled Canonical Evidence is invalid:\n" + "\n".join(enriched_errors))

    source_evidence = {
        "schema_version": INPUT_VERSION,
        "artifact_type": "seminartext.project_knowledge_evidence",
        "artifact_id": stable_id(f"{input_document['artifact_id']}_evidence", "artifact"),
        "source_input_artifact_id": input_document["artifact_id"],
        "evidence": sorted(source_evidence_records, key=lambda item: item["id"]),
        "topics": [{"id": item_id} for item_id in sorted(topics)],
        "concepts": [{"id": item_id} for item_id in sorted(concepts)],
    }

    evidence_output = project / "knowledge" / "canonical_evidence.json"
    source_output = project / "knowledge" / "source_evidence.json"
    knowledge = {
        "schema_version": "1.0.0",
        "artifact_type": "seminartext.canonical_knowledge",
        "artifact_id": stable_id(f"{input_document['artifact_id']}_canonical_v1", "artifact"),
        "version": 1,
        "canonical_evidence": {
            "artifact_id": enriched["artifact_id"],
            "schema_version": enriched["schema_version"],
            "sha256": sha256_bytes(canonical_bytes(enriched)),
            "path": project_relative(project, evidence_output),
        },
        "source_evidence": {
            "artifact_id": source_evidence["artifact_id"],
            "schema_version": source_evidence["schema_version"],
            "sha256": sha256_bytes(canonical_bytes(source_evidence)),
            "path": project_relative(project, source_output),
        },
        "project": input_document["project"],
        "seminars": input_document["seminars"],
        "topics": input_document["topics"],
        "concepts": input_document["concepts"],
        "relations": input_document["relations"],
        "review_decisions": input_document["review_decisions"],
        "relation_type_registry": input_document["relation_type_registry"],
    }
    knowledge_errors = validate_knowledge(knowledge, enriched, source_evidence)
    if knowledge_errors:
        raise ValueError("compiled Canonical Knowledge is invalid:\n" + "\n".join(knowledge_errors))

    coverage_document = {
        "schema_version": 1,
        "artifact_type": "seminartext.project_knowledge_coverage",
        "project_id": canonical["project"]["id"],
        "full_seminar_coverage": all(item["status"] == "COVERED" for item in coverage.values()),
        "sources": [
            {
                **coverage[source["id"]],
                "topic_ids": sorted(source_topics[source["id"]]),
                "transcript_revision_ids": sorted(
                    item["id"] for item in canonical["transcript_revisions"] if item["source_id"] == source["id"]
                ),
                "word_count": sum(1 for item in canonical["words"] if item["source_id"] == source["id"]),
                "evidence_ids": sorted(
                    item["id"] for item in source_evidence_records if item["canonical_source_id"] == source["id"]
                ),
            }
            for source in canonical["sources"]
        ],
    }
    return enriched, source_evidence, knowledge, coverage_document


def load_resolver(project: Path, path: Path | None, sources: list[dict[str, Any]]) -> dict[str, str]:
    if path is None:
        return {source["id"]: "RESOLVER_UNAVAILABLE" for source in sources}
    document = load_json(path, "source resolver")
    require_exact_keys(document, {"schema_version", "sources"}, "$.resolver")
    if document["schema_version"] != 1 or not isinstance(document["sources"], dict):
        raise ValueError("source resolver must use schema_version 1 and a sources mapping")
    result: dict[str, str] = {}
    for source in sources:
        item = document["sources"].get(source["id"])
        if item is None:
            result[source["id"]] = "RESOLVER_UNAVAILABLE"
            continue
        if not isinstance(item, dict) or set(item) - {"state", "path", "content_sha256"}:
            raise ValueError(f"resolver entry is malformed: {source['id']}")
        state = item.get("state")
        if state not in RESOLVER_STATES:
            raise ValueError(f"resolver state is invalid for {source['id']}: {state}")
        if state == "AVAILABLE":
            relative = item.get("path")
            if not isinstance(relative, str) or Path(relative).is_absolute() or ".." in Path(relative).parts:
                raise ValueError(f"AVAILABLE resolver path must be project-relative: {source['id']}")
            resolved = (project / relative).resolve()
            if project.resolve() not in resolved.parents or not resolved.is_file():
                raise ValueError(f"AVAILABLE resolver target is unavailable: {source['id']}")
            expected_hash = item.get("content_sha256", source["content_sha256"])
            if sha256_file(resolved) != expected_hash or expected_hash != source["content_sha256"]:
                raise ValueError(f"AVAILABLE resolver hash mismatch: {source['id']}")
        result[source["id"]] = state
    unknown = sorted(set(document["sources"]) - {source["id"] for source in sources})
    if unknown:
        raise ValueError(f"resolver contains unknown sources: {unknown}")
    return result


def frontmatter(metadata: dict[str, Any]) -> str:
    return "---\n" + json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n---\n"


def safe_label(value: str) -> str:
    return value.replace("[", "(").replace("]", ")").replace("|", "-").replace("\n", " ")


def link(folder: str, item_id: str, label: str) -> str:
    return f"[[{folder}/{item_id}|{safe_label(label)}]]"


def bullets(values: list[str]) -> str:
    return "\n".join(f"- {value}" for value in values) if values else "- None"


def render_note(metadata: dict[str, Any], title: str, body: str) -> bytes:
    return (frontmatter(metadata) + f"\n# {title}\n\n{body.rstrip()}\n").encode("utf-8")


def build_vault(
    evidence: dict[str, Any],
    source_evidence: dict[str, Any],
    knowledge: dict[str, Any],
    coverage: dict[str, Any],
    resolver: dict[str, str],
) -> dict[str, bytes]:
    sources = {item["id"]: item for item in evidence["sources"]}
    seminars = {item["id"]: item for item in knowledge["seminars"]}
    topics = {item["id"]: item for item in knowledge["topics"]}
    concepts = {item["id"]: item for item in knowledge["concepts"]}
    evidence_records = {item["id"]: item for item in source_evidence["evidence"]}
    relations = {item["id"]: item for item in knowledge["relations"]}
    files: dict[str, bytes] = {}

    def meta(stable_id_value: str, note_type: str, status: str = "DERIVED") -> dict[str, Any]:
        return {
            "stable_id": stable_id_value,
            "note_type": note_type,
            "ownership_class": "MANAGED_GENERATED",
            "generated_by": "seminartext_project_obsidian_export",
            "export_schema_version": EXPORT_VERSION,
            "lifecycle_status": status,
            "canonical_knowledge_artifact_id": knowledge["artifact_id"],
            "canonical_knowledge_sha256": sha256_bytes(canonical_bytes(knowledge)),
        }

    start_links = [link("Seminars", item["id"], item["title"]) for item in knowledge["seminars"]]
    files["00_START_HERE.md"] = render_note(
        meta("view_start_here", "index"),
        knowledge["project"]["title"],
        "This vault is a disposable derived view. Canonical JSON remains authoritative.\n\n"
        "## Seminars\n\n" + bullets(start_links) + "\n\n## Coverage\n\n[[_meta/coverage|Coverage report]]",
    )

    for seminar in knowledge["seminars"]:
        topic_links = [link("Topics", item_id, topics[item_id]["title"]) for item_id in seminar["topic_refs"]]
        source_links = [link("Sources", item["id"], item["title"]) for item in evidence["sources"]]
        files[f"Seminars/{seminar['id']}.md"] = render_note(
            meta(seminar["id"], "seminar", seminar["status"]),
            seminar["title"],
            "## Sources\n\n" + bullets(source_links) + "\n\n## Topics\n\n" + bullets(topic_links),
        )

    topic_by_source = {source_id: [] for source_id in sources}
    for topic in topics.values():
        for source_id in topic["source_scope"]["source_ids"]:
            topic_by_source[source_id].append(topic)
    evidence_by_source = {source_id: [] for source_id in sources}
    for item in evidence_records.values():
        evidence_by_source[item["canonical_source_id"]].append(item)

    for source in evidence["sources"]:
        body = (
            f"- Canonical Source ID: `{source['id']}`\n"
            f"- Content SHA-256: `{source['content_sha256']}`\n"
            f"- Resolver state: `{resolver[source['id']]}`\n\n"
            "## Topics\n\n"
            + bullets([link("Topics", item["id"], item["title"]) for item in topic_by_source[source["id"]]])
            + "\n\n## Evidence\n\n"
            + bullets([link("Evidence", item["id"], item["claim"]) for item in evidence_by_source[source["id"]]])
        )
        source_meta = meta(source["id"], "source", source["lifecycle_status"])
        source_meta["resolver_state"] = resolver[source["id"]]
        files[f"Sources/{source['id']}.md"] = render_note(source_meta, source["title"], body)

    for topic in knowledge["topics"]:
        topic_meta = meta(topic["id"], "topic", topic["status"])
        topic_meta["source_ids"] = topic["source_scope"]["source_ids"]
        topic_meta["transcript_revision_ids"] = topic["source_scope"]["transcript_revision_ids"]
        body = (
            f"**Lifecycle:** `{topic['status']}`\n\n## Summary\n\n{topic['summary']}\n\n"
            "## Sources\n\n"
            + bullets([link("Sources", item_id, sources[item_id]["title"]) for item_id in topic["source_scope"]["source_ids"]])
            + "\n\n## Concepts\n\n"
            + bullets([link("Concepts", item_id, concepts[item_id]["preferred_label"]) for item_id in topic["concept_refs"]])
            + "\n\n## Evidence\n\n"
            + bullets([link("Evidence", item_id, evidence_records[item_id]["claim"]) for item_id in topic["evidence_refs"]])
            + "\n\n## Seminar\n\n"
            + link("Seminars", topic["seminar_id"], seminars[topic["seminar_id"]]["title"])
        )
        files[f"Topics/{topic['id']}.md"] = render_note(topic_meta, topic["title"], body)

    for concept in knowledge["concepts"]:
        body = (
            f"**Lifecycle:** `{concept['status']}`\n\n"
            + ("**PROVISIONAL — DOMAIN_REVIEW has not accepted this Concept.**\n\n" if concept["status"] == "PROVISIONAL" else "")
            + f"## Description\n\n{concept['description']}\n\n## Topics\n\n"
            + bullets([link("Topics", item_id, topics[item_id]["title"]) for item_id in concept["topic_refs"]])
            + "\n\n## Evidence\n\n"
            + bullets([link("Evidence", item_id, evidence_records[item_id]["claim"]) for item_id in concept["evidence_refs"]])
        )
        files[f"Concepts/{concept['id']}.md"] = render_note(
            meta(concept["id"], "concept", concept["status"]), concept["preferred_label"], body
        )

    evidence_topics = {item_id: [] for item_id in evidence_records}
    evidence_concepts = {item_id: [] for item_id in evidence_records}
    for topic in topics.values():
        for item_id in topic["evidence_refs"]:
            evidence_topics[item_id].append(topic)
    for concept in concepts.values():
        for item_id in concept["evidence_refs"]:
            evidence_concepts[item_id].append(concept)
    for item in source_evidence["evidence"]:
        locator = item["locator"]
        evidence_meta = meta(item["id"], "evidence", "VERIFIED_SOURCE_RANGE")
        evidence_meta.update(
            {
                "canonical_source_id": item["canonical_source_id"],
                "canonical_transcript_revision_id": item["canonical_transcript_revision_id"],
                "canonical_word_start_id": item["canonical_word_start_id"],
                "canonical_word_end_id": item["canonical_word_end_id"],
                "locator": locator,
                "timing_status": item["timing_status"],
            }
        )
        body = (
            f"## Supplied claim\n\n{item['claim']}\n\n## Canonical excerpt\n\n> {item['quote']}\n\n"
            "## Exact locator\n\n"
            f"- Source: {link('Sources', item['canonical_source_id'], sources[item['canonical_source_id']]['title'])}\n"
            f"- Time: `{locator['start_seconds']}`–`{locator['end_seconds']}` seconds\n"
            f"- TranscriptRevision: `{item['canonical_transcript_revision_id']}`\n"
            f"- Word range: `{item['canonical_word_start_id']}` → `{item['canonical_word_end_id']}`\n"
            f"- Timing status: `{item['timing_status']}`\n"
            f"- Unaligned Words: `{item['unaligned_word_ids']}`\n\n"
            "## Topics\n\n"
            + bullets([link("Topics", topic["id"], topic["title"]) for topic in evidence_topics[item["id"]]])
            + "\n\n## Concepts\n\n"
            + bullets([link("Concepts", concept["id"], concept["preferred_label"]) for concept in evidence_concepts[item["id"]]])
        )
        files[f"Evidence/{item['id']}.md"] = render_note(evidence_meta, item["claim"], body)

    for relation in knowledge["relations"]:
        body = (
            f"- Type: `{relation['relation_type']}`\n"
            f"- Source: {link('Concepts', relation['source_concept_id'], concepts[relation['source_concept_id']]['preferred_label'])}\n"
            f"- Target: {link('Concepts', relation['target_concept_id'], concepts[relation['target_concept_id']]['preferred_label'])}\n\n"
            "## Evidence\n\n"
            + bullets([link("Evidence", item_id, evidence_records[item_id]["claim"]) for item_id in relation["evidence_refs"]])
        )
        files[f"Relations/{relation['id']}.md"] = render_note(meta(relation["id"], "relation", relation["status"]), relation["id"], body)

    coverage_lines = [
        f"- {link('Sources', item['source_id'], sources[item['source_id']]['title'])}: `{item['status']}` — {item['reason']}"
        for item in coverage["sources"]
    ]
    files["_meta/coverage.md"] = render_note(
        meta("view_coverage", "coverage"),
        "Coverage",
        f"Full seminar coverage: `{coverage['full_seminar_coverage']}`\n\n" + "\n".join(coverage_lines),
    )
    files["_meta/canonical_evidence.md"] = render_note(
        meta("view_canonical_evidence", "canonical_pointer"),
        "Canonical Evidence",
        f"- Artifact ID: `{evidence['artifact_id']}`\n- SHA-256: `{sha256_bytes(canonical_bytes(evidence))}`",
    )
    files["_meta/canonical_knowledge.md"] = render_note(
        meta("view_canonical_knowledge", "canonical_pointer"),
        "Canonical Knowledge",
        f"- Artifact ID: `{knowledge['artifact_id']}`\n- SHA-256: `{sha256_bytes(canonical_bytes(knowledge))}`",
    )
    return dict(sorted(files.items()))


def make_manifest(files: dict[str, bytes], metadata: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "artifact_type": "seminartext.managed_generated_export",
        "ownership_classes": ["MANAGED_GENERATED", "USER_OWNED"],
        "files": {path: sha256_bytes(payload) for path, payload in sorted(files.items())},
        **metadata,
    }


def managed_path(root: Path, relative: str) -> Path:
    relative_path = Path(relative)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise ValueError(f"managed output path is unsafe: {relative}")
    root_resolved = root.resolve()
    cursor = root_resolved
    for part in relative_path.parts[:-1]:
        cursor = cursor / part
        if cursor.is_symlink():
            raise ValueError(f"managed output parent is a symlink: {relative}")
    path = root_resolved / relative_path
    if path.is_symlink():
        raise ValueError(f"managed output path is a symlink: {relative}")
    try:
        path.parent.resolve().relative_to(root_resolved)
    except ValueError as exc:
        raise ValueError(f"managed output escapes destination: {relative}") from exc
    return path


def check_write_plan(root: Path, files: dict[str, bytes], manifest: dict[str, Any]) -> None:
    manifest_path = managed_path(root, MANIFEST_NAME)
    prior: dict[str, Any] | None = None
    if manifest_path.exists():
        prior = load_json(manifest_path, "managed export manifest")
        if prior.get("artifact_type") != "seminartext.managed_generated_export" or not isinstance(prior.get("files"), dict):
            raise ValueError(f"manifest collision: {manifest_path}")
    prior_files = prior["files"] if prior else {}
    stale = sorted(set(prior_files) - set(files))
    if stale:
        raise ValueError(f"refusing to delete or orphan managed files: {stale}")
    for relative, old_hash in prior_files.items():
        path = managed_path(root, relative)
        if not path.is_file() or sha256_file(path) != old_hash:
            raise ValueError(f"changed managed file requires explicit review: {relative}")
    for relative in files:
        path = managed_path(root, relative)
        if path.exists() and relative not in prior_files:
            raise ValueError(f"USER_OWNED path collides with generated output: {relative}")


def write_generated(root: Path, files: dict[str, bytes], manifest: dict[str, Any]) -> None:
    check_write_plan(root, files, manifest)
    root.mkdir(parents=True, exist_ok=True)
    for relative, payload in files.items():
        destination = managed_path(root, relative)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + ".tmp")
        temporary.write_bytes(payload)
        temporary.replace(destination)
    manifest_path = managed_path(root, MANIFEST_NAME)
    temporary_manifest = manifest_path.with_name(manifest_path.name + ".tmp")
    temporary_manifest.write_bytes(canonical_bytes(manifest))
    temporary_manifest.replace(manifest_path)


def export_project(args: argparse.Namespace) -> int:
    project = Path(args.project).expanduser().resolve()
    if not project.is_dir():
        raise ValueError(f"project directory not found: {project}")
    input_path = Path(args.knowledge_input).expanduser().resolve()
    destination = Path(args.destination).expanduser().resolve()
    input_document = load_json(input_path, "project knowledge input")
    evidence, source_evidence, knowledge, coverage = compile_documents(project, input_document)
    resolver_path = Path(args.source_resolver).expanduser().resolve() if args.source_resolver else None
    resolver = load_resolver(project, resolver_path, evidence["sources"])
    vault_files = build_vault(evidence, source_evidence, knowledge, coverage, resolver)
    knowledge_files = {
        "canonical_evidence.json": canonical_bytes(evidence),
        "source_evidence.json": canonical_bytes(source_evidence),
        "canonical_knowledge.json": canonical_bytes(knowledge),
        "coverage.json": canonical_bytes(coverage),
    }
    knowledge_manifest = make_manifest(
        knowledge_files,
        {
            "kind": "project_knowledge_build",
            "input_artifact_id": input_document["artifact_id"],
            "input_sha256": sha256_file(input_path),
        },
    )
    vault_manifest = make_manifest(
        vault_files,
        {
            "kind": "obsidian_derived_view",
            "canonical_evidence_artifact_id": evidence["artifact_id"],
            "canonical_evidence_sha256": sha256_bytes(canonical_bytes(evidence)),
            "canonical_knowledge_artifact_id": knowledge["artifact_id"],
            "canonical_knowledge_sha256": sha256_bytes(canonical_bytes(knowledge)),
            "coverage": coverage,
            "resolver_states": resolver,
        },
    )
    knowledge_root = project / "knowledge"
    check_write_plan(knowledge_root, knowledge_files, knowledge_manifest)
    check_write_plan(destination, vault_files, vault_manifest)
    result = {
        "status": "DRY_RUN" if args.dry_run else "EXPORTED",
        "dry_run": bool(args.dry_run),
        "source_count": len(evidence["sources"]),
        "topic_count": len(knowledge["topics"]),
        "concept_count": len(knowledge["concepts"]),
        "evidence_count": len(source_evidence["evidence"]),
        "locator_types": sorted({item["locator"]["type"] for item in source_evidence["evidence"]}),
        "generated_note_count": len(vault_files),
        "full_seminar_coverage": coverage["full_seminar_coverage"],
        "vault_manifest_sha256": sha256_bytes(canonical_bytes(vault_manifest)),
    }
    if not args.dry_run:
        write_generated(knowledge_root, knowledge_files, knowledge_manifest)
        write_generated(destination, vault_files, vault_manifest)
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project")
    parser.add_argument("--knowledge-input", required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--source-resolver")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        return export_project(args)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
