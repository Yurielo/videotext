#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
from pathlib import Path

MODEL = "qwen2.5:7b"

def clean(text):
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", str(text or ""))
    return "".join(c for c in text if c in "\n\t" or ord(c) >= 32)

def is_english(text):
    latin = len(re.findall(r"[A-Za-z]", text))
    cyr = len(re.findall(r"[А-Яа-яЁё]", text))
    return latin > cyr and latin >= 20

def run_model(prompt):
    p = subprocess.run(["ollama", "run", MODEL], input=prompt, text=True,
                       capture_output=True, timeout=1800, check=False)
    if p.returncode:
        raise SystemExit(p.stderr.strip() or "Ошибка Ollama")
    return p.stdout.strip()

def json_array(raw):
    raw = clean(raw)
    a, b = raw.find("["), raw.rfind("]")
    if a < 0 or b <= a:
        raise ValueError("Ollama не вернула JSON-массив")
    return json.loads(raw[a:b + 1], strict=False)

def translate_batch(values):
    payload = json.dumps(values, ensure_ascii=False)
    prompt = f"""Переведи с английского на русский следующий JSON-массив строк.
Верни только JSON-массив той же длины и в том же порядке.
Не добавляй пояснений, не меняй смысл и не объединяй строки.
ТЕКСТ:
{payload}"""
    result = json_array(run_model(prompt))
    if len(result) != len(values):
        raise ValueError("Ollama изменила количество строк при переводе")
    return [clean(x) for x in result]

def find_folder(root, source):
    target = str(Path(source).expanduser().resolve())
    for marker in root.rglob(".source_path"):
        try:
            value = str(Path(marker.read_text(encoding="utf-8").strip()).expanduser().resolve())
        except OSError:
            continue
        if value == target or Path(value).name == Path(source).name:
            return marker.parent
    raise SystemExit("Ошибка: папка результатов для этого видео не найдена")

def latest_srt(folder):
    candidates = []
    for p in folder.glob("transcript*.srt"):
        m = re.fullmatch(r"transcript(\d+)\.srt", p.name)
        candidates.append((int(m.group(1)) if m else 0, p))
    if not candidates:
        raise SystemExit("Ошибка: готовая расшифровка SRT не найдена")
    return sorted(candidates)[-1][1]

def translate_srt(src, dst, force):
    raw = src.read_text(encoding="utf-8", errors="replace").strip()
    blocks = re.split(r"\n\s*\n", raw)
    parsed, texts = [], []
    for block in blocks:
        lines = block.splitlines()
        ti = next((i for i, line in enumerate(lines) if "-->" in line), None)
        if ti is None:
            continue
        parsed.append((lines[:ti + 1], lines[ti + 1:]))
        texts.append(" ".join(x.strip() for x in lines[ti + 1:] if x.strip()))
    if not texts:
        raise SystemExit("Ошибка: SRT не содержит текста")
    if not is_english(" ".join(texts)):
        raise SystemExit("Перевод не требуется: расшифровка определена как русская")
    if dst.exists() and not force:
        print(f"Готовый перевод уже существует, используется повторно: {dst}")
        return
    translated = []
    for i in range(0, len(texts), 40):
        translated.extend(translate_batch(texts[i:i + 40]))
        print(f"Переведено субтитров: {min(i + 40, len(texts))}/{len(texts)}")
    out = []
    for i, (head, _) in enumerate(parsed, 1):
        out.append("\n".join([str(i)] + head[1:] + [translated[i - 1]]))
    dst.write_text("\n\n".join(out) + "\n", encoding="utf-8")
    print(f"РУССКИЕ СУБТИТРЫ ГОТОВЫ: {dst}")

def translate_topics(folder, force):
    src = folder / "topics.json"
    if not src.is_file():
        return
    data = json.loads(src.read_text(encoding="utf-8"))
    topics = data.get("topics", [])
    values = [f"{t.get('title', '')}\\n{t.get('summary', '')}" for t in topics]
    dst = folder / "topics_ru.json"
    if dst.exists() and not force:
        print(f"Готовый перевод таймкодинга уже существует: {dst}")
        return
    translated = []
    for i in range(0, len(values), 40):
        translated.extend(translate_batch(values[i:i + 40]))
    result = dict(data)
    result["language"] = "ru"
    result["translated_from"] = str(src)
    result["topics"] = []
    for t, text in zip(topics, translated):
        title, _, summary = text.partition("\n")
        item = dict(t)
        item["title"], item["summary"] = title.strip(), summary.strip()
        result["topics"].append(item)
    dst.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (folder / "topics_ru.txt").write_text("\n".join(
        f"{t['start']}–{t['end']} — {t['title']}" for t in result["topics"]
    ) + "\n", encoding="utf-8")
    print(f"РУССКИЙ ТАЙМКОДИНГ ГОТОВ: {dst}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("--root", default="~/Documents/Расшифровки")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    folder = find_folder(Path(args.root).expanduser(), args.source)
    src = latest_srt(folder)
    translate_srt(src, folder / "transcript_ru.srt", args.force)
    translate_topics(folder, args.force)
    (folder / "language.json").write_text(json.dumps({"original": "en", "translation": "ru"}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

if __name__ == "__main__":
    main()
