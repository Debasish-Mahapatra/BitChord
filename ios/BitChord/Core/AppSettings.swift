import Foundation
import Observation

/**
 * Ordering for the track list on an album or playlist page (SongSort). A
 * catalogue row carries no added date, so its place in the running order
 * stands in for one: a playlist is appended to as songs are added, so read
 * backwards it is newest first.
 */
enum SongSort: String, CaseIterable, Sendable {
    case `default` = "DEFAULT"
    case titleAsc = "TITLE_ASC"
    case titleDesc = "TITLE_DESC"
    case dateAddedAsc = "DATE_ADDED_ASC"
    case dateAddedDesc = "DATE_ADDED_DESC"

    var label: String {
        switch self {
        case .default: return "Default order"
        case .titleAsc: return "Alphabetical (A to Z)"
        case .titleDesc: return "Alphabetical (Z to A)"
        case .dateAddedAsc: return "Date added (oldest first)"
        case .dateAddedDesc: return "Date added (newest first)"
        }
    }

    var isDateAdded: Bool { self == .dateAddedAsc || self == .dateAddedDesc }

    /** The rows in this order, each with its place in the page's own order. */
    func sorted(_ songs: [Song]) -> [(offset: Int, element: Song)] {
        let indexed = Array(songs.enumerated()).map { (offset: $0.offset, element: $0.element) }
        switch self {
        case .default, .dateAddedAsc:
            return indexed
        case .dateAddedDesc:
            return indexed.reversed()
        case .titleAsc:
            return indexed.sorted { $0.element.title.localizedCaseInsensitiveCompare($1.element.title) == .orderedAscending }
        case .titleDesc:
            return indexed.sorted { $0.element.title.localizedCaseInsensitiveCompare($1.element.title) == .orderedDescending }
        }
    }
}

/** Ordering for a Library "Show all" grid: a card there only carries a title. */
enum LibrarySort: String, CaseIterable, Sendable {
    case `default` = "DEFAULT"
    case titleAsc = "TITLE_ASC"
    case titleDesc = "TITLE_DESC"

    var label: String {
        switch self {
        case .default: return "Default order"
        case .titleAsc: return "Alphabetical (A to Z)"
        case .titleDesc: return "Alphabetical (Z to A)"
        }
    }

    func sorted(_ items: [ShelfItem]) -> [ShelfItem] {
        switch self {
        case .default: return items
        case .titleAsc: return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDesc: return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        }
    }
}

/**
 * A quality ceiling, one per kind of connection (AudioQuality): Wi-Fi can stay
 * on Lossless while mobile data is capped. YouTube's own copy on this phone is
 * AAC; the higher rungs reach for the other sources first.
 */
enum AudioQuality: String, CaseIterable, Sendable {
    case low = "LOW", medium = "MEDIUM", high = "HIGH", lossless = "LOSSLESS"

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .lossless: return "Lossless"
        }
    }

    var detail: String {
        switch self {
        case .low: return "~48 kbps AAC · smallest download"
        case .medium: return "Best available · ~128 kbps AAC"
        case .high: return "JioSaavn up to 320kbps, YouTube fallback"
        case .lossless: return "Your addons + JioSaavn, bit-exact where available"
        }
    }
}

