"""Bounded, sequential prompt ablation; never changes production state."""
import json
import urllib.request
import sys

CONTEXT = [
    "Так, сейчас у нас заочники.", "Юрий, а я еще.", "А, да, Светлана.",
    "Здравствуйте. Я есть.", "Здравствуйте.",
    "Меня что-то выбрасывает сегодня.", "Прям каждую минуту вообще ужас.",
    "Ну, готова.", "Теперь точно заочники, да?",
]
TARGETS = [1, 5, 6, 8]
FULL_CONTEXT = [
    "Окей, чуть позже спрошу.", "Ирина Адамович.", "Я есть. Здравствуйте.",
    "Здравствуйте. Готова. Спасибо.", "Любовь Зуева.", "Здравствуйте. Я есть.",
    "Здравствуйте. Готова. Спасибо.", "Маргарита Мирошиченко.", "Добрый день. Я есть.",
    "Готова. Спасибо.", "Марина Кушнарева.", "Добрый вечер. Я есть.", "Татьяна.",
    "Я есть.", "Готова.", *CONTEXT,
]

def prompt(variant, index):
    text = CONTEXT[index]
    context = "\n".join(CONTEXT)
    prefix = "You are TranslateGemma. Translate TEXT from Russian to English.\nReturn only the translation of TEXT. Do not return labels, explanations, markdown, or JSON.\nPreserve meaning, names, terminology, numbers, punctuation, and natural repetitions.\n"
    if variant in ["local_window", "local_window_fragments"]:
        full_index = index + 15
        context = "\n".join(FULL_CONTEXT[max(0, full_index-8):full_index+9])
        extra = " Keep incomplete utterances incomplete; do not add words omitted by the speaker." if variant == "local_window_fragments" else ""
        return prefix + "The following is neighbouring spoken dialogue for interpretation only. Do not translate or copy it into the output.\nCONTEXT:\n" + context + "\nEND CONTEXT\nTranslate only the target TEXT, preserving incomplete speech without inventing a completion." + extra + "\nTEXT: " + text
    if variant in ["official_context", "official_fragment", "brief_context"]:
        header = "You are a professional Russian (ru) to English (en) translator. Your goal is to accurately convey the meaning and nuances of the original Russian text while adhering to English grammar, vocabulary, and cultural sensitivities.\n"
        extra = "Translate incomplete speech as an incomplete fragment, without adding a continuation.\n" if variant == "official_fragment" else ""
        if variant == "brief_context":
            return "Translate only TEXT from Russian to English. Neighbouring dialogue provides context; do not translate it. Preserve fragments and do not invent missing words.\nContext:\n" + context + "\nTEXT: " + text
        return header + "Neighbouring dialogue for interpretation only (do not include it in the translation):\n" + context + "\n\n" + extra + "Please translate the following Russian text into English. Return only its translation, without any additional explanations or commentary:\n\n" + text
    if variant == "isolated_v2":
        return prefix + "TEXT: " + text
    if variant == "context_before":
        return prefix + "The following is neighbouring spoken dialogue for interpretation only. Do not translate or copy it into the output.\nCONTEXT:\n" + context + "\nEND CONTEXT\nTranslate only the target TEXT, preserving incomplete speech without inventing a completion.\nTEXT: " + text
    if variant in ["bounded_before", "incomplete_before", "no_target_in_context"]:
        context = "\n".join(row for i, row in enumerate(CONTEXT) if variant != "no_target_in_context" or i != index)
        incomplete = " If TEXT is an incomplete utterance, translate it as an incomplete fragment; never add an implied verb, object or continuation. Preserve every noun or referent stated in TEXT." if variant != "bounded_before" else ""
        return prefix + "The following is neighbouring spoken dialogue for interpretation only. Do not translate or copy it into the output.\nCONTEXT:\n" + context + "\nEND CONTEXT\nTranslate only the target TEXT, preserving incomplete speech without inventing a completion." + incomplete + "\nTEXT: " + text
    if variant == "context_after":
        return prefix + "TEXT: " + text + "\n\nNeighbouring dialogue (context only; do not include its translation):\n" + context + "\n\nOutput only the English translation of TEXT above. Preserve ellipsis/incompleteness; do not add missing meaning."
    if variant == "structured_target":
        rows = "\n".join(("<target>" + row + "</target>") if i == index else "<context>" + row + "</context>" for i, row in enumerate(CONTEXT))
        return "You are a professional Russian-to-English translator of spoken dialogue. Use adjacent dialogue to interpret ambiguous words. Translate ONLY the text between <target> and </target>. Other rows are context only. Return the translation alone, without tags. Do not complete incomplete utterances or translate context rows.\n" + rows
    raise ValueError(variant)

variants = sys.argv[1:] or ["isolated_v2", "context_before", "context_after", "structured_target"]
for variant in variants:
    for index in TARGETS:
        body = {"model": "translategemma:4b", "stream": False, "messages": [{"role": "user", "content": prompt(variant, index)}], "options": {"temperature": 0, "num_predict": 256}}
        request = urllib.request.Request("http://127.0.0.1:11434/api/chat", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=180) as response:
            result = json.load(response)
        print(json.dumps({"variant": variant, "id": [17, 21, 22, 24][TARGETS.index(index)], "source": CONTEXT[index], "output": result["message"]["content"], "done_reason": result.get("done_reason"), "prompt_eval_count": result.get("prompt_eval_count"), "request": body}, ensure_ascii=False), flush=True)
