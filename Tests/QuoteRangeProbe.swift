import Foundation

@main
struct QuoteRangeProbe {
    static func main() throws {
        let cues = [
            SubtitleCue(id: 1, start: 1, end: 2, text: "Начинаем с цитаты Альфа."),
            SubtitleCue(id: 2, start: 2, end: 4, text: "Середина первого фрагмента."),
            SubtitleCue(id: 3, start: 4, end: 6, text: "Заканчиваем словами Омега!"),
            SubtitleCue(id: 4, start: 10, end: 12, text: "Начинаем с цитаты Альфа."),
            SubtitleCue(id: 5, start: 12, end: 14, text: "Заканчиваем словами Омега!")
        ]
        let matcher = QuoteRangeMatcher()
        let matches = matcher.candidates(
            cues: cues,
            startQuote: "ЦИТАТЫ альфа",
            endQuote: "словами омега",
            leadPadding: 0.25,
            trailingPadding: 0.5
        )
        try require(matches.count == 2, "не обнаружена неоднозначность повторяющихся цитат")
        try require(matches[0].start == 0.75 && matches[0].end == 6.5, "не применены отступы")
        try require(matches[0].startCueID == 1 && matches[0].endCueID == 3, "неверная пара cue")
        try require(matches[1].startCueID == 4 && matches[1].endCueID == 5, "повтор выбрал не ближайшее окончание")

        let fuzzy = matcher.candidates(
            cues: cues,
            startQuote: "Начинаем с цетаты Альфа",
            endQuote: "Заканчиваем словами Омега"
        )
        try require(fuzzy.count == 2, "ограниченный fuzzy-поиск не исправил одну опечатку")
        try require(matcher.normalize("Ёлка,  ТЕСТ!") == "елка тест", "нормализация ё/регистра/пунктуации неверна")
        print("QUOTE_RANGE_PROBE_PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private struct ProbeFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
