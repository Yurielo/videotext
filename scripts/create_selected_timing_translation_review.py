"""Create a human-review package for VideoText selected-timing translations."""
import argparse
import html
import json
from pathlib import Path


def timecode(seconds):
    milliseconds = round(seconds * 1000)
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    seconds, milliseconds = divmod(remainder, 1000)
    return f"{hours:02}:{minutes:02}:{seconds:02}.{milliseconds:03}"


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def verify(source, translation):
    units = source["units"]
    translated = translation["units"]
    if not units or source["sourceText"] != "".join(unit["text"] for unit in units):
        raise ValueError("source units do not provide lossless coverage")
    if translation["source"] != source or len(units) != len(translated):
        raise ValueError("translation source binding does not match")
    for unit, result in zip(units, translated):
        if (unit["id"], unit["textSHA256"], unit["start"], unit["end"]) != (
            result["sourceUnitID"], result["sourceTextSHA256"], result["start"], result["end"]
        ):
            raise ValueError("translation unit provenance does not match source unit")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    timing = arguments.project / "Support files" / "Selected timing"
    source = load_json(timing / "source_units.json")
    language_pair = next(timing.glob("translations.*-*.json"), None)
    if language_pair is None:
        raise ValueError("selected-timing translation artifact is missing")
    translation = load_json(language_pair)
    verify(source, translation)

    arguments.output.mkdir(parents=True, exist_ok=True)
    rows = list(zip(source["units"], translation["units"]))
    provenance = [
        "# VideoText PR #9: Selected-timing Human Translation Review",
        "",
        "**Reviewer status: NOT REVIEWED. This package does not self-approve translation quality.**",
        "",
        "The source time ranges are assembled by VideoText from selected JSON-full timing",
        "of the canonical SeminarText Whisper attempt. They are source provenance, not target-language word alignment.",
        "Listen to the original media for disputed wording or timing.",
        "",
        f"- Source language: `{translation['sourceLanguage']}`",
        f"- Target language: `{translation['targetLanguage']}`",
        f"- Translation model: `{translation['model']['model']}`",
        f"- Translation model digest: `{translation['model'].get('digest')}`",
        f"- Translation protocol: `{translation['model']['protocolVersion']}`",
        f"- SeminarText selected-manifest SHA-256: `{source['upstreamManifestSHA256']}`",
        f"- Source media SHA-256: `{source['sourceMediaSHA256']}`",
        "- Structural coverage/provenance validation: PASS",
        "- Semantic quality acceptance: PENDING HUMAN REVIEW",
        f"- [Source media]({arguments.video.resolve()})",
        "",
        "Review each row for meaning, negation, names, numbers, terminology, omissions, additions and natural spoken repetitions.",
        "",
    ]
    markdown_rows = []
    html_rows = []
    for unit, result in rows:
        interval = f"{timecode(unit['start'])} - {timecode(unit['end'])}"
        markdown_rows.extend([
            f"## Unit {unit['id']}: {interval}", "",
            "**Source**", "", unit["text"], "",
            "**Translation**", "", result["text"], "",
            "**Review**", "", "- [ ] Meaning and terminology faithful", "- [ ] No omission or invented content", "- [ ] Timing belongs to this source passage", "",
        ])
        html_rows.append(
            "<section>"
            f"<h2>Unit {unit['id']}: {html.escape(interval)}</h2>"
            f"<button data-time=\"{unit['start']}\">Listen</button>"
            f"<h3>Source</h3><pre>{html.escape(unit['text'])}</pre>"
            f"<h3>Translation</h3><pre>{html.escape(result['text'])}</pre>"
            "<p>Review: [ ] faithful meaning &nbsp; [ ] no omission/addition &nbsp; [ ] timing truthful</p>"
            "</section>"
        )
    markdown = "\n".join(provenance + markdown_rows) + "\n"
    (arguments.output / "selected-timing-human-translation-review.md").write_text(markdown, encoding="utf-8")
    page = f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VideoText selected-timing review</title>
<style>body{{font:16px system-ui,sans-serif;margin:24px auto;padding:0 20px;max-width:1000px;color:#202124}}section{{border-top:1px solid #ddd;padding:18px 0}}pre{{white-space:pre-wrap;overflow-wrap:anywhere;font:15px system-ui,sans-serif}}video{{width:100%;max-height:420px;background:#111}}button{{padding:8px 16px}}.warning{{border-left:4px solid #b54;padding-left:12px}}</style>
<h1>Selected-timing Human Translation Review</h1><p class="warning">NOT REVIEWED. Structural provenance passed; semantic translation quality requires a human listening review.</p>
<video id="source" controls preload="metadata" src="{html.escape(arguments.video.resolve().as_uri(), quote=True)}"></video>{''.join(html_rows)}
<script>document.querySelectorAll('[data-time]').forEach(button=>button.addEventListener('click',()=>{{const video=document.getElementById('source');video.currentTime=Number(button.dataset.time);video.play();}}));</script></html>'''
    (arguments.output / "selected-timing-human-translation-review.html").write_text(page, encoding="utf-8")
    print(f"SELECTED_TIMING_HUMAN_REVIEW_PACKAGE_CREATED: {arguments.output.resolve()}")


if __name__ == "__main__":
    main()
