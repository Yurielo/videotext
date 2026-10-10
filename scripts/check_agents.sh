#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT/.." && pwd)"
AGENTS_FILE="$ROOT/AGENTS.md"
INDEX_FILE="$ROOT/.codex/agents/README.md"
ROLE_DIR="$ROOT/.codex/agents"
WORKSPACE_ROLE_DIR="$WORKSPACE_ROOT/.codex/agents"

roles=(
  backend-developer
  ci-cd-engineer
  confluence-doc-writer
  database-architect
  frontend-developer
  github-pr-reviewer
  jira-sprint-planner
  product-owner
  qa-test-engineer
)

sections=(
  "## Назначение"
  "## Может менять"
  "## Не может менять"
  "## Обязательные проверки"
  "## Критерии готовности"
  "## Взаимодействие"
  "## Неприкосновенное QA-правило"
)

fail() {
  printf 'Agent integration FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -s "$AGENTS_FILE" ]] || fail "отсутствует AGENTS.md"
[[ -s "$INDEX_FILE" ]] || fail "отсутствует .codex/agents/README.md"
[[ -s "$WORKSPACE_ROOT/AGENTS.md" ]] || fail "отсутствует workspace AGENTS.md"
[[ -s "$ROOT/.codex/config.toml" ]] || fail "отсутствует project .codex/config.toml"
[[ -s "$WORKSPACE_ROOT/.codex/config.toml" ]] || fail "отсутствует workspace .codex/config.toml"

for role in "${roles[@]}"; do
  markdown_path="$ROLE_DIR/$role.md"
  toml_path="$ROLE_DIR/$role.toml"
  workspace_toml_path="$WORKSPACE_ROLE_DIR/$role.toml"
  [[ -s "$markdown_path" ]] || fail "отсутствует контракт $role.md"
  [[ -s "$toml_path" ]] || fail "отсутствует custom agent $role.toml"
  [[ -s "$workspace_toml_path" ]] || fail "custom agent $role.toml не зарегистрирован в workspace"
  /usr/bin/cmp -s "$toml_path" "$workspace_toml_path" || \
    fail "workspace-конфигурация $role.toml не совпадает с проектной"

  python3 -c '
import pathlib
import sys
import tomllib
path = pathlib.Path(sys.argv[1])
expected_name = sys.argv[2]
with path.open("rb") as source:
    data = tomllib.load(source)
for field in ("name", "description", "developer_instructions"):
    value = data.get(field)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"missing or empty {field}")
if data["name"] != expected_name:
    raise SystemExit(f"name {data['"'"'name'"'"']!r} does not match {expected_name!r}")
' "$toml_path" "$role" || fail "невалидная TOML-схема $role.toml"

  for section in "${sections[@]}"; do
    /usr/bin/grep -Fq "$section" "$markdown_path" || fail "$role.md не содержит раздел $section"
  done

  /usr/bin/grep -Fq "два последовательных полностью успешных E2E" "$markdown_path" || \
    fail "$role.md не содержит обязательное правило двух E2E"
  /usr/bin/grep -Fq "$role.md" "$AGENTS_FILE" || \
    fail "AGENTS.md не маршрутизирует роль $role.md"
  /usr/bin/grep -Fq "$role.md" "$INDEX_FILE" || \
    fail "индекс не содержит роль $role.md"
done

/usr/bin/grep -Fq "scripts/test_e2e.sh <короткое-видео> <модель-whisper>" "$AGENTS_FILE" || \
  fail "AGENTS.md не содержит команду release-gate"
/usr/bin/grep -Fiq "flaky-результат или исправление сбрасывает счетчик в ноль" "$AGENTS_FILE" || \
  fail "AGENTS.md не сбрасывает E2E-счетчик после ошибки"
[[ -s "$ROOT/docs/CI_COST_POLICY.md" ]] || fail "отсутствует docs/CI_COST_POLICY.md"
[[ -s "$ROOT/.ci/ci-risk-policy.json" ]] || fail "отсутствует deterministic CI risk policy"
/usr/bin/grep -Fq "scripts/ci_risk_classifier.py" "$AGENTS_FILE" || \
  fail "AGENTS.md не маршрутизирует deterministic CI risk classifier"
/usr/bin/grep -Fiq "billing/spending" "$AGENTS_FILE" || \
  fail "AGENTS.md не содержит billing hard stop"

printf 'Agent integration PASS: %d custom agents, TOML-схема, маршрутизация и QA-gate проверены.\n' "${#roles[@]}"
