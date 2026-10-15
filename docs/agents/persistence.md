# Файловые схемы и совместимость

Справочник application-developer, не отдельная роль.

- ProjectLayout задает пути Video, Texts, Support files. Изменение пути требует
  анализа существующих проектов и миграции.
- Codable, manifest.json, topics.json и кэши версионируются. Проверять чтение
  старых манифестов, optional defaults, поврежденные и неполные данные.
- JSON записывается атомарно; partial не считается результатом. TopicFileService
  сохраняет topics.json/topics.txt согласованно.
- cueIds, sourceCueStart/sourceCueEnd, coverage, положительность интервалов,
  порядок и непересечение проверяются строго.
- Source signature, модель, гранулярность и algorithmVersion инвалидируют
  несовместимый кэш.
- Проверять открытие через ProjectLocator/ProjectStore и обнаружение результатов.
  Новая БД или storage требуют отдельного продуктового scope.