/** App settings kept on this phone (AppSettings.kt), read by the views as they change. */
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    static let maxPinnedPlaylists = 5

    private let defaults = UserDefaults.standard

    /** Per page, keyed by browse id: one choice, kept until the user makes another. */
    private(set) var detailSongSorts: [String: SongSort]
    private(set) var librarySort: LibrarySort
    /** Playlist browse ids, in the order they were pinned. */
    private(set) var pinnedPlaylists: [String]

    // MARK: Settings rows (defaults as AppSettings.kt)

    var loudnessNormalization: Bool { didSet { defaults.set(loudnessNormalization, forKey: "loudness.on") } }
    var loudnessOffOnSpeaker: Bool { didSet { defaults.set(loudnessOffOnSpeaker, forKey: "loudness.offOnSpeaker") } }
    var reduceDynamicBlur: Bool { didSet { defaults.set(reduceDynamicBlur, forKey: "ui.reduceBlur") } }
    var syncedLyrics: Bool { didSet { defaults.set(syncedLyrics, forKey: "lyrics.synced") } }
    var lyricsBlur: Bool { didSet { defaults.set(lyricsBlur, forKey: "lyrics.blur") } }
    var playNextOnSwipe: Bool { didSet { defaults.set(playNextOnSwipe, forKey: "swipe.playNext") } }
    var dontRepeatSongs: Bool { didSet { defaults.set(dontRepeatSongs, forKey: "autoplay.noRepeats") } }
    var hideVolumeBar: Bool { didSet { defaults.set(hideVolumeBar, forKey: "player.hideVolume") } }
    var hideStatusBarInPlayer: Bool { didSet { defaults.set(hideStatusBarInPlayer, forKey: "player.hideStatusBar") } }
    var showQueueHistory: Bool { didSet { defaults.set(showQueueHistory, forKey: "queue.history") } }
    var hideSongStatus: Bool { didSet { defaults.set(hideSongStatus, forKey: "player.hideStatus") } }
    var showNerdStats: Bool { didSet { defaults.set(showNerdStats, forKey: "player.nerdStats") } }
    var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: "onboarding.complete") } }
    /** What the listener asked to be called on the first-run welcome. */
    var nickname: String { didSet { defaults.set(nickname, forKey: "profile.nickname") } }
    var audioQualityWifi: AudioQuality { didSet { defaults.set(audioQualityWifi.rawValue, forKey: "quality.wifi") } }
    var audioQualityCellular: AudioQuality { didSet { defaults.set(audioQualityCellular.rawValue, forKey: "quality.cellular") } }

    /** The ceiling for the connection the phone is on now. */
    var audioQuality: AudioQuality { NetworkWatch.shared.metered == true ? audioQualityCellular : audioQualityWifi }

    private init() {
        defaults.register(defaults: ["loudness.on": true, "loudness.offOnSpeaker": true, "lyrics.synced": true, "lyrics.blur": true])
        loudnessNormalization = defaults.bool(forKey: "loudness.on")
        loudnessOffOnSpeaker = defaults.bool(forKey: "loudness.offOnSpeaker")
        reduceDynamicBlur = defaults.bool(forKey: "ui.reduceBlur")
        syncedLyrics = defaults.bool(forKey: "lyrics.synced")
        lyricsBlur = defaults.bool(forKey: "lyrics.blur")
        playNextOnSwipe = defaults.bool(forKey: "swipe.playNext")
        dontRepeatSongs = defaults.bool(forKey: "autoplay.noRepeats")
        hideVolumeBar = defaults.bool(forKey: "player.hideVolume")
        hideStatusBarInPlayer = defaults.bool(forKey: "player.hideStatusBar")
        showQueueHistory = defaults.bool(forKey: "queue.history")
        hideSongStatus = defaults.bool(forKey: "player.hideStatus")
        showNerdStats = defaults.bool(forKey: "player.nerdStats")
        onboardingComplete = defaults.bool(forKey: "onboarding.complete")
        nickname = defaults.string(forKey: "profile.nickname") ?? ""
        audioQualityWifi = AudioQuality(rawValue: defaults.string(forKey: "quality.wifi") ?? "") ?? .lossless
        audioQualityCellular = AudioQuality(rawValue: defaults.string(forKey: "quality.cellular") ?? "") ?? .lossless
        let stored = defaults.dictionary(forKey: "detail.songSorts") as? [String: String] ?? [:]
        detailSongSorts = stored.compactMapValues(SongSort.init(rawValue:))
        librarySort = LibrarySort(rawValue: defaults.string(forKey: "library.sort") ?? "") ?? .default
        pinnedPlaylists = defaults.stringArray(forKey: "library.pinned") ?? []
    }

    func songSort(for browseId: String) -> SongSort { detailSongSorts[browseId] ?? .default }

    func setSongSort(_ sort: SongSort, for browseId: String) {
        detailSongSorts[browseId] = sort
        defaults.set(detailSongSorts.mapValues(\.rawValue), forKey: "detail.songSorts")
    }

    func setLibrarySort(_ sort: LibrarySort) {
        librarySort = sort
        defaults.set(sort.rawValue, forKey: "library.sort")
    }

    /** Pinning past the cap is refused rather than evicting one. Returns whether it's pinned now. */
    @discardableResult
    func togglePinned(_ browseId: String) -> Bool {
        if let index = pinnedPlaylists.firstIndex(of: browseId) {
            pinnedPlaylists.remove(at: index)
        } else if pinnedPlaylists.count >= Self.maxPinnedPlaylists {
            return false
        } else {
            pinnedPlaylists.append(browseId)
        }
        defaults.set(pinnedPlaylists, forKey: "library.pinned")
        return pinnedPlaylists.contains(browseId)
    }

    /** The shelf's pinned cards first, in pinning order, then the rest as they were. */
    func pinnedFirst(_ items: [ShelfItem]) -> [ShelfItem] {
        guard !pinnedPlaylists.isEmpty else { return items }
        let byId = Dictionary(items.compactMap { item in item.browseId.map { ($0, item) } }, uniquingKeysWith: { a, _ in a })
        let pinned = pinnedPlaylists.compactMap { byId[$0] }
        guard !pinned.isEmpty else { return items }
        let ids = Set(pinned.compactMap(\.browseId))
        return pinned + items.filter { !ids.contains($0.browseId ?? "") }
    }
}
