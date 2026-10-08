#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

DETAIL = {
    "low": {
        "min_sec": 180,
        "hard_min_sec": 60,
        "target_per_hour": "6–15",
    },
    "auto": {
        "min_sec": 60,
        "hard_min_sec": 25,
        "target_per_hour": "30–45",
    },
    "high": {
        "min_sec": 45,
        "hard_min_sec": 15,
        "target_per_hour": "20–50",
    },
}

WINDOW_SEC = 12 * 60

def clean_model_text(value):
    """Remove terminal/control noise occasionally emitted by local models."""
    text = str(value or "")
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    text = "".join(ch for ch in text if ch == "\n" or ch == "\t" or ord(ch) >= 32)
    return re.sub(r"\s+", " ", text).strip()

def is_russian_topic_text(value):
    """The seminar is Russian; reject translated/English model hallucinations."""
    text = clean_model_text(value)
    return bool(re.search(r"[А-Яа-яЁё]", text)) and not bool(re.search(r"[A-Za-z]", text))

def fallback_row(window):
    """Keep a valid Russian boundary when the local model breaks its contract."""
    source = clean_model_text(window[0].get("text", ""))
    words = re.findall(r"[А-Яа-яЁё0-9-]+", source)
    title = " ".join(words[:8]).strip(" -,:.;")
    if len(title) < 3:
        title = "Продолжение семинара"
    return {"start_id": window[0]["id"], "title": title, "summary": ""}


def has_repeated_words(value):
    """Reject obvious model glitches like 'реакциях реакциях'."""
    words = re.findall(r"[А-Яа-яЁё0-9-]+", clean_model_text(value).lower())
    if len(words) < 2:
        return False
    for a, b in zip(words, words[1:]):
        if len(a) >= 4 and a == b:
            return True
    return False


def has_contract_violation(raw):
    """Detect responses where the model ignored the JSON/Russian contract."""
    value = str(raw or "")
    lowered = value.lower()

    bad_markers = [
        "overall theme",
        "overall focus",
        "key concepts",
        "key sections",
        "would you like me",
        "here's a breakdown",
        "here is a breakdown",
        "in essence",
        "specific examples",
        "logistics & next steps",
    ]

    if any(marker in lowered for marker in bad_markers):
        return True

    # The answer to this task must contain a JSON array.
    if "[" not in value or "]" not in value:
        return True

    return False


def title_is_good(value):
    title = clean_model_text(value)

    if not title or not is_russian_topic_text(title):
        return False

    words = re.findall(r"[А-Яа-яЁё0-9-]+", title)

    if not 2 <= len(words) <= 11:
        return False

    if len(title) > 90:
        return False

    if has_repeated_words(title):
        return False

    if re.match(r"(?i)^тема\s*\d*\s*[:.-]", title):
        return False

    # Reject obvious verbatim conversational fragments.
    bad_starts = (
        "вы можете ",
        "вы знаете ",
        "я думаю ",
        "я хочу ",
        "давайте ",
        "смотрите ",
        "ну ",
        "вот ",
        "а можно ",
        "то есть ",
    )

    low = title.lower()
    if len(words) >= 6 and low.startswith(bad_starts):
        return False

    return True


def summary_is_good(value):
    summary = clean_model_text(value)

    if not summary:
        return True

    if not is_russian_topic_text(summary):
        return False

    if has_repeated_words(summary):
        return False

    if len(summary) > 420:
        return False

    return True


def parse_rows_strict(raw, valid_ids, first_id):
    """Parse only a contract-compliant model answer.

    Unlike old parse_rows(), this function does NOT repair an English
    essay or salvage headings from malformed prose.
    """
    if has_contract_violation(raw):
        raise ValueError("модель нарушила формат ответа")

    data = extract_json_array(raw)

    if not isinstance(data, list) or not data:
        raise ValueError("ожидался непустой JSON-массив")

    ordered_ids = sorted(valid_ids)
    out = []
    seen = set()

    for row in data:
        if not isinstance(row, dict):
            raise ValueError("элемент JSON не является объектом")

        if "start_id" not in row or "title" not in row or "summary" not in row:
            raise ValueError("нет обязательных полей start_id/title/summary")

        raw_sid = row.get("start_id")

        try:
            sid = int(str(raw_sid).strip("[] \"'"))
        except Exception:
            raise ValueError(f"некорректный start_id: {raw_sid!r}")

        # Preserve support for models that accidentally use a local
        # 1-based ordinal, but only if the literal ID is not valid.
        if sid not in valid_ids and 1 <= sid <= len(ordered_ids):
            sid = ordered_ids[sid - 1]

        if sid not in valid_ids:
            raise ValueError(f"несуществующий start_id: {sid}")

        if sid in seen:
            raise ValueError(f"повтор start_id: {sid}")

        title = clean_model_text(row.get("title", ""))
        summary = clean_model_text(row.get("summary", ""))

        if not title_is_good(title):
            raise ValueError(f"плохой title: {title!r}")

        if not summary_is_good(summary):
            raise ValueError(f"плохой summary: {summary!r}")

        seen.add(sid)

        out.append({
            "start_id": sid,
            "title": title,
            "summary": summary,
            "evidence_start_id": int(row.get("evidence_start_id", sid)),
            "evidence_end_id": int(row.get("evidence_end_id", sid)),
        })

    out.sort(key=lambda x: x["start_id"])

    if not out:
        raise ValueError("после QA не осталось тематических границ")

    # Strict mode: first returned boundary really must be the first
    # segment of the analysis window.
    if out[0]["start_id"] != first_id:
        raise ValueError(
            f"первая тема начинается с {out[0]['start_id']}, "
            f"ожидался {first_id}"
        )

    return out


