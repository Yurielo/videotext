# Роли VideoText v2

Основных ролей пять. Product Owner работает в основном контексте координатора;
количество отдельных запусков зависит от риска задачи.

| ID | Контракт |
| --- | --- |
| product-owner | [product-owner.md](product-owner.md) |
| application-developer | [application-developer.md](application-developer.md) |
| qa-test-engineer | [qa-test-engineer.md](qa-test-engineer.md) |
| github-pr-reviewer | [github-pr-reviewer.md](github-pr-reviewer.md) |
| ci-cd-engineer | [ci-cd-engineer.md](ci-cd-engineer.md) |

Переходные роли, не входящие в основной маршрут:
[backend-developer.md](backend-developer.md),
[frontend-developer.md](frontend-developer.md),
[database-architect.md](database-architect.md),
[jira-sprint-planner.md](jira-sprint-planner.md),
[confluence-doc-writer.md](confluence-doc-writer.md).
Они сохраняются для уже выданных handoff. Имена Jira/Confluence не предоставляют
доступа к внешним сервисам.

Маршрутизация: [AGENTS.md](../../AGENTS.md).
Общий gate: [RELEASE_GATE.md](../../docs/RELEASE_GATE.md).
Переход: [TRANSITION.md](../../docs/agents/TRANSITION.md).
Справочники: [pipeline](../../docs/agents/pipeline.md),
[SwiftUI](../../docs/agents/swiftui.md),
[persistence](../../docs/agents/persistence.md).

Проверка из любого рабочего каталога: scripts/check_agents.sh
(путь к скрипту должен указывать на нужный checkout).
Проверяются пять основных и пять переходных регистраций, TOML, контракты,
ссылки и обязательный release gate. Родительская папка не изменяется и
не обязана содержать дубликат конфигурации.
