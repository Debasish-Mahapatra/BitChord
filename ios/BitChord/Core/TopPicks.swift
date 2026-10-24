import Foundation
import Observation
import SwiftUI

/** What a Top Pick card is (TopPickKind). */
enum TopPickKind: String, Codable, Sendable {
    case latestRelease, personalStation, mood, artistAndSimilar, featuredArtist, newReleaseMix, discoveryStation
}

/**
 * A mood: the Moods & genres category it draws playlists from, and the shelf
 * words that pick the right shelf inside it (TopPickMood). The first seven are
 * the core moods Find Your Mood shows.
 */
enum TopPickMood: String, CaseIterable, Codable, Sendable, Identifiable {
    case energy, relax, feelingBlue, feelGood, focus, heartbreak, love
    case afterHours, aloneTime, chill, commuting, eatingCooking, evening, fitness, gaming, home, morning, motivation
    case outdoors, party, sleep, social, sports, summertime, holiday, weekend, wellbeing, work

    var id: String { rawValue }

    static let categoryBrowseId = "FEmusic_moods_and_genres_category"

    private static let chillCategory = "ggMPOg1uX1JOQWZFeDByc2Jm", commute = "ggMPOg1uX044Z2o5WERLckpU", energize = "ggMPOg1uX2lRZUZiMnNrQnJW"
    private static let feelGoodCategory = "ggMPOg1uXzZQbDB5eThLRTQ3", focusCategory = "ggMPOg1uX0NvNGNhWThMYWRh"
    private static let gamingCategory = "ggMPOg1uX3NmUVV4Vzl3WGQ0", partyCategory = "ggMPOg1uX0pmQ0s2V0JRclZs"
    private static let romance = "ggMPOg1uX0FzQ2FhZWtUY211", sad = "ggMPOg1uX0JLQ0gySWZKZVY1"
    private static let sleepCategory = "ggMPOg1uX1MxaFQ3Z0JMZkN4", workout = "ggMPOg1uX09LWkhnTjRGRUJh"

    var params: String {
        switch self {
        case .energy, .motivation, .sports: return Self.energize
        case .relax, .afterHours, .aloneTime, .chill, .eatingCooking, .evening, .home, .wellbeing: return Self.chillCategory
        case .feelingBlue, .heartbreak: return Self.sad
        case .feelGood, .morning, .summertime, .holiday: return Self.feelGoodCategory
        case .focus, .work: return Self.focusCategory
        case .love: return Self.romance
        case .commuting: return Self.commute
        case .fitness, .outdoors: return Self.workout
        case .gaming: return Self.gamingCategory
        case .party, .social, .weekend: return Self.partyCategory
        case .sleep: return Self.sleepCategory
        }
    }

    var shelfWords: [String] {
        switch self {
        case .relax: return ["unwind", "peaceful", "relaxing", "laidback"]
        case .feelingBlue: return ["sad", "melanchol", "lonely"]
        case .heartbreak: return ["heartbreak", "breakup", "break-up", "broken", "heartache"]
        case .afterHours: return ["deep grooves", "electronic", "jazz", "r&b"]
        case .aloneTime: return ["mellow", "acoustic", "laidback"]
        case .chill: return ["chill", "chilled"]
        case .eatingCooking: return ["coffee", "soul", "jazz", "r&b"]
        case .evening: return ["unwind", "acoustic", "laidback", "jazz"]
        case .fitness: return ["gym", "cardio", "essentials"]
        case .home: return ["coffee shop", "chill pop", "laidback"]
        case .morning: return ["happy", "confident", "pop"]
        case .motivation: return ["motivation", "power", "beast"]
        case .outdoors: return ["outdoor", "running"]
        case .social: return ["party today", "chill party", "throwback"]
        case .sports: return ["beast", "power", "hip-hop"]
        case .summertime: return ["dance", "kicking back", "feel-good pop"]
        case .holiday: return ["throwback", "happy"]
        case .weekend: return ["party today", "dance"]
        case .wellbeing: return ["mindfulness", "meditation", "yoga"]
        case .work: return ["flow", "instrumental", "reading"]
        default: return []
        }
    }

    var isCoreMood: Bool { (TopPickMood.allCases.firstIndex(of: self) ?? 99) <= 6 }

