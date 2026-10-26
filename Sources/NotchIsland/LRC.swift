import Foundation

struct LyricLine: Equatable {
    let time: TimeInterval
    let text: String
}

enum LyricsState {
    case idle, loading, found, missing
}

/// Lector del formato LRC: líneas tipo "[01:23.45] texto".
enum LRC {
    static func parse(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []

        for raw in lrc.split(whereSeparator: { $0.isNewline }) {
            var rest = Substring(raw)
            var times: [TimeInterval] = []

            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
                    times.append(minutes * 60 + seconds)
                }
                rest = rest[rest.index(after: close)...]
            }

            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in times {
                lines.append(LyricLine(time: t, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}
