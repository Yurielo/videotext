# Pipeline и внешние процессы

Справочник application-developer, не отдельная роль.

- WorkflowEngine и adapters сохраняют зависимости операций и восстановление.
  Не запускать Whisper при пригодном full.srt; transcript.txt восстанавливать
  из пригодных артефактов, когда это поддерживается.
- whisper-cli: full JSON/confidence, явная Silero VAD-модель и ограниченный
  fallback без VAD. При изменении аргументов: scripts/test_whisper_vad.sh.
- ffmpeg/ffprobe: валидировать интервалы, длительности, результат и ошибки.
- Ollama/HybridTopicAdapter: ограниченные попытки и таймауты, валидный fallback,
  кэш по источнику, модели, гранулярности и algorithmVersion.
- SRT/topics: cueId, порядок, покрытие, непересечение и временные границы.
  Не менять алгоритм тем без явного scope.
- Отмена завершает принадлежащие операции процессы, очищает partial и оставляет
  возобновляемый проект. Не останавливать чужие процессы или общий Ollama.
- Progress/ETA отражают фактические операции; ошибки идут в UI, manifest и логи.
- Проверять применимые probe/regression; выпуск по docs/RELEASE_GATE.md.
