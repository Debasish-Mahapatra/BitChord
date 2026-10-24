import Foundation

/**
 * Whether a row from another catalogue is the same recording as a YouTube
 * track (TrackMatcher.kt): the title's core words alike, the same version
 * markers (a remix is not the original), a shared artist, a length within
 * half a minute, and the explicit flag agreeing where both say.
 */
enum TrackMatcher {
    struct Target: Sendable {
        var title: String
        var artist: String = ""
        var durationSec: Int?
        var album: String?
        var isExplicit: Bool?
        var isVideo = false

        init(title: String, artist: String = "", durationSec: Int? = nil, album: String? = nil, isExplicit: Bool? = nil, isVideo: Bool = false) {
            self.title = title
            self.artist = artist
            self.durationSec = durationSec
            self.album = album
            self.isExplicit = isExplicit
            self.isVideo = isVideo
        }

        init(_ song: Song) {
            self.init(title: song.title, artist: song.artist, durationSec: TrackMatcher.secondsOf(song.durationText),
                      album: song.albumName, isExplicit: song.isExplicit ? true : nil, isVideo: song.isVideo)
        }
    }

    /** A catalogue row, as much of it as matching reads. */
    struct Candidate: Sendable {
        var title: String
        var artist: String
        var album: String?
        var durationSec: Int?
        var isExplicit: Bool?
    }

    // MARK: Queries

