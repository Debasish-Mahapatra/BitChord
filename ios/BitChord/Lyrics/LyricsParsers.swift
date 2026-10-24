import Foundation

/** TtmlLyrics.kt: Apple-style TTML, word and syllable timed, with agents and backing vocals. */
enum TTMLParser {
    /** A tiny DOM: XMLParser hands events, the walk below wants a tree. */
    final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Child] = []
        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        enum Child {
            case element(Node)
            case text(String)
        }

        /** By qualified name, falling back to the local name. */
        func attribute(_ name: String) -> String? {
            if let value = attributes[name] { return value }
            let local = name.split(separator: ":").last.map(String.init) ?? name
            return attributes.first { $0.key.split(separator: ":").last.map(String.init) == local }?.value
        }

        var localName: String { name.split(separator: ":").last.map(String.init) ?? name }

        var textContent: String {
            children.map {
                switch $0 {
                case .text(let text): return text
                case .element(let node): return node.textContent
                }
            }.joined()
        }

        func descendants(_ localName: String) -> [Node] {
            var out: [Node] = []
            for case .element(let node) in children {
                if node.localName == localName { out.append(node) }
                out += node.descendants(localName)
            }
            return out
        }

        var hasTimedDescendant: Bool {
            for case .element(let node) in children {
                if node.attribute("begin") != nil, node.attribute("end") != nil { return true }
                if node.hasTimedDescendant { return true }
            }
            return false
        }
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = Node(name: qName ?? elementName, attributes: attributeDict)
            stack.last?.children.append(.element(node))
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let top = stack.last else { return }
            if case .text(let previous) = top.children.last {
                top.children[top.children.count - 1] = .text(previous + string)
            } else {
                top.children.append(.text(string))
            }
        }
    }

    static func parse(_ xml: String) -> [LyricLine] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let builder = Builder()
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let root = builder.root else { return [] }

        var agentTypes: [String: String] = [:]
        for agent in root.descendants("agent") {
            if let id = agent.attribute("xml:id"), let type = agent.attribute("type") { agentTypes[id] = type }
        }

        var parsed: [(line: LyricLine, singer: String?)] = []
        for p in root.descendants("p") {
            let begin = p.attribute("begin").flatMap(time)
            let end = p.attribute("end").flatMap(time)
            var main = WordBuilder()
            var backing = WordBuilder()
            walk(p, into: &main, backing: &backing, inBacking: false)
            let words = main.finish()
            let singer = p.attribute("ttm:agent")
            if words.isEmpty {
                let text = p.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let begin else { continue }
                parsed.append((LyricLine(time: begin, text: text, sungUntil: end.flatMap { $0 > begin ? $0 : nil }), singer))
                continue
            }
            var line = LyricLine(time: min(begin ?? words[0].start, words[0].start), text: words.map(\.text).joined(separator: " "), words: words)
            let backingWords = backing.finish()
            if !backingWords.isEmpty {
                line.backgrounds = [LyricLine(time: backingWords[0].start, text: backingWords.map(\.text).joined(separator: " "), words: backingWords)]
            }
            parsed.append((line, singer))
        }
        parsed.sort { $0.line.time < $1.line.time }
        let sides = LyricsPost.alignments(singers: parsed.map(\.singer), types: agentTypes)
        let lines = zip(parsed, sides).map { item, side -> LyricLine in
            var line = item.line
            line.alignment = side
            line.backgrounds = line.backgrounds.map { var bg = $0; bg.alignment = side; return bg }
            return line
        }
        return LyricsPost.withInstrumentalGaps(lines)
    }

    /** Timed spans become syllables of words; text between them decides where words end. */
    private static func walk(_ node: Node, into main: inout WordBuilder, backing: inout WordBuilder, inBacking: Bool) {
        for child in node.children {
            switch child {
            case .text(let text):
                if inBacking { backing.untimed(text) } else { main.untimed(text) }
            case .element(let element):
                let role = element.attribute("ttm:role")
                if role == "x-translation" || role == "x-roman" { continue }
                let toBacking = inBacking || role == "x-bg"
                if let b = element.attribute("begin").flatMap(time), let e = element.attribute("end").flatMap(time),
                   !element.hasTimedDescendant {
                    if toBacking { backing.timed(element.textContent, b, e) } else { main.timed(element.textContent, b, e) }
                } else {
                    walk(element, into: &main, backing: &backing, inBacking: toBacking)
                }
            }
        }
    }

    struct WordBuilder {
        private var words: [LyricWord] = []
        private var open: LyricWord?
        private var pieces: [(start: Int, end: Int, chars: Range<Int>)] = []

        mutating func timed(_ raw: String, _ start: Int, _ end: Int) {
            if raw.first?.isWhitespace == true { close() }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if var word = open {
                    let from = word.text.count
                    word.text += text
                    word.end = max(word.end, end)
                    open = word
                    pieces.append((start, end, from..<word.text.count))
                } else {
                    open = LyricWord(start: start, end: end, text: text)
                    pieces = [(start, end, 0..<text.count)]
                }
            }
            if raw.last?.isWhitespace == true { close() }
        }

        mutating func untimed(_ text: String) {
            if text.allSatisfy(\.isWhitespace) {
                close()
                return
            }
            // Punctuation glued to the word before it.
            guard var word = open else { return }
            if text.first?.isWhitespace == true { close(); return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            word.text += trimmed
            open = word
            if let last = pieces.indices.last { pieces[last].chars = pieces[last].chars.lowerBound..<word.text.count }
            if text.last?.isWhitespace == true { close() }
        }

        mutating func close() {
            guard var word = open else { return }
            if pieces.count > 1 {
                word.syllables = pieces.map { LyricSyllable(start: $0.start, end: $0.end, startChar: $0.chars.lowerBound, endChar: $0.chars.upperBound) }
                word.syllables[0].startChar = 0
                word.syllables[word.syllables.count - 1].endChar = word.text.count
            }
            words.append(word)
            open = nil
            pieces = []
        }

        mutating func finish() -> [LyricWord] {
            close()
            return words
        }
    }

    /** `27.395`, `m:ss.f`, `h:m:s.f`, a trailing `s`, or `Nms`, in milliseconds. */
    static func time(_ raw: String) -> Int? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("ms"), let value = Double(text.dropLast(2)) { return Int(value) }
        if text.hasSuffix("s") { text.removeLast() }
        let parts = text.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return Int((seconds * 1000).rounded())
    }
}

