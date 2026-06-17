import Foundation

struct MusicTimedLyricLine: Equatable, Sendable {
    let offset: TimeInterval
    let text: String
}

/// Timed lyrics for the current track. In-memory only — never persist or log.
struct MusicTimedLyrics: Equatable, Sendable {
    let lines: [MusicTimedLyricLine]

    init?(lines: [MusicTimedLyricLine]) {
        let sorted = lines.sorted { $0.offset < $1.offset }
        guard !sorted.isEmpty else { return nil }
        self.lines = sorted
    }

    static func parsingLRC(_ text: String) -> MusicTimedLyrics? {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#) else {
            return nil
        }
        var lines: [MusicTimedLyricLine] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let nsLine = rawLine as NSString
            let matches = regex.matches(in: rawLine, range: NSRange(location: 0, length: nsLine.length))
            guard let lastMatch = matches.last else { continue }
            let content = nsLine.substring(from: lastMatch.range.location + lastMatch.range.length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            for match in matches {
                let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound {
                    let fractionText = nsLine.substring(with: match.range(at: 3))
                    fraction = (Double(fractionText) ?? 0) / pow(10, Double(fractionText.count))
                }
                lines.append(MusicTimedLyricLine(offset: minutes * 60 + seconds + fraction, text: content))
            }
        }
        return MusicTimedLyrics(lines: lines)
    }

    func currentLine(at elapsed: TimeInterval) -> String? {
        lines.last(where: { $0.offset <= elapsed })?.text
    }
}