    var title: String {
        switch self {
        case .energy: return "Energy"
        case .relax: return "Relax"
        case .feelingBlue: return "Feeling Blue"
        case .feelGood: return "Feel Good"
        case .focus: return "Focus"
        case .heartbreak: return "Heartbreak"
        case .love: return "Love"
        case .afterHours: return "After Hours"
        case .aloneTime: return "Alone Time"
        case .chill: return "Chill"
        case .commuting: return "Commuting"
        case .eatingCooking: return "Eating & Cooking"
        case .evening: return "Evening"
        case .fitness: return "Fitness"
        case .gaming: return "Gaming"
        case .home: return "Home"
        case .morning: return "Morning"
        case .motivation: return "Motivation"
        case .outdoors: return "Outdoors"
        case .party: return "Party"
        case .sleep: return "Sleep"
        case .social: return "Social"
        case .sports: return "Sports"
        case .summertime: return "Summertime Sounds"
        case .holiday: return "Holiday"
        case .weekend: return "Weekend"
        case .wellbeing: return "Wellbeing"
        case .work: return "Work"
        }
    }

    var line: String {
        switch self {
        case .energy: return "High-voltage tracks to keep you moving."
        case .relax: return "Easy, soothing sounds to slow things down."
        case .feelingBlue: return "Sad songs for when you need them."
        case .feelGood: return "Bright, upbeat songs to lift the day."
        case .focus: return "Steady music to keep you in the zone."
        case .heartbreak: return "Breakup anthems, one tear at a time."
        case .love: return "Romantic songs for the moment."
        case .afterHours: return "Late-night grooves for when the city goes quiet."
        case .aloneTime: return "Mellow songs for time to yourself."
        case .chill: return "Laid-back sounds to take it easy."
        case .commuting: return "The right soundtrack for the road."
        case .eatingCooking: return "Warm, easy music for the kitchen and the table."
        case .evening: return "Gentle songs to wind the day down."
        case .fitness: return "Hard-hitting tracks to push you further."
        case .gaming: return "Soundtracks to level up to."
        case .home: return "Easy listening for a slow day in."
        case .morning: return "Bright songs to start the day right."
        case .motivation: return "Anthems to get you up and going."
        case .outdoors: return "Music for fresh air and open roads."
        case .party: return "Crowd-pleasers to keep the night going."
        case .sleep: return "Soft, calming sounds to drift off to."
        case .social: return "Songs everyone in the room will know."
        case .sports: return "Game-day energy, start to finish."
        case .summertime: return "Sunny songs for long, warm days."
        case .holiday: return "Festive favourites for the season."
        case .weekend: return "Feel-good music for your days off."
        case .wellbeing: return "Calm music for mindfulness and yoga."
        case .work: return "Steady instrumentals to get things done."
        }
    }

    /** The card's colours: background, emblem stroke and eyebrow (MoodStyle). */
    var style: (background: Color, stroke: Color, eyebrow: Color) {
        func s(_ bg: UInt32, _ stroke: UInt32, _ eyebrow: UInt32? = nil) -> (Color, Color, Color) {
            let strokeColor = UIColor(hex: stroke)
            return (Color(hex: bg), Color(hex: stroke), eyebrow.map { Color(hex: $0) } ?? Color(strokeColor.mixed(with: .white, 0.35)))
        }
        switch self {
        case .energy: return s(0x1EBD38, 0xE2F6A2, 0xE8FF9C)
        case .relax: return s(0x31AFF3, 0xB4E9FF, 0xD6F3FF)
        case .feelingBlue: return s(0x253AB2, 0x6CC4FF, 0xA9DBFF)
        case .feelGood: return s(0xF2A900, 0xFFE8A0, 0xFFF27A)
        case .focus: return s(0xF28400, 0xFFD6A4, 0xFFE2B8)
        case .heartbreak: return s(0xEA3520, 0xFFA690, 0xFFC9BC)
        case .love: return s(0xF34CA0, 0xFFB8DC, 0xFFD0EA)
        case .afterHours: return s(0x3A1F78, 0xC9B6FF)
        case .aloneTime: return s(0x2C6E8C, 0xA9E2F5)
        case .chill: return s(0x138A86, 0xA6F0E6)
        case .commuting: return s(0x17855F, 0xA8EFD0)
        case .eatingCooking: return s(0xD9621A, 0xFFD3A8)
        case .evening: return s(0x2A3A8C, 0xB8C6FF)
        case .fitness: return s(0x8DB014, 0xEFFFA8)
        case .gaming: return s(0x239A2A, 0xB8FFB0)
        case .home: return s(0x0E8A6C, 0xA8F2DB)
        case .morning: return s(0xF08C1A, 0xFFE2A6)
        case .motivation: return s(0xC01E4A, 0xFFB3C6)
        case .outdoors: return s(0x4C8A1E, 0xD4F5A8)
        case .party: return s(0xC2287A, 0xFFC0E0)
        case .sleep: return s(0x26266E, 0xC2C6FF)
        case .social: return s(0xE0507A, 0xFFD0DE)
        case .sports: return s(0x1C6CD0, 0xB8D8FF)
        case .summertime: return s(0xFF8C00, 0xFFE6A8)
        case .holiday: return s(0xC62828, 0xFFC8C8)
        case .weekend: return s(0x7A3CC2, 0xE2CCFF)
        case .wellbeing: return s(0x36A98A, 0xC6F7E6)
        case .work: return s(0x3E63C9, 0xC4D2FF)
        }
    }