def retry_window_prompt(window, detail):
    """Second attempt after the model ignored the primary contract."""
    lines = []
    for x in window:
        value = re.sub(r"\s+", " ", x["text"]).strip()
        lines.append(
            f'[{x["id"]}] {fmt_clock(x["start"])}–'
            f'{fmt_clock(x["end"])} | {value}'
        )

    first_id = window[0]["id"]

    return f"""Выполни задачу заново.

ПРЕДЫДУЩИЙ ОТВЕТ БЫЛ ОШИБОЧНЫМ И НЕ СООТВЕТСТВОВАЛ ФОРМАТУ.

Тебе дан ТОЛЬКО один фрагмент русскоязычного семинара.
Не пересказывай семинар.
Не пиши Overall Theme, Key Concepts, выводы, советы или Markdown.
Не предлагай дальнейшую помощь.
Не отвечай по-английски.

Нужно определить смены темы ТОЛЬКО внутри показанного фрагмента.

Ответ должен быть ТОЛЬКО корректным JSON-массивом вида:

[
  {{"start_id": {first_id}, "title": "Русское название темы", "summary": "Короткое русское описание"}}
]

Правила:
- Все title и summary только на русском языке.
- Первый start_id ОБЯЗАТЕЛЬНО {first_id}.
- Используй только ID из квадратных скобок.
- title: 2–10 слов.
- title должен называть ТЕМУ, а не копировать случайную реплику.
- summary: максимум одно короткое предложение.
- Не добавляй знаний, которых нет в тексте.
- Режим детализации: {detail}.
- Ориентир: {DETAIL[detail]["target_per_hour"]} тем на час.
- Не делай темы короче примерно {DETAIL[detail]["min_sec"]} секунд
  без реальной смысловой смены.

СЕГМЕНТЫ:
""" + "\n".join(lines)


def recovery_window_prompt(window, detail):
    """Minimal final model attempt based only on original transcript."""
    lines = []
    for x in window:
        value = re.sub(r"\s+", " ", x["text"]).strip()
        lines.append(f'[{x["id"]}] {value}')

    first_id = window[0]["id"]

    return f"""Ты работаешь как технический тематизатор расшифровки.

Верни ТОЛЬКО JSON. Никакого другого текста.

Определи основные смысловые темы этого фрагмента.
Не пересказывай весь семинар.
Не копируй длинные реплики в title.

Первый элемент:
start_id = {first_id}

Формат:
[
  {{
    "start_id": {first_id},
    "title": "Название темы на русском",
    "summary": "Одно короткое предложение на русском"
  }}
]

Допускается несколько элементов.
Используй только реальные ID из текста.
Режим: {detail}.

ТЕКСТ:
""" + "\n".join(lines)


def improved_fallback_row(window):
    """Last-resort deterministic fallback.

    It is intentionally conservative and marked for manual review.
    """
    joined = " ".join(
        clean_model_text(x.get("text", ""))
        for x in window[:12]
    )

    title = ""

    # Useful especially for seminar openings.
    seminar_name = re.search(
        r'семинар[а-яё]*\s+[«"]([^»"]{2,60})[»"]',
        joined,
        flags=re.I,
    )

    if seminar_name:
        title = f'Введение в семинар «{seminar_name.group(1).strip()}»'

    if not title:
        # Keep fallback neutral rather than inventing a false semantic label.
        title = "Тема требует ручной проверки"

    return {
        "start_id": window[0]["id"],
        "title": title,
        "summary": "",
        "qa_status": "fallback",
        "qa_attempt": "fallback",
    }


def parse_srt(path: Path):
    raw = path.read_text(encoding="utf-8", errors="replace").strip()
    blocks = re.split(r"\n\s*\n", raw) if raw else []
    items = []
    for block in blocks:
        lines = [x.rstrip() for x in block.splitlines()]
        ti = next((i for i, x in enumerate(lines) if "-->" in x), None)
        if ti is None:
            continue
        left, right = [x.strip() for x in lines[ti].split("-->", 1)]
        body = " ".join(x.strip() for x in lines[ti+1:] if x.strip())
        if body:
            items.append({"id": len(items)+1, "start": left, "end": right, "text": body})
    if not items:
        raise SystemExit(f"Ошибка: в SRT нет временных сегментов: {path}")
    return items

def srt_seconds(v):
    h,m,rest = v.split(":")
    s,ms = rest.split(",")
    return int(h)*3600+int(m)*60+int(s)+int(ms)/1000

def fmt_clock(v):
    h,m,rest = v.split(":")
    s = rest.split(",")[0]
    return f"{m}:{s}" if h == "00" else f"{h}:{m}:{s}"

def find_transcript(root: Path, source: Path):
    if source.is_file() and source.suffix.lower() == ".srt":
        return source
    folder = source if source.is_dir() else root / source.stem
    candidates = []
    if folder.is_dir():
        plain = folder / "transcript.srt"
        if plain.is_file():
            candidates.append((0, plain))
        for p in folder.glob("transcript*.srt"):
            m = re.fullmatch(r"transcript(\d+)\.srt", p.name)
            if m:
                candidates.append((int(m.group(1)), p))
    if candidates:
        return sorted(candidates, key=lambda x: x[0])[-1][1]
    if source.is_file() and root.is_dir():
        target = str(source.resolve())
        for marker in root.rglob(".source_path"):
            try:
                value = marker.read_text(encoding="utf-8", errors="replace").strip()
            except OSError:
                continue
            try:
                resolved = str(Path(value).expanduser().resolve())
            except Exception:
                resolved = value
            if resolved == target or Path(value).name == source.name:
                return find_transcript(root, marker.parent)
    raise SystemExit("Ошибка: готовый SRT не найден. Сначала выполните seminartext transcribe файл.mp4")

def make_windows(items, window_sec=WINDOW_SEC):
    windows = []
    cur = []
    win_start = None
    for x in items:
        st = srt_seconds(x["start"])
        if win_start is None:
            win_start = st
        if cur and st - win_start >= window_sec:
            windows.append(cur)
            cur = []
            win_start = st
        cur.append(x)
    if cur:
        windows.append(cur)
    return windows

