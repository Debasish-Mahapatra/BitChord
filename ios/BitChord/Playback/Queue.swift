import Foundation

/**
 * The three-tier queue's rules as plain list edits — a port of the shared
 * QueueTimeline.kt / QueueSections.kt (via the web player's timeline.ts, which
 * ports them one to one), so this orders a queue exactly as the phone does.
 *
 * - context: the album, playlist or one-off song the user started.
 * - user: tracks queued by hand ("Play Next", "Add to Queue").
 * - autoplay: the radio that plays on once the rest runs out.
 */
enum QueueTier: String, Codable, Sendable {
    case context, user, autoplay
}

/** Where a queue (or a track in it) was started from. */
struct QueueSource: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case album, playlist, artist, library, search, home, radio, queue, other }
    var title: String
    var kind: Kind
    var id: String?
}

struct QueueEntry: Identifiable, Codable, Hashable, Sendable {
    /** Assigned when the track enters the queue and never changed. */
    let id: UUID
    var song: Song
    var tier: QueueTier
    var source: QueueSource?

    init(_ song: Song, tier: QueueTier, source: QueueSource?, id: UUID = UUID()) {
        self.id = id
        self.song = song
        self.tier = tier
        self.source = source
    }
}

enum QueueTimeline {
    /** Past this point in a track, Back restarts it instead of going to the previous one. */
    static let backRestartsAfter: TimeInterval = 10

    static func upcomingUserQueue(_ timeline: [QueueEntry], _ current: Int) -> [QueueEntry] {
        guard timeline.indices.contains(current) else { return [] }
        return timeline[(current + 1)...].filter { $0.tier == .user }
    }

    /**
     * Starting an album, playlist or artist: [preceding context] + [selected] +
     * [the user's upcoming queue, kept] + [following context].
     */
    static func contextQueue(_ timeline: [QueueEntry], current: Int, songs: [Song], selected: Int,
                             source: QueueSource) -> (timeline: [QueueEntry], start: Int) {
        guard !songs.isEmpty else { return ([], 0) }
        let kept = upcomingUserQueue(timeline, current)
        let entries = songs.map { QueueEntry($0, tier: .context, source: source) }
        let at = min(max(selected, 0), entries.count - 1)
        return (Array(entries[..<at]) + [entries[at]] + kept + Array(entries[(at + 1)...]), at)
    }

    /** A one-off song (Search, Home, Explore): [the song] + [the user's upcoming queue, kept]. */
    static func oneOffQueue(_ timeline: [QueueEntry], current: Int, song: Song, source: QueueSource) -> [QueueEntry] {
        [QueueEntry(song, tier: .context, source: source)] + upcomingUserQueue(timeline, current)
    }

    /** "Play Next" at the head of the user queue, "Add to Queue" at its tail, ahead of context and AutoPlay. */
    static func userInsertionIndex(_ timeline: [QueueEntry], current: Int, next: Bool) -> Int {
        guard !timeline.isEmpty else { return 0 }
        let start = min(max(current + 1, 0), timeline.count)
        if next { return start }
        return timeline[start...].firstIndex { $0.tier != .user } ?? timeline.count
    }

    /**
     * Tapping a row in Up Next (QueueTimeline.computeJumpOrder):
     * 1. Back, or the same track: a pure seek.
     * 2. A context track: a pure seek, unless hand-queued tracks were skipped
     *    over; then those are pinned right after the target instead of lost.
     * 3. A hand-queued track: the hand-queued tracks bypassed are dropped.
     * 4. An AutoPlay track: it becomes the context (a station pivot); the old
     *    context and the bypassed AutoPlay go.
     */
    static func jump(_ timeline: [QueueEntry], current: Int, target: Int) -> (timeline: [QueueEntry], index: Int)? {
        let n = timeline.count
        guard timeline.indices.contains(current), timeline.indices.contains(target) else { return nil }
        if target <= current { return (timeline, target) }
        let tiers = timeline.map(\.tier)
        func whereFrom(_ from: Int, _ tier: QueueTier) -> [Int] { (from..<n).filter { tiers[$0] == tier } }
        func between(_ tier: QueueTier) -> [Int] { ((current + 1)..<target).filter { tiers[$0] == tier } }
        let history = Array(0...current)
        var order: [Int]
        var newIndex: Int
        var promote = false
        switch tiers[target] {
        case .context:
            let crossedUser = between(.user)
            if crossedUser.isEmpty { return (timeline, target) }
            let bypassedContext = between(.context)
            let after = target + 1
            order = history + bypassedContext + [target] + crossedUser
                + whereFrom(after, .user) + whereFrom(after, .context) + whereFrom(after, .autoplay)
            newIndex = history.count + bypassedContext.count
        case .user:
            order = history + [target] + whereFrom(target + 1, .user)
                + whereFrom(current + 1, .context) + whereFrom(current + 1, .autoplay)
            newIndex = history.count
        case .autoplay:
            order = history + [target] + whereFrom(current + 1, .user) + whereFrom(target + 1, .autoplay)
            newIndex = history.count
            promote = true
        }
        let edited = order.map { index -> QueueEntry in
            var entry = timeline[index]
            if index == target, promote {
                entry.tier = .context
                entry.source = QueueSource(title: entry.source?.title ?? entry.song.title, kind: entry.source?.kind ?? .queue, id: entry.source?.id)
            }
            return entry
        }
        return (edited, newIndex)
    }

    /** Played hand-queued rows, pruned once playback is back in the context so repeat-all cycles only the context. */
    static func playedUserQueueIndices(_ timeline: [QueueEntry], current: Int) -> [Int] {
        guard current > 0, timeline.indices.contains(current), timeline[current].tier == .context else { return [] }
        return (0..<current).filter { timeline[$0].tier == .user }
    }