    /** The mood the hour suits, most of the time; any core mood the rest (moodFor). */
    static func forHour(_ hour: Int) -> TopPickMood {
        let suited: [TopPickMood]
        switch hour {
        case 5...8: suited = [.energy, .feelGood, .focus]
        case 9...11: suited = [.focus, .feelGood, .energy]
        case 12...16: suited = [.feelGood, .focus, .energy, .relax]
        case 17...19: suited = [.energy, .feelGood, .relax]
        case 20...22: suited = [.love, .relax, .heartbreak, .feelGood]
        default: suited = [.relax, .feelingBlue, .heartbreak, .love]
        }
        return Double.random(in: 0..<1) < 0.7 ? suited.randomElement()! : allCases.filter(\.isCoreMood).randomElement()!
    }
}



struct TopPick: Codable, Hashable, Sendable, Identifiable {
    var kind: TopPickKind
    var title: String = ""
    var subtitle: String = ""
    var artistName: String?
    var artistBrowseId: String?
    var images: [String] = []
    var browseId: String?
    var watch: WatchTarget?
    var mood: TopPickMood?
    var exclude: [String] = []
    var hints: [String] = []

    var id: String { "\(kind.rawValue):\(title):\(mood?.rawValue ?? "")" }

    /** The card's three lines (cardText). */
    func text(listenerName: String?) -> (eyebrow: String, title: String, subtitle: String) {
        let artist = artistName ?? ""
        switch kind {
        case .latestRelease: return ("New from \(artist)", title, subtitle)
        case .personalStation:
            let first = listenerName?.split(separator: " ").first.map(String.init)
            return ("Made for You", first.map { "\($0)’s Station" } ?? "Your Station", "")
        case .mood:
            let mood = self.mood ?? .feelGood
            return ("Mood for You", mood.title, mood.line)
        case .artistAndSimilar: return ("Featuring \(artist)", "\(artist) & Similar Artists", "")
        case .featuredArtist: return ("Featuring \(artist)", title, subtitle)
        case .newReleaseMix: return ("Made for You", title, subtitle)
        case .discoveryStation: return ("Made for You", "Discovery Station", "")
        }
    }

    static func moodStation(_ mood: TopPickMood, hints: [String] = TopPicks.regionHints()) -> TopPick {
        TopPick(kind: .mood, mood: mood, hints: hints)
    }
}

/**
 * Builds the Top Picks row (data/TopPicks.kt): a latest release from the
 * artists the account plays most, then — shuffled — a personal station, a
 * mood for the hour, "& Similar Artists", a featured artist, the New Release
 * mix, another "& Similar", and a discovery station.
 */
enum TopPicks {
    struct LocalTaste {
        var artists: [ArtistRef] = []
        var songs: [Song] = []
        var genres: [String] = []
    }

    static let artistCount = 3
    static let artistPool = 10