def run_ollama(model, prompt, timeout=900):
    try:
        p = subprocess.run(
            ["ollama", "run", model],
            input=prompt,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        raise SystemExit("Ошибка: ollama не найден.")
    except subprocess.TimeoutExpired:
        raise RuntimeError("таймаут Ollama")
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout or "").strip())
    return p.stdout.strip()


def run_ollama_structured(
    model,
    prompt,
    detail="auto",
    timeout=900,
    first_id=None,
    valid_ids=None,
):
    """Call local Ollama API with a strict semantic JSON Schema."""

    max_topics = {
        "low": 4,
        "auto": 12,
        "high": 10,
    }.get(detail, 6)

    if first_id is None:
        raise ValueError("first_id обязателен для Structured Outputs")

    valid_ids = sorted(set(valid_ids or []))

    start_id_schema = {
        "type": "integer",
        "minimum": 1,
    }

    if valid_ids:
        start_id_schema["enum"] = valid_ids

    topic_schema = {
        "type": "object",
        "properties": {
            "start_id": start_id_schema,
            "title": {
                "type": "string",
                "minLength": 3,
                "maxLength": 90,
            },
            "summary": {
                "type": "string",
                "maxLength": 420,
            },
            "evidence_start_id": {
                "type": "integer",
                "minimum": 1,
            },
            "evidence_end_id": {
                "type": "integer",
                "minimum": 1,
            },
        },
        "required": [
            "start_id",
            "title",
            "summary",
            "evidence_start_id",
            "evidence_end_id",
        ],
        "additionalProperties": False,
    }

    first_topic_schema = {
        "type": "object",
        "properties": {
            "start_id": {
                "type": "integer",
                "const": int(first_id),
            },
            "title": {
                "type": "string",
                "minLength": 3,
                "maxLength": 90,
            },
            "summary": {
                "type": "string",
                "maxLength": 420,
            },
            "evidence_start_id": {
                "type": "integer",
                "minimum": 1,
            },
            "evidence_end_id": {
                "type": "integer",
                "minimum": 1,
            },
        },
        "required": [
            "start_id",
            "title",
            "summary",
            "evidence_start_id",
            "evidence_end_id",
        ],
        "additionalProperties": False,
    }

    schema = {
        "type": "object",
        "properties": {
            "first_topic": first_topic_schema,
            "additional_topics": {
                "type": "array",
                "maxItems": max(0, max_topics - 1),
                "items": topic_schema,
            },
        },
        "required": [
            "first_topic",
            "additional_topics",
        ],
        "additionalProperties": False,
    }

    payload = {
        "model": model,
        "stream": False,
        "messages": [
            {
                "role": "system",
                "content": (
                    "Ты технический тематизатор русскоязычной расшифровки. "
                    "Определяй только крупные смысловые переходы внутри данного окна. "
                    "Не пересказывай весь текст. "
                    "Не создавай отдельную тему для каждого участника или реплики. "
                    "Название должно быть предметным, 2–10 слов, на русском языке. "
                    "Избегай общих названий вроде «Присутствующие», «Обсуждение», "
                    "«Вопросы», «Продолжение». "
                    "Для каждой темы обязательно укажи evidence_start_id и "
                    "evidence_end_id — реальные ID сегментов из расшифровки, "
                    "которые лучше всего подтверждают тему. "
                    "Не придумывай ID и не цитируй текст вручную."
                ),
            },
            {
                "role": "user",
                "content": prompt,
            },
        ],
        "format": schema,
        "options": {
            "temperature": 0,
        },
    }

    body = json.dumps(
        payload,
        ensure_ascii=False,
    ).encode("utf-8")

    request = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat",
        data=body,
        headers={
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(
            request,
            timeout=timeout,
        ) as response:
            raw_response = response.read().decode(
                "utf-8",
                errors="replace",
            )

    except urllib.error.HTTPError as exc:
        try:
            detail_text = exc.read().decode(
                "utf-8",
                errors="replace",
            )
        except Exception:
            detail_text = str(exc)
        raise RuntimeError(
            f"Ollama API HTTP {exc.code}: {detail_text}"
        ) from exc

    except urllib.error.URLError as exc:
        raise RuntimeError(
            f"Ollama API недоступен: {exc}"
        ) from exc

    except TimeoutError as exc:
        raise RuntimeError(
            "таймаут Ollama API"
        ) from exc

    outer = json.loads(raw_response)
    message = outer.get("message") or {}
    content = message.get("content", "")

    if not content:
        raise RuntimeError(
            "Ollama API вернул пустой message.content"
        )

    structured = json.loads(
        content,
        strict=False,
    )

    if not isinstance(structured, dict):
        raise RuntimeError(
            "Structured Output должен быть объектом"
        )

    first_topic = structured.get("first_topic")
    additional = structured.get("additional_topics", [])

    if not isinstance(first_topic, dict):
        raise RuntimeError(
            "Нет first_topic"
        )

    if not isinstance(additional, list):
        raise RuntimeError(
            "additional_topics должен быть массивом"
        )

    topics = [first_topic] + additional

    # Сортируем и удаляем случайные повторы start_id.
    cleaned = []
    seen = set()

    for topic in topics:
        sid = topic.get("start_id")
        if sid in seen:
            continue
        seen.add(sid)
        cleaned.append(topic)

    cleaned.sort(key=lambda x: x.get("start_id", 0))

    # --------------------------------------------------------
    # Grounding QA by real segment IDs
    # --------------------------------------------------------

    valid_id_set = set(valid_ids or [])

    grounded = []

    for topic in cleaned:
        ev_start = topic.get("evidence_start_id")
        ev_end = topic.get("evidence_end_id")

        try:
            ev_start = int(ev_start)
            ev_end = int(ev_end)
        except Exception:
            raise RuntimeError(
                "Некорректные evidence_start_id/evidence_end_id"
            )

        if ev_start not in valid_id_set:
            raise RuntimeError(
                f"evidence_start_id отсутствует в окне: {ev_start}"
            )

        if ev_end not in valid_id_set:
            raise RuntimeError(
                f"evidence_end_id отсутствует в окне: {ev_end}"
            )

        if ev_end < ev_start:
            raise RuntimeError(
                f"evidence range перевёрнут: {ev_start}–{ev_end}"
            )

        topic["evidence_start_id"] = ev_start
        topic["evidence_end_id"] = ev_end

        grounded.append(topic)

    return json.dumps(
        grounded,
        ensure_ascii=False,
    )


def extract_json_array(text):
    # Gemma sometimes emits literal newlines/control characters inside
    # quoted JSON strings. strict=False accepts those while preserving JSON.
    cleaned = text.strip()
    cleaned = re.sub(r"^```(?:json)?\\s*", "", cleaned, flags=re.I)
    cleaned = re.sub(r"\\s*```$", "", cleaned)

    a, b = cleaned.find("["), cleaned.rfind("]")
    if a >= 0 and b > a:
        payload = cleaned[a:b+1]
        return json.loads(payload, strict=False)

    raise ValueError("JSON-массив не найден")

def repair_json(model, bad_text, task_hint):
    prompt = f"""Преобразуй следующий ответ в корректный JSON-массив.
Никаких пояснений, Markdown и текста вне JSON.
Это русскоязычный семинар. Все значения title и summary должны быть только
на русском языке кириллицей; латинские буквы запрещены. Не переводи названия
на английский и не добавляй новых фактов.
Сохрани только элементы, соответствующие задаче: {task_hint}

ОТВЕТ:
{bad_text}
"""
    repaired = run_ollama(model, prompt, timeout=300)
    return extract_json_array(repaired)

def salvage_rows(text):
    """Extract start_id/title/summary from Gemma's malformed JSON-like output."""
    rows = []
    for block in re.findall(r"\{.*?\}", text, flags=re.S):
        sid_m = re.search(r'"?start_id"?\s*:\s*"?\s*\[?\s*(\d+)\s*\]?\s*"?', block, flags=re.I)
        title_m = re.search(
            r'"?title"?\s*:\s*"(?P<v>.*?)"\s*,\s*"?summary"?\s*:',
            block,
            flags=re.S | re.I,
        )
        summary_m = re.search(
            r'"?summary"?\s*:\s*"(?P<v>.*?)"\s*$',
            block.strip(),
            flags=re.S | re.I,
        )
        if not sid_m or not title_m:
            continue
        title = re.sub(r"\s+", " ", title_m.group("v")).strip()
        summary = ""
        if summary_m:
            summary = re.sub(r"\s+", " ", summary_m.group("v")).strip()
        rows.append({
            "start_id": int(sid_m.group(1)),
            "title": title,
            "summary": summary,
        })
    # If the model ignored JSON entirely, keep one conservative boundary
    # from its first substantive Markdown heading. The caller anchors it to
    # the first segment of the window; do not invent additional timestamps.
    if not rows:
        heading = re.search(r"(?m)^\s*[*-]\s*\*\*(?:\[[^\]]+\]\s*)?(.+?)\*\*\s*:??", text)
        if heading:
            title = re.sub(r"\s+", " ", heading.group(1)).strip()
            if title:
                rows.append({"start_id": None, "title": title, "summary": ""})
    return rows

def parse_rows(raw, model, valid_ids, first_id=None):
    data = None

    try:
        data = extract_json_array(raw)
    except Exception:
        try:
            data = repair_json(
                model,
                raw,
                "список тематических границ со start_id, title, summary",
            )
        except Exception:
            data = salvage_rows(raw)

    if not data:
        data = salvage_rows(raw)

    ordered_ids = sorted(valid_ids)
    out, seen = [], set()

    for row in data:
        if not isinstance(row, dict):
            continue
        try:
            raw_sid = row.get("start_id")
            if raw_sid is None and first_id is not None:
                sid = first_id
            else:
                sid = int(str(raw_sid).strip("[] \"'"))
        except Exception:
            continue

        # Gemma sometimes renumbers the current window locally as 1,2,3...
        # If that ID does not exist globally, interpret it as a 1-based
        # ordinal within the current window.
        if sid not in valid_ids and 1 <= sid <= len(ordered_ids):
            sid = ordered_ids[sid - 1]

        if sid not in valid_ids or sid in seen:
            continue

        title = clean_model_text(row.get("title", ""))
        summary = clean_model_text(row.get("summary", ""))
        if not title:
            continue
        if not is_russian_topic_text(title) or (summary and not is_russian_topic_text(summary)):
            continue

        seen.add(sid)
        out.append({"start_id": sid, "title": title, "summary": summary})

    out.sort(key=lambda x: x["start_id"])

    if not out:
        raise ValueError("не удалось извлечь тематические границы из ответа модели")

    # Do not invent a generic "Начало раздела". If the model's first real
    # topic starts later inside the analysis window, anchor that topic to
    # the beginning of the window. This preserves complete coverage while
    # keeping an informative title.
    if first_id is not None and out[0]["start_id"] != first_id:
        out[0] = dict(out[0])
        out[0]["start_id"] = first_id

    return out


def boundary_prompt(window, detail):
    lines = []

    for x in window:
        value = re.sub(r"\s+", " ", x["text"]).strip()
        lines.append(
            f'[{x["id"]}] {fmt_clock(x["start"])}–'
            f'{fmt_clock(x["end"])} | {value}'
        )

    first_id = window[0]["id"]

    return f"""Определи только ГРАНИЦЫ смысловых тем
в этом фрагменте русскоязычного семинара.

Не придумывай названия.
Не делай summary.
Не пересказывай текст.

Верни start_id сегментов, с которых реально начинается новая тема.

Первый start_id ОБЯЗАТЕЛЬНО {first_id}.

Режим детализации: {detail}.
Ориентир: {DETAIL[detail]["target_per_hour"]} тем на час.
Не создавай темы короче примерно {DETAIL[detail]["min_sec"]} секунд
без явной смысловой смены.

Используй только реальные ID из квадратных скобок.

СЕГМЕНТЫ:
""" + "\n".join(lines)


def run_ollama_boundaries(
    model,
    prompt,
    first_id,
    valid_ids,
    detail="auto",
    timeout=900,
):
    max_topics = {
        "low": 4,
        "auto": 12,
        "high": 10,
    }.get(detail, 6)

    valid_ids = sorted(set(valid_ids))

    schema = {
        "type": "object",
        "properties": {
            "boundaries": {
                "type": "array",
                "minItems": 1,
                "maxItems": max_topics,
                "items": {
                    "type": "integer",
                    "enum": valid_ids,
                },
            }
        },
        "required": ["boundaries"],
        "additionalProperties": False,
    }

    payload = {
        "model": model,
        "stream": False,
        "messages": [
            {
                "role": "system",
                "content": (
                    "Ты определяешь только границы смысловых тем "
                    "в русскоязычной расшифровке. "
                    "Не создавай названия, summaries и объяснения."
                ),
            },
            {
                "role": "user",
                "content": prompt,
            },
        ],
        "format": schema,
        "options": {
            "temperature": 0,
        },
    }

    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")

    request = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(request, timeout=timeout) as response:
        outer = json.loads(
            response.read().decode("utf-8", errors="replace")
        )

    content = (outer.get("message") or {}).get("content", "")
    data = json.loads(content, strict=False)

    boundaries = data.get("boundaries")

    if not isinstance(boundaries, list) or not boundaries:
        raise ValueError("нет boundaries")

    boundaries = [int(x) for x in boundaries]

    if first_id not in boundaries:
        boundaries.insert(0, first_id)

    boundaries = sorted(set(boundaries))

    if boundaries[0] != first_id:
        raise ValueError(
            f"первая граница {boundaries[0]}, ожидалась {first_id}"
        )

    for sid in boundaries:
        if sid not in valid_ids:
            raise ValueError(f"несуществующий boundary id: {sid}")

    return boundaries


def window_prompt(window, detail):
    lines = []
    for x in window:
        text = re.sub(r"\s+", " ", x["text"]).strip()
        lines.append(f'[{x["id"]}] {fmt_clock(x["start"])}–{fmt_clock(x["end"])} | {text}')
    return f"""Проанализируй ТОЛЬКО этот фрагмент русскоязычного семинара.

Найди реальные смены темы внутри этого окна.
Режим детализации: {detail}.
Ориентир: {DETAIL[detail]["target_per_hour"]} тем на час.
Не создавай темы короче примерно {DETAIL[detail]["min_sec"]} секунд без явной смены темы.
Для одного окна около 12 минут:
- low: верни обычно 1–4 тематические границы;
- auto: обычно 5–10;
- high: обычно 4–10.
Не делай отдельную тему для каждого SRT-сегмента.

Правила:
- Ответ только на русском.
- В каждом title и summary используй только русские слова кириллицей; латинские буквы запрещены.
- Границу ставь только на существующем ID сегмента.
- Верни только JSON-массив.
- Поля: start_id, title, summary.
- title: 3–10 слов, конкретное и информативное название темы.
- Используй терминологию самого выступающего и формулировки, максимально близкие к исходному тексту.
- Не интерпретируй, не оценивай и не исправляй мировоззрение автора.
- Не добавляй собственных выводов, причин, объяснений и фактов, которых нет в сегментах.
- Не заменяй необычные авторские понятия своими терминами.
- Не используй расплывчатые названия вроде "Интерес к теме", "Выражение интереса к теме", "Обсуждение", "Продолжение", "Вопросы и предложения участников", если можно назвать конкретный предмет разговора.
- ОБЯЗАТЕЛЬНО верни тему для первого ID данного окна; первый элемент JSON должен иметь start_id первого показанного сегмента.
- Для detail=low поле summary оставь пустой строкой.
- Для detail=auto/high summary: одно короткое нейтральное предложение, только по содержанию фрагмента.
- Не вычисляй время.

Формат каждого элемента JSON:
{{"start_id": <ТОЧНЫЙ ID ИЗ КВАДРАТНЫХ СКОБОК>, "title": "<название темы>", "summary": "<описание или пустая строка>"}}

ВАЖНО:
- Не перенумеровывай сегменты как 1, 2, 3...
- Используй буквально те ID, которые стоят в квадратных скобках перед сегментами.
- Не копируй примеры названий; формулируй название только по данному тексту.

СЕГМЕНТЫ:
""" + "\n".join(lines)




def refinement_prompt(block, detail):
    lines = []

    for x in block:
        value = re.sub(r"\s+", " ", x["text"]).strip()
        lines.append(
            f'[{x["id"]}] {fmt_clock(x["start"])}–'
            f'{fmt_clock(x["end"])} | {value}'
        )

    first_id = block[0]["id"]

    return f"""Этот смысловой блок получился слишком длинным
и, вероятно, содержит несколько отдельных тем.

Найди ВНУТРЕННИЕ смены темы внутри этого диапазона.

Не возвращай только одну границу, если внутри текста действительно есть:
- переход от одного вопроса к другому;
- переход от примера к объяснению;
- переход от практики к итогам;
- переход к организационным вопросам;
- начало подведения итогов.

Первый start_id ОБЯЗАТЕЛЬНО {first_id}.

Для режима {detail} постарайся выделить 2–5 смысловых частей,
если содержание это позволяет.

Не дели текст механически по времени.
Не создавай границу на каждом вопросе или каждой реплике.
Используй только реальные ID из квадратных скобок.

Верни только boundaries через Structured Output.

СЕГМЕНТЫ:
""" + "\n".join(lines)



def run_ollama_refinement(
    model,
    prompt,
    first_id,
    valid_ids,
    detail="auto",
    timeout=900,
):
    """Force at least one internal boundary for an overlong block."""

    valid_ids = sorted(set(valid_ids))
    internal_ids = [x for x in valid_ids if x != first_id]

    if not internal_ids:
        return [first_id]

    max_additional = {
        "low": 3,
        "auto": 5,
        "high": 8,
    }.get(detail, 5)

    schema = {
        "type": "object",
        "properties": {
            "first_boundary": {
                "type": "integer",
                "const": int(first_id),
            },
            "additional_boundaries": {
                "type": "array",
                "minItems": 1,
                "maxItems": max_additional,
                "items": {
                    "type": "integer",
                    "enum": internal_ids,
                },
            },
        },
        "required": [
            "first_boundary",
            "additional_boundaries",
        ],
        "additionalProperties": False,
    }

    payload = {
        "model": model,
        "stream": False,
        "messages": [
            {
                "role": "system",
                "content": (
                    "Этот блок уже признан слишком длинным. "
                    "Ты обязан найти как минимум одну внутреннюю "
                    "смысловую границу. Не возвращай только начало блока."
                ),
            },
            {
                "role": "user",
                "content": prompt,
            },
        ],
        "format": schema,
        "options": {
            "temperature": 0,
        },
    }

    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")

    request = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(request, timeout=timeout) as response:
        outer = json.loads(
            response.read().decode("utf-8", errors="replace")
        )

    content = (outer.get("message") or {}).get("content", "")
    data = json.loads(content, strict=False)

    first = int(data.get("first_boundary"))
    additional = data.get("additional_boundaries")

    if first != first_id:
        raise ValueError(
            f"refinement first_boundary={first}, ожидалось {first_id}"
        )

    if not isinstance(additional, list) or not additional:
        raise ValueError(
            "refinement не вернул внутренних границ"
        )

    boundaries = [first_id] + [int(x) for x in additional]
    boundaries = sorted(set(boundaries))

    for sid in boundaries:
        if sid not in valid_ids:
            raise ValueError(
                f"refinement придумал ID {sid}"
            )

    return boundaries


def refine_boundaries(
    model,
    window,
    boundaries,
    detail="auto",
    max_depth=2,
    depth=0,
):
    """Recursively split implausibly long thematic ranges."""

    max_sec = {
        "low": 10 * 60,
        "auto": 5 * 60,
        "high": 3 * 60,
    }.get(detail, 5 * 60)

    by_id = {x["id"]: x for x in window}

    result = []

    for i, sid in enumerate(boundaries):
        next_sid = (
            boundaries[i + 1]
            if i + 1 < len(boundaries)
            else None
        )

        start_idx = next(
            j for j, x in enumerate(window)
            if x["id"] == sid
        )

        if next_sid is not None:
            end_idx = next(
                j for j, x in enumerate(window)
                if x["id"] == next_sid
            )
            block = window[start_idx:end_idx]
        else:
            block = window[start_idx:]

        if not block:
            continue

        duration = (
            srt_seconds(block[-1]["end"])
            - srt_seconds(block[0]["start"])
        )

        result.append(sid)

        if (
            duration <= max_sec
            or depth >= max_depth
            or len(block) < 8
        ):
            continue

        valid_ids = {x["id"] for x in block}
        first_id = block[0]["id"]

        try:
            sub = run_ollama_refinement(
                model,
                refinement_prompt(block, detail),
                first_id=first_id,
                valid_ids=valid_ids,
                detail=detail,
            )
        except Exception:
            continue

        sub = [x for x in sub if x != first_id]

        if not sub:
            continue

        refined = refine_boundaries(
            model,
            block,
            [first_id] + sub,
            detail=detail,
            max_depth=max_depth,
            depth=depth + 1,
        )

        for extra in refined[1:]:
            if extra not in result:
                result.append(extra)

    return sorted(set(result))



def analyze_window_boundaries(
    window,
    detail="auto",
    model="gemma3:4b",
):
    """
    Run the production Topic Engine boundary stage for one analysis window.

    Returns a sorted list of real SRT segment IDs.
    This function is shared by normal topic analysis and the gold benchmark.
    """

    if not window:
        return []

    valid_ids = {x["id"] for x in window}
    first_id = window[0]["id"]

    # --------------------------------------------------
    # STAGE A1: primary semantic boundary detection
    # --------------------------------------------------

    try:
        boundaries = run_ollama_boundaries(
            model,
            boundary_prompt(window, detail),
            first_id=first_id,
            valid_ids=valid_ids,
            detail=detail,
        )
    except Exception as exc:
        print(
            f"Boundary detection failed: {exc}",
            file=sys.stderr,
        )
        boundaries = [first_id]

    # --------------------------------------------------
    # STAGE A2: minimum-duration filtering
    # --------------------------------------------------

    min_gap = DETAIL[detail]["hard_min_sec"]
    by_id = {x["id"]: x for x in window}

    filtered = []

    for sid in boundaries:
        if not filtered:
            filtered.append(sid)
            continue

        prev = filtered[-1]

        cur_t = srt_seconds(by_id[sid]["start"])
        prev_t = srt_seconds(by_id[prev]["start"])

        if cur_t - prev_t >= min_gap:
            filtered.append(sid)

    boundaries = filtered

    # --------------------------------------------------
    # STAGE A3: recursively split implausibly long blocks
    # --------------------------------------------------

    boundaries = refine_boundaries(
        model,
        window,
        boundaries,
        detail=detail,
    )

    # --------------------------------------------------
    # STAGE A4: enforce minimum temporal distance again
    # after refinement. Refinement may otherwise return
    # several neighbouring SRT segment IDs as separate topics.
    # --------------------------------------------------

    boundaries = sorted(set(boundaries))

    final_filtered = []

    for sid in boundaries:
        if not final_filtered:
            final_filtered.append(sid)
            continue

        prev = final_filtered[-1]

        cur_t = srt_seconds(by_id[sid]["start"])
        prev_t = srt_seconds(by_id[prev]["start"])

        if cur_t - prev_t >= min_gap:
            final_filtered.append(sid)

    return final_filtered


def topic_range_prompt(segment_range):
    lines = []

    for x in segment_range:
        value = re.sub(r"\s+", " ", x["text"]).strip()
        lines.append(
            f'[{x["id"]}] {fmt_clock(x["start"])}–'
            f'{fmt_clock(x["end"])} | {value}'
        )

    return """Перед тобой только ОДИН смысловой блок русскоязычного семинара.

Дай ему:
1. короткое предметное название темы;
2. одно нейтральное предложение summary.

Не используй знания из других частей семинара.
Не упоминай того, чего нет в показанном тексте.
Не называй тему «Обсуждение», «Вопросы», «Продолжение», «Тема 1».
Не копируй длинную реплику как title.

СЕГМЕНТЫ:
""" + "\n".join(lines)


def run_ollama_topic_label(
    model,
    prompt,
    start_id,
    end_id,
    timeout=900,
):
    schema = {
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "minLength": 3,
                "maxLength": 90,
            },
            "summary": {
                "type": "string",
                "maxLength": 420,
            },
        },
        "required": ["title", "summary"],
        "additionalProperties": False,
    }

    payload = {
        "model": model,
        "stream": False,
        "messages": [
            {
                "role": "system",
                "content": (
                    "Ты называешь только тот смысловой блок, "
                    "который дан в текущем сообщении. "
                    "Не используй знания из других частей семинара. "
                    "Пиши только по-русски."
                ),
            },
            {
                "role": "user",
                "content": prompt,
            },
        ],
        "format": schema,
        "options": {
            "temperature": 0,
        },
    }

    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")

    request = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(request, timeout=timeout) as response:
        outer = json.loads(
            response.read().decode("utf-8", errors="replace")
        )

    content = (outer.get("message") or {}).get("content", "")
    data = json.loads(content, strict=False)

    title = clean_model_text(data.get("title", ""))
    summary = clean_model_text(data.get("summary", ""))

    if not title_is_good(title):
        raise ValueError(f"плохой title: {title!r}")

    if not summary_is_good(summary):
        raise ValueError(f"плохой summary: {summary!r}")

    return {
        "start_id": start_id,
        "title": title,
        "summary": summary,
        "evidence_start_id": start_id,
        "evidence_end_id": end_id,
        "qa_status": "ok",
        "qa_attempt": "2stage",
    }