    /** What to search a catalogue for: title and primary artist, the title alone, and a romanised form. */
    static func queries(_ target: Target) -> [String] {
        let title = searchableTitle(target.title, artist: target.artist)
        guard !title.isEmpty else { return [] }
        let artist = primaryArtist(target.artist)
        var out = artist.isEmpty ? [title] : ["\(title) \(artist)", title]
        let latin = romajiOf(title).trimmingCharacters(in: .whitespaces)
        let isLatinQuery = latin.allSatisfy { latinQueryChars.contains($0) }
        let other = (!latin.isEmpty && latin != title && isLatinQuery) ? latin
            : scriptMates(target.title).first { !$0.isEmpty && $0 != title }
        if let other { out.append(other) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    static func searchableTitle(_ title: String, artist: String = "") -> String {
        let parts = parseTitle(title, artist: artist)
        return (parts.words + parts.versions.sorted()).joined(separator: " ")
    }

    static func primaryArtist(_ artist: String) -> String {
        split(normalize(artist), artistSeparators).first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    static func sharesArtist(_ wanted: String, _ got: String) -> Bool {
        let want = artistNames(wanted), have = artistNames(got)
        return !want.isEmpty && !have.isEmpty && want.contains { w in have.contains { h in sameArtist(w, h) } }
    }

    // MARK: Ranking

    static func ranked(_ candidates: [Candidate], _ target: Target) -> [Candidate] {
        let scored = candidates.compactMap { candidate in score(candidate, target).map { (candidate, $0) } }
        let credited = scored.filter { artistScore(target.artist, $0.0.artist) != nil }
        return (credited.isEmpty ? scored : credited).sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func score(_ candidate: Candidate, _ target: Target) -> Int? {
        let wanted = parseTitle(target.title, artist: target.artist)
        let got = parseTitle(candidate.title, artist: candidate.artist)
        guard !wanted.core.isEmpty, !got.core.isEmpty else { return nil }
        let isTitleMatch: Bool
        if wanted.core == got.core || romajiOf(wanted.core) == romajiOf(got.core) {
            isTitleMatch = true
        } else if wanted.core.count <= 3 || got.core.count <= 3 {
            isTitleMatch = false
        } else {
            isTitleMatch = wanted.core.contains(got.core) || got.core.contains(wanted.core)
        }
        guard isTitleMatch else { return nil }
        let albumMarks = albumVersionMarkers(candidate.album)
        let effectiveVersions = got.versions.union(albumMarks.intersection(novocalTakes)).union(albumMarks.intersection(wanted.versions))
        guard wanted.versions == effectiveVersions else { return nil }

        let creditedArtist = artistScore(target.artist, candidate.artist)
        guard let duration = durationScore(target.durationSec, candidate.durationSec, allowVideoDrift: creditedArtist != nil) else { return nil }
        let artist: Int
        if let creditedArtist {
            artist = creditedArtist
        } else if !target.isVideo, withinSeconds(candidate, target, creditOverrideSec) {
            artist = creditsDisagree
        } else {
            return nil
        }
        guard let explicit = explicitScore(target.isExplicit, candidate.isExplicit) else { return nil }
        return base + artist + duration + albumScore(target.album, candidate.album) + explicit + contextScore(wanted, got)
    }

    /** Close matches filed under more than one album, when the target names none: a catalogue that can't agree. */
    static func hasConflictingAlbums(_ candidates: [Candidate], _ target: Target) -> Bool {
        if !(target.album ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return false }
        let comparable = target.durationSec != nil ? candidates.filter { withinSeconds($0, target, durationLimitSec) } : candidates
        if target.durationSec != nil, comparable.isEmpty { return false }
        return Set(comparable.compactMap { albumKey($0.album) }).count > 1
    }

    /** Of several close matches, the single one with the fullest credit, if there is exactly one. */
    static func uniquelyMostCreditedCloseMatch(_ candidates: [Candidate], _ target: Target) -> Candidate? {
        let close = candidates.filter { withinSeconds($0, target, durationLimitSec) }
        guard close.count >= 2 else { return nil }
        let ranked = close.map { ($0, artistNames($0.artist).count) }
        guard let top = ranked.map(\.1).max(), top >= 2 else { return nil }
        let winners = ranked.filter { $0.1 == top }.map(\.0)
        return winners.count == 1 ? winners[0] : nil
    }

    static func withinSeconds(_ candidate: Candidate, _ target: Target, _ seconds: Int) -> Bool {
        guard let wanted = target.durationSec, let got = candidate.durationSec else { return false }
        return abs(wanted - got) <= seconds
    }

    // MARK: Titles

    struct TitleParts {
        var words: [String]
        var core: String
        var versions: Set<String>
        var context: Set<String>
    }

    static func parseTitle(_ raw: String, artist: String = "") -> TitleParts {
        var versions = Set<String>()
        var context = Set<String>()
        var text = normalize(raw)

        for _ in 0..<bracketPasses {
            guard bracketed.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { break }
            text = replace(bracketed, in: text) { inner in
                classify(inner, &versions, &context)
                return " "
            }
        }
        if let open = text.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            classify(String(text[open...]), &versions, &context)
            text = String(text[..<open])
        }

        for _ in 0..<dashPasses {
            guard let match = dash.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text) else { break }
            let head = String(text[..<range.lowerBound])
            let tail = String(text[range.upperBound...])
            if isArtistName(head, artist) {
                classify(head, &versions, &context)
                text = tail
            } else if !hasFilingLatin(head), hasFilingLatin(tail), !isArtistName(tail, artist) {
                classify(head, &versions, &context)
                text = tail
            } else {
                classify(tail, &versions, &context)
                text = head
            }
        }

        text = featuring.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        let containsCJK = text.unicodeScalars.contains { s in
            (0x3040...0x309F).contains(s.value) || (0x30A0...0x30FF).contains(s.value)
                || (0x4E00...0x9FFF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
        }

        var words = split(text, wordSplit).map(alnum).filter { !$0.isEmpty && !joiningWords.contains($0) }
        while words.count > 1 {
            let last = words[words.count - 1]
            if trailingNoise.contains(last) {
                words.removeLast()
            } else if trailingTakes.contains(last) {
                versions.insert(last)
                words.removeLast()
            } else {
                break
            }
        }
        let core = containsCJK
            ? cjkStrip.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            : words.joined()
        return TitleParts(words: words, core: core, versions: versions, context: context)
    }

    private static func classify(_ segment: String, _ versions: inout Set<String>, _ context: inout Set<String>) {
        let words = split(segment, wordSplit).map(alnum).filter { !$0.isEmpty }
        guard !words.isEmpty, !neutralSegments.contains(words.joined()) else { return }
        let marks = words.filter { versionWords.contains($0) }
        if !marks.isEmpty {
            versions.formUnion(marks)
            return
        }
        context.formUnion(words.filter { $0.count > 2 && !noiseWords.contains($0) })
    }

    private static func isArtistName(_ text: String, _ artist: String) -> Bool {
        guard !artist.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let words = split(text, wordSplit).map(alnum).filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }
        let credited = Set(split(normalize(artist), wordSplit).map(alnum).filter { !$0.isEmpty })
        return words.allSatisfy(credited.contains)
    }

    static func normalize(_ text: String) -> String {
        var out = text.precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(of: "&", with: " and ")
        out = cjkOpen.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "(")
        out = cjkClose.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: ")")
        return out
    }

