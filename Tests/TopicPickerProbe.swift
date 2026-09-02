import Foundation
import AppKit

enum TopicPickerProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

@main
enum TopicPickerProbe {
    static func main() {
        do {
            let fullTitle = String(repeating: "Длинное название темы ", count: 4)
            let topic = TopicSegment(
                id: "topic-15",
                title: fullTitle,
                start: 3_723.4,
                end: 10_925.2,
                duration: 1,
                keywords: [],
                cueIds: [1]
            )
            let title = TopicPickerFormatter.title(for: topic)
            try require(
                title.hasPrefix("topic-15 · 01:02:03–03:02:05 · 2:00:02 · "),
                "не показаны диапазон и длительность темы длиннее часа"
            )
            try require(title.hasSuffix("…"), "длинное название не сокращено")
            try require(!title.contains("00:01"), "использовано устаревшее поле duration вместо end-start")
            let menuFont = NSFont.menuFont(ofSize: 0)
            let width = (title as NSString).size(withAttributes: [.font: menuFont]).width
            try require(width <= 760, "пункт меню шире безопасной области: \(Int(width.rounded())) px")
            let help = TopicPickerFormatter.help(for: topic)
            try require(help.contains(fullTitle), "подсказка не содержит полное название")
            try require(help.contains("Начало: 01:02:03.400"), "подсказка потеряла точное начало")
            try require(help.contains("Конец: 03:02:05.200"), "подсказка потеряла точный конец")
            try require(help.contains("Длительность: 02:00:01.800"), "подсказка потеряла точную длительность")

            let roundedRange = TopicSegment(
                id: "topic-edge",
                title: "Проверка округления",
                start: 0.49,
                end: 1.51,
                keywords: [],
                cueIds: [1]
            )
            try require(
                TopicPickerFormatter.title(for: roundedRange).contains("00:00:00–00:00:02 · 00:02"),
                "длительность не согласована с отображаемыми границами"
            )
            print("TOPIC PICKER PASS")
        } catch {
            fputs("TOPIC PICKER FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TopicPickerProbeError.failed(message) }
    }
}