    static func build(homeShelves: [HomeShelf], local: LocalTaste, now: Date = Date()) async -> [TopPick] {
        async let historyRequest = recentHistory()
        async let mixesRequest = findMixes(homeShelves)
        let history = await historyRequest
        let ranked = weightedSample(Array(rankArtists(history, local.artists).prefix(artistPool)), count: artistCount)
        var artists: [ArtistCard] = []
        await withTaskGroup(of: (Int, ArtistCard?).self) { group in
            for (index, ref) in ranked.enumerated() {
                group.addTask {
                    guard let id = ref.browseId, let page = try? await Innertube.shared.browse(id) else { return (index, nil) }
                    var parsed = InnertubeParser.parseArtistPage(page)
                    if parsed.name == nil { parsed.name = ref.name }
                    return (index, ArtistCard(page: parsed, browseId: id))
                }
            }
            var found: [(Int, ArtistCard)] = []
            for await (index, card) in group { if let card { found.append((index, card)) } }
            var seen = Set<String>()
            artists = found.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert(AppleCatalogue.matchKey($0.name)).inserted }
        }
        let photos = await applePhotos(artists)
        let mixes = await mixesRequest
        let lead = latestRelease(artists)
        var rest: [TopPick] = []
        if let station = personalStation(mixes, history, local) { rest.append(station) }
        rest.append(TopPick(kind: .mood, mood: .forHour(Calendar.current.component(.hour, from: now)),
                            hints: Array(Set(local.genres.map { $0.lowercased() } + regionHints()))))
        if let first = artists.first, let pick = andSimilar(first, photos) { rest.append(pick) }
        if artists.count > 1, let pick = featured(artists[1], photos) { rest.append(pick) }
        if let mix = mixes[.newRelease] {
            rest.append(TopPick(kind: .newReleaseMix, title: mix.title, subtitle: mix.subtitle,
                                images: [mix.thumbnailUrl].compactMap { $0 }, watch: watchTarget(mix)))
        }
        if artists.count > 2, let pick = andSimilar(artists[2], photos) { rest.append(pick) }
        if let discovery = discoveryStation(mixes, artists, history) { rest.append(discovery) }
        return [lead].compactMap { $0 } + rest.shuffled()
    }

    /** The songs a pick plays. */
    static func queue(_ pick: TopPick) async -> [Song] {
        if pick.kind == .mood { return await moodQueue(pick) }
        guard let target = pick.watch else { return [] }
        if pick.kind == .personalStation || pick.kind == .discoveryStation { return await freshStation(pick, target) }
        return (try? await Innertube.shared.watchQueue(target)) ?? []
    }

    // MARK: Inputs

    static func recentHistory() async -> [Song] {
        guard await MainActor.run(body: { Account.shared.isSignedIn }),
              let response = try? await Innertube.shared.browse("FEmusic_history") else { return [] }
        return InnertubeParser.collectSongsDeep(response)
    }

    private enum Mix { case supermix, discover, newRelease }

    private static func findMixes(_ homeShelves: [HomeShelf]) async -> [Mix: ShelfItem] {
        func isMix(_ item: ShelfItem) -> Bool { item.browseId.map { bare($0).hasPrefix("RDTMAK") } ?? false }
        var mixes = homeShelves.flatMap(\.items).filter(isMix)
        let signedIn = await MainActor.run { Account.shared.isSignedIn }
        if mixes.isEmpty, signedIn, let page = try? await Innertube.shared.browse("FEmusic_mixed_for_you") {
            mixes = InnertubeParser.parseTwoRowItemsDeep(page).filter(isMix)
        }
        guard !mixes.isEmpty else { return [:] }
        var found: [Mix: ShelfItem] = [:]
        for item in mixes {
            let title = item.title.lowercased()
            let kind: Mix? = title.contains("supermix") ? .supermix : title.contains("discover") ? .discover
                : title.contains("new release") ? .newRelease : nil
            if let kind, found[kind] == nil { found[kind] = item }
        }
        if found.isEmpty { found[.supermix] = mixes[0] }
        return found
    }

    private static func bare(_ id: String) -> String { id.hasPrefix("VL") ? String(id.dropFirst(2)) : id }
    private static func watchTarget(_ item: ShelfItem) -> WatchTarget? { item.browseId.map { WatchTarget(playlistId: bare($0)) } }

    /** History weighted by recency, plus this phone's own top artists. */
    private static func rankArtists(_ history: [Song], _ local: [ArtistRef]) -> [ArtistRef] {
        var scores: [String: (name: String, score: Double)] = [:]
        var order: [String] = []
        func credit(_ id: String?, _ name: String, _ weight: Double) {
            guard let id, id.hasPrefix("UC"), !name.isEmpty, name.caseInsensitiveCompare("Various Artists") != .orderedSame else { return }
            if scores[id] == nil { order.append(id) }
            scores[id] = (name, (scores[id]?.score ?? 0) + weight)
        }
        for (index, song) in history.enumerated() {
            let recency = 1.0 - Double(index) / Double(max(1, history.count))
            if let lead = song.artists.first(where: { $0.browseId != nil }) {
                credit(lead.browseId, lead.name, 1.0 + recency * 0.5)
            } else {
                credit(song.artistId, song.artist, 1.0 + recency * 0.5)
            }
        }
        for (index, artist) in local.enumerated() { credit(artist.browseId, artist.name, Double(local.count - index) * 0.5) }
        return order.sorted { scores[$0]!.score > scores[$1]!.score }.map { ArtistRef(name: scores[$0]!.name, browseId: $0) }
    }

    private static func weightedSample<T>(_ ranked: [T], count: Int) -> [T] {
        var pool = Array(ranked.enumerated())
        var picked: [T] = []
        while picked.count < count, !pool.isEmpty {
            let weights = pool.map { Double(ranked.count - $0.offset) }
            var roll = Double.random(in: 0..<1) * weights.reduce(0, +)
            let index = weights.firstIndex { roll -= $0; return roll <= 0 } ?? 0
            picked.append(pool.remove(at: index).element)
        }
        return picked
    }

    // MARK: Picks

    private struct ArtistCard: Sendable {
        let page: ArtistPage
        let browseId: String
        var name: String { page.name ?? "" }

        /** The artists the page lists as related, at most four, not this one. */
        var related: [(name: String, browseId: String)] {
            let own = AppleCatalogue.matchKey(name)
            guard let shelf = page.shelves.first(where: { !$0.items.isEmpty && $0.items.allSatisfy { $0.browseId?.hasPrefix("UC") == true } }) else { return [] }
            var seen = Set<String>()
            return shelf.items.compactMap { item -> (String, String)? in
                guard let id = item.browseId, id != browseId else { return nil }
                let key = AppleCatalogue.matchKey(item.title)
                guard !key.isEmpty, key != own, seen.insert(key).inserted else { return nil }
                return (item.title, id)
            }.prefix(4).map { $0 }
        }
    }

    private static let year = NSRegularExpression(#"\b(19|20)\d{2}\b"#)
    private static let single = NSRegularExpression(#"\b(Single|EP)\b"#)

    private static func yearOf(_ subtitle: String) -> Int {
        let matches = year.matches(in: subtitle, range: NSRange(subtitle.startIndex..., in: subtitle))
        return matches.last.flatMap { Int((subtitle as NSString).substring(with: $0.range)) } ?? 0
    }

    /** The newest album or single across the picked artists. */
    private static func latestRelease(_ artists: [ArtistCard]) -> TopPick? {
        var best: (year: Int, single: Bool, rank: Int, artist: ArtistCard, item: ShelfItem)?
        for (rank, artist) in artists.enumerated() {
            for shelf in artist.page.shelves {
                guard let item = shelf.items.first, item.browseId?.hasPrefix("MPRE") == true else { continue }
                let candidate = (yearOf(item.subtitle), item.subtitle.matches(single), rank, artist, item)
                if let current = best {
                    let better = candidate.0 > current.year || (candidate.0 == current.year && (candidate.1 && !current.single
                        || (candidate.1 == current.single && candidate.2 < current.rank)))
                    if better { best = candidate }
                } else {
                    best = candidate
                }
            }
        }
        guard let best else { return nil }
        return TopPick(kind: .latestRelease, title: best.item.title, subtitle: best.item.subtitle, artistName: best.artist.name,
                       images: [best.item.thumbnailUrl].compactMap { $0 }, browseId: best.item.browseId)
    }

    private static func personalStation(_ mixes: [Mix: ShelfItem], _ history: [Song], _ local: LocalTaste) -> TopPick? {
        let watch = mixes[.supermix].flatMap(watchTarget)
            ?? (local.songs.first ?? history.first).map { WatchTarget(playlistId: "RDAMVM\($0.videoId)", videoId: $0.videoId) }
        return watch.map { TopPick(kind: .personalStation, watch: $0) }
    }

    private static func andSimilar(_ artist: ArtistCard, _ photos: [String: String]) -> TopPick? {
        guard let radio = artist.page.radio, let face = photos[artist.name] else { return nil }
        var related: [String] = []
        for (name, _) in artist.related {
            if let photo = photos[name], photo != face, !related.contains(photo) { related.append(photo) }
            if related.count == 2 { break }
        }
        return TopPick(kind: .artistAndSimilar, title: artist.name, artistName: artist.name, artistBrowseId: artist.browseId,
                       images: [face] + related, watch: radio)
    }

    private static func featured(_ artist: ArtistCard, _ photos: [String: String]) -> TopPick? {
        guard let shuffle = artist.page.shuffle ?? artist.page.radio, let face = photos[artist.name] else { return nil }
        return TopPick(kind: .featuredArtist, title: artist.name,
                       subtitle: artist.page.monthlyListenerCount ?? artist.page.subscriberCountText ?? "",
                       artistName: artist.name, artistBrowseId: artist.browseId, images: [face], watch: shuffle)
    }

    private static func discoveryStation(_ mixes: [Mix: ShelfItem], _ artists: [ArtistCard], _ history: [Song]) -> TopPick? {
        if let watch = mixes[.discover].flatMap(watchTarget) { return TopPick(kind: .discoveryStation, watch: watch) }
        guard let seed = artists.first, let radio = seed.page.radio else { return nil }
        return TopPick(kind: .discoveryStation, artistName: seed.name, watch: radio, exclude: history.prefix(200).map(\.videoId))
    }

    // MARK: Queues

    /** A station built fresh: up to 30 of the mix, topped up to 60 from radios off three recent plays. */
    private static func freshStation(_ pick: TopPick, _ target: WatchTarget) async -> [Song] {
        async let mixRequest = try? Innertube.shared.watchQueue(target)
        let history = await recentHistory()
        let seeds = Array(history.prefix(40).shuffled().prefix(3))
        var around: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for seed in seeds {
                group.addTask { (try? await Innertube.shared.watchQueue(WatchTarget(playlistId: "RDAMVM\(seed.videoId)", videoId: seed.videoId))) ?? [] }
            }
            for await songs in group { around += songs }
        }
        let mix = await mixRequest ?? []
        let discovery = pick.kind == .discoveryStation
        let heard = discovery ? Set(history.map(\.videoId) + pick.exclude) : []
        let seedArtist = discovery ? pick.artistName?.lowercased() : nil
        func keep(_ song: Song) -> Bool {
            !heard.contains(song.videoId) && (seedArtist == nil || !song.artist.lowercased().contains(seedArtist!))
        }
        let core = Array(mix.filter(keep).shuffled().prefix(30))
        let coreIds = Set(core.map(\.videoId))
        var seen = Set<String>()
        let extra = around.filter { keep($0) && !coreIds.contains($0.videoId) && seen.insert($0.videoId).inserted }
            .shuffled().prefix(60 - core.count)
        let station = (core + extra).shuffled()
        if station.count >= 12 { return station }
        return mix.shuffled()
    }

    /** A mood: the best-matching shelf of its category, up to three of its playlists, 60 songs. */
    private static func moodQueue(_ pick: TopPick) async -> [Song] {
        guard let mood = pick.mood,
              let page = try? await Innertube.shared.browse(TopPickMood.categoryBrowseId, params: mood.params) else { return [] }
        let shelves = InnertubeParser.parseHome(page)
        func playlists(_ shelf: HomeShelf) -> [ShelfItem] { shelf.items.filter { $0.browseId?.hasPrefix("VL") == true } }
        let candidates = shelves.filter { !playlists($0).isEmpty }
        func score(_ shelf: HomeShelf) -> Int {
            let title = shelf.title.lowercased()
            return 2 * mood.shelfWords.filter { title.contains($0) }.count + pick.hints.filter { !$0.isEmpty && title.contains($0) }.count
        }
        guard let best = candidates.map(score).max(),
              let shelf = candidates.filter({ score($0) == best }).randomElement() else { return [] }
        let chosen = Array(playlists(shelf).prefix(6).shuffled().prefix(3))
        var songs: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for item in chosen {
                group.addTask {
                    let id = bare(item.browseId!)
                    if let response = try? await Innertube.shared.nextPlaylist(id) {
                        let audio = InnertubeParser.parseWatchQueue(response, preferAudio: true)
                        if !audio.isEmpty { return audio }
                    }
                    guard let page = try? await Innertube.shared.browse(item.browseId!) else { return [] }
                    return InnertubeParser.parseCollection(page, browseId: item.browseId!).songs
                }
            }
            for await batch in group { songs += batch }
        }
        var seen = Set<String>()
        return Array(songs.filter { seen.insert($0.videoId).inserted }.shuffled().prefix(60))
    }

    static func regionHints() -> [String] {
        switch Locale.current.region?.identifier ?? "" {
        case "IN": return ["bollywood", "indian", "hindi", "punjabi", "desi"]
        case "PK": return ["pakistani", "urdu", "punjabi"]
        case "KR": return ["k-pop", "korean"]
        case "JP": return ["j-pop", "japanese"]
        case "BR": return ["brazil", "sertanejo", "funk"]
        case "MX", "ES", "AR", "CO", "CL", "PE": return ["latin", "latino", "reggaeton"]
        default: return []
        }
    }

    // MARK: Apple artist photos

    /** Photos for the picked artists and their related ones, four lookups at a time. */
    private static func applePhotos(_ artists: [ArtistCard]) async -> [String: String] {
        var catalogues: [(name: String, titles: () async -> [String])] = []
        var names = Set<String>()
        for artist in artists where names.insert(artist.name).inserted {
            let page = artist.page
            catalogues.append((artist.name, { AppleCatalogue.titles(of: page) }))
        }
        for artist in artists {
            for (name, channel) in artist.related where names.insert(name).inserted {
                catalogues.append((name, {
                    guard let page = try? await Innertube.shared.browse(channel) else { return [] }
                    return AppleCatalogue.titles(of: InnertubeParser.parseArtistPage(page))
                }))
            }
        }
        var photos: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            var iterator = catalogues.makeIterator()
            func addNext() {
                guard let next = iterator.next() else { return }
                group.addTask { (next.name, await AppleArtistPhotos.shared.photo(for: next.name, catalogue: next.titles)) }
            }
            for _ in 0..<4 { addNext() }
            for await (name, photo) in group {
                if let photo { photos[name] = photo }
                addNext()
            }
        }
        return photos
    }
}

