import Foundation

@main
struct DiagnosticsProbe {
    static func main() async throws {
        let controller = ProcessController()
        let runner = ToolRunner(controller: controller)
        let service = DiagnosticsService(runner: runner)
        let report = await service.collect(profile: .core)
        try require(report.canonicalFFmpegPath?.contains("ffmpeg-full") == true, "ffmpeg-full не выбран каноническим")
        for filter in ["subtitles", "rubberband", "boxblur", "gblur", "overlay", "afftdn", "loudnorm"] {
            try require(report.capabilities?[filter] == true, "нет обязательного фильтра \(filter)")
        }
        try require(report.warnings?.contains(where: { $0.contains("translategemma") || $0.contains("Daniel") || $0.contains("Yuri") }) != true, "core diagnostics включили translation-only предупреждение")
        let tasks = report.terminalTasks ?? []
        try require(tasks.first(where: { $0.id == "TOOL-01" })?.status == "completed", "TOOL-01 не завершён")
        try require(tasks.first(where: { $0.id == "TOOL-02" })?.requiresExplicitApproval == true, "TOOL-02 не защищён approval")
        try require(tasks.first(where: { $0.id == "TOOL-03" })?.status == "completed", "TOOL-03 не зафиксировал Whisper/VAD benchmark")
        try require(tasks.first(where: { $0.id == "MODEL-01" })?.status == "completed", "core topic models не готовы")
        try require(tasks.first(where: { $0.id == "MODEL-TRANSLATION" }) == nil, "core diagnostics включили TranslateGemma task")
        try require(tasks.first(where: { $0.id == "TTS-01" }) == nil, "core diagnostics включили translation-only voice task")
        try require(tasks.first(where: { $0.id == "AUDIO-01" })?.status == "completed", "AUDIO-01 не сохранил benchmark verdict")
        try require(tasks.first(where: { $0.id == "AUDIO-02" })?.status == "completed-with-rejection", "AUDIO-02 не сохранил отклонение NARA-WPE")
        let dereverbTask = tasks.first(where: { $0.id == "AUDIO-03" })
        try require(dereverbTask?.status == "completed", "AUDIO-03 не фиксирует принятие Product Owner")
        try require(dereverbTask?.blockedBy.isEmpty == true, "AUDIO-03 всё ещё заблокирован listening QA")
        let translationTasks = await service.collect(profile: .translation).terminalTasks ?? []
        try require(translationTasks.first(where: { $0.id == "MODEL-TRANSLATION" }) != nil, "translation diagnostics потеряли TranslateGemma")
        try require(translationTasks.first(where: { $0.id == "TTS-01" }) != nil, "translation diagnostics потеряли voice checks")
        try require(!controller.launchedExecutables.contains(where: { $0.contains("brew upgrade") }), "диагностика запустила изменение Homebrew")
        print("DIAGNOSTICS_PROBE_PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
