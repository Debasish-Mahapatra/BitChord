import Observation
import SwiftUI

/** A page pushed over a tab: what the phone's detailStack and mood page hold. */
enum Page: Hashable, Identifiable {
    case browse(BrowseItem)
    case mood(MoodGenre)
    case history
    case moods
    /** A shelf's "Show all" grid; a Library shelf's gets the sort menu. */
    case showAll(title: String, items: [ShelfItem], library: Bool = false)
    case settings
    case account
    case sources

    var id: String {
        switch self {
        case .browse(let item): return "b:" + item.browseId
        case .mood(let mood): return "m:" + mood.id
        case .history: return "history"
        case .moods: return "moods"
        case .showAll(let title, _, _): return "all:" + title
        case .settings: return "settings"
        case .account: return "account"
        case .sources: return "sources"
        }
    }
}

/**
 * Where the app is: the tab, the pages pushed over it, the player sheet and
 * any open menu. Tapping a tab — even the current one — clears the stack, as
 * on the phone.
 */
@MainActor
@Observable
final class Router {
    static let shared = Router()

    enum Tab: Int, CaseIterable, Identifiable {
        case home, explore, library, search

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .home: return "Home"
            case .explore: return "Explore"
            case .library: return "Library"
            case .search: return "Search"
            }
        }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .explore: return "square.grid.2x2.fill"
            case .library: return "square.stack.fill"
            case .search: return "magnifyingglass"
            }
        }
    }

    var tab: Tab = .home
    private(set) var stacks: [Tab: [Page]] = [:]
    var showPlayer = false
    var songMenu: Song?
    /** Song Info opened from a held row's menu, shown as an alert card. */
    var songInfo: Song?
    /** The account's own playlist the open song menu's row sits in, for "Remove from this playlist". */
    var songMenuPlaylist: String?
    var browseMenu: BrowseItem?
    /** Whether the open browse menu is for a playlist the account made (Rename, Delete). */
    var browseMenuOwned = false
    /** The last row removed from a playlist, so its open page drops it too. */
    var removedFromPlaylist: (playlistId: String, setVideoId: String)?
    /** Asks for a new name for the account's own playlist. */
    var renamePlaylist: BrowseItem?
    /** The account's own playlist being rearranged on its page, by browse id. */
    var reorderPlaylist: String?
    /** The playlist whose Delete row has been tapped once and now asks to be tapped again. */
    var confirmingDelete: String?
    /** Bumped when a playlist is renamed or deleted, so the open page and Library reload. */
    private(set) var playlistsChanged = 0

    func playlistDidChange() { playlistsChanged += 1 }
    var playlistPicker: Song?
    /** "Switch account", over everything but the player. */
    var accountPopup = false
    /** The release page whose frosted sort menu is open, by browse id. */
    var sortMenu: String?
    var newPlaylist = false
    /** Bumped when the Search tab is tapped: clear the field and focus it. */
    private(set) var searchFocusToken = 0

    var stack: [Page] { stacks[tab] ?? [] }
    var top: Page? { stack.last }

    func select(_ newTab: Tab) {
        stacks[newTab] = []
        tab = newTab
        if newTab == .search { searchFocusToken += 1 }
    }

    func push(_ page: Page) {
        guard top != page else { return }
        withAnimation(.fastOutSlowIn(0.18)) { stacks[tab, default: []].append(page) }
    }

    func open(_ item: BrowseItem) {
        push(.browse(item))
    }

    func openAlbum(id: String, title: String? = nil) {
        open(BrowseItem(browseId: id, title: title ?? "", subtitle: "", thumbnailUrl: nil, type: .album))
    }

    func openArtist(id: String, name: String? = nil) {
        open(BrowseItem(browseId: id, title: name ?? "", subtitle: "", thumbnailUrl: nil, type: .artist))
    }

    func back() {
        guard !stack.isEmpty else { return }
        withAnimation(.fastOutSlowIn(0.18)) { _ = stacks[tab]?.popLast() }
    }

    /** Opening a page from the player closes the player first. */
    func openFromPlayer(_ action: () -> Void) {
        showPlayer = false
        action()
    }
}
