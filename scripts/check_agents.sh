#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
active = (
    "product-owner", "application-developer", "qa-test-engineer",
    "github-pr-reviewer", "ci-cd-engineer",
)
legacy = (
    "backend-developer", "frontend-developer", "database-architect",
    "jira-sprint-planner", "confluence-doc-writer",
)
legacy_release_invariant = "два последовательных полностью успешных E2E"
sections = (
    "Назначение", "Может менять", "Не может менять", "Обязательные проверки",
    "Критерии готовности", "Взаимодействие", "Неприкосновенное QA-правило",
)

def require(condition, message):
    if not condition:
        raise ValueError(message)

def read(path):
    value = (root / path).read_text(encoding="utf-8")
    require(value.strip(), f"empty {path}")
    return value

try:
    routing = read("AGENTS.md")
    index = read(".codex/agents/README.md")
    gate = read("docs/RELEASE_GATE.md")
    config = tomllib.loads(read(".codex/config.toml"))
    require(config.get("agents", {}).get("enabled") is True, "agents disabled")
    for role in active + legacy:
        path = f".codex/agents/{role}"
        contract = read(path + ".md")
        registration = tomllib.loads(read(path + ".toml"))
        require(registration.get("name") == role, f"name mismatch: {role}")
        for field in ("description", "developer_instructions"):
            value = registration.get(field)
            require(isinstance(value, str) and value.strip(), f"{role}: missing {field}")
        require(role + ".md" in registration["developer_instructions"],
                f"{role}: missing contract reference")
        for section in sections:
            require("## " + section in contract, f"{role}: missing {section}")
        require(role + ".md" in index, f"{role}: missing index entry")
        if role in active:
            require(role + ".md" in routing, f"{role}: missing routing")
            require("docs/RELEASE_GATE.md" in contract, f"{role}: missing shared gate")
        else:
            require(role in routing, f"{role}: missing compatibility routing")
            require(legacy_release_invariant in contract,
                    f"{role}: missing legacy release invariant")
    for role in ("product-owner", "github-pr-reviewer", "jira-sprint-planner"):
        data = tomllib.loads(read(f".codex/agents/{role}.toml"))
        require(data.get("sandbox_mode") == "read-only", f"{role}: read-only lost")
    for phrase in (
        "закоммиченного чистого состояния",
        "два последовательных полностью успешных запуска",
        "scripts/test_e2e.sh <короткое-видео> <модель-whisper>",
        "реальное короткое видео",
        "Ошибка, flaky-результат или исправление сбрасывает счетчик в ноль",
        "scripts/ci_risk_classifier.py", "Billing/spending", "Owner Test PASS",
        "machine-readable evidence",
    ):
        require(phrase in gate, f"missing release invariant: {phrase}")
    for path in ("docs/CI_COST_POLICY.md", ".ci/ci-risk-policy.json",
                 "docs/agents/TRANSITION.md", "docs/agents/pipeline.md",
                 "docs/agents/swiftui.md", "docs/agents/persistence.md"):
        read(path)
    for path in ("AGENTS.md", ".codex/agents/README.md"):
        for target in re.findall(r"\]\(([^)]+)\)", read(path)):
            if "://" not in target:
                require((root / path).parent.joinpath(target).is_file(),
                        f"{path}: broken link {target}")
except (OSError, ValueError) as error:
    print(f"Agent integration FAIL: {error}", file=sys.stderr)
    sys.exit(1)
print("Agent integration PASS: 5 active, 5 compatibility roles; TOML, routing and release gate.")
PY
