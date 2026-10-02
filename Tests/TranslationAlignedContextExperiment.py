"""One bounded structured-output ablation; this is not production code."""
import json
import sys
import urllib.request

with open(sys.argv[1], encoding="utf-8") as source:
    cues = json.load(source)["cues"]
ids = [17, 21, 22, 24]
targets = {str(cue["id"]): cue["text"] for cue in cues if cue["id"] in ids}
context = "\n".join(cue["text"] for cue in cues[15:])
schema = {"type": "object", "properties": {key: {"type": "string"} for key in targets}, "required": list(targets), "additionalProperties": False}
prompt = "Translate the target utterances from Russian to English. The surrounding spoken dialogue is context for interpreting meaning only. Return a JSON object with exactly the target IDs as keys and their translations as values. Preserve every stated referent and incomplete speech. Do not copy neighboring utterances, add words omitted by a speaker, or complete another speaker's statement.\nCONTEXT:\n" + context + "\nTARGETS:\n" + json.dumps(targets, ensure_ascii=False)
body = {"model": "translategemma:4b", "stream": False, "format": schema, "messages": [{"role": "user", "content": prompt}], "options": {"temperature": 0, "num_predict": 384}}
request = urllib.request.Request("http://127.0.0.1:11434/api/chat", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
with urllib.request.urlopen(request, timeout=180) as response:
    result = json.load(response)
print(json.dumps({"request": body, "response": result}, ensure_ascii=False), flush=True)
