"""Versioned, source-bound identity for native project ASR completion.

The legacy ``.seminartext_complete`` marker remains a readable lifecycle flag.
It is never sufficient evidence of compatible reuse without the versioned
identity stored beside it in ``.seminartext_completion.json``.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
ARTIFACT_TYPE = "seminartext.asr_completion"
IDENTITY_NAME = ".seminartext_completion.json"
MARKER_NAME = ".seminartext_complete"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _resolved_file(path_value: str | Path) -> Path:
    path = Path(path_value).expanduser().resolve(strict=True)
    if not path.is_file():
        raise ValueError(f"expected a regular file: {path}")
    return path


def build_configuration(
    *,
    language: str,
    mode: str,
    chunk_seconds: int,
    model_path: str | Path,
    vad_model_path: str | Path,
    whisper_path: str | Path,
    producer_path: str | Path,
    producer_version: str,
    whisper_threads: int,
    structured_timing: bool,
) -> dict[str, Any]:
    """Describe effective ASR inputs and the exact producer/runtime bytes."""
    if language not in {"ru", "en"}:
        raise ValueError(f"unsupported ASR language: {language}")
    if mode not in {"normal", "careful"}:
        raise ValueError(f"unsupported ASR mode: {mode}")
    if not isinstance(chunk_seconds, int) or chunk_seconds < 1:
        raise ValueError("chunk_seconds must be a positive integer")

    model = _resolved_file(model_path)
    vad_model = _resolved_file(vad_model_path)
    whisper = _resolved_file(whisper_path)
    producer = _resolved_file(producer_path)
    return {
        "language": language,
        "mode": mode,
        "chunk_seconds": chunk_seconds,
        "whisper_model": {"path": str(model), "sha256": sha256_file(model)},
        "vad_model": {"path": str(vad_model), "sha256": sha256_file(vad_model)},
        "whisper_runtime": {"path": str(whisper), "sha256": sha256_file(whisper)},
        "producer": {"path": str(producer), "sha256": sha256_file(producer)},
        "producer_version": producer_version,
        "parameters": {
            "threads": whisper_threads,
            "normal": {"threshold": 0.55, "silence_ms": 550, "beam": 5, "best_of": 5},
            "careful": {"threshold": 0.45, "silence_ms": 700, "beam": 8, "best_of": 8},
            "retry": {"threshold": 0.68, "silence_ms": 350, "beam": 3, "best_of": 3},
            "vad": {"speech_pad_ms": 250, "max_speech_duration_s": 200,
                    "overlap_s": 0.10, "no_speech_threshold": 0.60,
                    "suppress_non_speech": True, "max_len": 80,
                    "split_on_word": True},
            "russian_prompt_sha256": hashlib.sha256(
                "Семинар на русском языке. Целостное Метоисцеление, кинезиология, "
                "прикладная кинезиология, Биологическое Центрирование, "
                "иглорефлексотерапия, акупунктура, меридиан, мышечное тестирование, "
                "психосоматика, метафизика, каббала, кли, масах, клипот, сфирот, "
                "Новолуние, Полнолуние.".encode("utf-8")
            ).hexdigest(),
        },
        "structured_timing": bool(structured_timing),
    }


def _artifact_hashes(
    project_root: Path,
    source_id: str,
    structured_timing: bool,
    source: dict[str, Any] | None = None,
    configuration: dict[str, Any] | None = None,
    allow_derived_rebuild: bool = False,
) -> dict[str, str]:
    relative_paths = [
        f"transcript/{source_id}/transcript.txt",
        f"transcript/{source_id}/transcript_clean.txt",
        f"transcript/{source_id}/transcript_review.txt",
        f"transcript/{source_id}/transcript.srt",
        f"transcript/{source_id}.json",
    ]
    timing_manifest = f"transcript/{source_id}/structured_timing/manifest.json"
    timing_dir = project_root / f"transcript/{source_id}/structured_timing"
    if structured_timing:
        relative_paths.append(timing_manifest)
    elif timing_dir.exists():
        # If selected timing was retained, it is part of the completion bundle
        # and must remain intact even when this invocation did not request it.
        relative_paths.append(timing_manifest)

    result: dict[str, str] = {}
    rebuildable = {
        f"transcript/{source_id}/transcript_clean.txt",
        f"transcript/{source_id}/transcript_review.txt",
        f"transcript/{source_id}.json",
    }
    for relative in relative_paths:
        try:
            path = (project_root / relative).resolve(strict=True)
        except FileNotFoundError as exc:
            if allow_derived_rebuild and relative in rebuildable:
                continue
            raise ValueError(f"required artifact is missing: {relative}") from exc
        if not path.is_relative_to(project_root.resolve()):
            raise ValueError(f"artifact escapes project root: {relative}")
        if not path.is_file():
            raise ValueError(f"required artifact is missing or not a file: {relative}")
        result[relative] = sha256_file(path)

    manifest_path = project_root / timing_manifest
    if timing_manifest in result:
        _validate_timing_manifest(project_root, source_id, manifest_path, source, configuration)
    return result


def _validate_timing_manifest(
    project_root: Path,
    source_id: str,
    manifest_path: Path,
    source: dict[str, Any] | None = None,
    configuration: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    if payload.get("schema_version") != 1 or payload.get("artifact_type") != "seminartext.selected_whisper_timing":
        raise ValueError("selected timing manifest has an unknown schema")
    parts = payload.get("parts")
    if not isinstance(parts, list) or not parts:
        raise ValueError("selected timing manifest has no parts")
    if source is not None and payload.get("source", {}).get("media_sha256") != source.get("sha256"):
        raise ValueError("selected timing source hash does not match the current source")
    if source is not None:
        timing_source = payload.get("source", {})
        reference = timing_source.get("reference")
        if (
            reference != source.get("reference")
            or timing_source.get("reference_sha256")
            != hashlib.sha256(str(reference).encode("utf-8")).hexdigest()
        ):
            raise ValueError("selected timing source reference is inconsistent")
    if configuration is not None:
        transcription = payload.get("transcription", {})
        if (
            transcription.get("language") != configuration.get("language")
            or transcription.get("mode") != configuration.get("mode")
            or transcription.get("chunk_seconds") != configuration.get("chunk_seconds")
            or transcription.get("whisper_model", {}).get("sha256")
            != configuration.get("whisper_model", {}).get("sha256")
            or transcription.get("whisper_model", {}).get("path")
            != configuration.get("whisper_model", {}).get("path")
            or transcription.get("vad_model", {}).get("sha256")
            != configuration.get("vad_model", {}).get("sha256")
            or transcription.get("vad_model", {}).get("path")
            != configuration.get("vad_model", {}).get("path")
        ):
            raise ValueError("selected timing configuration does not match the current ASR configuration")
    for index, part in enumerate(parts):
        if part.get("order") != index or part.get("id") != f"part_{index:04d}":
            raise ValueError("selected timing parts are not contiguous and ordered")
        if part.get("selected_attempt") not in {"initial", "retry"}:
            raise ValueError("selected timing part has no selected attempt identity")
        artifacts = part.get("artifacts")
        if not isinstance(artifacts, dict):
            raise ValueError("selected timing part is missing artifact identities")
        for key in ("txt", "srt", "json_full"):
            artifact = artifacts.get(key)
            if not isinstance(artifact, dict):
                raise ValueError(f"selected timing part is missing {key}")
            relative = artifact.get("path")
            expected = f"parts/part_{index:04d}.{ {'txt':'txt','srt':'srt','json_full':'json'}[key] }"
            if relative != expected:
                raise ValueError(f"selected timing {key} path is inconsistent")
            path = (manifest_path.parent / relative).resolve(strict=True)
            if not path.is_relative_to(manifest_path.parent.resolve()):
                raise ValueError("selected timing artifact escapes timing directory")
            if not path.is_file() or sha256_file(path) != artifact.get("sha256"):
                raise ValueError(f"selected timing {key} hash mismatch for part {index}")
    return payload


def verify_completion(
    project_root: str | Path,
    source_id: str,
    source: dict[str, Any],
    configuration: dict[str, Any],
) -> tuple[bool, str]:
    """Return whether a marker has a matching, intact, versioned identity."""
    root = Path(project_root).resolve()
    identity_path = root / "transcript" / source_id / IDENTITY_NAME
    marker_path = root / "transcript" / source_id / MARKER_NAME
    if not marker_path.is_file() or not identity_path.is_file():
        return False, "legacy or incomplete completion identity"
    try:
        payload = json.loads(identity_path.read_text(encoding="utf-8"))
        if payload.get("schema_version") != SCHEMA_VERSION or payload.get("artifact_type") != ARTIFACT_TYPE:
            return False, "unknown completion identity version"
        if payload.get("source") != source or payload.get("configuration") != configuration:
            return False, "source or ASR configuration identity changed"
        current = _artifact_hashes(
            root, source_id, bool(configuration.get("structured_timing")), source, configuration,
            allow_derived_rebuild=True,
        )
        expected_artifacts = payload.get("artifacts")
        if not isinstance(expected_artifacts, dict):
            return False, "completion identity has no artifact hashes"
        derived_paths = {
            f"transcript/{source_id}/transcript_clean.txt",
            f"transcript/{source_id}/transcript_review.txt",
            f"transcript/{source_id}.json",
        }
        expected_core = {path: digest for path, digest in expected_artifacts.items() if path not in derived_paths}
        current_core = {path: digest for path, digest in current.items() if path not in derived_paths}
        if expected_core != current_core:
            return False, "selected recognized evidence or timing artifact set changed"
        if not derived_paths.issubset(expected_artifacts):
            return False, "completion identity omits required derived artifact identities"
        rebuild = [
            path for path in sorted(derived_paths)
            if current.get(path) != expected_artifacts.get(path)
        ]
        if payload.get("selected_attempts") != _selected_attempts(root, source_id, source, configuration):
            return False, "selected attempt identity changed"
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        return False, f"invalid completion artifacts: {exc}"
    if rebuild:
        return True, "derived artifacts require deterministic rebuild: " + ", ".join(rebuild)
    return True, "compatible validated completion"


def write_completion(
    project_root: str | Path,
    source_id: str,
    source: dict[str, Any],
    configuration: dict[str, Any],
) -> None:
    """Atomically publish a versioned identity only after all artifacts exist."""
    root = Path(project_root).resolve()
    transcript_dir = root / "transcript" / source_id
    if not transcript_dir.is_dir():
        raise ValueError(f"transcript directory does not exist for {source_id}")
    artifacts = _artifact_hashes(
        root, source_id, bool(configuration.get("structured_timing")), source, configuration
    )
    payload = {
        "schema_version": SCHEMA_VERSION,
        "artifact_type": ARTIFACT_TYPE,
        "source": source,
        "configuration": configuration,
        "selected_attempts": _selected_attempts(root, source_id, source, configuration),
        "artifacts": artifacts,
    }
    fd, temporary_name = tempfile.mkstemp(prefix=".completion.", suffix=".tmp", dir=transcript_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, transcript_dir / IDENTITY_NAME)
        (transcript_dir / MARKER_NAME).touch()
    except BaseException:
        Path(temporary_name).unlink(missing_ok=True)
        raise


def _selected_attempts(
    project_root: Path,
    source_id: str,
    source: dict[str, Any] | None = None,
    configuration: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    manifest = project_root / "transcript" / source_id / "structured_timing" / "manifest.json"
    if not manifest.is_file():
        return []
    payload = _validate_timing_manifest(project_root, source_id, manifest, source, configuration)
    return [
        {"part_id": part["id"], "order": part["order"], "selected_attempt": part["selected_attempt"]}
        for part in payload["parts"]
    ]
