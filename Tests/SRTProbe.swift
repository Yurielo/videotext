import Foundation

@main
struct SRTProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let mediaDuration = Double(CommandLine.arguments[2]) else {
            fputs("Использование: videotext-srt-probe <full.srt> <длительность-медиа>\n", stderr)
            exit(2)
        }

        let srtURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let result = try SRTService().loadWithReport(from: srtURL)
        let warnings = SRTService().validateTimeline(result.cues, mediaDuration: mediaDuration)
        print("CUES=\(result.cues.count)")
        print("SKIPPED_ZERO=\(result.skippedZeroDurationCount)")
        print("WARNINGS=\(warnings.count)")
        warnings.prefix(10).forEach { print($0) }
        guard warnings.isEmpty else { exit(1) }
    }
}
