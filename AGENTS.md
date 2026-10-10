# Агенты разработки videotext

## Область действия

Эти правила действуют для всего дерева проекта `videotext`. Файлы `.toml` в
`.codex/agents/` регистрируют именованных custom agents, а одноименные `.md`
являются подробным источником их полномочий, ограничений и критериев готовности.

`Product Owner` является главным управляющим агентом процесса разработки
`videotext`: он первым фиксирует пользовательский результат, scope,
acceptance criteria, stop conditions и решает, какие профильные агенты нужны.
Остальные агенты подключаются по необходимости как исполнители, ревьюеры или
проверяющие в рамках scope, заданного `Product Owner`.

Перед началом задачи координатор обязан сначала определить, требуется ли
решение `Product Owner`. Для любой новой функции, изменения UX, релизного
решения, спорного scope или многомодульной работы `Product Owner` запускается
первым. После этого координатор вызывает соответствующего именованного агента
и читает его Markdown-контракт. Если задача пересекает несколько областей,
подключаются только необходимые дополнительные роли.

## Реестр ролей

| Роль | Инструкция | Когда обязательна |
|---|---|---|
| Backend Developer | `.codex/agents/backend-developer.md` | `Core`, `Services`, `Adapters`, workflow, CLI, SRT/topics |
| Frontend Developer | `.codex/agents/frontend-developer.md` | SwiftUI, `ContentView`, `WorkflowViewModel`, прогресс, ETA, уведомления |
| Database Architect | `.codex/agents/database-architect.md` | `manifest.json`, `topics.json`, история, кэш, миграции и совместимость |
| QA Test Engineer | `.codex/agents/qa-test-engineer.md` | тесты, воспроизведение ошибок, регрессии и любой release candidate |
| CI/CD Engineer | `.codex/agents/ci-cd-engineer.md` | сборка `.app`, подпись, упаковка и выдача версии |
| GitHub PR Reviewer | `.codex/agents/github-pr-reviewer.md` | независимое ревью существенных изменений production-кода |
| Product Owner | `.codex/agents/product-owner.md` | новая функция, изменение UX, спорный scope или критерии приемки |
| Jira Sprint Planner | `.codex/agents/jira-sprint-planner.md` | крупная многомодульная задача, зависимости и этапы реализации |
| Confluence Doc Writer | `.codex/agents/confluence-doc-writer.md` | README, архитектура, инструкции, QA-отчет и release notes |

Названия GitHub, Jira и Confluence обозначают проектные роли. Они не требуют
внешних сервисов или учетных записей, если пользователь явно не запросил такую
интеграцию.

## Маршрутизация задачи

1. `Product Owner` является главным владельцем процесса: формулирует
   пользовательский результат, scope, out-of-scope, acceptance criteria и
   stop conditions.
2. `Product Owner` решает, какие агенты нужны для задачи, и передает им
   конкретный handoff: ожидаемый результат, границы файлов, обязательные
   проверки и критерии возврата.
3. Для существенной задачи, затрагивающей несколько модулей, `Product Owner`
   подключает `Jira Sprint Planner` для этапов и зависимостей.
4. Реализацию ведет владелец области. Параллельные агенты получают непересекающиеся
   наборы файлов; два агента не редактируют один файл одновременно.
5. Изменения схем обязательно согласуются между `Database Architect`,
   `Backend Developer` и `QA Test Engineer`.
6. Изменения пользовательского поведения согласуются между `Frontend Developer`,
   `Product Owner` и `QA Test Engineer`.
7. После существенного изменения production-кода `GitHub PR Reviewer` выполняет
   независимое read-only ревью, а `QA Test Engineer` проверяет риск и тесты.
8. `CI/CD Engineer` подключается только после инженерных и QA-проверок. Он не
   может подменить E2E smoke-тестом.
9. `Confluence Doc Writer` обновляет документацию только по фактически
   реализованному и проверенному состоянию.

Финальный release verdict состоит из четырех независимых положительных решений:
`GitHub PR Reviewer` не видит блокеров, `QA Test Engineer` подтверждает тесты,
`CI/CD Engineer` подтверждает идентичность и пригодность сборки, `Product Owner`
дает продуктовый go/no-go. Ни одна роль не может отменить отрицательный verdict
другой роли без исправления и повторной проверки.

## Использование субагентов

Для многомодульных изменений production-кода координатор обязан использовать
зарегистрированных TOML-агентов и делегировать хотя бы одну независимую
подзадачу подходящей роли. Для подготовки релизной сборки отдельно вызываются
`qa-test-engineer`, `github-pr-reviewer` и `ci-cd-engineer`. Если именованный
агент не загрузился, release-задача блокируется до исправления конфигурации.

Делегирование должно быть конкретным: роль, ожидаемый результат, разрешенные
файлы, запрещенные области и обязательные проверки. Агент завершает работу
отчетом по единому контракту:

- примененная роль;
- выполненная работа;
- измененные файлы;
- выполненные проверки и их результат;
- найденные риски или блокеры;
- что передается следующей роли.

Для узкой правки одного файла координатор может применить инструкцию ведущей
роли самостоятельно. Нельзя создавать параллельную работу ради количества
агентов или дублировать уже порученную подзадачу.