/** LrcLib.parseLrc / EnhancedLrc: line stamps, and `<mm:ss.xx>` word stamps when present. */
enum LRCParser {
    private static let lineStamp = NSRegularExpression(#"^\[(\d{1,3}):(\d{2})[.:](\d{2,3})\](.*)$"#)
    private static let wordStamp = NSRegularExpression(#"<(\d{1,3}):(\d{2})[.:](\d{2,3})>"#)

    private static func ms(_ m: String, _ s: String, _ f: String) -> Int {
        let fraction = Int(f) ?? 0
        return ((Int(m) ?? 0) * 60 + (Int(s) ?? 0)) * 1000 + (f.count == 2 ? fraction * 10 : fraction)
    }

    static func parse(_ text: String) -> [LyricLine] {
        var stamped: [(time: Int, body: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = lineStamp.firstMatch(in: line, range: range) else { continue }
            func group(_ i: Int) -> String { String(line[Range(match.range(at: i), in: line)!]) }
            stamped.append((ms(group(1), group(2), group(3)), group(4)))
        }
        stamped.sort { $0.time < $1.time }
        let hasWords = stamped.contains { wordStamp.firstMatch(in: $0.body, range: NSRange($0.body.startIndex..., in: $0.body)) != nil }

        var lines: [LyricLine] = []
        for (i, entry) in stamped.enumerated() {
            var body = entry.body
            var alignment = LyricAlignment.start
            if body.hasPrefix("<R>") {
                alignment = .end
                body.removeFirst(3)
            }
            let range = NSRange(body.startIndex..., in: body)
            let stamps = wordStamp.matches(in: body, range: range)
            let plain = wordStamp.stringByReplacingMatches(in: body, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
            let nextTime = i + 1 < stamped.count ? stamped[i + 1].time : nil
            if plain.isEmpty {
                // An empty line stays only as a long pause (≥ 4 s) or at the very end.
                if hasWords { continue }
                if nextTime == nil || nextTime! - entry.time >= LyricsPost.minGap { lines.append(LyricLine(time: entry.time, text: "")) }
                continue
            }
            var line = LyricLine(time: entry.time, text: plain, alignment: alignment)
            if !stamps.isEmpty {
                var runs: [(start: Int, text: String)] = []
                for (k, stamp) in stamps.enumerated() {
                    func group(_ g: Int) -> String { String(body[Range(stamp.range(at: g), in: body)!]) }
                    let textStart = stamp.range.location + stamp.range.length
                    let textEnd = k + 1 < stamps.count ? stamps[k + 1].range.location : (body as NSString).length
                    let piece = (body as NSString).substring(with: NSRange(location: textStart, length: textEnd - textStart))
                    runs.append((ms(group(1), group(2), group(3)), piece))
                }
                line.words = words(from: runs, lineEnd: nextTime ?? (runs.last!.start + 800))
            }
            lines.append(line)
        }
        if let first = lines.first, !first.isGap, first.time >= LyricsPost.minGap, !hasWords {
            lines.insert(LyricLine(time: 0, text: ""), at: 0)
        }
        return hasWords ? LyricsPost.withInstrumentalGaps(lines) : lines
    }

    /** Runs glued into words where no whitespace separates them (wordsFromRuns, Latin case). */
    private static func words(from runs: [(start: Int, text: String)], lineEnd: Int) -> [LyricWord] {
        var words: [LyricWord] = []
        var current: LyricWord?
        var pieces: [(Int, Int, Range<Int>)] = []
        func close() {
            guard var word = current else { return }
            if pieces.count > 1 {
                word.syllables = pieces.map { LyricSyllable(start: $0.0, end: $0.1, startChar: $0.2.lowerBound, endChar: $0.2.upperBound) }
            }
            words.append(word)
            current = nil
            pieces = []
        }
        for (i, run) in runs.enumerated() {
            let end = i + 1 < runs.count ? runs[i + 1].start : lineEnd
            if run.text.first?.isWhitespace == true { close() }
            let text = run.text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { close(); continue }
            if var word = current {
                let from = word.text.count
                word.text += text
                word.end = end
                current = word
                pieces.append((run.start, end, from..<word.text.count))
            } else {
                current = LyricWord(start: run.start, end: end, text: text)
                pieces = [(run.start, end, 0..<text.count)]
            }
            if run.text.last?.isWhitespace == true { close() }
        }
        close()
        return words
    }
}

/** ProviderLyrics.parse: whatever a provider answered, unwrapped and handed to the right parser. */
enum ProviderLyrics {
    static func parse(_ raw: String) -> [LyricLine] {
        var content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("{"), let json = try? JSON(data: Data(content.utf8)) {
            if json["isError"].bool == true || json["ok"].bool == false || json["error"].exists { return [] }
            for key in ["ttml", "ttmlContent", "lyrics", "lrc", "content", "text", "syncedLyrics", "plainLyrics", "lyric"] {
                if let value = json[key].string, !value.isEmpty { content = value; break }
            }
        }
        if content.contains("&lt;tt") { content = unescapeHTML(content) }
        if content.contains("<tt") || content.contains("http://www.w3.org/ns/ttml") { return TTMLParser.parse(content) }
        if content.hasPrefix("<") { return [] }
        let synced = LRCParser.parse(content)
        if !synced.isEmpty { return synced }
        return plain(content)
    }

    /** Unsynced text, one line per line. */
    static func plain(_ text: String) -> [LyricLine] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.range(of: "lyrics (not found|unavailable)|^error", options: [.regularExpression, .caseInsensitive]) != nil }) { return [] }
        return lines.filter { !($0.hasPrefix("[") && $0.contains(":") && $0.hasSuffix("]")) }.map { LyricLine(time: 0, text: $0) }
    }

    static func unescapeHTML(_ text: String) -> String {
        var out = text
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        return out
    }

    /**
     * LyricsPlus v2: `lyrics:[{time,duration,text,syllabus:[{time,duration,text}],element:{singer}}]`,
     * a trailing space in a syllable ending its word.
     */
    static func lyricsPlus(_ json: JSON) -> [LyricLine] {
        var agentTypes: [String: String] = [:]
        if let agents = json["metadata"]["agents"].object {
            for (id, value) in agents {
                let agent = JSON(value)
                agentTypes[agent["alias"].string ?? id] = agent["type"].string
            }
        }
        var parsed: [(LyricLine, String?)] = []
        for item in json["lyrics"].array {
            guard let start = item["time"].double.map({ Int($0) }) else { continue }
            let duration = item["duration"].double.map { Int($0) } ?? 0
            let syllables = item["syllabus"].array
            let singer = item["element"]["singer"].string
            if syllables.isEmpty {
                let text = (item["text"].string ?? "").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                parsed.append((LyricLine(time: start, text: text, sungUntil: duration > 0 ? start + duration : nil), singer))
                continue
            }
            var main = TTMLParser.WordBuilder()
            var backing = TTMLParser.WordBuilder()
            for syllable in syllables {
                guard let s = syllable["time"].double.map({ Int($0) }) else { continue }
                let e = s + (syllable["duration"].double.map { Int($0) } ?? 0)
                let text = syllable["text"].string ?? ""
                if syllable["isBackground"].bool == true { backing.timed(text, s, e) } else { main.timed(text, s, e) }
            }
            let words = main.finish()
            guard !words.isEmpty else { continue }
            var line = LyricLine(time: min(start, words[0].start), text: words.map(\.text).joined(separator: " "), words: words)
            let bg = backing.finish()
            if !bg.isEmpty { line.backgrounds = [LyricLine(time: bg[0].start, text: bg.map(\.text).joined(separator: " "), words: bg)] }
            parsed.append((line, singer))
        }
        parsed.sort { $0.0.time < $1.0.time }
        let sides = LyricsPost.alignments(singers: parsed.map(\.1), types: agentTypes)
        let lines = zip(parsed, sides).map { item, side -> LyricLine in
            var line = item.0
            line.alignment = side
            return line
        }
        return LyricsPost.withInstrumentalGaps(lines)
    }
}
