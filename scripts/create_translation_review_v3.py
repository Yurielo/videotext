"""Build a diagnostic review package from retained source and actual responses."""
import argparse
import html
import json
from pathlib import Path

ROWS = [[1], [2], [4], [6], [8], [11], [16], [17], [21, 22], [23], [24], [19, 20]]


def timecode(seconds):
    milliseconds = round(seconds * 1000)
    hours, remainder = divmod(milliseconds, 3600000)
    minutes, remainder = divmod(remainder, 60000)
    seconds, milliseconds = divmod(remainder, 1000)
    return f"{hours:02}:{minutes:02}:{seconds:02}.{milliseconds:03}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("v1", type=Path)
    parser.add_argument("v2", type=Path)
    parser.add_argument("production", type=Path)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("--video", type=Path, required=True)
    arguments = parser.parse_args()
    source = json.loads(arguments.fixture.read_text(encoding="utf-8"))["cues"]
    v1 = {cue["id"]: cue["text"] for cue in json.loads(arguments.v1.read_text(encoding="utf-8"))["cues"]}
    v2 = {cue["id"]: cue["text"] for cue in json.loads(arguments.v2.read_text(encoding="utf-8"))["cues"]}
    production = json.loads(arguments.production.read_text(encoding="utf-8"))
    new = {cue["id"]: cue["text"] for cue in production["cues"]}
    assert len(new) == len(source) and list(new) == [cue["id"] for cue in source], "Output alignment changed"
    assert all(a["id"] == b["id"] and a["start"] == b["start"] and a["end"] == b["end"]
               for a, b in zip(source, production["cues"])), "Cue times changed"
    by_id = {cue["id"]: cue for cue in source}
    intro = [
        "# VideoText PR #9: Human Translation Review V3", "",
        "**Human review: NOT PERFORMED. No row is self-approved.**", "",
        "Russian ASR is not audio-Gold. Listen to the source intervals when judging ambiguous rows.",
        "All times below are relative to the 180-second clip (original recording: add 10 minutes).",
        "The clip was recreated from the unchanged source recording; Whisper was not rerun.",
        "Architecture: DOCUMENT CONTEXT + LOCAL OVERLAP CONTEXT + OWNED CONTENT.",
        "Stable identity: cueId. Translation uses only translategemma:4b.",
        f"Protocol: `{production['protocolVersion']}`.",
        f"Model digest: `{production.get('digest')}`.",
        f"Context identity: `{production.get('contextIdentity')}`.",
        f"Structural issues: {production['structuralIssueCount']}.",
        f"Automated failure-class alarms: {', '.join(production['failedChecks']) or 'NONE'}.",
        "These alarms are bounded fixture checks, not independent semantic acceptance.",
        f"[Source clip]({arguments.video.resolve()})", "",
        "Release E2Es: DEFERRED. Candidate: NOT BUILT. Installed app: UNCHANGED.", "",
    ]
    sections = []
    cards = []
    for ids in ROWS:
        position = next(index for index, cue in enumerate(source) if cue["id"] == ids[0])
        last_position = next(index for index, cue in enumerate(source) if cue["id"] == ids[-1])
        context = source[max(0, position - 2):last_position + 3]
        label = " / ".join(map(str, ids))
        interval = f"{timecode(by_id[ids[0]]['start'])} - {timecode(by_id[ids[-1]]['end'])}"
        changed = [str(cue_id) for cue_id in ids if v1[cue_id] != new[cue_id]]
        relevant_alarms = [alarm for alarm in production["failedChecks"]
                           if any(alarm.startswith(f"{cue_id}-") for cue_id in ids)]
        notes = ["Changed vs V1: " + (", ".join(changed) if changed else "NONE")]
        if relevant_alarms:
            notes.append("Automated alarm: " + "; ".join(relevant_alarms))
        if 17 in ids:
            notes.append("Source cue is elliptical; the next cue is not an explicit completion. Listen and do not infer omitted speech.")
        if set(ids).intersection({2, 8, 11}):
            notes.append("Name spelling requires source-audio verification.")
        if 23 in ids:
            notes.append("The long source interval is an existing ASR-timeline anomaly, outside this translation change.")
        entries = [
            ("Russian ASR", "\n".join(f"{cue_id}: {by_id[cue_id]['text']}" for cue_id in ids)),
            ("Surrounding Russian source", "\n".join(f"{cue['id']}: {cue['text']}" for cue in context)),
            ("Original V1", "\n".join(f"{cue_id}: {v1[cue_id]}" for cue_id in ids)),
            ("Rejected V2 experiment", "\n".join(f"{cue_id}: {v2[cue_id]}" for cue_id in ids)),
            ("New production V3", "\n".join(f"{cue_id}: {new[cue_id]}" for cue_id in ids)),
            ("Technical note", "\n".join(notes)),
        ]
        section = [f"## ID {label}: {interval}", ""]
        for title, text in entries:
            section += [f"**{title}**", "", text, ""]
        sections.extend(section)
        details = "".join(f"<h3>{html.escape(title)}</h3><pre>{html.escape(text)}</pre>" for title, text in entries)
        cards.append(f'<section><h2>ID {html.escape(label)}: {interval}</h2><button data-time="{by_id[ids[0]]["start"]}">Listen</button>{details}</section>')
    all_cues = ["## All 24 production cues", ""]
    all_cues += [f"- {cue['id']} | {timecode(cue['start'])} - {timecode(cue['end'])} | {cue['text']}" for cue in production["cues"]]
    arguments.output_directory.mkdir(parents=True, exist_ok=True)
    markdown = "\n".join(intro + sections + all_cues) + "\n"
    (arguments.output_directory / "human-translation-review-v3.md").write_text(markdown, encoding="utf-8")
    header = "<p>Russian ASR is not audio-Gold. Listen to ambiguous intervals. Human review has not been performed; no row is accepted.</p>"
    status = html.escape(", ".join(production["failedChecks"]) or "NONE")
    page = f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VideoText Review V3</title>
<style>body{{font:16px system-ui,sans-serif;margin:24px auto;padding:0 20px;max-width:1000px;color:#202124;background:#fff}}h1{{font-size:26px}}h2{{font-size:20px}}h3{{font-size:15px;margin-bottom:6px}}section{{border-top:1px solid #ddd;padding:20px 0}}pre{{white-space:pre-wrap;overflow-wrap:anywhere;font:15px system-ui,sans-serif;margin-top:0}}video{{width:100%;max-height:360px;background:#111}}button{{padding:8px 16px}}.warning{{border-left:4px solid #ba4400;padding-left:12px}}</style>
<h1>Human Translation Review V3</h1>{header}<p class="warning">Automated alarms: {status}</p>
<video id="source" controls preload="metadata" src="{html.escape(arguments.video.resolve().as_uri(), quote=True)}"></video>{''.join(cards)}
<script>document.querySelectorAll('[data-time]').forEach(button=>button.addEventListener('click',()=>{{const video=document.getElementById('source');video.currentTime=Number(button.dataset.time);video.play();video.scrollIntoView({{block:'center'}});}}));</script></html>'''
    (arguments.output_directory / "human-translation-review-v3.html").write_text(page, encoding="utf-8")
    print(f"V3_PACKAGE_CREATED: {arguments.output_directory.resolve()}")


if __name__ == "__main__":
    main()
