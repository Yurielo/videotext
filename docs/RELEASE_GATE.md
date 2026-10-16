# Единый контракт QA и выпуска VideoText

Этот файл является обязательным источником release-правил для всех активных
ролей. Исторические копии в переходных контрактах не разрешают обход этого gate.

Кандидат собирается из закоммиченного чистого состояния. Evidence фиксирует
commit SHA, git status и identity исходников, кандидата и входных данных.
Нельзя продвигать candidate из dirty worktree. После исправления релевантные
проверки проходят заново, изменения коммитятся, gate выполняется из чистого
состояния; candidate пересобирается при изменении release inputs.

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

### Owner-approved delivery chain

Явный `Owner Test PASS` для exact Candidate разрешает Codex самостоятельно
завершить безопасную delivery chain:

`Owner PASS → final gate verification → merge → installation exact accepted
Candidate → post-install smoke → DELIVERED`.

Отдельное Owner approval между merge и installation не требуется, когда
одновременно сохранены accepted HEAD и application tree, Candidate и его
digest, пересборка или переподпись не требуются, а обязательные gates PASS.
Если после Owner PASS меняется application code/tree или Candidate, это
разрешение прекращается: требуется новый Owner Test и acceptance. Это правило
не отменяет остальные governance gates, identity checks, rollback или строгую
проверку подписи перед установкой.