/** Matching a YouTube artist to Apple's catalogue by shared song and release titles (AppleCatalogue). */
enum AppleCatalogue {
    static func matchKey(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "$", with: "s")
            .folding(options: .diacriticInsensitive, locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func titleKey(_ title: String) -> String? {
        var core = title.components(separatedBy: " (").first ?? title
        core = core.components(separatedBy: " [").first ?? core
        for suffix in [" - Single", " - EP"] where core.hasSuffix(suffix) { core.removeLast(suffix.count) }
        let key = matchKey(core)
        return key.count >= 4 ? key : nil
    }

    static func titles(of page: ArtistPage) -> [String] {
        page.songs.map(\.title) + page.shelves.flatMap(\.items).filter { $0.browseId?.hasPrefix("MPRE") == true }.map(\.title)
    }

    static func sharesTitles(artistId: Int, keys: Set<String>) async -> Bool {
        guard !keys.isEmpty, let url = URL(string: "https://itunes.apple.com/lookup?id=\(artistId)&entity=song&limit=200"),
              let (data, _) = try? await HTTP.session.data(from: url), let json = try? JSON(data: data) else { return false }
        return json["results"].array.contains { row in
            ["trackName", "collectionName"].contains { row[$0].string.flatMap(titleKey).map(keys.contains) ?? false }
        }
    }
}

/**
 * An artist's photo off their Apple Music page (AppleArtistPhotos): an iTunes
 * search by name, kept only when Apple's artist shares song or release titles
 * with the YouTube one, then the page's og:image if it's an artist image.
 * Answers — misses included — are remembered.
 */
actor AppleArtistPhotos {
    static let shared = AppleArtistPhotos()
    private var known: [String: String] = UserDefaults.standard.dictionary(forKey: "apple.artistPhotos") as? [String: String] ?? [:]

    func photo(for artistName: String, catalogue: () async -> [String]) async -> String? {
        let name = AppleCatalogue.matchKey(artistName)
        guard !name.isEmpty else { return nil }
        if let hit = known[name] { return hit.isEmpty ? nil : hit }
        let keys = Set(await catalogue().compactMap(AppleCatalogue.titleKey))
        guard !keys.isEmpty else { return nil }
        guard let found = await lookup(artistName, key: name, titles: keys) else { return nil }
        known[name] = found
        UserDefaults.standard.set(known, forKey: "apple.artistPhotos")
        return found.isEmpty ? nil : found
    }

    /** nil: a network miss, not remembered. "": Apple has no matching artist photo. */
    private func lookup(_ artistName: String, key: String, titles: Set<String>) async -> String? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: artistName), URLQueryItem(name: "entity", value: "musicArtist"),
                                 URLQueryItem(name: "limit", value: "5")]
        guard let (data, _) = try? await HTTP.session.data(from: components.url!), let json = try? JSON(data: data) else { return nil }
        var tried = 0
        for result in json["results"].array {
            guard AppleCatalogue.matchKey(result["artistName"].string ?? "") == key,
                  let link = result["artistLinkUrl"].string, link.hasPrefix("https://music.apple.com/"),
                  let id = result["artistId"].double.map({ Int($0) }),
                  await AppleCatalogue.sharesTitles(artistId: id, keys: titles) else { continue }
            tried += 1
            if let photo = await ogImage(String(link.split(separator: "?").first ?? Substring(link))) { return photo }
            if tried == 2 { break }
        }
        return ""
    }

    private func ogImage(_ page: String) async -> String? {
        guard let url = URL(string: page) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(HTTP.webUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await HTTP.session.data(for: request) else { return nil }
        let head = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
        guard let range = head.range(of: #"property="og:image"\s+content="([^"]+)""#, options: .regularExpression) else { return nil }
        let match = String(head[range])
        guard let start = match.range(of: "content=\"")?.upperBound else { return nil }
        let image = String(match[start...].dropLast())
        let bucket = image.components(separatedBy: "mzstatic.com/image/thumb/").dropFirst().first?.split(separator: "/").first ?? ""
        return bucket.hasPrefix("Features") || bucket.hasPrefix("AMCArtistImages") ? image : nil
    }
}

/**
 * The Top Picks row's state: built once an hour (the picks keep to their
 * hour, so a pull refreshes the feed and not them), remembered across launches.
 */
@MainActor
@Observable
final class TopPicksStore {
    static let shared = TopPicksStore()

    private(set) var picks: [TopPick]?
    private(set) var loading = false
    private var builtFor: String?

    private struct Stored: Codable {
        var listener: String?
        var slot: String
        var picks: [TopPick]
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("top-picks.json")
    }

    private static func slot(_ now: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: now)
        return String(format: "%04d-%02d-%02dT%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
    }

    func load(homeShelves: [HomeShelf]) async {
        let listener = Account.shared.session.map { $0.pageId ?? $0.dataSyncId ?? String($0.cookie.prefix(24)) }
        let key = "\(listener ?? "guest")|\(Self.slot())"
        guard builtFor != key, !loading else { return }
        if let data = try? Data(contentsOf: Self.url), let stored = try? JSONDecoder().decode(Stored.self, from: data),
           stored.listener == listener, stored.slot == Self.slot() {
            picks = stored.picks
            builtFor = key
            return
        }
        loading = true
        let built = await TopPicks.build(homeShelves: homeShelves, local: History.shared.localTaste)
        loading = false
        builtFor = key
        picks = built
        let stored = Stored(listener: listener, slot: Self.slot(), picks: built)
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: Self.url, options: .atomic) }
    }
}

extension History {
    /** This phone's own taste: its most-played artists and songs (the Replay chart's stand-in). */
    var localTaste: TopPicks.LocalTaste {
        var counts: [String: (ref: ArtistRef, count: Int)] = [:]
        for song in songs {
            let ref = song.artists.first(where: { $0.browseId != nil }) ?? ArtistRef(name: song.artist, browseId: song.artistId)
            guard let id = ref.browseId else { continue }
            counts[id] = (ref, (counts[id]?.count ?? 0) + 1)
        }
        let artists = counts.values.sorted { $0.count > $1.count }.prefix(10).map(\.ref)
        return TopPicks.LocalTaste(artists: Array(artists), songs: Array(songs.prefix(5)))
    }
}
