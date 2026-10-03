"""Prepare explicit counterfactual inputs, never a production translation repair."""

import argparse
import copy
import hashlib
import json
from pathlib import Path


def prepare(request, replacements):
    changed = copy.deepcopy(request)
    messages = changed["messages"]
    if len(messages) != 1 or messages[0]["role"] != "user":
        raise ValueError("Expected the recorded single-message production request")
    prefix, separator, owned_json = messages[0]["content"].rpartition("\n\n\n")
    if not separator:
        raise ValueError("No recorded OWNED_CONTENT boundary")
    rows = json.loads(owned_json)
    ids = [row["id"] for row in rows]
    if not isinstance(replacements, dict) or any(
        not isinstance(key, str) or str(int(key)) != key for key in replacements
    ):
        raise ValueError("Replacement IDs must use canonical integer string keys")
    if len(ids) != len(set(ids)) or not set(map(int, replacements)).issubset(ids):
        raise ValueError("Replacement IDs must belong to the recorded request")
    if json.dumps(rows, ensure_ascii=False, sort_keys=True, separators=(",", ":")) != owned_json:
        raise ValueError("Re-encoding would alter untouched source serialization")
    differences = []
    for row in rows:
        key = str(row["id"])
        if key in replacements:
            value = replacements[key]
            if not isinstance(value, str) or not value.strip():
                raise ValueError("Counterfactual text must remain nonempty")
            differences.append({"id": row["id"], "original": row["text"], "counterfactual": value})
            row["text"] = value
    messages[0]["content"] = prefix + separator + json.dumps(
        rows, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    # The context, output schema, decoding options and identities stay fixed.
    for key in request:
        if key != "messages" and request[key] != changed[key]:
            raise AssertionError("A non-source request field changed")
    if changed["messages"][0]["content"].rpartition(separator)[0] != prefix:
        raise AssertionError("Context/instruction prefix changed")
    if len(differences) != len(replacements):
        raise AssertionError("Not every requested replacement was consumed")
    return changed, differences


def self_test():
    request = {"model": "test-only", "messages": [{"role": "user", "content":
        "unchanged context\n\n\n[{\"id\":41,\"text\":\"Original\"}]"}],
        "format": {"type": "array"}, "options": {"temperature": 0}}
    original = copy.deepcopy(request)
    changed, differences = prepare(request, {"41": "Counterfactual"})
    assert request == original and differences[0]["id"] == 41
    assert changed["options"] == request["options"]
    no_op, differences = prepare(request, {})
    assert no_op == request and differences == []
    for bad in ({"42": "Unknown owner"}, {"41": ""}, {"41": 9}, {"041": "No-op"}):
        try:
            prepare(request, bad)
        except ValueError:
            pass
        else:
            raise AssertionError("Invalid counterfactual accepted")
    print("CAUSAL_ABLATION_SELF_TEST_PASS: no model execution")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("request", nargs="?", type=Path)
    parser.add_argument("replacements", nargs="?", type=Path)
    parser.add_argument("output", nargs="?", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if None in (args.request, args.replacements, args.output):
        parser.error("request, replacements and output are required")
    if args.output.exists() or args.output.with_suffix(".changes.json").exists():
        raise ValueError("Refusing to replace retained evidence")
    raw = args.request.read_bytes()
    request = json.loads(raw)
    changed, differences = prepare(request, json.loads(args.replacements.read_text()))
    encoded = (json.dumps(changed, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()
    args.output.write_bytes(encoded)
    args.output.with_suffix(".changes.json").write_text(json.dumps({
        "purpose": "CAUSAL_COUNTERFACTUAL_ONLY_NOT_A_REPAIR",
        "originalRequestSHA256": hashlib.sha256(raw).hexdigest(),
        "counterfactualRequestSHA256": hashlib.sha256(encoded).hexdigest(),
        "changes": differences,
        "contextAndOptionsUnchanged": True,
        "noProductionIntegration": True,
    }, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