    /** Where the AutoPlay section begins: the first AutoPlay track still to come. */
    static func autoplaySectionStart(_ timeline: [QueueEntry], current: Int) -> Int {
        let after = min(max(current + 1, 0), timeline.count)
        return timeline[after...].firstIndex { $0.tier == .autoplay } ?? timeline.count
    }

    // MARK: Shuffle

    /** Never an unchanged order when two or more can move: an identity shuffle reads as the tap being ignored. */
    static func avoidIdentity(_ original: [Int], _ shuffled: [Int]) -> [Int] {
        guard original.count > 1, shuffled == original else { return shuffled }
        return Array(shuffled.dropFirst()) + [shuffled[0]]
    }

    /** A queue started with shuffle on: the picked track leads, the user queue keeps its order, the rest shuffle per section. */
    static func shuffledStartingOrder(_ entries: [QueueEntry], start: Int) -> [QueueEntry] {
        guard !entries.isEmpty else { return [] }
        let at = min(max(start, 0), entries.count - 1)
        let rest = entries.enumerated().filter { $0.offset != at }.map(\.element)
        return [entries[at]] + rest.filter { $0.tier == .user }
            + rest.filter { $0.tier == .context }.shuffled() + rest.filter { $0.tier == .autoplay }.shuffled()
    }

    /** Shuffle applied to what's still to come, as a permutation of [upcoming]: the user queue never moves. */
    static func shuffledUpcomingOrder(_ upcoming: [QueueTier]) -> [Int] {
        func of(_ tier: QueueTier) -> [Int] { upcoming.indices.filter { upcoming[$0] == tier } }
        let context = of(.context)
        let autoplay = of(.autoplay)
        return of(.user) + avoidIdentity(context, context.shuffled()) + avoidIdentity(autoplay, autoplay.shuffled())
    }
}

/**
 * The station that plays on after the queue runs out — QueueBuilder.kt.
 * Watch queues carry the same recording twice (the official audio and the
 * music video), so tracks match on a normalised title plus a shared artist;
 * per-artist caps keep a station from becoming one artist's discography.
 */
enum StationBuilder {
    static let perArtistLimit = 2
    static let seedArtistLimit = 4
    static let batchLimit = 10

    private static let noise = NSRegularExpression(
        #"\((?:official|lyric|lyrics|lyrical|audio|video|visuali[sz]er|full song|hd|4k)[^)]*\)|\(from[^)]*\)|\[[^\]]*\]|\b(?:official (?:video|audio|music video)|lyrical video|full video|4k video)\b"#,
        caseInsensitive: true)
    private static let topic = NSRegularExpression(#"\s*-\s*topic\b"#, caseInsensitive: true)
    private static let punctuation = NSRegularExpression(#"[^\p{L}\p{N}]+"#)
    private static let spaces = NSRegularExpression(#"\s+"#)
    private static let separators = NSRegularExpression(#",|&|·|•|;| feat| ft\.| ft | x | with "#)

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func normalisedTitle(_ raw: String) -> String {
        var title = raw.lowercased().components(separatedBy: " | ").first ?? ""
        title = replace(noise, in: title, with: " ")
        title = replace(punctuation, in: title, with: " ")
        return replace(spaces, in: title, with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func artistSet(_ raw: String) -> Set<String> {
        let cleaned = replace(topic, in: raw.lowercased(), with: " ")
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        var parts: [String] = []
        var last = cleaned.startIndex
        for match in separators.matches(in: cleaned, range: range) {
            let r = Range(match.range, in: cleaned)!
            parts.append(String(cleaned[last..<r.lowerBound]))
            last = r.upperBound
        }
        parts.append(String(cleaned[last...]))
        return Set(parts.map { replace(spaces, in: replace(punctuation, in: $0, with: " "), with: " ").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    private static func artistLine(_ song: Song) -> String {
        song.artists.isEmpty ? song.artist : song.artists.map(\.name).joined(separator: ", ")
    }

    static func isSameRecording(_ a: Song, _ b: Song) -> Bool {
        if a.videoId == b.videoId { return true }
        let title = normalisedTitle(a.title)
        guard !title.isEmpty, title == normalisedTitle(b.title) else { return false }
        let left = artistSet(artistLine(a)), right = artistSet(artistLine(b))
        return left.isEmpty || right.isEmpty || !left.isDisjoint(with: right)
    }

    /** The candidates worth appending after [existing]: nothing already queued, nothing repeated, at most [limit]. */
    static func extend(_ existing: [Song], candidates: [Song], limit: Int = batchLimit) -> [Song] {
        var taken = existing
        var perArtist: [String: Int] = [:]
        let seedArtists = existing.last.map { artistSet(artistLine($0)) } ?? []
        var out: [Song] = []
        // Catalogue cuts over music videos; videos stand in only when there's nothing else.
        let songs = candidates.filter { !$0.isVideo }
        for candidate in songs.isEmpty ? candidates : songs {
            if out.count >= limit { break }
            if taken.contains(where: { isSameRecording($0, candidate) }) { continue }
            let artists = artistSet(artistLine(candidate)).sorted()
            if let key = artists.first {
                let cap = artists.contains(where: seedArtists.contains) ? seedArtistLimit : perArtistLimit
                let played = perArtist[key, default: 0]
                if played >= cap { continue }
                perArtist[key] = played + 1
            }
            taken.append(candidate)
            out.append(candidate)
        }
        return out
    }
}