    private static func hasFilingLatin(_ text: String) -> Bool {
        split(text, wordSplit).map(alnum).filter { !$0.isEmpty }.contains { word in
            word.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) && !versionWords.contains(word)
                && !noiseWords.contains(word) && !trailingNoise.contains(word) && !joiningWords.contains(word)
        }
    }

    /** A title written twice across a dash, once in each script: both halves, so either can be searched. */
    static func scriptMates(_ raw: String) -> [String] {
        let text = normalize(raw)
        guard let match = dash.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return [] }
        let head = searchableTitle(String(text[..<range.lowerBound]))
        let tail = searchableTitle(String(text[range.upperBound...]))
        guard !head.isEmpty, !tail.isEmpty, head != tail else { return [] }
        return romajiOf(head) == tail || romajiOf(tail) == head ? [head, tail] : []
    }

    /** Kana spelt out in Hepburn, so a Japanese title and its romanised listing compare equal. */
    static func romajiOf(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        var geminate = false
        var lastVowel: Character?
        func hiragana(_ c: Character) -> Character {
            guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1, (0x30A1...0x30F6).contains(scalar.value),
                  let shifted = Unicode.Scalar(scalar.value - 0x60) else { return c }
            return Character(shifted)
        }
        func emit(_ roma: String) {
            var r = roma
            if geminate {
                geminate = false
                if r.hasPrefix("ch") { r = "t" + r } else if r.hasPrefix("sh") { r = "s" + r } else if r.hasPrefix("ts") { r = "t" + r } else if let first = r.first { r = String(first) + r }
            }
            out += r
            lastVowel = r.last { "aeiou".contains($0) }
        }
        while i < chars.count {
            let c = hiragana(chars[i])
            switch c {
            case "っ":
                geminate = true
                i += 1
            case "ー":
                if let lastVowel { out.append(lastVowel) }
                i += 1
            case "ん":
                let peek = i + 1 < chars.count ? kanaRomaji[hiragana(chars[i + 1])]?.first : nil
                emit(peek == "b" || peek == "m" || peek == "p" ? "m" : "n")
                i += 1
            default:
                guard let base = kanaRomaji[c] else {
                    out.append(c)
                    lastVowel = nil
                    geminate = false
                    i += 1
                    continue
                }
                let next = i + 1 < chars.count ? hiragana(chars[i + 1]) : nil
                if let next, let small = smallY[next] ?? smallV[next] {
                    let cons = consOverrides.first { base.hasPrefix($0.key) }?.value ?? String(base.dropLast())
                    let glide = (cons == "sh" || cons == "ch" || cons == "j") && small.hasPrefix("y") ? String(small.dropFirst()) : small
                    emit(cons + glide)
                    i += 2
                } else {
                    emit(base)
                    i += 1
                }
            }
        }
        return out
    }

    // MARK: Scores

    private static func artistScore(_ wanted: String, _ got: String) -> Int? {
        let want = artistNames(wanted), have = artistNames(got)
        if want.isEmpty || have.isEmpty { return 0 }
        guard sharesArtist(wanted, got) else { return nil }
        return want == have ? artistExact : artistShared
    }

    static func artistNames(_ value: String) -> Set<[String]> {
        Set(split(normalize(value), artistSeparators).map { name in
            split(name, wordSplit).map(alnum).filter { $0.count > 1 }
        }.filter { !$0.isEmpty })
    }

    private static func sameArtist(_ a: [String], _ b: [String]) -> Bool { runOf(a, b) || runOf(b, a) }

    private static func runOf(_ outer: [String], _ inner: [String]) -> Bool {
        guard !inner.isEmpty, inner.count <= outer.count else { return false }
        return (0...(outer.count - inner.count)).contains { Array(outer[$0..<($0 + inner.count)]) == inner }
    }

    private static func durationScore(_ wanted: Int?, _ got: Int?, allowVideoDrift: Bool) -> Int? {
        guard let wanted, let got else { return 0 }
        let drift = abs(wanted - got)
        if drift > durationLimitSec, allowVideoDrift, drift <= videoDurationLimitSec { return 0 }
        if drift > durationLimitSec { return nil }
        return drift <= durationTightSec ? durationTight : durationLoose
    }

    private static func albumScore(_ wanted: String?, _ got: String?) -> Int {
        guard let want = albumKey(wanted), let have = albumKey(got) else { return 0 }
        return want == have ? albumExact : 0
    }

    private static func explicitScore(_ wanted: Bool?, _ got: Bool?) -> Int? {
        guard let wanted, let got else { return 0 }
        return wanted == got ? explicitExact : nil
    }

    static func albumVersionMarkers(_ album: String?) -> Set<String> {
        guard let album, !album.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return parseTitle(album).versions
    }

    private static func albumKey(_ value: String?) -> String? {
        var text = normalize(value ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        for _ in 0..<bracketPasses {
            text = bracketed.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        let key = split(text, wordSplit).map(alnum).filter { !$0.isEmpty && !albumNoiseWords.contains($0) }.joined()
        return key.isEmpty ? nil : key
    }

    static func secondsOf(_ text: String?) -> Int? {
        guard let parts = text?.trimmingCharacters(in: .whitespaces).split(separator: ":"), (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard let n = Int(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            total = total * 60 + n
        }
        return total > 0 ? total : nil
    }

    private static func contextScore(_ wanted: TitleParts, _ got: TitleParts) -> Int {
        wanted.context.isDisjoint(with: got.context) ? 0 : contextShared
    }

    // MARK: Helpers

    private static func split(_ text: String, _ regex: NSRegularExpression) -> [String] {
        var out: [String] = []
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            out.append(String(text[last..<range.lowerBound]))
            last = range.upperBound
        }
        out.append(String(text[last...]))
        return out
    }

    /** Letters and numbers only (`[^\p{L}\p{N}]` removed): combining marks go too, as on the phone. */
    private static func alnum(_ word: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in word.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                out.append(scalar)
            default:
                continue
            }
        }
        return String(out)
    }

    /** Replaces each match of a one-group pattern with what [transform] makes of its group. */
    private static func replace(_ regex: NSRegularExpression, in text: String, _ transform: (String) -> String) -> String {
        var out = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
            out += text[last..<whole.lowerBound]
            out += transform(String(text[inner]))
            last = whole.upperBound
        }
        out += text[last...]
        return out
    }

    // MARK: Constants

    private static let base = 100
    private static let artistExact = 25
    private static let artistShared = 10
    private static let creditsDisagree = -30
    private static let creditOverrideSec = 2
    private static let durationTight = 40
    private static let durationLoose = 15
    private static let albumExact = 35
    private static let explicitExact = 20
    private static let contextShared = 20
    private static let durationTightSec = 3
    static let durationLimitSec = 30
    private static let videoDurationLimitSec = 90
    private static let bracketPasses = 3
    private static let dashPasses = 3

    private static let bracketed = NSRegularExpression(#"[(\[]([^()\[\]]*)[)\]]"#)
    private static let dash = NSRegularExpression(#"\s+[-–—|]+\s+"#)
    private static let featuring = NSRegularExpression(#"\b(feat|ft|featuring|with)\b.*"#)
    private static let wordSplit = NSRegularExpression(#"[\s.·~〜]+"#)
    /** Java's `\p{Punct}` is ASCII punctuation only. */
    private static let cjkStrip = NSRegularExpression(#"[\s!-/:-@\[-`{-~・～〜ー-]+"#)
    private static let cjkOpen = NSRegularExpression("[「『【〈《〔［｛]")
    private static let cjkClose = NSRegularExpression("[」』】〉》〕］｝]")
    private static let artistSeparators = NSRegularExpression(#"\s*(?:[,&/;·|、，×]|\band\b|\bx\b|\bvs\.?\b|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b|\bwith\b)\s*"#)
    private static let latinQueryChars = Set("abcdefghijklmnopqrstuvwxyz0123456789 ")

    private static let kanaRomaji: [Character: String] = {
        var map: [Character: String] = [:]
        func row(_ consonant: String, _ kana: String, _ vowels: String = "aiueo") {
            for (k, v) in zip(kana, vowels) { map[k] = consonant + String(v) }
        }
        row("", "あいうえお")
        row("k", "かきくけこ"); row("g", "がぎぐげご")
        row("s", "さしすせそ"); map["し"] = "shi"
        row("z", "ざじずぜぞ"); map["じ"] = "ji"
        row("t", "たちつてと"); map["ち"] = "chi"; map["つ"] = "tsu"
        row("d", "だぢづでど"); map["ぢ"] = "ji"; map["づ"] = "zu"
        row("n", "なにぬねの")
        row("h", "はひふへほ"); map["ふ"] = "fu"
        row("b", "ばびぶべぼ"); row("p", "ぱぴぷぺぽ")
        row("m", "まみむめも")
        map["や"] = "ya"; map["ゆ"] = "yu"; map["よ"] = "yo"
        row("r", "らりるれろ")
        map["わ"] = "wa"; map["を"] = "wo"; map["ん"] = "n"
        map["ゔ"] = "vu"
        map["ぁ"] = "a"; map["ぃ"] = "i"; map["ぅ"] = "u"; map["ぇ"] = "e"; map["ぉ"] = "o"
        map["ゃ"] = "ya"; map["ゅ"] = "yu"; map["ょ"] = "yo"; map["ゎ"] = "wa"
        map["ゕ"] = "ka"; map["ゖ"] = "ke"
        return map
    }()
    private static let smallY: [Character: String] = ["ゃ": "ya", "ゅ": "yu", "ょ": "yo"]
    private static let smallV: [Character: String] = ["ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o"]
    private static let consOverrides = ["shi": "sh", "chi": "ch", "tsu": "ts", "fu": "f", "ji": "j", "zu": "z"]

    private static let versionWords: Set<String> = [
        "remix", "remixes", "rmx", "refix", "flip", "bootleg", "mashup", "medley",
        "live", "concert", "unplugged", "acoustic", "instrumental", "karaoke",
        "vocals", "vocal", "acapella", "acappella", "backing", "stems", "stem",
        "cover", "demo", "reprise", "remake", "rework", "extended", "edit",
        "version", "mix", "dub", "vip", "session", "sessions",
        "sped", "slowed", "reverb", "nightcore", "lofi", "orchestral", "symphonic",
        "part", "pt", "chapter",
        "カバー", "カラオケ", "リミックス", "ライブ", "アコースティック",
        "インスト", "バージョン", "歌ってみた", "踊ってみた", "弾いてみた",
        "翻唱", "现场", "混音",
        "커버", "라이브", "리믹스",
    ]
    private static let trailingTakes: Set<String> = ["instrumental", "karaoke", "acapella", "acappella", "remix", "rmx", "nightcore"]
    private static let novocalTakes: Set<String> = ["instrumental", "karaoke", "acapella", "acappella", "backing", "stems", "stem"]
    private static let neutralSegments: Set<String> = [
        "albumversion", "originalversion", "originalmix", "singleversion",
        "radioversion", "radioedit", "stereoversion", "monoversion",
        "studioversion", "fullversion", "standardversion", "explicitversion",
        "deluxeversion", "originaltrack",
    ]
    private static let noiseWords: Set<String> = [
        "official", "video", "audio", "lyrics", "lyric", "lyrical", "visualizer",
        "song", "songs", "full", "music", "the", "and", "from", "feat", "ft",
        "featuring", "with", "new", "latest", "free", "download", "remaster",
        "remastered", "explicit", "clean", "bonus", "track", "deluxe", "original",
        "album", "single", "hd", "hq", "4k", "mp3",
    ]
    private static let albumNoiseWords: Set<String> = [
        "album", "deluxe", "edition", "expanded", "remaster", "remastered",
        "version", "explicit", "clean", "bonus", "anniversary",
    ]
    private static let trailingNoise: Set<String> = [
        "song", "songs", "video", "audio", "lyrics", "lyric", "lyrical",
        "official", "full", "hd", "hq", "4k", "mp3", "ost", "soundtrack",
    ]
    private static let joiningWords: Set<String> = ["and"]
}