def merge_prompt(candidates, items, detail):
    by_id = {x["id"]: x for x in items}
    rows = []
    for i, c in enumerate(candidates, 1):
        t = by_id[c["start_id"]]["start"]
        rows.append(f'[{i}] start_id={c["start_id"]} time={fmt_clock(t)} title="{c["title"]}" summary="{c["summary"]}"')
    return f"""Перед тобой кандидаты тематических глав, найденные по частям одного семинара.

Задача: объединить соседние дубли и близкие темы, убрать лишние дробления.
Режим: {detail}.
Ориентир: {DETAIL[detail]["target_per_hour"]} итоговых тем на час.

Правила:
- Ответ только на русском.
- Используй только существующие start_id из списка кандидатов.
- Первая итоговая тема должна начинаться с самого первого start_id.
- start_id строго возрастают.
- Верни только JSON-массив.
- Поля: start_id, title, summary.
- Не вычисляй время.

КАНДИДАТЫ:
""" + "\n".join(rows)

def make_topics(items, boundaries):
    by_id = {x["id"]: x for x in items}
    out = []
    for i, row in enumerate(boundaries):
        start_item = by_id[row["start_id"]]
        end_time = by_id[boundaries[i+1]["start_id"]]["start"] if i+1 < len(boundaries) else items[-1]["end"]
        out.append({
            "number": i+1,
            "start": start_item["start"],
            "end": end_time,
            "start_seconds": round(srt_seconds(start_item["start"]), 3),
            "end_seconds": round(srt_seconds(end_time), 3),
            "title": row["title"],
            "summary": row["summary"],
            "start_segment_id": row["start_id"],
            "evidence_start_id": row.get("evidence_start_id"),
            "evidence_end_id": row.get("evidence_end_id"),
            "qa_status": row.get("qa_status", "ok"),
            "qa_attempt": row.get("qa_attempt", "primary"),
        })
    return out