Backend и frontend могут работать параллельно только после фиксации общего
контракта и на разных файлах. Изменения `Models.swift`, `ProjectLayout.swift`,
миграций и persistence-сервисов выполняются последовательно. Тяжелые проверки
Whisper/Ollama/ffmpeg, два финальных E2E и замена одной `.app` также выполняются
последовательно.

## Границы изменений

- Любые новые требования сверяются с существующей архитектурой до редактирования.
- Нельзя ослаблять строгую валидацию SRT, `cueId`, временной шкалы,
  `topics.json`, ffprobe или файлов проекта.
- Нельзя повторно запускать Whisper, если существующий `full.srt` валиден и
  операция может быть продолжена без расшифровки.
- Нельзя удалять или откатывать несвязанные пользовательские изменения.
- Нельзя вмешиваться в работающие `videotext`, `whisper-cli`, `ffmpeg` или
  `ffprobe`. Перед заменой приложения проверяются эти активные процессы.
  Ollama является необходимым локальным сервисом тематического E2E: его можно
  использовать, но нельзя останавливать или перенастраивать без явной задачи.
- Изменение тематического алгоритма выполняется только при явном scope пользователя.

## Обязательный QA-цикл

Обычная задача должна иметь проверки, соразмерные риску. Изменение только
агентских инструкций или документации не требует сборки приложения и E2E.

### CI risk и hosted-расходы

Каждый diff до CI/CD verdict детерминированно классифицируется командой
`scripts/ci_risk_classifier.py` по правилам `.ci/ci-risk-policy.json`:

- `LEVEL_A` — UI, application workflow/orchestration, Core/Services business
  logic, text/timing processing, обычные исправления и изменения содержимого
  bundled dependency без изменения packaging, discovery, native architecture,
  signing или toolchain. Применимые local focused/regression/real scenarios,
  независимые QA/review, CORE E2E, Candidate identity, codesign/lifecycle и
  Owner Test остаются обязательными; GitHub-hosted macOS не требуется.
- `LEVEL_B` — build/platform/distribution infrastructure: Xcode/build settings,
  packaging, runtime discovery, signing/notarization, native architecture,
  toolchain и native dependency loading. Помимо применимых локальных gates
  требуется одна независимая clean GitHub-hosted macOS build/toolchain проверка
  exact SHA.

Release не является третьим risk class: применяется уровень фактического diff
и отдельные promotion checks. Неизвестный или неоднозначный infrastructure-
sensitive diff классифицируется fail-closed как `LEVEL_B`; LLM не может в
одиночку понизить класс.

Paid macOS workflow не запускается на `push`, `pull_request`, `schedule` или
`workflow_call`. Governed entry point — `scripts/dispatch_paid_macos_gate.py`;
он допускает только exact-SHA `LEVEL_B` после machine-readable подтверждения
всех применимых локальных gates. Норма — одна попытка. Единственный
повтор на том же SHA разрешен только для документированной infrastructure
failure по контракту `docs/CI_COST_POLICY.md`. Product/test failure не дает
основания для повтора. Billing/spending failure является hard stop: Codex и
automation запрещено менять budget/spending limits, обходить ограничение или
создавать повторный paid run.

CI/CD verdict не означает автоматически GitHub-hosted CI. Для `LEVEL_A`
machine-readable local release evidence является допустимым CI/CD evidence.
Billing/capacity failure не инвалидирует уже полученные local product evidence.
Governance-only изменения не инвалидируют Candidate, если content identity
release inputs не изменился. Owner утверждает policy, а не каждый отдельный
технический запуск. Полный контракт: `docs/CI_COST_POLICY.md`.

Release inputs включают `Sources/**`, `Resources/**`, `scripts/build_app.sh`,
`scripts/test_e2e.sh`, `Tests/EndToEnd.swift` и все файлы, включаемые в bundle.
Их content hash фиксируется до candidate build и повторно проверяется после
каждого E2E. Любое изменение release inputs аннулирует candidate и сбрасывает
счетчик E2E.

Готовую `.app` запрещено выдавать пользователю, пока одновременно не выполнены
все условия:

1. Все релевантные unit/probe/integration-проверки успешны.
2. В отдельный путь собран release candidate; стабильная пользовательская
   сборка при этом не удаляется и не заменяется.
3. После последнего изменения production-кода, build/package-логики или E2E-
   harness выполнены два последовательных полностью успешных запуска
   `scripts/test_e2e.sh <короткое-видео> <модель-whisper>`.
4. Оба E2E используют реальное короткое видео и компилируют тот же неизменный
   snapshot production-исходников, из которого собран candidate. Это проверка
   processing pipeline; сам candidate binary отдельно проходит smoke-проверку.
   Ошибка, flaky-результат или исправление сбрасывает счетчик в ноль.
5. Тот же candidate без пересборки проходит smoke-запуск, проверку версии,
   архитектуры, подписи и отсутствия `videotext`, `whisper-cli`, `ffmpeg` и
   `ffprobe`; затем продвигается в итоговый путь с проверкой совпадения hash.
6. Сохранено machine-readable evidence: hashes release inputs, candidate,
   видео и модели, команды, exit status, логи, даты и версии инструментов.
7. Итоговый отчет честно перечисляет проверки, входные данные, результаты и
   известные ограничения.

## Критерий завершения

Задача завершена только когда пользовательский результат реализован, ведущая
роль приняла свою область, независимые проверки выполнены, документация не
расходится с кодом, а для выдаваемой сборки соблюден полный release-gate.
