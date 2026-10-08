#!/usr/bin/env python3
"""Deterministic, fail-closed human review workflow for Topic Drafts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from schemas.validate_canonical_evidence_v1 import validate_bundle  # noqa: E402
from seminartext_modules.project_knowledge_bridge import compile_documents  # noqa: E402


VERSION = "1.0.0"
VERSION_V2 = "2.0.0"
DRAFT_TYPE = "seminartext.topic_drafts"
PACKAGE_TYPE = "seminartext.topic_review_package"
DECISIONS_TYPE = "seminartext.topic_review_decisions"
BOUNDARY_LEDGER_TYPE = "seminartext.boundary_review_ledger"
BOUNDARY_DECISIONS_TYPE = "seminartext.boundary_review_decisions"
INPUT_TYPE = "seminartext.project_knowledge_input"
SCHEMA = ROOT / "schemas" / "topic_review_workflow_v1.schema.json"
SCHEMA_V2 = ROOT / "schemas" / "topic_review_workflow_v2.schema.json"
ID_RE = re.compile(r"^[a-z][a-z0-9._:-]{2,127}$")
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
ACTIONS = {"ACCEPT", "RENAME", "SPLIT", "MERGE", "REJECT", "DEFER"}
V2_OPERATIONS = {"ACCEPT", "RENAME", "SPLIT", "MERGE", "TRIM", "REALIGN", "EXCLUDE", "CLASSIFY"}
V2_DISPOSITIONS = {"SEMANTIC_KNOWLEDGE", "SEMINAR_STRUCTURE", "NON_SEMANTIC_EXCLUDED"}
HUMAN_ACTORS = {"human_domain_reviewer", "product_owner"}
ORIGIN_MAP = {
    "machine_assisted": "semi_automatic",
    "semi_automatic": "semi_automatic",
    "verified_manual": "verified_manual",
    "gold": "gold",
}
RELATION_REGISTRY = [
    {"id": "supports", "description": "The source concept provides support for the target claim."},
    {"id": "contradicts", "description": "The source and target claims are explicitly competing or conflicting."},
    {"id": "refines", "description": "The source concept narrows or elaborates the target concept."},
    {"id": "depends_on", "description": "The target concept is a stated prerequisite of the source concept."},
    {"id": "associated_with", "description": "The source and target concepts are associated without an inferred ontology."},
]


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


def require_id(value: Any, path: str) -> str:
    if not isinstance(value, str) or ID_RE.fullmatch(value) is None:
        raise ValueError(f"{path}: invalid stable ID")
    return value


def require_hash(value: Any, path: str) -> str:
    if not isinstance(value, str) or HASH_RE.fullmatch(value) is None:
        raise ValueError(f"{path}: expected SHA-256")
    return value


def require_exact(value: Any, required: set[str], optional: set[str], path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected object")
    missing = sorted(required - value.keys())
    unexpected = sorted(value.keys() - required - optional)
    if missing or unexpected:
        raise ValueError(f"{path}: missing={missing} unexpected={unexpected}")
    return value


def validate_schema(document: dict[str, Any]) -> None:
    try:
        from jsonschema import Draft202012Validator
    except ModuleNotFoundError as exc:
        raise ValueError("jsonschema is required; use the supported core/dev_test runtime") from exc
    schema = load_json(SCHEMA, "Topic review workflow schema")
    artifact_defs = {
        DRAFT_TYPE: "topic_drafts",
        PACKAGE_TYPE: "review_package",
        DECISIONS_TYPE: "review_decisions",
    }
    definition = artifact_defs.get(document.get("artifact_type"))
    validation_schema = (
        {"$schema": schema["$schema"], "$defs": schema["$defs"], "$ref": f"#/$defs/{definition}"}
        if definition
        else schema
    )
    errors = sorted(
        Draft202012Validator(validation_schema).iter_errors(document),
        key=lambda error: (tuple(str(part) for part in error.path), error.message),
    )
    if errors:
        raise ValueError(
            "Topic review workflow schema validation failed:\n"
            + "\n".join(f"{error.json_path}: {error.message}" for error in errors)
        )


def validate_schema_v2(document: dict[str, Any]) -> None:
    """Validate only V2 artifacts; v1 validation and serialization stay unchanged."""
    try:
        from jsonschema import Draft202012Validator
    except ModuleNotFoundError as exc:
        raise ValueError("jsonschema is required; use the supported core/dev_test runtime") from exc
    schema = load_json(SCHEMA_V2, "Topic review workflow V2 schema")
    artifact_defs = {
        DECISIONS_TYPE: "review_decisions_v2",
        "seminartext.boundary_proposal_requests": "boundary_requests",
        "seminartext.boundary_proposals": "boundary_proposals",
        BOUNDARY_LEDGER_TYPE: "boundary_review_ledger",
        BOUNDARY_DECISIONS_TYPE: "boundary_review_decisions",
        "seminartext.human_review_result": "review_result_v2",
    }
    definition = artifact_defs.get(document.get("artifact_type"))
    validation_schema = (
        {"$schema": schema["$schema"], "$defs": schema["$defs"], "$ref": f"#/$defs/{definition}"}
        if definition
        else schema
    )
    errors = sorted(
        Draft202012Validator(validation_schema).iter_errors(document),
        key=lambda error: (tuple(str(part) for part in error.path), error.message),
    )
    if errors:
        raise ValueError(
            "Topic review workflow V2 schema validation failed:\n"
            + "\n".join(f"{error.json_path}: {error.message}" for error in errors)
        )


def stable_id(value: str, prefix: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_") or "item"
    return f"{prefix}_{slug}"[:120]


def index(records: list[dict[str, Any]], label: str) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for number, record in enumerate(records):
        if not isinstance(record, dict):
            raise ValueError(f"{label}[{number}]: expected object")
        item_id = require_id(record.get("id"), f"{label}[{number}].id")
        if item_id in result:
            raise ValueError(f"{label}: duplicate stable ID {item_id}")
        result[item_id] = record
    return result


def load_evidence(project: Path) -> tuple[dict[str, Any], str]:
    path = project / "evidence" / "canonical_bundle.json"
    bundle = load_json(path, "project Canonical Evidence")
    errors = validate_bundle(bundle)
    if errors:
        raise ValueError("project Canonical Evidence is invalid:\n" + "\n".join(errors))
    return bundle, sha256_file(path)


def resolve_word_range(
    item: dict[str, Any],
    sources: dict[str, dict[str, Any]],
    revisions: dict[str, dict[str, Any]],
    words: dict[str, dict[str, Any]],
    path: str,
) -> dict[str, Any]:
    source = sources.get(item["source_id"])
    revision = revisions.get(item["transcript_revision_id"])
    first = words.get(item["word_start_id"])
    last = words.get(item["word_end_id"])
    if source is None:
        raise ValueError(f"{path}: invalid Source ID {item['source_id']}")
    if revision is None or revision.get("source_id") != source["id"]:
        raise ValueError(f"{path}: invalid TranscriptRevision {item['transcript_revision_id']}")
    provenance = revision.get("transcript_provenance")
    legacy_verified = provenance is None and revision.get("authority") == "authoritative" and revision.get("lifecycle_status") == "verified"
    explicit_verified = isinstance(provenance, dict) and provenance.get("verification_state") == "fully_human_verified" and revision.get("authority") == "authoritative" and revision.get("lifecycle_status") == "verified"
    allowed_machine = isinstance(provenance, dict) and provenance.get("verification_state") in {"machine_unverified", "selectively_verified"} and revision.get("authority") == "candidate" and revision.get("lifecycle_status") == "active"
    if not legacy_verified and not explicit_verified and not allowed_machine:
        raise ValueError(f"{path}: TranscriptRevision must be explicitly assured and active/verified")
    if first is None or last is None:
        raise ValueError(f"{path}: missing canonical Word endpoint")
    if any(
        word.get("source_id") != source["id"]
        or word.get("transcript_revision_id") != revision["id"]
        for word in (first, last)
    ):
        raise ValueError(f"{path}: cross-source or cross-revision Word range")
    if last["sequence"] < first["sequence"]:
        raise ValueError(f"{path}: invalid inverted Word range")
    selected = sorted(
        (
            word
            for word in words.values()
            if word["transcript_revision_id"] == revision["id"]
            and first["sequence"] <= word["sequence"] <= last["sequence"]
        ),
        key=lambda word: word["sequence"],
    )
    if [word["sequence"] for word in selected] != list(range(first["sequence"], last["sequence"] + 1)):
        raise ValueError(f"{path}: non-contiguous Word range")
    aligned = [word for word in selected if word["alignment_status"] != "unaligned"]
    if not aligned or source["kind"] not in {"audio", "video"}:
        raise ValueError(f"{path}: exact time locator unavailable")
    quote = revision["canonical_text"][selected[0]["char_start"] : selected[-1]["char_end"]]
    result = {
        "word_start_id": selected[0]["id"],
        "word_end_id": selected[-1]["id"],
        "word_start_sequence": selected[0]["sequence"],
        "word_end_sequence": selected[-1]["sequence"],
        "quote": quote,
        "locator": {
            "type": "time_interval",
            "start_seconds": aligned[0]["start_seconds"],
            "end_seconds": aligned[-1]["end_seconds"],
        },
    }
    if provenance is not None:
        result["transcript_provenance"] = provenance
    return result


def validate_drafts(project: Path, drafts: dict[str, Any]) -> tuple[dict[str, Any], str, list[dict[str, Any]], list[dict[str, Any]]]:
    validate_schema(drafts)
    if drafts.get("artifact_type") != DRAFT_TYPE or drafts.get("schema_version") != VERSION:
        raise ValueError("Topic Draft input must use seminartext.topic_drafts v1.0.0")
    require_id(drafts["artifact_id"], "$.artifact_id")
    bundle, bundle_hash = load_evidence(project)
    if drafts["project"]["id"] != bundle["project"]["id"]:
        raise ValueError("Topic Draft project ID does not match Canonical Evidence")
    sources = index(bundle["sources"], "$.canonical.sources")
    revisions = index(bundle["transcript_revisions"], "$.canonical.transcript_revisions")
    words = index(bundle["words"], "$.canonical.words")
    evidence_input = index(drafts["evidence"], "$.evidence")
    resolved_evidence: list[dict[str, Any]] = []
    for number, evidence in enumerate(drafts["evidence"]):
        span = resolve_word_range(evidence, sources, revisions, words, f"$.evidence[{number}]")
        resolved_evidence.append({**evidence, **span})
    resolved_by_id = {item["id"]: item for item in resolved_evidence}

    topic_ids: set[str] = set()
    resolved_topics: list[dict[str, Any]] = []
    for number, topic in enumerate(drafts["topics"]):
        topic_id = require_id(topic["id"], f"$.topics[{number}].id")
        if topic_id in topic_ids:
            raise ValueError(f"$.topics: duplicate stable ID {topic_id}")
        topic_ids.add(topic_id)
        if topic["lifecycle_status"] != "REVIEW_REQUIRED":
            raise ValueError(f"{topic_id}: Topic Draft must start REVIEW_REQUIRED")
        if topic["seminar_id"] != drafts["seminar"]["id"]:
            raise ValueError(f"{topic_id}: Topic Draft belongs to another seminar")
        if topic["semantic_origin"] not in ORIGIN_MAP:
            raise ValueError(f"{topic_id}: unsupported semantic origin")
        span = resolve_word_range(topic, sources, revisions, words, f"$.topics[{number}]")
        evidence_items = []
        for evidence_id in topic["evidence_refs"]:
            evidence = resolved_by_id.get(evidence_id)
            if evidence is None:
                raise ValueError(f"{topic_id}: missing evidence {evidence_id}")
            if evidence["source_id"] != topic["source_id"] or evidence["transcript_revision_id"] != topic["transcript_revision_id"]:
                raise ValueError(f"{topic_id}: evidence belongs to another source or revision")
            if not (
                span["word_start_sequence"] <= evidence["word_start_sequence"]
                and evidence["word_end_sequence"] <= span["word_end_sequence"]
            ):
                raise ValueError(f"{topic_id}: evidence lies outside Topic Draft range")
            evidence_items.append(evidence)
        if not evidence_items:
            raise ValueError(f"{topic_id}: missing evidence")
        evidence_hash = sha256_bytes(canonical_bytes(evidence_items))
        core = {
            **topic,
            **span,
            "evidence_sha256": evidence_hash,
            "generator": drafts["generator"],
            "review_history": [],
        }
        core["topic_sha256"] = sha256_bytes(canonical_bytes(core))
        resolved_topics.append(core)
    return bundle, bundle_hash, resolved_evidence, resolved_topics


def render_review_markdown(package: dict[str, Any]) -> str:
    lines = [
        "# SeminarText Topic Human Review",
        "",
        f"Project: {package['project']['title']} (`{package['project']['id']}`)",
        f"Seminar: {package['seminar']['title']} (`{package['seminar']['id']}`)",
        f"Package: `{package['artifact_id']}`",
        "",
        "Every draft remains REVIEW_REQUIRED until an explicit human ReviewDecision is applied.",
        "Edit the decision template, not Canonical Knowledge JSON.",
        "",
    ]
    for number, topic in enumerate(package["topics"], 1):
        lines.extend(
            [
                f"## {number}. {topic['proposed_title']}",
                "",
                f"- Draft ID: `{topic['id']}`",
                f"- Status: `{topic['lifecycle_status']}`",
                f"- Source: `{topic['source_id']}`",
                f"- TranscriptRevision: `{topic['transcript_revision_id']}`",
                f"- Words: `{topic['word_start_id']}` → `{topic['word_end_id']}`",
                f"- Time: {topic['locator']['start_seconds']} → {topic['locator']['end_seconds']} seconds",
                f"- Semantic origin: `{topic['semantic_origin']}`",
                f"- Generator: `{topic['generator']['id']}` `{topic['generator']['version']}`",
                f"- Evidence hash: `{topic['evidence_sha256']}`",
                f"- Draft hash: `{topic['topic_sha256']}`",
                "",
                topic["proposed_summary"] or "_No proposed summary supplied._",
                "",
                "Evidence:",
            ]
        )
        provenance = topic.get("transcript_provenance")
        if provenance:
            lines.extend([
                f"- Transcript origin: `{provenance['origin']}`",
                f"- Transcript method: `{provenance['method']}`",
                f"- Transcript verification: `{provenance['verification_state']}`",
            ])
        for evidence_id in topic["evidence_refs"]:
            evidence = next(item for item in package["evidence"] if item["id"] == evidence_id)
            lines.extend(["", f"- `{evidence_id}`: {evidence['claim']}", f"  > {evidence['quote']}"])
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def prepare(project: Path, drafts_path: Path, output: Path) -> dict[str, Any]:
    if output.exists():
        raise ValueError(f"review output already exists: {output}")
    drafts = load_json(drafts_path, "Topic Draft input")
    bundle, bundle_hash, evidence, topics = validate_drafts(project, drafts)
    package = {
        "schema_version": VERSION,
        "artifact_type": PACKAGE_TYPE,
        "artifact_id": stable_id(drafts["artifact_id"], "review_package"),
        "project": drafts["project"],
        "seminar": drafts["seminar"],
        "canonical_evidence": {"artifact_id": bundle["artifact_id"], "sha256": bundle_hash},
        "draft_input": {"artifact_id": drafts["artifact_id"], "sha256": sha256_file(drafts_path)},
        "review_policy": {
            "authoring_gate": "DOMAIN_AUTHORING",
            "review_gate": "DOMAIN_REVIEW",
            "machine_assisted_default": "REVIEW_REQUIRED",
            "automatic_acceptance": False,
        },
        "evidence": sorted(evidence, key=lambda item: item["id"]),
        "topics": sorted(topics, key=lambda item: (item["sequence"], item["id"])),
    }
    validate_schema(package)
    package_bytes = canonical_bytes(package)
    template = {
        "schema_version": VERSION,
        "artifact_type": DECISIONS_TYPE,
        "artifact_id": stable_id(package["artifact_id"], "review_decisions"),
        "review_package_id": package["artifact_id"],
        "review_package_sha256": sha256_bytes(package_bytes),
        "reviewer": {"actor_type": "human_domain_reviewer", "actor_id": "reviewer_id_required"},
        "decisions": [],
    }
    validate_schema(template)
    output.mkdir(parents=True)
    (output / "review_package.json").write_bytes(package_bytes)
    (output / "REVIEW.md").write_text(render_review_markdown(package), encoding="utf-8")
    (output / "review_decisions.template.json").write_bytes(canonical_bytes(template))
    return {
        "status": "REVIEW_REQUIRED",
        "package": str(output / "review_package.json"),
        "review_document": str(output / "REVIEW.md"),
        "decision_template": str(output / "review_decisions.template.json"),
        "total": len(package["topics"]),
        "unreviewed": len(package["topics"]),
    }


def load_package(project: Path, package_path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    package = load_json(package_path, "Topic review package")
    validate_schema(package)
    if package.get("artifact_type") != PACKAGE_TYPE or package.get("schema_version") != VERSION:
        raise ValueError("review package contract mismatch")
    bundle, bundle_hash = load_evidence(project)
    if package["canonical_evidence"]["artifact_id"] != bundle["artifact_id"]:
        raise ValueError("stale review package: Canonical Evidence artifact changed")
    if package["canonical_evidence"]["sha256"] != bundle_hash:
        raise ValueError("stale review package: underlying evidence changed")
    evidence_by_id = {item["id"]: item for item in package["evidence"]}
    for topic in package["topics"]:
        evidence_items = [evidence_by_id[item_id] for item_id in topic["evidence_refs"]]
        if topic["evidence_sha256"] != sha256_bytes(canonical_bytes(evidence_items)):
            raise ValueError(f"stale review package: evidence snapshot changed for {topic['id']}")
        core = dict(topic)
        supplied_hash = core.pop("topic_sha256")
        if supplied_hash != sha256_bytes(canonical_bytes(core)):
            raise ValueError(f"stale review package: Topic Draft changed for {topic['id']}")
    return package, bundle


def validate_result_topic(result: dict[str, Any], package: dict[str, Any], bundle: dict[str, Any], path: str) -> None:
    sources = index(bundle["sources"], "$.canonical.sources")
    revisions = index(bundle["transcript_revisions"], "$.canonical.transcript_revisions")
    words = index(bundle["words"], "$.canonical.words")
    span = resolve_word_range(result, sources, revisions, words, path)
    evidence_by_id = {item["id"]: item for item in package["evidence"]}
    if not result["evidence_refs"] or not set(result["evidence_refs"]).issubset(evidence_by_id):
        raise ValueError(f"{path}: result evidence must come from the reviewed package")
    for evidence_id in result["evidence_refs"]:
        evidence = evidence_by_id[evidence_id]
        if evidence["source_id"] != result["source_id"] or evidence["transcript_revision_id"] != result["transcript_revision_id"]:
            raise ValueError(f"{path}: result evidence belongs to another source or revision")
        if not (
            span["word_start_sequence"] <= evidence["word_start_sequence"]
            and evidence["word_end_sequence"] <= span["word_end_sequence"]
        ):
            raise ValueError(f"{path}: result evidence lies outside the result Topic range")


def validate_decisions(
    package_path: Path,
    package: dict[str, Any],
    bundle: dict[str, Any],
    decisions: dict[str, Any],
    *,
    require_complete: bool,
) -> tuple[dict[str, dict[str, Any]], list[dict[str, Any]]]:
    validate_schema(decisions)
    if decisions.get("artifact_type") != DECISIONS_TYPE or decisions.get("schema_version") != VERSION:
        raise ValueError("review decisions contract mismatch")
    if decisions["review_package_id"] != package["artifact_id"]:
        raise ValueError("orphan ReviewDecision: package ID mismatch")
    if decisions["review_package_sha256"] != sha256_file(package_path):
        raise ValueError("stale review package: decision package hash mismatch")
    reviewer = decisions["reviewer"]
    if reviewer["actor_type"] not in HUMAN_ACTORS:
        raise ValueError("semantic ReviewDecision requires a human reviewer")
    require_id(reviewer["actor_id"], "$.reviewer.actor_id")
    package_topics = {item["id"]: item for item in package["topics"]}
    result_ids = set(package_topics)
    covered: dict[str, dict[str, Any]] = {}
    decision_ids: set[str] = set()
    normalized: list[dict[str, Any]] = []
    for number, decision in enumerate(decisions["decisions"]):
        path = f"$.decisions[{number}]"
        decision_id = require_id(decision["id"], f"{path}.id")
        if decision_id in decision_ids:
            raise ValueError(f"duplicate ReviewDecision {decision_id}")
        decision_ids.add(decision_id)
        action = decision["action"]
        if action not in ACTIONS:
            raise ValueError(f"{path}: unsupported decision {action}")
        targets = decision["target_ids"]
        if len(set(targets)) != len(targets):
            raise ValueError(f"{path}: duplicate target")
        for target_id in targets:
            if target_id not in package_topics:
                raise ValueError(f"orphan ReviewDecision target {target_id}")
            if target_id in covered:
                raise ValueError(f"duplicate decision for Topic Draft {target_id}")
            covered[target_id] = decision
        snapshots = {item["topic_id"]: item["topic_sha256"] for item in decision["expected_topics"]}
        if len(snapshots) != len(decision["expected_topics"]) or set(snapshots) != set(targets):
            raise ValueError(f"{path}: expected Topic snapshots must match targets")
        for target_id in targets:
            if snapshots[target_id] != package_topics[target_id]["topic_sha256"]:
                raise ValueError(f"{path}: stale Topic Draft {target_id}")
        results = decision["result_topics"]
        new_title = decision.get("new_title")
        new_summary = decision.get("new_summary")
        if action in {"ACCEPT", "REJECT", "DEFER"}:
            if len(targets) != 1 or results or new_title is not None or new_summary is not None:
                raise ValueError(f"{path}: invalid {action} shape")
        elif action == "RENAME":
            if len(targets) != 1 or results or not isinstance(new_title, str) or not new_title.strip():
                raise ValueError(f"{path}: RENAME requires one target and a non-empty new_title")
        elif action == "SPLIT":
            if len(targets) != 1 or len(results) < 2:
                raise ValueError(f"{path}: SPLIT requires one target and at least two explicit result Topics")
        elif action == "MERGE":
            if len(targets) < 2 or len(results) != 1:
                raise ValueError(f"{path}: MERGE requires at least two targets and one explicit result Topic")
        if action in {"SPLIT", "MERGE"}:
            source_keys = {
                (package_topics[target]["source_id"], package_topics[target]["transcript_revision_id"])
                for target in targets
            }
            if len(source_keys) != 1:
                raise ValueError(f"{path}: cross-source SPLIT/MERGE is unsupported")
            for result_number, result in enumerate(results):
                result_id = require_id(result["id"], f"{path}.result_topics[{result_number}].id")
                if result_id in result_ids:
                    raise ValueError(f"{path}: conflicting stable ID {result_id}")
                result_ids.add(result_id)
                validate_result_topic(result, package, bundle, f"{path}.result_topics[{result_number}]")
                if (result["source_id"], result["transcript_revision_id"]) not in source_keys:
                    raise ValueError(f"{path}: result Topic changes source or revision")
        normalized.append(decision)
    if require_complete and set(covered) != set(package_topics):
        raise ValueError(f"unreviewed Topic Drafts remain: {sorted(set(package_topics) - set(covered))}")
    return covered, normalized


def decision_status(package: dict[str, Any], covered: dict[str, dict[str, Any]]) -> dict[str, int]:
    counts = {
        "TOTAL": len(package["topics"]),
        "UNREVIEWED": len(package["topics"]) - len(covered),
        "ACCEPTED": 0,
        "RENAMED": 0,
        "SPLIT": 0,
        "MERGED": 0,
        "REJECTED": 0,
        "DEFERRED": 0,
    }
    labels = {
        "ACCEPT": "ACCEPTED",
        "RENAME": "RENAMED",
        "SPLIT": "SPLIT",
        "MERGE": "MERGED",
        "REJECT": "REJECTED",
        "DEFER": "DEFERRED",
    }
    for decision in {item["id"]: item for item in covered.values()}.values():
        counts[labels[decision["action"]]] += len(decision["target_ids"])
    return counts


def status(project: Path, package_path: Path, decisions_path: Path | None) -> dict[str, Any]:
    package, bundle = load_package(project, package_path)
    covered: dict[str, dict[str, Any]] = {}
    if decisions_path is not None:
        decisions = load_json(decisions_path, "Topic review decisions")
        covered, _ = validate_decisions(package_path, package, bundle, decisions, require_complete=False)
    return {"status": "PASS", **decision_status(package, covered)}


def topic_from_review(topic: dict[str, Any], decision: dict[str, Any], decision_artifact_id: str) -> dict[str, Any]:
    action = decision["action"]
    title = decision["new_title"] if action == "RENAME" else topic["proposed_title"]
    summary = decision.get("new_summary") or topic["proposed_summary"] or "No summary supplied."
    lifecycle = {
        "ACCEPT": "ACCEPTED",
        "RENAME": "PROVISIONAL",
        "SPLIT": "SUPERSEDED",
        "MERGE": "SUPERSEDED",
        "REJECT": "REJECTED",
        "DEFER": "PROVISIONAL",
    }[action]
    return {
        "id": topic["id"],
        "seminar_id": topic["seminar_id"],
        "source_scope": {
            "source_ids": [topic["source_id"]],
            "transcript_revision_ids": [topic["transcript_revision_id"]],
            "order_start": topic["word_start_sequence"],
            "order_end": topic["word_end_sequence"],
        },
        "title": title,
        "summary": summary,
        "temporal_scope": {
            "start_seconds": topic["locator"]["start_seconds"],
            "end_seconds": topic["locator"]["end_seconds"],
        },
        "order_scope": {"sequence": topic["sequence"]},
        "evidence_refs": topic["evidence_refs"],
        "concept_refs": [],
        "status": lifecycle,
        "provenance": {
            "origin": "human_review",
            "source_artifact_id": decision_artifact_id,
            "source_status": "product_review_required",
        },
        "version": 2 if action in {"RENAME", "SPLIT", "MERGE"} else 1,
    }


def result_topic(result: dict[str, Any], seminar_id: str, decision_artifact_id: str, bundle: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    sources = index(bundle["sources"], "$.canonical.sources")
    revisions = index(bundle["transcript_revisions"], "$.canonical.transcript_revisions")
    words = index(bundle["words"], "$.canonical.words")
    span = resolve_word_range(result, sources, revisions, words, "$.result_topic")
    topic = {
        "id": result["id"],
        "seminar_id": seminar_id,
        "source_scope": {
            "source_ids": [result["source_id"]],
            "transcript_revision_ids": [result["transcript_revision_id"]],
            "order_start": span["word_start_sequence"],
            "order_end": span["word_end_sequence"],
        },
        "title": result["proposed_title"],
        "summary": result["proposed_summary"] or "No summary supplied.",
        "temporal_scope": {
            "start_seconds": span["locator"]["start_seconds"],
            "end_seconds": span["locator"]["end_seconds"],
        },
        "order_scope": {"sequence": result["sequence"]},
        "evidence_refs": result["evidence_refs"],
        "concept_refs": [],
        "status": "PROVISIONAL",
        "provenance": {
            "origin": "human_review",
            "source_artifact_id": decision_artifact_id,
            "source_status": "product_review_required",
        },
        "version": 1,
    }
    source = {
        "topic_id": result["id"],
        "topic_set_id": result["topic_set_id"],
        "sequence": result["sequence"],
        "origin": ORIGIN_MAP[result["semantic_origin"]],
        "transcript_revision_id": result["transcript_revision_id"],
        "word_start_id": result["word_start_id"],
        "word_end_id": result["word_end_id"],
    }
    return topic, source


def apply(project: Path, package_path: Path, decisions_path: Path, output: Path) -> dict[str, Any]:
    if output.exists():
        raise ValueError(f"reviewed semantic output already exists: {output}")
    package, bundle = load_package(project, package_path)
    decisions = load_json(decisions_path, "Topic review decisions")
    covered, normalized = validate_decisions(package_path, package, bundle, decisions, require_complete=True)
    package_topics = {item["id"]: item for item in package["topics"]}
    knowledge_topics: list[dict[str, Any]] = []
    topic_sources: list[dict[str, Any]] = []
    review_decisions: list[dict[str, Any]] = []
    for topic in package["topics"]:
        decision = covered[topic["id"]]
        knowledge_topics.append(topic_from_review(topic, decision, decisions["artifact_id"]))
        topic_sources.append(
            {
                "topic_id": topic["id"],
                "topic_set_id": topic["topic_set_id"],
                "sequence": topic["sequence"],
                "origin": ORIGIN_MAP[topic["semantic_origin"]],
                "transcript_revision_id": topic["transcript_revision_id"],
                "word_start_id": topic["word_start_id"],
                "word_end_id": topic["word_end_id"],
            }
        )
    for decision in normalized:
        result_ids = []
        for result in decision["result_topics"]:
            new_topic, new_source = result_topic(result, package["seminar"]["id"], decisions["artifact_id"], bundle)
            knowledge_topics.append(new_topic)
            topic_sources.append(new_source)
            result_ids.append(result["id"])
        if decision["action"] in {"ACCEPT", "RENAME"}:
            result_ids = decision["target_ids"]
        review_decisions.append(
            {
                "id": decision["id"],
                "action": decision["action"],
                "target_ids": decision["target_ids"],
                "result_ids": result_ids,
                "reason": decision["reason"],
                "actor_type": decisions["reviewer"]["actor_type"],
                "actor_id": decisions["reviewer"]["actor_id"],
                "timestamp": decision["timestamp"],
                "input_version": 1,
                "output_version": 2 if decision["action"] in {"RENAME", "SPLIT", "MERGE"} else 1,
                "provenance": {"origin": "human_review", "source_artifact_id": decisions["artifact_id"]},
            }
        )
    knowledge_topics.sort(key=lambda item: (item["order_scope"]["sequence"], item["id"]))
    topic_sources.sort(key=lambda item: (item["sequence"], item["topic_id"]))
    artifact_id = stable_id(decisions["artifact_id"], "reviewed_topics")
    source_ids_with_topics = {item["source_scope"]["source_ids"][0] for item in knowledge_topics}
    result = {
        "schema_version": VERSION,
        "artifact_type": INPUT_TYPE,
        "artifact_id": artifact_id,
        "project": {
            "id": package["project"]["id"],
            "title": package["project"]["title"],
            "status": "PROVISIONAL",
            "version": 1,
            "provenance": {"origin": "human_review", "source_artifact_id": artifact_id},
        },
        "seminars": [
            {
                "id": package["seminar"]["id"],
                "project_id": package["project"]["id"],
                "title": package["seminar"]["title"],
                "status": "PROVISIONAL",
                "version": 1,
                "provenance": {"origin": "human_review", "source_artifact_id": artifact_id},
                "topic_refs": [item["id"] for item in knowledge_topics],
            }
        ],
        "topics": knowledge_topics,
        "concepts": [],
        "relations": [],
        "review_decisions": sorted(review_decisions, key=lambda item: item["id"]),
        "relation_type_registry": RELATION_REGISTRY,
        "topic_sources": topic_sources,
        "evidence": [
            {
                key: evidence[key]
                for key in ("id", "claim", "source_id", "transcript_revision_id", "word_start_id", "word_end_id")
            }
            for evidence in package["evidence"]
        ],
        "coverage": [
            {
                "source_id": source["id"],
                "status": "COVERED" if source["id"] in source_ids_with_topics else "SEMANTIC_INPUT_UNAVAILABLE",
                "reason": (
                    "Explicit reviewed Topic state is supplied."
                    if source["id"] in source_ids_with_topics
                    else "No reviewed Topic Draft was supplied for this source."
                ),
            }
            for source in bundle["sources"]
        ],
    }
    compile_documents(project, result)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(canonical_bytes(result))
    return {
        "status": "PASS",
        **decision_status(package, covered),
        "output": str(output),
        "output_sha256": sha256_file(output),
        "canonical_knowledge_compatible": True,
    }


def _canonical_indexes(bundle: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    return (
        index(bundle["sources"], "$.canonical.sources"),
        index(bundle["transcript_revisions"], "$.canonical.transcript_revisions"),
        index(bundle["words"], "$.canonical.words"),
    )


def _enrich_fragment(
    fragment: dict[str, Any],
    topic: dict[str, Any],
    sources: dict[str, dict[str, Any]],
    revisions: dict[str, dict[str, Any]],
    words: dict[str, dict[str, Any]],
    path: str,
) -> dict[str, Any]:
    if fragment["source_id"] != topic["source_id"] or fragment["transcript_revision_id"] != topic["transcript_revision_id"]:
        raise ValueError(f"{path}: fragment changes the original source or TranscriptRevision")
    span = resolve_word_range(fragment, sources, revisions, words, path)
    if not (
        topic["word_start_sequence"] <= span["word_start_sequence"]
        and span["word_end_sequence"] <= topic["word_end_sequence"]
    ):
        raise ValueError(f"{path}: fragment lies outside original Topic Draft {topic['id']}")
    package_evidence = set(topic["evidence_refs"])
    if not set(fragment["evidence_refs"]).issubset(package_evidence):
        raise ValueError(f"{path}: fragment evidence is not inherited from its original Topic Draft")
    return {
        **fragment,
        **span,
        "source_topic_sha256": topic["topic_sha256"],
        "canonical_evidence_provenance": {
            "source_id": fragment["source_id"],
            "transcript_revision_id": fragment["transcript_revision_id"],
            "word_start_id": span["word_start_id"],
            "word_end_id": span["word_end_id"],
        },
    }


def validate_decisions_v2(
    package_path: Path,
    package: dict[str, Any],
    bundle: dict[str, Any],
    decisions: dict[str, Any],
    *,
    require_complete: bool,
    require_approved_boundaries: bool = False,
) -> tuple[dict[str, dict[str, Any]], list[dict[str, Any]]]:
    """Validate lossless source-fragment-to-result composition.

    Every selected source Topic Draft is partitioned exactly once. Every fragment
    is consumed by exactly one typed result. This makes trim/exclusion explicit
    and prevents a structural fragment from silently entering Knowledge output.
    """
    validate_schema_v2(decisions)
    if decisions.get("artifact_type") != DECISIONS_TYPE or decisions.get("schema_version") != VERSION_V2:
        raise ValueError("review decisions V2 contract mismatch")
    if decisions["review_package_id"] != package["artifact_id"]:
        raise ValueError("orphan ReviewDecision V2: package ID mismatch")
    if decisions["review_package_sha256"] != sha256_file(package_path):
        raise ValueError("stale review package: V2 decision package hash mismatch")
    if decisions["reviewer"]["actor_type"] not in HUMAN_ACTORS:
        raise ValueError("semantic ReviewDecision V2 requires a human reviewer")
    require_id(decisions["reviewer"]["actor_id"], "$.reviewer.actor_id")
    if require_approved_boundaries and decisions["boundary_authority"] != "PRODUCT_OWNER_DOMAIN_REVIEW":
        raise ValueError("exact boundaries remain REVIEW_REQUIRED")

    package_topics = {item["id"]: item for item in package["topics"]}
    package_evidence = {item["id"] for item in package["evidence"]}
    sources, revisions, words = _canonical_indexes(bundle)
    semantic_records = decisions.get("authoritative_semantic_decisions")
    boundary_provenance = decisions.get("exact_boundary_provenance")
    if (semantic_records is None) != (boundary_provenance is None):
        raise ValueError(
            "complete semantic authority and exact-boundary provenance must be supplied together"
        )

    semantic_by_id: dict[str, dict[str, Any]] = {}
    boundary_by_id: dict[str, dict[str, Any]] = {}
    if semantic_records is not None:
        semantic_numbers: set[int] = set()
        semantic_topics: set[str] = set()
        for number, record in enumerate(semantic_records):
            path = f"$.authoritative_semantic_decisions[{number}]"
            record_id = require_id(record["id"], f"{path}.id")
            if record_id in semantic_by_id:
                raise ValueError(f"duplicate authoritative semantic decision {record_id}")
            review_item_number = record["review_item_number"]
            if review_item_number in semantic_numbers:
                raise ValueError(f"duplicate authoritative review item {review_item_number}")
            semantic_numbers.add(review_item_number)
            source_topic_id = record["source_topic_id"]
            if source_topic_id not in package_topics:
                raise ValueError(f"{path}: semantic decision refers to an unknown source Topic")
            if source_topic_id in semantic_topics:
                raise ValueError(f"duplicate authoritative semantic decision for {source_topic_id}")
            semantic_topics.add(source_topic_id)
            semantic_by_id[record_id] = record
        if semantic_topics != set(package_topics):
            raise ValueError("authoritative semantic decisions must account for every source Topic exactly once")

        if decisions["boundary_authority"] != "PRODUCT_OWNER_DOMAIN_REVIEW":
            raise ValueError("exact-boundary provenance requires PRODUCT_OWNER_DOMAIN_REVIEW authority")
        boundary_sources: dict[str, dict[str, Any]] = {}
        for number, source in enumerate(boundary_provenance["sources"]):
            path = f"$.exact_boundary_provenance.sources[{number}]"
            artifact_id = require_id(source["artifact_id"], f"{path}.artifact_id")
            if artifact_id in boundary_sources:
                raise ValueError(f"duplicate exact-boundary source {artifact_id}")
            boundary_sources[artifact_id] = source
        for number, boundary in enumerate(boundary_provenance["resolved_boundaries"]):
            path = f"$.exact_boundary_provenance.resolved_boundaries[{number}]"
            boundary_id = require_id(boundary["boundary_proposal_id"], f"{path}.boundary_proposal_id")
            if boundary_id in boundary_by_id:
                raise ValueError(f"duplicate resolved exact boundary {boundary_id}")
            source = boundary_sources.get(boundary["source_artifact_id"])
            if source is None or source["sha256"] != boundary["source_artifact_sha256"]:
                raise ValueError(f"{path}: exact boundary source artifact is missing or mismatched")
            word = words.get(boundary["canonical_word_id"])
            if word is None:
                raise ValueError(f"{path}: exact boundary canonical Word does not exist")
            timestamp = word.get("start_seconds")
            if not isinstance(timestamp, (int, float)):
                timestamp = word.get("end_seconds")
            if timestamp != boundary["timestamp"]:
                raise ValueError(f"{path}: exact boundary timestamp does not match Canonical Evidence")
            boundary_by_id[boundary_id] = boundary
        if sum(source["decision_count"] for source in boundary_sources.values()) != len(boundary_by_id):
            raise ValueError("exact-boundary source counts do not match resolved boundary inventory")

    covered: dict[str, dict[str, Any]] = {}
    decision_ids: set[str] = set()
    result_ids: set[str] = set()
    consumed_semantic_refs: set[str] = set()
    consumed_boundary_refs: set[str] = set()
    normalized: list[dict[str, Any]] = []
    for number, decision in enumerate(decisions["decisions"]):
        path = f"$.decisions[{number}]"
        decision_id = require_id(decision["id"], f"{path}.id")
        if decision_id in decision_ids:
            raise ValueError(f"duplicate ReviewDecision V2 {decision_id}")
        decision_ids.add(decision_id)
        if not set(decision["operations"]).issubset(V2_OPERATIONS):
            raise ValueError(f"{path}: unsupported V2 operation")
        targets = decision["target_ids"]
        semantic_refs = decision.get("semantic_decision_refs", [])
        boundary_refs = decision.get("boundary_decision_refs", [])
        if semantic_records is not None:
            if not semantic_refs:
                raise ValueError(f"{path}: governed transformation has no semantic decision provenance")
            if consumed_semantic_refs.intersection(semantic_refs):
                raise ValueError(f"{path}: authoritative semantic decision is consumed more than once")
            for semantic_ref in semantic_refs:
                record = semantic_by_id.get(semantic_ref)
                if record is None:
                    raise ValueError(f"{path}: unknown authoritative semantic decision reference")
                if record["source_topic_id"] not in targets:
                    raise ValueError(f"{path}: semantic decision source Topic is not a transformation target")
            consumed_semantic_refs.update(semantic_refs)
            if consumed_boundary_refs.intersection(boundary_refs):
                raise ValueError(f"{path}: exact boundary decision is consumed more than once")
            if any(boundary_ref not in boundary_by_id for boundary_ref in boundary_refs):
                raise ValueError(f"{path}: unknown exact boundary decision reference")
            consumed_boundary_refs.update(boundary_refs)
        for target_id in targets:
            if target_id not in package_topics:
                raise ValueError(f"{path}: orphan target {target_id}")
            if target_id in covered:
                raise ValueError(f"duplicate V2 decision for Topic Draft {target_id}")
            covered[target_id] = decision
        snapshots = {item["topic_id"]: item["topic_sha256"] for item in decision["expected_topics"]}
        if len(snapshots) != len(decision["expected_topics"]) or set(snapshots) != set(targets):
            raise ValueError(f"{path}: expected Topic snapshots must match targets")
        for target_id in targets:
            if snapshots[target_id] != package_topics[target_id]["topic_sha256"]:
                raise ValueError(f"{path}: stale Topic Draft {target_id}")

        fragments: dict[str, dict[str, Any]] = {}
        fragments_by_topic: dict[str, list[dict[str, Any]]] = {target_id: [] for target_id in targets}
        for fragment_number, fragment in enumerate(decision["source_fragments"]):
            fragment_path = f"{path}.source_fragments[{fragment_number}]"
            fragment_id = require_id(fragment["id"], f"{fragment_path}.id")
            if fragment_id in fragments:
                raise ValueError(f"{path}: duplicate fragment ID {fragment_id}")
            source_topic_id = fragment["source_topic_id"]
            if source_topic_id not in targets:
                raise ValueError(f"{fragment_path}: fragment source Topic is not a decision target")
            enriched = _enrich_fragment(
                fragment, package_topics[source_topic_id], sources, revisions, words, fragment_path
            )
            fragments[fragment_id] = enriched
            fragments_by_topic[source_topic_id].append(enriched)

        for target_id, topic_fragments in fragments_by_topic.items():
            ordered = sorted(topic_fragments, key=lambda item: item["word_start_sequence"])
            expected = package_topics[target_id]["word_start_sequence"]
            for fragment in ordered:
                if fragment["word_start_sequence"] != expected:
                    raise ValueError(f"{path}: gap or overlap in fragment partition for {target_id}")
                expected = fragment["word_end_sequence"] + 1
            if expected != package_topics[target_id]["word_end_sequence"] + 1:
                raise ValueError(f"{path}: fragment partition does not cover all of {target_id}")

        if semantic_records is not None:
            fragment_starts = {fragment["word_start_id"] for fragment in fragments.values()}
            for boundary_ref in boundary_refs:
                if boundary_by_id[boundary_ref]["canonical_word_id"] not in fragment_starts:
                    raise ValueError(f"{path}: exact boundary is not represented by a source-fragment start")

        consumed: set[str] = set()
        normalized_results: list[dict[str, Any]] = []
        for result_number, result in enumerate(decision["results"]):
            result_path = f"{path}.results[{result_number}]"
            result_id = require_id(result["id"], f"{result_path}.id")
            if result_id in result_ids:
                raise ValueError(f"duplicate V2 result ID {result_id}")
            result_ids.add(result_id)
            if result["disposition"] not in V2_DISPOSITIONS:
                raise ValueError(f"{result_path}: unsupported disposition")
            refs = result["fragment_refs"]
            if any(ref not in fragments for ref in refs):
                raise ValueError(f"{result_path}: unknown fragment reference")
            if consumed.intersection(refs):
                raise ValueError(f"{result_path}: source fragment is consumed more than once")
            consumed.update(refs)
            if not set(result["evidence_refs"]).issubset(package_evidence):
                raise ValueError(f"{result_path}: evidence is not in the reviewed package")
            selected = [fragments[ref] for ref in refs]
            selected.sort(key=lambda item: item["word_start_sequence"])
            source_keys = {(item["source_id"], item["transcript_revision_id"]) for item in selected}
            if len(source_keys) != 1:
                raise ValueError(f"{result_path}: cross-source or cross-revision composition is unsupported")
            for previous, current in zip(selected, selected[1:]):
                if current["word_start_sequence"] != previous["word_end_sequence"] + 1:
                    raise ValueError(f"{result_path}: composed result fragments are not contiguous")
            normalized_results.append(
                {
                    **result,
                    "source_id": selected[0]["source_id"],
                    "transcript_revision_id": selected[0]["transcript_revision_id"],
                    "word_start_id": selected[0]["word_start_id"],
                    "word_end_id": selected[-1]["word_end_id"],
                    "word_start_sequence": selected[0]["word_start_sequence"],
                    "word_end_sequence": selected[-1]["word_end_sequence"],
                    "locator": {
                        "type": "time_interval",
                        "start_seconds": selected[0]["locator"]["start_seconds"],
                        "end_seconds": selected[-1]["locator"]["end_seconds"],
                    },
                }
            )
        if consumed != set(fragments):
            raise ValueError(f"{path}: every source fragment must map to exactly one typed result")
        normalized.append({**decision, "source_fragments": list(fragments.values()), "results": normalized_results})

    if require_complete and set(covered) != set(package_topics):
        raise ValueError(f"unreviewed Topic Drafts remain: {sorted(set(package_topics) - set(covered))}")
    if semantic_records is not None:
        if consumed_semantic_refs != set(semantic_by_id):
            raise ValueError("authoritative semantic decision provenance is incomplete")
        if consumed_boundary_refs != set(boundary_by_id):
            raise ValueError("exact-boundary decision provenance is incomplete")
    return covered, normalized


def status_v2(project: Path, package_path: Path, decisions_path: Path) -> dict[str, Any]:
    package, bundle = load_package(project, package_path)
    decisions = load_json(decisions_path, "Topic review decisions V2")
    covered, normalized = validate_decisions_v2(package_path, package, bundle, decisions, require_complete=False)
    return {
        "status": "PASS",
        "schema_version": VERSION_V2,
        "source_topics": len(package["topics"]),
        "covered_topics": len(covered),
        "decisions": len(normalized),
        "fragments": sum(len(item["source_fragments"]) for item in normalized),
        "results": sum(len(item["results"]) for item in normalized),
        "boundary_authority": decisions["boundary_authority"],
        "application_authorized": decisions["boundary_authority"] == "PRODUCT_OWNER_DOMAIN_REVIEW",
        "authoritative_semantic_decisions": len(decisions.get("authoritative_semantic_decisions", [])),
        "resolved_boundary_decisions": len(
            decisions.get("exact_boundary_provenance", {}).get("resolved_boundaries", [])
        ),
    }


def apply_v2(project: Path, package_path: Path, decisions_path: Path, output: Path) -> dict[str, Any]:
    if output.exists():
        raise ValueError(f"review result V2 already exists: {output}")
    package, bundle = load_package(project, package_path)
    decisions = load_json(decisions_path, "Topic review decisions V2")
    _, normalized = validate_decisions_v2(
        package_path, package, bundle, decisions, require_complete=True, require_approved_boundaries=True
    )
    canonical_path = project / "evidence" / "canonical_bundle.json"
    timeline_path = project / "evidence" / "word_timeline.json"
    if not timeline_path.is_file():
        raise ValueError("project Word Timeline is missing")
    canonical_hash = sha256_file(canonical_path)
    timeline_hash = sha256_file(timeline_path)
    decision_hash = sha256_file(decisions_path)
    units = {disposition: [] for disposition in V2_DISPOSITIONS}
    lineage: list[dict[str, Any]] = []
    for decision in normalized:
        for fragment in decision["source_fragments"]:
            lineage.append(
                {
                    **fragment,
                    "word_timeline_provenance": {
                        "path": "evidence/word_timeline.json",
                        "sha256": timeline_hash,
                    },
                    "review_decision_provenance": {
                        "review_decision_id": decision["id"],
                        "decision_artifact_id": decisions["artifact_id"],
                        "decision_artifact_sha256": decision_hash,
                        "actor_type": decisions["reviewer"]["actor_type"],
                        "actor_id": decisions["reviewer"]["actor_id"],
                        "semantic_decision_refs": decision.get("semantic_decision_refs", []),
                        "boundary_decision_refs": decision.get("boundary_decision_refs", []),
                    },
                }
            )
        for result in decision["results"]:
            units[result["disposition"]].append(
                {
                    **result,
                    "provenance": {
                        "review_decision_id": decision["id"],
                        "decision_artifact_id": decisions["artifact_id"],
                        "decision_artifact_sha256": decision_hash,
                        "canonical_evidence_sha256": canonical_hash,
                        "word_timeline_sha256": timeline_hash,
                        "boundary_authority": decisions["boundary_authority"],
                        "semantic_decision_refs": decision.get("semantic_decision_refs", []),
                        "boundary_decision_refs": decision.get("boundary_decision_refs", []),
                    },
                }
            )
    result = {
        "schema_version": VERSION_V2,
        "artifact_type": "seminartext.human_review_result",
        "artifact_id": stable_id(decisions["artifact_id"], "review_result"),
        "review_package": {"artifact_id": package["artifact_id"], "sha256": sha256_file(package_path)},
        "decision_artifact": {"artifact_id": decisions["artifact_id"], "sha256": decision_hash},
        "canonical_evidence": {"artifact_id": bundle["artifact_id"], "sha256": canonical_hash},
        "word_timeline": {"path": "evidence/word_timeline.json", "sha256": timeline_hash},
        "source_topic_snapshots": package["topics"],
        "fragment_lineage": sorted(lineage, key=lambda item: (item["word_start_sequence"], item["id"])),
        "semantic_knowledge": sorted(units["SEMANTIC_KNOWLEDGE"], key=lambda item: (item["sequence"], item["id"])),
        "seminar_structure": sorted(units["SEMINAR_STRUCTURE"], key=lambda item: (item["sequence"], item["id"])),
        "non_semantic_excluded": sorted(units["NON_SEMANTIC_EXCLUDED"], key=lambda item: (item["sequence"], item["id"])),
        "application_status": "APPLIED",
        "decision_artifact_limitations": decisions.get("limitations", []),
    }
    validate_schema_v2(result)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(canonical_bytes(result))
    return {"status": "PASS", "output": str(output), "output_sha256": sha256_file(output)}


def _word_context(
    words: list[dict[str, Any]], transcript_revision_id: str, sequence: int, radius: int = 12
) -> tuple[str, str]:
    ordered = sorted(
        (item for item in words if item["transcript_revision_id"] == transcript_revision_id),
        key=lambda item: item["sequence"],
    )
    by_sequence = {item["sequence"]: item for item in ordered}
    before = " ".join(by_sequence[number]["text"] for number in range(max(0, sequence - radius), sequence) if number in by_sequence)
    after = " ".join(by_sequence[number]["text"] for number in range(sequence, sequence + radius) if number in by_sequence)
    return before, after


def render_boundary_review(proposals: dict[str, Any]) -> str:
    lines = [
        "# Exact boundary proposals — Product Owner review",
        "",
        "These machine-located anchors are non-authoritative. The semantic decisions are already accepted; only exact word positions are under review.",
        "",
        "Allowed review outcomes: `ACCEPT_BOUNDARY_PROPOSAL`, `SELECT_ALTERNATIVE`, `ADJUST`, `DEFER`.",
        "",
    ]
    for number, proposal in enumerate(proposals["proposals"], 1):
        lines.extend(
            [
                f"## {number}. {proposal['boundary_proposal_id']}",
                "",
                f"- Drafts: {', '.join(f'`{item}`' for item in proposal['affected_original_drafts'])}",
                f"- Boundary role: `{proposal['boundary_role']}`",
                f"- Ambiguity: `{proposal['ambiguity']}`",
                f"- Confidence: `{proposal['confidence']}`",
                f"- Status: `{proposal['status']}`",
                f"- Accepted semantic decision: {proposal['accepted_po_semantic_decision']}",
                "",
            ]
        )
        for candidate_number, candidate in enumerate(proposal["candidates"], 1):
            lines.extend(
                [
                    f"### Candidate {candidate_number}",
                    "",
                    f"- Word: `{candidate['word_id']}`",
                    f"- Timestamp: `{candidate['timestamp']:.3f}` seconds",
                    f"- Mechanical rationale: {candidate['mechanical_rationale']}",
                    "",
                    f"Before: …{candidate['evidence_before']}",
                    "",
                    f"After: **{candidate['evidence_after']}**…",
                    "",
                ]
            )
        if proposal.get("blocker_reason"):
            lines.extend([f"Blocker: {proposal['blocker_reason']}", ""])
        lines.extend(["Product Owner outcome: `________________`", "", "---", ""])
    return "\n".join(lines).rstrip() + "\n"


def prepare_boundary_proposals(project: Path, package_path: Path, requests_path: Path, output: Path) -> dict[str, Any]:
    if output.exists():
        raise ValueError(f"boundary proposal output already exists: {output}")
    package, bundle = load_package(project, package_path)
    requests = load_json(requests_path, "boundary proposal requests")
    validate_schema_v2(requests)
    if requests.get("artifact_type") != "seminartext.boundary_proposal_requests":
        raise ValueError("boundary proposal request contract mismatch")
    if requests["review_package_id"] != package["artifact_id"] or requests["review_package_sha256"] != sha256_file(package_path):
        raise ValueError("boundary requests refer to a stale or different review package")
    topics = {item["id"]: item for item in package["topics"]}
    words = index(bundle["words"], "$.canonical.words")
    word_list = list(words.values())
    revisions = index(bundle["transcript_revisions"], "$.canonical.transcript_revisions")
    proposals: list[dict[str, Any]] = []
    request_ids: set[str] = set()
    for number, request in enumerate(requests["requests"]):
        path = f"$.requests[{number}]"
        request_id = require_id(request["id"], f"{path}.id")
        if request_id in request_ids:
            raise ValueError(f"duplicate boundary proposal request {request_id}")
        request_ids.add(request_id)
        affected = request["affected_original_drafts"]
        if any(topic_id not in topics for topic_id in affected):
            raise ValueError(f"{path}: affected original draft is not in the review package")
        candidates = []
        rationales = request["mechanical_rationales"]
        if len(rationales) != len(request["candidate_word_ids"]):
            raise ValueError(f"{path}: each candidate requires one mechanical rationale")
        affected_source_keys = {(topics[item]["source_id"], topics[item]["transcript_revision_id"]) for item in affected}
        for candidate_number, (word_id, rationale) in enumerate(zip(request["candidate_word_ids"], rationales)):
            word = words.get(word_id)
            if word is None:
                raise ValueError(f"{path}.candidate_word_ids[{candidate_number}]: canonical Word does not exist")
            if (word["source_id"], word["transcript_revision_id"]) not in affected_source_keys:
                raise ValueError(f"{path}: candidate belongs to another source or TranscriptRevision")
            minimum = min(topics[item]["word_start_sequence"] for item in affected)
            maximum = max(topics[item]["word_end_sequence"] for item in affected)
            if not minimum <= word["sequence"] <= maximum:
                raise ValueError(f"{path}: candidate lies outside the affected original Draft span")
            timestamp = word.get("start_seconds")
            if not isinstance(timestamp, (int, float)):
                timestamp = word.get("end_seconds")
            if not isinstance(timestamp, (int, float)):
                raise ValueError(f"{path}: candidate has no exact aligned timestamp")
            before, after = _word_context(word_list, word["transcript_revision_id"], word["sequence"])
            candidates.append(
                {
                    "word_id": word_id,
                    "timestamp": timestamp,
                    "evidence_before": before,
                    "evidence_after": after,
                    "mechanical_rationale": rationale,
                }
            )
        ambiguity = (
            "INSUFFICIENT_EVIDENCE" if not candidates else "NONE" if len(candidates) == 1 else "MULTIPLE_CANDIDATES"
        )
        proposal = {
            "boundary_proposal_id": request_id,
            "affected_original_drafts": affected,
            "accepted_po_semantic_decision": request["accepted_po_semantic_decision"],
            "boundary_role": request["boundary_role"],
            "proposed_canonical_word_id": candidates[0]["word_id"] if len(candidates) == 1 else None,
            "proposed_timestamp": candidates[0]["timestamp"] if len(candidates) == 1 else None,
            "candidates": candidates,
            "ambiguity": ambiguity,
            "confidence": request["confidence"],
            "status": "REVIEW_REQUIRED",
        }
        if not candidates:
            if not request.get("blocker_reason"):
                raise ValueError(f"{path}: insufficient evidence requires blocker_reason")
            proposal["blocker_reason"] = request["blocker_reason"]
        proposals.append(proposal)
    timeline_path = project / "evidence" / "word_timeline.json"
    if not timeline_path.is_file():
        raise ValueError("project Word Timeline is missing")
    source_revisions = {topics[item]["transcript_revision_id"] for request in requests["requests"] for item in request["affected_original_drafts"]}
    assurance = {revision_id: revisions[revision_id]["transcript_provenance"] for revision_id in sorted(source_revisions)}
    artifact = {
        "schema_version": VERSION_V2,
        "artifact_type": "seminartext.boundary_proposals",
        "artifact_id": stable_id(requests["artifact_id"], "boundary_proposals"),
        "authority": "REVIEW_REQUIRED",
        "review_package": {"artifact_id": package["artifact_id"], "sha256": sha256_file(package_path)},
        "canonical_evidence": {"artifact_id": bundle["artifact_id"], "sha256": sha256_file(project / "evidence" / "canonical_bundle.json")},
        "word_timeline": {"path": "evidence/word_timeline.json", "sha256": sha256_file(timeline_path)},
        "transcript_assurance": assurance,
        "proposals": proposals,
    }
    validate_schema_v2(artifact)
    output.mkdir(parents=True)
    json_path = output / "boundary_proposals.json"
    markdown_path = output / "BOUNDARY_REVIEW.md"
    json_path.write_bytes(canonical_bytes(artifact))
    markdown_path.write_text(render_boundary_review(artifact), encoding="utf-8")
    counts = {"NONE": 0, "MULTIPLE_CANDIDATES": 0, "INSUFFICIENT_EVIDENCE": 0}
    for proposal in proposals:
        counts[proposal["ambiguity"]] += 1
    return {
        "status": "REVIEW_REQUIRED",
        "total": len(proposals),
        "unambiguous": counts["NONE"],
        "ambiguous": counts["MULTIPLE_CANDIDATES"],
        "blocked": counts["INSUFFICIENT_EVIDENCE"],
        "artifact": str(json_path),
        "review_document": str(markdown_path),
    }


def _boundary_proposal_index(proposals: dict[str, Any]) -> dict[str, dict[str, Any]]:
    validate_schema_v2(proposals)
    if proposals.get("artifact_type") != "seminartext.boundary_proposals":
        raise ValueError("boundary proposal contract mismatch")
    result: dict[str, dict[str, Any]] = {}
    for number, proposal in enumerate(proposals["proposals"]):
        proposal_id = require_id(proposal["boundary_proposal_id"], f"$.proposals[{number}].boundary_proposal_id")
        if proposal_id in result:
            raise ValueError(f"duplicate boundary proposal {proposal_id}")
        result[proposal_id] = proposal
    return result


def _resolve_boundary_choices(
    proposals_path: Path,
    proposals: dict[str, Any],
    ledger: dict[str, Any],
) -> list[dict[str, Any]]:
    validate_schema_v2(ledger)
    if ledger.get("artifact_type") != BOUNDARY_LEDGER_TYPE:
        raise ValueError("boundary review ledger contract mismatch")
    expected_proposal_ref = {
        "artifact_id": proposals["artifact_id"],
        "sha256": sha256_file(proposals_path),
    }
    if ledger["boundary_proposals"] != expected_proposal_ref:
        raise ValueError("boundary review ledger refers to stale or different proposals")
    if ledger["reviewer"]["actor_type"] not in HUMAN_ACTORS:
        raise ValueError("boundary DOMAIN_REVIEW requires a human reviewer")
    require_id(ledger["reviewer"]["actor_id"], "$.reviewer.actor_id")

    proposal_by_id = _boundary_proposal_index(proposals)
    decision_ids: set[str] = set()
    resolved: list[dict[str, Any]] = []
    for number, choice in enumerate(ledger["decisions"]):
        path = f"$.decisions[{number}]"
        proposal_id = require_id(choice["boundary_proposal_id"], f"{path}.boundary_proposal_id")
        if proposal_id in decision_ids:
            raise ValueError(f"duplicate boundary DOMAIN_REVIEW decision {proposal_id}")
        decision_ids.add(proposal_id)
        proposal = proposal_by_id.get(proposal_id)
        if proposal is None:
            raise ValueError(f"{path}: unknown boundary proposal {proposal_id}")

        candidate_number = choice["selected_candidate_number"]
        if candidate_number > len(proposal["candidates"]):
            raise ValueError(f"{path}: selected candidate does not exist")
        candidate = proposal["candidates"][candidate_number - 1]
        if choice["canonical_word_id"] != candidate["word_id"] or choice["timestamp"] != candidate["timestamp"]:
            raise ValueError(f"{path}: selected canonical anchor does not match the stated candidate")
        if choice["outcome"] == "ACCEPT_BOUNDARY_PROPOSAL":
            if proposal["ambiguity"] != "NONE" or candidate_number != 1:
                raise ValueError(f"{path}: ACCEPT_BOUNDARY_PROPOSAL requires the sole proposed candidate")
        elif proposal["ambiguity"] != "MULTIPLE_CANDIDATES":
            raise ValueError(f"{path}: SELECT_ALTERNATIVE requires multiple candidates")

        resolved.append(
            {
                **choice,
                "selected_candidate": candidate,
                "affected_original_drafts": proposal["affected_original_drafts"],
                "accepted_po_semantic_decision": proposal["accepted_po_semantic_decision"],
                "boundary_role": proposal["boundary_role"],
                "status": "DECIDED",
            }
        )

    missing = sorted(set(proposal_by_id) - decision_ids)
    unexpected = sorted(decision_ids - set(proposal_by_id))
    if missing or unexpected:
        raise ValueError(f"boundary DOMAIN_REVIEW ledger is incomplete: missing={missing} unexpected={unexpected}")
    return resolved


def resolve_boundary_decisions(
    project: Path,
    proposals_path: Path,
    ledger_path: Path,
    output: Path,
) -> dict[str, Any]:
    if output.exists():
        raise ValueError(f"boundary decision artifact already exists: {output}")
    proposals = load_json(proposals_path, "boundary proposals")
    ledger = load_json(ledger_path, "boundary review ledger")
    resolved = _resolve_boundary_choices(proposals_path, proposals, ledger)
    artifact = {
        "schema_version": VERSION_V2,
        "artifact_type": BOUNDARY_DECISIONS_TYPE,
        "artifact_id": stable_id(ledger["artifact_id"], "boundary_decisions"),
        "authority": "PRODUCT_OWNER_DOMAIN_REVIEW",
        "review_gate": "DOMAIN_REVIEW",
        "reviewer": ledger["reviewer"],
        "source_ledger": {"artifact_id": ledger["artifact_id"], "sha256": sha256_file(ledger_path)},
        "boundary_proposals": {"artifact_id": proposals["artifact_id"], "sha256": sha256_file(proposals_path)},
        "review_package": proposals["review_package"],
        "canonical_evidence": proposals["canonical_evidence"],
        "word_timeline": proposals["word_timeline"],
        "transcript_assurance": proposals["transcript_assurance"],
        "decisions": resolved,
        "unresolved_review_required": [],
    }
    validate_schema_v2(artifact)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(canonical_bytes(artifact))
    return {
        "status": "PASS",
        "authority": artifact["authority"],
        "decisions_persisted": len(resolved),
        "unresolved_review_required": 0,
        "output": str(output),
        "output_sha256": sha256_file(output),
    }


def status_boundary_decisions(project: Path, proposals_path: Path, decisions_path: Path) -> dict[str, Any]:
    proposals = load_json(proposals_path, "boundary proposals")
    decisions = load_json(decisions_path, "boundary review decisions")
    validate_schema_v2(decisions)
    if decisions.get("artifact_type") != BOUNDARY_DECISIONS_TYPE:
        raise ValueError("boundary review decision contract mismatch")
    expected_ref = {"artifact_id": proposals["artifact_id"], "sha256": sha256_file(proposals_path)}
    if decisions["boundary_proposals"] != expected_ref:
        raise ValueError("boundary review decisions refer to stale or different proposals")
    proposal_by_id = _boundary_proposal_index(proposals)
    resolved_by_id: dict[str, dict[str, Any]] = {}
    for number, decision in enumerate(decisions["decisions"]):
        proposal_id = decision["boundary_proposal_id"]
        if proposal_id in resolved_by_id:
            raise ValueError(f"duplicate resolved boundary decision {proposal_id}")
        proposal = proposal_by_id.get(proposal_id)
        if proposal is None:
            raise ValueError(f"$.decisions[{number}]: unknown boundary proposal {proposal_id}")
        candidate_number = decision["selected_candidate_number"]
        if candidate_number > len(proposal["candidates"]):
            raise ValueError(f"$.decisions[{number}]: selected candidate does not exist")
        candidate = proposal["candidates"][candidate_number - 1]
        if decision["outcome"] == "ACCEPT_BOUNDARY_PROPOSAL":
            if proposal["ambiguity"] != "NONE" or candidate_number != 1:
                raise ValueError(f"$.decisions[{number}]: invalid accepted proposal outcome")
        elif proposal["ambiguity"] != "MULTIPLE_CANDIDATES":
            raise ValueError(f"$.decisions[{number}]: invalid alternative-selection outcome")
        if (
            decision["canonical_word_id"] != candidate["word_id"]
            or decision["timestamp"] != candidate["timestamp"]
            or decision["selected_candidate"] != candidate
            or decision["affected_original_drafts"] != proposal["affected_original_drafts"]
            or decision["accepted_po_semantic_decision"] != proposal["accepted_po_semantic_decision"]
            or decision["boundary_role"] != proposal["boundary_role"]
        ):
            raise ValueError(f"$.decisions[{number}]: resolved decision does not match source proposal")
        resolved_by_id[proposal_id] = decision
    unresolved = sorted(set(proposal_by_id) - set(resolved_by_id))
    if unresolved or decisions["unresolved_review_required"]:
        raise ValueError(f"unresolved boundary proposals remain: {unresolved}")
    return {
        "status": "PASS",
        "authority": decisions["authority"],
        "proposals": len(proposal_by_id),
        "decisions_persisted": len(resolved_by_id),
        "unresolved_review_required": 0,
        "source_transcript_revision_mutated": False,
    }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("project")
    prepare_parser.add_argument("--drafts", required=True)
    prepare_parser.add_argument("--output", required=True)
    status_parser = commands.add_parser("status")
    status_parser.add_argument("project")
    status_parser.add_argument("--package", required=True)
    status_parser.add_argument("--decisions")
    apply_parser = commands.add_parser("apply")
    apply_parser.add_argument("project")
    apply_parser.add_argument("--package", required=True)
    apply_parser.add_argument("--decisions", required=True)
    apply_parser.add_argument("--output", required=True)
    status_v2_parser = commands.add_parser("status-v2")
    status_v2_parser.add_argument("project")
    status_v2_parser.add_argument("--package", required=True)
    status_v2_parser.add_argument("--decisions", required=True)
    apply_v2_parser = commands.add_parser("apply-v2")
    apply_v2_parser.add_argument("project")
    apply_v2_parser.add_argument("--package", required=True)
    apply_v2_parser.add_argument("--decisions", required=True)
    apply_v2_parser.add_argument("--output", required=True)
    boundary_parser = commands.add_parser("prepare-boundaries")
    boundary_parser.add_argument("project")
    boundary_parser.add_argument("--package", required=True)
    boundary_parser.add_argument("--requests", required=True)
    boundary_parser.add_argument("--output", required=True)
    boundary_resolve_parser = commands.add_parser("resolve-boundaries")
    boundary_resolve_parser.add_argument("project")
    boundary_resolve_parser.add_argument("--proposals", required=True)
    boundary_resolve_parser.add_argument("--ledger", required=True)
    boundary_resolve_parser.add_argument("--output", required=True)
    boundary_status_parser = commands.add_parser("boundary-status")
    boundary_status_parser.add_argument("project")
    boundary_status_parser.add_argument("--proposals", required=True)
    boundary_status_parser.add_argument("--decisions", required=True)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        project = Path(args.project).expanduser().resolve()
        if not project.is_dir():
            raise ValueError(f"project does not exist: {project}")
        if args.command == "prepare":
            report = prepare(project, Path(args.drafts).expanduser().resolve(), Path(args.output).expanduser().resolve())
        elif args.command == "status":
            decisions = Path(args.decisions).expanduser().resolve() if args.decisions else None
            report = status(project, Path(args.package).expanduser().resolve(), decisions)
        elif args.command == "apply":
            report = apply(
                project,
                Path(args.package).expanduser().resolve(),
                Path(args.decisions).expanduser().resolve(),
                Path(args.output).expanduser().resolve(),
            )
        elif args.command == "status-v2":
            report = status_v2(
                project,
                Path(args.package).expanduser().resolve(),
                Path(args.decisions).expanduser().resolve(),
            )
        elif args.command == "apply-v2":
            report = apply_v2(
                project,
                Path(args.package).expanduser().resolve(),
                Path(args.decisions).expanduser().resolve(),
                Path(args.output).expanduser().resolve(),
            )
        elif args.command == "prepare-boundaries":
            report = prepare_boundary_proposals(
                project,
                Path(args.package).expanduser().resolve(),
                Path(args.requests).expanduser().resolve(),
                Path(args.output).expanduser().resolve(),
            )
        elif args.command == "resolve-boundaries":
            report = resolve_boundary_decisions(
                project,
                Path(args.proposals).expanduser().resolve(),
                Path(args.ledger).expanduser().resolve(),
                Path(args.output).expanduser().resolve(),
            )
        else:
            report = status_boundary_decisions(
                project,
                Path(args.proposals).expanduser().resolve(),
                Path(args.decisions).expanduser().resolve(),
            )
    except ValueError as exc:
        print(f"HUMAN REVIEW WORKFLOW: FAIL\n{exc}", file=sys.stderr)
        return 2
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
