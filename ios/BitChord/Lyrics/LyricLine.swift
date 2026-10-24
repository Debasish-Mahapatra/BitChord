import Foundation

/** One syllable's timing and its characters inside the word (LyricLine.kt). */
struct LyricSyllable: Hashable, Sendable {
    var start: Int
    var end: Int
    var startChar: Int
    var endChar: Int
}

struct LyricWord: Hashable, Sendable {
    var start: Int
    var end: Int
    var text: String
    /** Empty, or two or more covering the whole word: one syllable is just the word. */
    var syllables: [LyricSyllable] = []
}

enum LyricAlignment: Hashable, Sendable { case start, end }

/** One line of a lyric sheet. Times are milliseconds into the track. */
struct LyricLine: Hashable, Sendable {
    var time: Int
    var text: String
    var words: [LyricWord] = []
    var sungUntil: Int?
    /** The answering or backing vocal, as a line with its own timings (zero or one). */
    var backgrounds: [LyricLine] = []
    var alignment: LyricAlignment = .start

    var background: LyricLine? { backgrounds.first }
    var isGap: Bool { text.isEmpty }
    var isWordSynced: Bool { !words.isEmpty }
    var hasKnownEnd: Bool { !words.isEmpty || sungUntil != nil }

    private var ownEnd: Int { words.last?.end ?? sungUntil ?? time }

    /** Where the line stops, its backing vocal included. */
    var end: Int { max(ownEnd, background?.end ?? ownEnd) }

    /** Each word's character range in [text], found walking forward. */
    var wordSpans: [Range<Int>] {
        let chars = Array(text)
        var cursor = 0
        return words.map { word in
            let target = Array(word.text)
            var found = cursor
            if !target.isEmpty, chars.count >= target.count {
                var i = cursor
                while i + target.count <= chars.count {
                    if Array(chars[i..<(i + target.count)]) == target { found = i; break }
                    i += 1
                }
            }
            let range = found..<min(chars.count, found + target.count)
            cursor = range.upperBound
            return range
        }
    }

    /**
     * How many characters have been sung at [ms], fractionally: each syllable
     * fills its characters over its own duration, and the space after a word
     * across the pause before the next.
     */
    func revealedChars(at ms: Int) -> Double {
        let length = Double(text.count)
        guard isWordSynced else { return ms >= time ? length : 0 }
        if ms >= end { return length }
        if ms <= time { return 0 }
        let spans = wordSpans
        var revealed = 0.0
        for (i, word) in words.enumerated() {
            let span = spans[i]
            if ms < word.start { return revealed }
            if ms >= word.end {
                revealed = Double(span.upperBound)
                // The gap to the next word fills across the pause.
                if i + 1 < words.count {
                    let next = words[i + 1]
                    let gapChars = Double(spans[i + 1].lowerBound - span.upperBound)
                    if ms < next.start, next.start > word.end {
                        revealed += gapChars * Double(ms - word.end) / Double(next.start - word.end)
                        return revealed
                    }
                    revealed += gapChars
                }
                continue
            }
            if word.syllables.isEmpty {
                let t = Double(ms - word.start) / Double(max(1, word.end - word.start))
                return Double(span.lowerBound) + t * Double(span.count)
            }
            for syllable in word.syllables {
                if ms < syllable.start { return Double(span.lowerBound + syllable.startChar) }
                if ms < syllable.end {
                    let t = Double(ms - syllable.start) / Double(max(1, syllable.end - syllable.start))
                    return Double(span.lowerBound + syllable.startChar) + t * Double(syllable.endChar - syllable.startChar)
                }
            }
            return Double(span.upperBound)
        }
        return revealed
    }
}

/** A lyric sheet and where it came from. */
struct Lyrics: Sendable {
    var lines: [LyricLine]
    var source: LyricsSource

    /** Any line with a time: a synced sheet. */
    var isSynced: Bool { lines.contains { $0.time > 0 } }
    var isWordSynced: Bool { lines.contains { $0.isWordSynced } }
    var hasDuet: Bool { lines.contains { $0.alignment == .end } }
}

// MARK: - Post-processing (LyricsPostProcess)

enum LyricsPost {
    static let minGap = 4000

    /** Empty lines where the music runs at least four seconds without a vocal. */
    static func withInstrumentalGaps(_ lines: [LyricLine]) -> [LyricLine] {
        guard let first = lines.first else { return lines }
        var out: [LyricLine] = []
        if !first.isGap, first.time >= minGap { out.append(LyricLine(time: 0, text: "")) }
        for (i, line) in lines.enumerated() {
            out.append(line)
            guard i + 1 < lines.count, line.hasKnownEnd, !line.isGap else { continue }
            let next = lines[i + 1]
            if next.time - line.end >= minGap, line.end > line.time, !next.isGap {
                out.append(LyricLine(time: line.end, text: ""))
            }
        }
        return out
    }

    /** A trailing "(…)" split off as the backing vocal, as withBackgroundVocals. */
    static func withBackgroundVocals(_ lines: [LyricLine]) -> [LyricLine] {
        lines.map { line in
            guard line.background == nil, !line.isGap, line.text.hasSuffix(")") else { return line }
            let chars = Array(line.text)
            var depth = 0
            var open: Int?
            for i in stride(from: chars.count - 1, through: 0, by: -1) {
                if chars[i] == ")" { depth += 1 }
                if chars[i] == "(" {
                    depth -= 1
                    if depth == 0 { open = i; break }
                }
            }
            guard let open, open > 0 else { return line }
            let lead = String(chars[..<open]).trimmingCharacters(in: .whitespaces)
            let backing = String(chars[open...])
            guard !lead.isEmpty, backing.contains(where: { $0.isLetter || $0.isNumber }) else { return line }
            var out = line
            if line.isWordSynced {
                let spans = line.wordSpans
                guard let split = spans.firstIndex(where: { $0.lowerBound == open }) else { return line }
                out.text = lead
                out.words = Array(line.words[..<split])
                var bg = LyricLine(time: line.words[split].start, text: backing)
                bg.words = Array(line.words[split...])
                bg.alignment = line.alignment
                out.backgrounds = [bg]
            } else {
                out.text = lead
                var bg = LyricLine(time: line.time, text: backing, sungUntil: line.sungUntil)
                bg.alignment = line.alignment
                out.backgrounds = [bg]
            }
            return out
        }
    }

    /**
     * Duet sides from each line's singer: turns alternate as the singer
     * changes, a group sings centre-left, and a sheet that ends up almost all
     * on the right is flipped back (lineAlignments).
     */
    static func alignments(singers: [String?], types: [String: String]) -> [LyricAlignment] {
        var left = true
        var last: String?
        var right = 0, placed = 0
        var out: [LyricAlignment] = []
        for singer in singers {
            guard let singer, !singer.isEmpty else { out.append(.start); continue }
            let type = types[singer] ?? (singer == "v1000" ? "group" : singer == "v2000" ? "other" : "person")
            placed += 1
            if type == "group" { out.append(.start); continue }
            if last == nil { left = type != "other" } else if singer != last { left.toggle() }
            last = singer
            if !left { right += 1 }
            out.append(left ? .start : .end)
        }
        if placed > 0, Double(right) / Double(placed) >= 0.85 {
            out = out.map { $0 == .start ? .end : .start }
        }
        return out
    }
}