def write_outputs(out_dir, topics, srt, detail, model, force):
    txt = out_dir/"topics.txt"
    md = out_dir/"topics.md"
    js = out_dir/"topics.json"
    if not force and any(p.exists() for p in (txt,md,js)):
        raise SystemExit("Ошибка: topics-файлы уже существуют. Используйте --force.")
    txt_lines=[]
    md_lines=["# Тематический таймкодинг","",f"Источник SRT: `{srt}`",f"Детализация: `{detail}`",f"Модель: `{model}`",""]
    for t in topics:
        a,b=fmt_clock(t["start"]),fmt_clock(t["end"])
        title = re.sub(r"\\s+", " ", t["title"]).strip()
        summary = re.sub(r"\\s+", " ", t["summary"]).strip()

        txt_lines.append(f'{a}–{b} — {title}')
        if detail != "low" and summary:
            txt_lines.append(f'  {summary}')
        txt_lines.append("")

        md_lines += [f'## {t["number"]}. {a}–{b} — {title}', ""]
        if detail != "low" and summary:
            md_lines += [summary, ""]
    txt.write_text("\n".join(x for x in txt_lines if x is not None).rstrip()+"\n",encoding="utf-8")
    md.write_text("\n".join(md_lines).rstrip()+"\n",encoding="utf-8")
    js.write_text(json.dumps({"source_srt":str(srt),"detail":detail,"model":model,"topics":topics},ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    return txt,md,js

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("--root",required=True)
    ap.add_argument("--detail",choices=["low","auto","high"],default="auto")
    ap.add_argument("--model",default="gemma3:4b")
    ap.add_argument("--force",action="store_true")
    args=ap.parse_args()

    root=Path(args.root).expanduser()
    source=Path(args.source).expanduser()
    srt=find_transcript(root,source)
    existing_json = srt.parent / "topics.json"
    if existing_json.is_file() and not args.force:
        try:
            cached = json.loads(existing_json.read_text(encoding="utf-8"))
            cached_topics = cached.get("topics") if isinstance(cached, dict) else None
            cached_is_russian = (
                isinstance(cached_topics, list)
                and len(cached_topics) >= 2
                and all(
                    is_russian_topic_text(topic.get("title", ""))
                    and (not topic.get("summary") or is_russian_topic_text(topic.get("summary", "")))
                    for topic in cached_topics
                    if isinstance(topic, dict)
                )
            )
            if cached_is_russian:
                print(f"Готовый таймкодинг найден, повторный анализ не требуется: {existing_json}")
                print(f"Тем найдено: {len(cached_topics)}")
                print(f"TOPICS TXT:  {srt.parent / 'topics.txt'}")
                print(f"TOPICS MD:   {srt.parent / 'topics.md'}")
                print(f"TOPICS JSON: {existing_json}")
                return
            print("Существующий таймкодинг отклонён проверкой языка/качества; создаю заново.", file=sys.stderr)
        except (OSError, ValueError, TypeError):
            pass
    items=parse_srt(srt)
    windows=make_windows(items)

    print(f"SRT-сегментов: {len(items)}; окон анализа: {len(windows)}", file=sys.stderr)

    candidates=[]
    qa_windows=[]

    for i, window in enumerate(windows, 1):
        print(
            f"Окно {i}/{len(windows)}: "
            f"{fmt_clock(window[0]['start'])}–"
            f"{fmt_clock(window[-1]['end'])}",
            file=sys.stderr,
        )

        # --------------------------------------------------
        # STAGE A: boundaries only
        # Shared production entry point used by benchmark too.
        # --------------------------------------------------

        boundaries = analyze_window_boundaries(
            window,
            detail=args.detail,
            model=args.model,
        )

        # --------------------------------------------------
        # STAGE B: label each exact semantic range
        # --------------------------------------------------

        rows = []
        range_errors = []

        for j, sid in enumerate(boundaries):
            next_sid = (
                boundaries[j + 1]
                if j + 1 < len(boundaries)
                else None
            )

            start_index = next(
                idx for idx, x in enumerate(window)
                if x["id"] == sid
            )

            if next_sid is not None:
                end_index = next(
                    idx for idx, x in enumerate(window)
                    if x["id"] == next_sid
                )
                segment_range = window[start_index:end_index]
            else:
                segment_range = window[start_index:]

            if not segment_range:
                continue

            ev_start = segment_range[0]["id"]
            ev_end = segment_range[-1]["id"]

            try:
                row = run_ollama_topic_label(
                    args.model,
                    topic_range_prompt(segment_range),
                    ev_start,
                    ev_end,
                )

            except Exception as exc:
                range_errors.append({
                    "start_id": ev_start,
                    "end_id": ev_end,
                    "error": str(exc),
                })

                print(
                    f"Окно {i}: label {ev_start}–{ev_end} "
                    f"отклонён: {exc}",
                    file=sys.stderr,
                )

                row = {
                    "start_id": ev_start,
                    "title": "Тема требует ручной проверки",
                    "summary": "",
                    "evidence_start_id": ev_start,
                    "evidence_end_id": ev_end,
                    "qa_status": "fallback",
                    "qa_attempt": "2stage-fallback",
                }

            rows.append(row)

        qa_windows.append({
            "window": i,
            "start_segment_id": first_id,
            "start": window[0]["start"],
            "end": window[-1]["end"],
            "status": (
                "fallback"
                if any(
                    r.get("qa_status") == "fallback"
                    for r in rows
                )
                else "ok"
            ),
            "boundaries": boundaries,
            "range_errors": range_errors,
        })

        candidates.extend(rows)

    qa_path = srt.parent / "topics_qa.json"

    qa_path.write_text(
        json.dumps(
            {
                "model": args.model,
                "detail": args.detail,
                "engine": "2stage",
                "windows": qa_windows,
            },
            ensure_ascii=False,
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )

    # dedupe start_ids
    dedup={}
    for c in candidates:
        dedup.setdefault(c["start_id"],c)
    candidates=[dedup[k] for k in sorted(dedup)]

    # Do NOT send all candidates to Gemma again: on long seminars the
    # beginning of that prompt can fall out of the model context window.
    # Window-level candidates are already intentionally sparse. Merge them
    # deterministically using real SRT times only.
    min_gap = DETAIL[args.detail]["min_sec"]
    final_rows = []

    for c in candidates:
        if not final_rows:
            final_rows.append(c)
            continue

        prev = final_rows[-1]
        cur_t = srt_seconds(next(x["start"] for x in items if x["id"] == c["start_id"]))
        prev_t = srt_seconds(next(x["start"] for x in items if x["id"] == prev["start_id"]))

        # Suppress only boundaries that are implausibly close for the
        # selected detail level. Keep the earlier boundary and its title.
        if cur_t - prev_t < min_gap:
            continue

        final_rows.append(c)

    # Safety: a long seminar must never collapse to a single chapter.
    duration = srt_seconds(items[-1]["end"]) - srt_seconds(items[0]["start"])
    if duration >= 1800 and len(final_rows) < 2:
        raise SystemExit(
            "Ошибка: после объединения осталось меньше двух тем. "
            "Исходные кандидаты сохранены; автоматическое схлопывание запрещено."
        )

    debug_final = srt.parent / "topics_candidates.json"
    debug_final.write_text(
        json.dumps(final_rows, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    topics=make_topics(items,final_rows)
    txt,md,js=write_outputs(srt.parent,topics,srt,args.detail,args.model,args.force)

    fallback_count = sum(
        1 for topic in topics
        if topic.get("qa_status") == "fallback"
    )

    print(f"Тем найдено: {len(topics)}")
    print(f"Тем для ручной проверки: {fallback_count}")
    print(f"TOPICS TXT:  {txt}")
    print(f"TOPICS MD:   {md}")
    print(f"TOPICS JSON: {js}")
    print(f"TOPICS QA:   {srt.parent / 'topics_qa.json'}")

if __name__=="__main__":
    main()
