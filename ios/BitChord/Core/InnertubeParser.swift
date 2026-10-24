import Foundation

/**
 * Port of shared/…/innertube/InnertubeParser.kt: the same renderers, read the
 * same way. InnerTube responses are deeply nested and drift between layouts,
 * so structured paths are used where the layout is stable (search, home) and a
 * recursive scan where it is not (playlists, albums).
 */
enum InnertubeParser {

    // MARK: Search

    struct SearchPage: Sendable {
        var rows: [SearchResult]
        var continuation: String?
    }

    /**
     * Search rows are heterogeneous: songs carry a videoId, albums, artists and
     * playlists a browseId and a page type, and both arrive as
     * `musicResponsiveListItemRenderer`. The "All" tab's promoted top result is
     * a `musicCardShelfRenderer`, read first.
     */
    static func parseSearchPage(_ response: JSON, includeVideos: Bool = false) -> SearchPage {
        let cards = includeVideos ? [] : response.collect("musicCardShelfRenderer")
        let topResults: [SearchResult] = cards.compactMap { card in
            if let song = parseCardShelfSong(card) { return .topTrack(song) }
            if let item = parseCardShelfBrowse(card) { return .browse(item) }
            return nil
        }
        // Rows inside an artist's promoted card are billed by the card; see cardShelfCredit.
        var cardCredits: [String: Credits] = [:]
        for card in cards {
            guard let credit = cardShelfCredit(card) else { continue }
            for row in card.collect("musicResponsiveListItemRenderer") {
                if let key = rowKey(row) { cardCredits[key] = credit }
            }
        }

        var seen = Set<String>()
        var parsed: [SearchResult] = []
        for result in topResults {
            switch result {
            case .topTrack(let song):
                // The mixed All page stays music-only.
                if !song.isVideo, seen.insert("v:" + song.videoId).inserted { parsed.append(result) }
            case .browse(let item):
                if seen.insert("b:" + item.browseId).inserted { parsed.append(result) }
            case .track:
                break
            }
        }
        for renderer in response.collect("musicResponsiveListItemRenderer") {
            // Browse rows first: an album row also carries a "play album" videoId in its overlay.
            if let browse = parseBrowseItem(renderer) {
                if seen.insert("b:" + browse.browseId).inserted { parsed.append(.browse(browse)) }
            } else if let song = parseResponsiveListItem(renderer, fallback: rowKey(renderer).flatMap { cardCredits[$0] } ?? Credits()) {
                if song.isVideo == includeVideos, seen.insert("v:" + song.videoId).inserted {
                    parsed.append(.track(song))
                }
            }
        }
        return SearchPage(rows: parsed, continuation: continuationToken(response))
    }

    /** What identifies a row across two walks of the same response. */
    private static func rowKey(_ row: JSON) -> String? {
        playableVideoId(row) ?? row["navigationEndpoint"]["browseEndpoint"]["browseId"].string
    }

    /**
     * The typeahead queries of `music/get_search_suggestions`. `searchEndpoint.query`
     * over the display runs, which are split only so the typed prefix can be bold.
     */
    static func parseSearchSuggestions(_ response: JSON) -> [String] {
        var seen = Set<String>()
        return response.collect("searchSuggestionRenderer").compactMap { renderer in
            let query = renderer["navigationEndpoint"]["searchEndpoint"]["query"].string ?? renderer["suggestion"].runs
            guard let query = query.nonBlank, seen.insert(query).inserted else { return nil }
            return query
        }
    }

    private static func parseBrowseItem(_ renderer: JSON) -> BrowseItem? {
        let endpoint = renderer["navigationEndpoint"]["browseEndpoint"]
        guard let browseId = endpoint["browseId"].string else { return nil }
        let pageType = endpoint["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string ?? ""
        let columns = renderer["flexColumns"]
        let title = columns[0]["musicResponsiveListItemFlexColumnRenderer"]["text"].runs
        guard title.nonBlank != nil else { return nil }
        let subtitle = columns[1]["musicResponsiveListItemFlexColumnRenderer"]["text"].runs
        // A video chart or compilation would be a dead-end page once its video rows are dropped.
        if title.matches(videoWord) || subtitle.matches(videoWord) { return nil }
        return BrowseItem(
            browseId: browseId,
            title: title,
            subtitle: subtitle,
            thumbnailUrl: renderer["thumbnail"]["musicThumbnailRenderer"]["thumbnail"]["thumbnails"].bestThumbnail,
            type: BrowseType(pageType: pageType, browseId: browseId)
        )
    }

    // MARK: Home

    static func sections(_ response: JSON) -> [JSON] {
        response["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].first["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array
    }

    static func parseHome(_ response: JSON) -> [HomeShelf] {
        sections(response).compactMap { section in
            if section["musicCarouselShelfRenderer"].exists { return carouselShelf(section["musicCarouselShelfRenderer"]) }
            if section["musicShelfRenderer"].exists { return plainShelf(section["musicShelfRenderer"]) }
            return nil
        }
    }

    /** More Home shelves off a continuation, wherever the envelope puts them. */
    static func parseHomeContinuation(_ root: JSON) -> [HomeShelf] {
        var out: [HomeShelf] = []
        func walk(_ node: JSON) {
            if let object = node.object {
                if object["musicCarouselShelfRenderer"] != nil, let shelf = carouselShelf(node["musicCarouselShelfRenderer"]) { out.append(shelf) }
                if object["musicShelfRenderer"] != nil, let shelf = plainShelf(node["musicShelfRenderer"]) { out.append(shelf) }
                for key in object.keys.sorted() { walk(node[key]) }
            } else {
                node.array.forEach(walk)
            }
        }
        walk(root)
        return out
    }

    /** The home feed's own continuation, at the section list's level. */
    static func homeContinuation(_ response: JSON) -> String? {
        let list = response["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].first["tabRenderer"]["content"]["sectionListRenderer"]
        let envelope = list.exists ? list : response["continuationContents"]["sectionListContinuation"]
        return envelope["continuations"].first["nextContinuationData"]["continuation"].string
            ?? continuationToken(JSON(envelope["contents"].array.last?.raw))
    }

    /** Moods & genres: grids of navigation buttons, whose params pick the mood's playlists. */
    static func parseMoodAndGenres(_ response: JSON) -> [MoodGenreSection] {
        let parsed: [MoodGenreSection] = sections(response).compactMap { section in
            let grid = section["gridRenderer"]
            guard grid.exists else { return nil }
            let title = grid["header"]["gridHeaderRenderer"]["title"].runs
            let items: [MoodGenre] = grid["items"].array.compactMap { item in
                let button = item["musicNavigationButtonRenderer"]
                guard button.exists else { return nil }
                var endpoint = button["clickCommand"]["browseEndpoint"]
                if !endpoint.exists { endpoint = button["navigationEndpoint"]["browseEndpoint"] }
                guard let browseId = endpoint["browseId"].string, let label = button["buttonText"].runs.nonBlank else { return nil }
                return MoodGenre(title: label, browseId: browseId, params: endpoint["params"].string,
                                 stripeColor: button["solid"]["leftStripeColor"].double.map { UInt32(truncatingIfNeeded: Int64($0)) })
            }
            return title.nonBlank == nil || items.isEmpty ? nil : MoodGenreSection(title: title, items: items)
        }
        // A signed-in page's "For you" grid only repeats buttons the later grids hold.
        return parsed.enumerated().filter { index, section in
            let later = Set(parsed.dropFirst(index + 1).flatMap { $0.items.map(\.id) })
            return !section.items.contains { later.contains($0.id) } && section.title.lowercased() != "for you"
        }.map(\.element)
    }

    private static func carouselShelf(_ carousel: JSON) -> HomeShelf? {
        let header = carousel["header"]["musicCarouselShelfBasicHeaderRenderer"]
        let title = header["title"].runs
        let strapline = header["strapline"].runs
        let contents = carousel["contents"].array
        let parsed: [ShelfItem] = contents.compactMap { item in
            if let card = parseTwoRowItem(item["musicTwoRowItemRenderer"]) { return card }
            if let song = parseResponsiveListItem(item["musicResponsiveListItemRenderer"]) {
                return ShelfItem(title: song.title, subtitle: song.artist, thumbnailUrl: song.thumbnailUrl,
                                 videoId: song.videoId, browseId: nil, song: song, isVideo: song.isVideo)
            }
            // "Top artists" chart rows name an artist with no track attached.
            return parseArtistRow(item["musicResponsiveListItemRenderer"])
        }
        // A shelf billed as videos keeps the videos it can play and loses the compilations.
        let items = title.matches(videoWord) ? parsed.filter { $0.videoId != nil } : parsed
        guard !items.isEmpty else { return nil }
        let shelfTitle = title.nonBlank ?? "For you"
        let fromList = contents.first?["musicResponsiveListItemRenderer"].exists == true
        let more = moreEndpoint(header)
        return HomeShelf(title: shelfTitle, items: items, strapline: strapline,
                         moreBrowseId: more["browseId"].string, moreParams: more["params"].string,
                         layout: .of(title: shelfTitle, items: items, fromList: fromList))
    }

    private static func plainShelf(_ shelf: JSON) -> HomeShelf? {
        let title = shelf["title"].runs
        let items = shelf["contents"].array
            .compactMap { parseResponsiveListItem($0["musicResponsiveListItemRenderer"]) }
            .map { ShelfItem(title: $0.title, subtitle: $0.artist, thumbnailUrl: $0.thumbnailUrl, videoId: $0.videoId, browseId: nil, song: $0, isVideo: $0.isVideo) }
        guard !items.isEmpty else { return nil }
        let shelfTitle = title.nonBlank ?? "For you"
        return HomeShelf(title: shelfTitle, items: items, layout: .of(title: shelfTitle, items: items, fromList: true))
    }

    /** Where a carousel's "More" leads, off whichever of its header shapes came back. */
    private static func moreEndpoint(_ header: JSON) -> JSON {
        if let endpoint = header["title"]["runs"].array.first(where: { $0["navigationEndpoint"]["browseEndpoint"].exists }) {
            return endpoint["navigationEndpoint"]["browseEndpoint"]
        }
        let candidates = [
            header["moreContentButton"]["buttonRenderer"]["navigationEndpoint"]["browseEndpoint"],
            header["moreContentButton"]["musicMoreContentButtonRenderer"]["navigationEndpoint"]["browseEndpoint"],
        ] + header["endIcons"].array.flatMap {
            [$0["musicNavigationButtonRenderer"]["clickCommand"]["browseEndpoint"],
             $0["musicNavigationButtonRenderer"]["navigationEndpoint"]["browseEndpoint"]]
        } + [header["navigationEndpoint"]["browseEndpoint"]]
        return candidates.first(where: \.exists) ?? .null
    }

    // MARK: Artist

    /**
     * Artist landing page: a "Top songs" shelf (a few rows, its header linking
     * to the full playlist) plus carousels for Albums, Singles & EPs and friends.
     */
    static func parseArtistPage(_ response: JSON) -> ArtistPage {
        let header = response["header"]
        let credit = Credits(artistName: artistName(header))
        var songs: [Song] = []
        var moreSongs: String?
        var shelves: [HomeShelf] = []
        for section in sections(response) {
            let shelf = section["musicShelfRenderer"]
            if shelf.exists {
                songs += shelf["contents"].array.compactMap { parseResponsiveListItem($0["musicResponsiveListItemRenderer"], fallback: credit) }
                if moreSongs == nil {
                    moreSongs = shelf["title"]["runs"].first["navigationEndpoint"]["browseEndpoint"]["browseId"].string
                }
            }
            let carousel = section["musicCarouselShelfRenderer"]
            if carousel.exists {
                let carouselHeader = carousel["header"]["musicCarouselShelfBasicHeaderRenderer"]
                let title = carouselHeader["title"].runs
                let items = carousel["contents"].array.compactMap { parseTwoRowItem($0["musicTwoRowItemRenderer"]) }
                    .filter { $0.browseId != nil || $0.isVideo }
                let more = moreEndpoint(carouselHeader)
                if title.nonBlank != nil, !items.isEmpty {
                    shelves.append(HomeShelf(title: title, items: items, moreBrowseId: more["browseId"].string, moreParams: more["params"].string,
                                             layout: .of(title: title, items: items, fromList: false)))
                }
            }
        }
        return ArtistPage(
            name: credit.artistName,
            thumbnailUrl: artistThumbnail(header),
            songs: songs,
            moreSongsBrowseId: moreSongs,
            shelves: shelves,
            description: parseDescription(response),
            subscriberCountText: subscriberCount(header),
            monthlyListenerCount: header["musicImmersiveHeaderRenderer"]["monthlyListenerCount"].firstRunText,
            subscription: parseSubscription(header).map { ArtistPage.Subscription(channelId: $0.channelId, subscribed: $0.subscribed) },
            radio: headerWatchTarget(header, "startRadioButton"),
            shuffle: headerWatchTarget(header, "playButton")
        )
    }

    /** The artist header's Radio or Shuffle button, as a watch queue. */
    private static func headerWatchTarget(_ header: JSON, _ button: String) -> WatchTarget? {
        let endpoint = header["musicImmersiveHeaderRenderer"][button]["buttonRenderer"]["navigationEndpoint"]["watchEndpoint"]
        guard let playlistId = endpoint["playlistId"].string else { return nil }
        return WatchTarget(playlistId: playlistId, videoId: endpoint["videoId"].string, params: endpoint["params"].string?.removingPercentEncoding)
    }

    private static func subscriberCount(_ header: JSON) -> String? {
        let immersive = header["musicImmersiveHeaderRenderer"]
        guard immersive.exists else { return nil }
        let button2 = immersive["subscriptionButton2"]["subscribeButtonRenderer"]
        let button1 = immersive["subscriptionButton"]["subscribeButtonRenderer"]
        return button2["subscriberCountWithSubscribeText"].firstRunText
            ?? button1["longSubscriberCountText"].firstRunText
            ?? button1["shortSubscriberCountText"].firstRunText
    }

    private static func artistName(_ header: JSON) -> String? {
        let renderer = header["musicImmersiveHeaderRenderer"].exists ? header["musicImmersiveHeaderRenderer"] : header["musicVisualHeaderRenderer"]
        return renderer["title"].runs.nonBlank
    }

    private static func artistThumbnail(_ header: JSON) -> String? {
        guard header.exists else { return nil }
        let immersive = header["musicImmersiveHeaderRenderer"]
        let visual = header["musicVisualHeaderRenderer"]
        var renderer = [immersive["thumbnail"], visual["foregroundThumbnail"], visual["thumbnail"]]
            .first(where: \.exists)?["musicThumbnailRenderer"] ?? .null
        if !renderer.exists { renderer = header.collect("musicThumbnailRenderer").first ?? .null }
        return renderer["thumbnail"]["thumbnails"].bestThumbnail
    }

    // MARK: Albums and playlists

    /** Every `musicResponsiveListItemRenderer` with a videoId, wherever it sits. */
    static func collectSongsDeep(_ root: JSON) -> [Song] {
        let credit = pageCredit(root)
        var order: [String] = []
        var songs: [String: Song] = [:]
        for renderer in root.collect("musicResponsiveListItemRenderer") {
            guard let song = parseResponsiveListItem(renderer, fallback: credit) else { continue }
            if songs[song.videoId] == nil { order.append(song.videoId) }
            songs[song.videoId] = song
        }
        return order.compactMap { songs[$0] }
    }

    /**
     * A playlist page's own track list and the token for the rest — scoped to
     * the playlist shelf, so a "Suggestions" shelf below isn't read as tracks
     * the playlist holds. Nil off a page with nothing playlist-shaped.
     */
    static func parsePlaylistShelf(_ root: JSON) -> (songs: [Song], continuation: String?)? {
        var scope = root["continuationContents"]
        if !scope.exists { scope = root["contents"]["twoColumnBrowseResultsRenderer"]["secondaryContents"] }
        guard scope.exists else { return nil }
        let playlistScope = scope["musicPlaylistShelfContinuation"].exists
            ? scope["musicPlaylistShelfContinuation"]
            : scope.collect("musicPlaylistShelfRenderer").first
        guard let playlistScope else { return nil }
        let credit = pageCredit(root)
        var seen = Set<String>()
        let songs = playlistScope.collect("musicResponsiveListItemRenderer")
            .compactMap { parseResponsiveListItem($0, fallback: credit) }
            .filter { seen.insert($0.videoId).inserted }
        return (songs, continuationToken(playlistScope))
    }

    static func parseCollection(_ root: JSON, browseId: String) -> CollectionPage {
        let header = parseBrowseHeader(root)
        let playlist = parsePlaylistShelf(root)
        let songs = playlist?.songs ?? collectSongsDeep(root)
        var shelves: [HomeShelf] = []
        for carousel in root["contents"]["twoColumnBrowseResultsRenderer"]["secondaryContents"].collect("musicCarouselShelfRenderer") {
            if let shelf = carouselShelf(carousel) { shelves.append(shelf) }
        }
        let playlistId = parseAlbumPlaylistId(root) ?? (browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : nil)
        let headerArtist = headerRenderer(root).flatMap { header in
            creditsOf(headerCreditLines.flatMap { header[$0]["runs"].array }).artistId
        }
        return CollectionPage(
            title: header?.title ?? "",
            subtitle: header?.subtitle ?? "",
            thumbnailUrl: header?.thumbnailUrl,
            description: parseDescription(root),
            songs: songs,
            playlistId: playlistId,
            continuation: playlist?.continuation,
            shelves: shelves,
            artistId: headerArtist
        )
    }

    /**
     * The cards on a library feed — saved playlists, albums, artists. The page
     * remembers grid or list view, serving two-row cards for one and list rows
     * for the other, so both are read.
     */
    static func parseLibraryItems(_ root: JSON) -> (items: [ShelfItem], continuation: String?) {
        var order: [String] = []
        var items: [String: ShelfItem] = [:]
        for renderer in root.collect("musicTwoRowItemRenderer") {
            guard let item = parseTwoRowItem(renderer), let id = item.browseId, items[id] == nil else { continue }
            order.append(id)
            items[id] = item
        }
        for renderer in root.collect("musicResponsiveListItemRenderer") {
            guard let item = parseBrowseItem(renderer), items[item.browseId] == nil else { continue }
            order.append(item.browseId)
            items[item.browseId] = ShelfItem(title: item.title, subtitle: item.subtitle, thumbnailUrl: item.thumbnailUrl, videoId: nil, browseId: item.browseId)
        }
        return (order.compactMap { items[$0] }, continuationToken(root))
    }

    /** The next page's token: `continuationItemRenderer` (either command shape), else `nextContinuationData`. */
    static func continuationToken(_ root: JSON) -> String? {
        let endpoint = root.collect("continuationItemRenderer").first?["continuationEndpoint"] ?? .null
        if let token = endpoint["continuationCommand"]["token"].string { return token }
        if let token = endpoint["commandExecutorCommand"]["commands"].array
            .first(where: { $0["continuationCommand"].exists })?["continuationCommand"]["token"].string {
            return token
        }
        return root.collect("nextContinuationData").first?["continuation"].string
    }

    // MARK: Renderers

    private static func playableVideoId(_ renderer: JSON) -> String? {
        renderer["playlistItemData"]["videoId"].string
            ?? renderer["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]["watchEndpoint"]["videoId"].string
    }

    /** One track row; [fallback] is what the page it came from is billed to. */
    static func parseResponsiveListItem(_ renderer: JSON, fallback: Credits = Credits()) -> Song? {
        guard renderer.exists, let videoId = playableVideoId(renderer) else { return nil }
        let columns = renderer["flexColumns"]
        let title = columns[0]["musicResponsiveListItemFlexColumnRenderer"]["text"].runs
        guard title.nonBlank != nil else { return nil }

        let subtitleRuns = columns[1]["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"].array
        let subtitle = subtitleRuns.map { $0["text"].string ?? "" }.joined()
        let parts = subtitle.components(separatedBy: " • ").filter { $0.nonBlank != nil }
        // A search row states its runtime in the subtitle; an album row in a fixed column.
        let duration = parts.last.flatMap { $0.wholeMatch(durationPattern) ? $0 : nil }
            ?? renderer["fixedColumns"].array.lazy.compactMap { column -> String? in
                let text = column["musicResponsiveListItemFixedColumnRenderer"]["text"].runs
                return text.wholeMatch(durationPattern) ? text : nil
            }.first
        let rowType = parts.first { typeWords.contains($0.lowercased()) }?.lowercased()
        let artist = parts.first { !$0.wholeMatch(durationPattern) && !typeWords.contains($0.lowercased()) && !$0.wholeMatch(tally) }

        let credits = creditsOf(columns.array.flatMap { $0["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"].array })
        let creditedArtists = artistNamesFromRuns(subtitleRuns)
        let thumbnails = renderer["thumbnail"]["musicThumbnailRenderer"]["thumbnail"]["thumbnails"]

        return Song(
            videoId: videoId,
            title: title,
            artist: creditedArtists ?? credits.artistName?.nonBlank ?? artist ?? fallback.artistName ?? "Unknown artist",
            thumbnailUrl: thumbnails.bestThumbnail,
            durationText: duration,
            artistId: credits.artistId ?? fallback.artistId,
            artists: credits.artists.isEmpty ? fallback.artists : credits.artists,
            albumId: credits.albumId ?? fallback.albumId,
            albumName: credits.albumName ?? fallback.albumName,
            setVideoId: renderer["playlistItemData"]["playlistSetVideoId"].string,
            isVideo: rowType == "video" || thumbnails.isNotSquare,
            isExplicit: hasExplicitBadge(renderer.raw)
        )
    }

    /** The promoted result at the top of an unfiltered search, when it's a track. */
    private static func parseCardShelfSong(_ renderer: JSON) -> Song? {
        guard let videoId = renderer["onTap"]["watchEndpoint"]["videoId"].string else { return nil }
        let title = renderer["title"].runs
        guard title.nonBlank != nil else { return nil }
        let subtitleRuns = renderer["subtitle"]["runs"].array
        let subtitle = subtitleRuns.map { $0["text"].string ?? "" }.joined()
        let parts = subtitle.components(separatedBy: " • ").filter { $0.nonBlank != nil }
        let duration = parts.last.flatMap { $0.wholeMatch(durationPattern) ? $0 : nil }
        let rowType = parts.first { typeWords.contains($0.lowercased()) }?.lowercased()
        let credits = creditsOf(subtitleRuns)
        let artist = parts.first { !$0.wholeMatch(durationPattern) && !typeWords.contains($0.lowercased()) && !$0.wholeMatch(tally) }
        let thumbnails = renderer["thumbnail"]["musicThumbnailRenderer"]["thumbnail"]["thumbnails"]
        return Song(
            videoId: videoId,
            title: title,
            artist: artistNamesFromRuns(subtitleRuns) ?? credits.artistName?.nonBlank ?? artist ?? "Unknown artist",
            thumbnailUrl: thumbnails.bestThumbnail,
            durationText: duration,
            artistId: credits.artistId,
            artists: credits.artists,
            albumId: credits.albumId,
            albumName: credits.albumName,
            isVideo: rowType == "video" || thumbnails.isNotSquare,
            isExplicit: hasExplicitBadge(renderer["subtitleBadges"].raw)
        )
    }

    /** Who the rows inside a promoted artist card are by — a song card's rows are other people's. */
    private static func cardShelfCredit(_ card: JSON) -> Credits? {
        let endpoint = card["onTap"]["browseEndpoint"]
        guard endpoint.exists else { return nil }
        let pageType = endpoint["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string ?? ""
        guard pageType.contains("ARTIST"), let name = card["title"].runs.nonBlank else { return nil }
        return Credits(artistId: endpoint["browseId"].string, artistName: name)
    }

    private static func parseCardShelfBrowse(_ renderer: JSON) -> BrowseItem? {
        let endpoint = renderer["onTap"]["browseEndpoint"]
        guard let browseId = endpoint["browseId"].string else { return nil }
        let pageType = endpoint["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string ?? ""
        let title = renderer["title"].runs
        guard title.nonBlank != nil else { return nil }
        let subtitle = renderer["subtitle"].runs
        if title.matches(videoWord) || subtitle.matches(videoWord) { return nil }
        return BrowseItem(browseId: browseId, title: title, subtitle: subtitle,
                          thumbnailUrl: renderer["thumbnail"]["musicThumbnailRenderer"]["thumbnail"]["thumbnails"].bestThumbnail,
                          type: BrowseType(pageType: pageType, browseId: browseId))
    }

    /** A chart row naming an artist rather than a track. */
    private static func parseArtistRow(_ renderer: JSON) -> ShelfItem? {
        guard renderer.exists else { return nil }
        let endpoint = renderer["navigationEndpoint"]["browseEndpoint"]
        let pageType = endpoint["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string ?? ""
        guard pageType.contains("ARTIST"), let browseId = endpoint["browseId"].string else { return nil }
        let columns = renderer["flexColumns"]
        let title = columns[0]["musicResponsiveListItemFlexColumnRenderer"]["text"].runs
        guard title.nonBlank != nil else { return nil }
        return ShelfItem(
            title: title,
            subtitle: columns[1]["musicResponsiveListItemFlexColumnRenderer"]["text"].runs,
            thumbnailUrl: renderer["thumbnail"]["musicThumbnailRenderer"]["thumbnail"]["thumbnails"].bestThumbnail,
            videoId: nil,
            browseId: browseId
        )
    }

    /** The artist and album pages a run list links out to. */
    struct Credits: Sendable {
        var artistId: String?
        var artistName: String?
        var artists: [ArtistRef] = []
        var albumId: String?
        var albumName: String?
    }

    /** Only the first ARTIST and ALBUM run become the ids; every ARTIST run is kept in [artists]. */
    private static func creditsOf(_ runs: [JSON]) -> Credits {
        var credits = Credits()
        for run in runs {
            let browse = run["navigationEndpoint"]["browseEndpoint"]
            guard let id = browse["browseId"].string else { continue }
            let pageType = browse["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string ?? ""
            let name = run["text"].string ?? ""
            if pageType.contains("ARTIST") {
                if name.nonBlank != nil { credits.artists.append(ArtistRef(name: name, browseId: id)) }
                if credits.artistId == nil {
                    credits.artistId = id
                    credits.artistName = name
                }
            } else if pageType.contains("ALBUM"), credits.albumId == nil {
                credits.albumId = id
                credits.albumName = name
            }
        }
        return credits
    }

    /** Every name in the artist segment, linked or not. */
    private static func artistNamesFromRuns(_ runs: [JSON]) -> String? {
        var groups: [[JSON]] = [[]]
        for run in runs {
            if run["text"].string?.trimmingCharacters(in: .whitespaces) == "•" {
                groups.append([])
            } else {
                groups[groups.count - 1].append(run)
            }
        }
        guard let group = groups.first(where: { group in
            group.contains { ($0["navigationEndpoint"]["browseEndpoint"]["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string ?? "").contains("ARTIST") }
        }) else { return nil }
        var seen = Set<String>()
        let names = group.enumerated().compactMap { index, run -> String? in
            guard index % 2 == 0, let text = run["text"].string?.trimmingCharacters(in: .whitespaces).nonBlank else { return nil }
            return seen.insert(text).inserted ? text : nil
        }
        return names.joined(separator: ", ").nonBlank
    }

    /** Who a release page is billed to, off its own header — only releases, never playlists. */
    private static func pageCredit(_ root: JSON) -> Credits {
        guard let header = headerRenderer(root) else { return Credits() }
        let lines = headerCreditLines.map { header[$0]["runs"].array }
        let parts = lines.flatMap { line in
            line.map { $0["text"].string ?? "" }.joined()
                .replacingOccurrences(of: " · ", with: " • ")
                .components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard parts.contains(where: { releaseWords.contains($0.lowercased()) }) else { return Credits() }
        var credits = creditsOf(lines.flatMap { $0 })
        if let named = lines.lazy.compactMap(artistNamesFromRuns).first {
            credits.artistName = named
            return credits
        }
        credits.artistName = parts.first {
            $0.nonBlank != nil && !typeWords.contains($0.lowercased()) && !$0.wholeMatch(tally) && !$0.wholeMatch(year) && !$0.wholeMatch(durationPattern)
        }
        return credits
    }

    private static func headerRenderer(_ root: JSON) -> JSON? {
        headerRenderers.lazy.compactMap { root.collect($0).first }.first
    }

    struct BrowseHeader: Sendable {
        var title: String
        var subtitle: String
        var thumbnailUrl: String?
    }

    static func parseBrowseHeader(_ root: JSON) -> BrowseHeader? {
        guard let header = headerRenderer(root) else { return nil }
        let title = header["title"].runs
        guard title.nonBlank != nil else { return nil }
        var lines: [String] = []
        for line in headerCreditLines.map({ header[$0].runs }) where line.nonBlank != nil && !lines.contains(line) {
            lines.append(line)
        }
        // The sleeve under "thumbnail" first: a sorted walk would reach the credit's avatar
        // ("straplineThumbnail") before it, where the response's own order doesn't.
        let sleeve = header["thumbnail"].collect("musicThumbnailRenderer").first ?? header.collect("musicThumbnailRenderer").first
        return BrowseHeader(title: title, subtitle: lines.joined(separator: " • "),
                            thumbnailUrl: sleeve?["thumbnail"]["thumbnails"].bestThumbnail)
    }

    /** The playlist behind an album's full track list, off the header's play button. */
    static func parseAlbumPlaylistId(_ root: JSON) -> String? {
        if let header = headerRenderer(root) {
            for renderer in header.collect("musicPlayButtonRenderer") + header.collect("buttonRenderer") {
                if let id = playlistIdFromPlayAction(renderer) { return id }
            }
        }
        guard let canonical = root["microformat"]["microformatDataRenderer"]["urlCanonical"].string,
              let range = canonical.range(of: "list=") else { return nil }
        return String(canonical[range.upperBound...].prefix { $0 != "&" }).nonBlank
    }

    private static func playlistIdFromPlayAction(_ node: JSON) -> String? {
        let endpoint = node["playNavigationEndpoint"].exists ? node["playNavigationEndpoint"]
            : node["navigationEndpoint"].exists ? node["navigationEndpoint"] : node
        return endpoint["watchPlaylistEndpoint"]["playlistId"].string ?? endpoint["watchEndpoint"]["playlistId"].string
    }

    /** "About the album" / "About the artist". */
    static func parseDescription(_ root: JSON) -> String? {
        if let shelf = root.collect("musicDescriptionShelfRenderer").first?["description"].runs.nonBlank { return shelf }
        for name in headerRenderers + ["musicImmersiveHeaderRenderer"] {
            if let text = root.collect(name).first?["description"].runs.nonBlank { return text }
        }
        return nil
    }

    // MARK: Watch queue and lyrics

    /**
     * Tracks of a `next` response — the AutoPlay radio mix. With [preferAudio],
     * a row YouTube pairs with its audio version (a wrapper with a
     * counterpart) is swapped for that ATV audio track.
     */
    static func parseWatchQueue(_ root: JSON, preferAudio: Bool = false) -> [Song] {
        var replacements: [String: JSON] = [:]
        var dropped = Set<String>()
        if preferAudio {
            for wrapper in root.collect("playlistPanelVideoWrapperRenderer") {
                let halves = [wrapper["primaryRenderer"]["playlistPanelVideoRenderer"]].filter(\.exists)
                    + wrapper["counterpart"].array.map { $0["counterpartRenderer"]["playlistPanelVideoRenderer"] }.filter(\.exists)
                guard let primary = halves.first, let primaryId = primary["videoId"].string,
                      let audio = halves.first(where: isAudioTrack) else { continue }
                replacements[primaryId] = audio
                for half in halves.dropFirst() { if let id = half["videoId"].string { dropped.insert(id) } }
            }
        }
        var order: [String] = []
        var songs: [String: Song] = [:]
        for found in root.collect("playlistPanelVideoRenderer") {
            guard let foundId = found["videoId"].string, !dropped.contains(foundId) else { continue }
            let renderer = replacements[foundId] ?? found
            guard let videoId = renderer["videoId"].string, let title = renderer["title"].runs.nonBlank else { continue }
            let bylineRuns = renderer["longBylineText"]["runs"].array
            let byline = bylineRuns.map { $0["text"].string ?? "" }
            let artist = byline.prefix { !$0.contains("•") }.joined().trimmingCharacters(in: .whitespaces)
            let credits = creditsOf(bylineRuns)
            if songs[videoId] == nil { order.append(videoId) }
            songs[videoId] = Song(
                videoId: videoId,
                title: title,
                artist: artist,
                thumbnailUrl: renderer["thumbnail"]["thumbnails"].bestThumbnail,
                durationText: renderer["lengthText"].runs.nonBlank,
                artistId: credits.artistId,
                artists: credits.artists,
                albumId: credits.albumId,
                albumName: credits.albumName,
                // A catalogue track reads "Artist • Album • Year"; its video "Artist • 417M views • …".
                isVideo: byline.contains { $0.localizedCaseInsensitiveContains("views") },
                isExplicit: hasExplicitBadge(renderer.raw)
            )
        }
        return order.compactMap { songs[$0] }
    }

    private static func isAudioTrack(_ renderer: JSON) -> Bool {
        renderer["navigationEndpoint"]["watchEndpoint"]["watchEndpointMusicSupportedConfigs"]["watchEndpointMusicConfig"]["musicVideoType"].string
            == "MUSIC_VIDEO_TYPE_ATV"
    }

    /** Every two-row card on a page, wherever it sits (parseTwoRowItemsDeep). */
    static func parseTwoRowItemsDeep(_ root: JSON) -> [ShelfItem] {
        root.collect("musicTwoRowItemRenderer").compactMap(parseTwoRowItem)
    }

    /** A data-sync id as a request wants it: the part after "||" when there is one (DataSyncId.kt). */
    static func normalizeDataSyncId(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let bars = raw.range(of: "||") else { return raw }
        let after = String(raw[bars.upperBound...]).trimmingCharacters(in: .whitespaces)
        if !after.isEmpty { return after }
        let before = String(raw[..<bars.lowerBound]).trimmingCharacters(in: .whitespaces)
        return before.isEmpty ? nil : before
    }

    /**
     * The channels a login can act as (parseAccountChannels), from whichever
     * envelope the switcher arrived in. An entry with neither token is
     * dropped: there would be nothing to send for it.
     */
    static func parseAccountChannels(_ root: JSON) -> [AccountProfile] {
        var seen = Set<String>()
        return root.collect("accountItem").compactMap { item in
            guard let name = (item["accountName"].runs.nonBlank ?? item["accountName"]["simpleText"].string?.nonBlank) else { return nil }
            let pageId = item.findString("pageId")
            let dataSyncId = normalizeDataSyncId(item.findString("datasyncIdToken"))
            guard pageId != nil || dataSyncId != nil else { return nil }
            let id = pageId ?? dataSyncId ?? name
            guard seen.insert(id).inserted else { return nil }
            let handle = item["channelHandle"].runs.nonBlank ?? item["accountByline"].runs.nonBlank ?? ""
            return AccountProfile(id: id, name: name, handle: handle, avatar: item["accountPhoto"]["thumbnails"].bestThumbnail,
                                  pageId: pageId, dataSyncId: dataSyncId, isBrand: pageId != nil)
        }
    }

    /**
     * The account's own state for one track, off its row in the watch queue
     * (parseSongMenu): the thumbs rating, scoped to [videoId]'s row so a
     * stranger's like button isn't read for it. Nil when the row doesn't say.
     */
    static func parseLikeStatus(_ root: JSON, videoId: String) -> LikeStatus? {
        guard let row = root.collect("playlistPanelVideoRenderer").first(where: { $0["videoId"].string == videoId }) else { return nil }
        return row.collect("likeButtonRenderer").first?["likeStatus"].string.flatMap(LikeStatus.init(rawValue:))
    }

    /** A release's or playlist's save state off its header's bookmark toggle (parseLibraryState). */
    static func parseLibraryState(_ root: JSON) -> (playlistId: String, saved: Bool)? {
        let buttons = root.collect("musicResponsiveHeaderRenderer").first?["buttons"].array ?? []
        func isSaveToggle(_ b: JSON) -> Bool {
            b["defaultIcon"]["iconType"].string == "BOOKMARK_BORDER" || b["toggledIcon"]["iconType"].string == "BOOKMARK"
        }
        guard let save = buttons.map({ $0["toggleButtonRenderer"] }).first(where: { $0.exists && isSaveToggle($0) }),
              save["isDisabled"].bool != true else { return nil }
        let play = buttons.map { $0["musicPlayButtonRenderer"]["playNavigationEndpoint"] }.first(where: \.exists) ?? .null
        guard let playlistId = play["watchPlaylistEndpoint"]["playlistId"].string ?? play["watchEndpoint"]["playlistId"].string else { return nil }
        return (playlistId, save["isToggled"].bool == true)
    }

    /**
     * Whether a playlist page is one the account made (parsePlaylistOwned):
     * an editable header, an Edit/Delete row in its menu, or no save bookmark
     * (there's nothing to save your own playlist into).
     */
    static func parsePlaylistOwned(_ root: JSON) -> Bool? {
        if !root.collect("musicEditablePlaylistDetailHeaderRenderer").isEmpty { return true }
        guard let header = root.collect("musicResponsiveHeaderRenderer").first else { return nil }
        if header.collect("menuNavigationItemRenderer").contains(where: { ["DELETE", "EDIT"].contains($0["icon"]["iconType"].string ?? "") }) {
            return true
        }
        return !header["buttons"].array.contains { b in
            let t = b["toggleButtonRenderer"]
            return t["defaultIcon"]["iconType"].string == "BOOKMARK_BORDER" || t["toggledIcon"]["iconType"].string == "BOOKMARK"
        }
    }

    /** The artist header's subscribe state; absent signed out. */
    static func parseSubscription(_ header: JSON) -> (channelId: String, subscribed: Bool)? {
        let immersive = header["musicImmersiveHeaderRenderer"]
        for button in [immersive["subscriptionButton2"]["subscribeButtonRenderer"], immersive["subscriptionButton"]["subscribeButtonRenderer"]] {
            guard let subscribed = button["subscribed"].bool else { continue }
            let channelId = button["channelId"].string
                ?? button["serviceEndpoints"].array.lazy.compactMap { $0["subscribeEndpoint"]["channelIds"].first.string }.first
            if let channelId { return (channelId, subscribed) }
        }
        return nil
    }

    /** The lyrics tab's browse id off a `next` response. */
    static func lyricsBrowseId(_ root: JSON) -> String? {
        root.collect("tabRenderer").lazy.compactMap { tab -> String? in
            let browse = tab["endpoint"]["browseEndpoint"]
            let pageType = browse["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string
            return pageType == "MUSIC_PAGE_TYPE_TRACK_LYRICS" ? browse["browseId"].string : nil
        }.first
    }

    /** Plain lyrics off the lyrics tab's browse response, and who supplied them. */
    static func parsePlainLyrics(_ root: JSON) -> (text: String, source: String?)? {
        guard let shelf = root.collect("musicDescriptionShelfRenderer").first,
              let text = shelf["description"].runs.nonBlank else { return nil }
        return (text, shelf["footer"].runs.nonBlank)
    }

    // MARK: Cards

    private static func parseTwoRowItem(_ renderer: JSON) -> ShelfItem? {
        guard renderer.exists, let title = renderer["title"].runs.nonBlank else { return nil }
        let endpoint = renderer["navigationEndpoint"]
        let browseId = endpoint["browseEndpoint"]["browseId"].string
        // Uncatalogued history cards carry MPED<videoId> instead of a watch endpoint.
        let videoId = endpoint["watchEndpoint"]["videoId"].string
            ?? browseId.flatMap { $0.hasPrefix("MPED") ? String($0.dropFirst(4)) : nil }
        let resolvedBrowseId = browseId.flatMap { $0.hasPrefix("MPED") ? nil : $0 }
        let thumbnails = renderer["thumbnailRenderer"]["musicThumbnailRenderer"]["thumbnail"]["thumbnails"]
        let subtitle = renderer["subtitle"].runs
        // A playable card with widescreen art is a music-video upload.
        let isVideo = resolvedBrowseId == nil && videoId != nil
            && (thumbnails.isNotSquare || renderer["aspectRatio"].string?.contains("16_9") == true)
        if let id = resolvedBrowseId, !["VL", "PL", "MPRE", "UC"].contains(where: id.hasPrefix),
           title.matches(videoWord) || subtitle.matches(videoWord) {
            return nil
        }
        return ShelfItem(title: title, subtitle: subtitle, thumbnailUrl: thumbnails.bestThumbnail,
                         videoId: videoId, browseId: resolvedBrowseId, isVideo: isVideo)
    }

    /** A shelf card's credit, "Song • Chelsea Wolfe" read as just the artist. */
    static func artistFromSubtitle(_ subtitle: String) -> String {
        let parts = subtitle.components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.nonBlank != nil }
        return parts.first { !typeWords.contains($0.lowercased()) && !$0.wholeMatch(tally) && !$0.wholeMatch(durationPattern) } ?? subtitle
    }

    private static func hasExplicitBadge(_ node: Any?) -> Bool {
        switch node {
        case let string as String: return string == "MUSIC_EXPLICIT_BADGE"
        case let array as [Any]: return array.contains(where: hasExplicitBadge)
        case let object as [String: Any]: return object.values.contains(where: hasExplicitBadge)
        default: return false
        }
    }

    private static let durationPattern = NSRegularExpression(#"\d+:\d{2}(:\d{2})?"#)
    private static let year = NSRegularExpression(#"\d{4}"#)
    /** A counted quantity — "12.4M plays", "13 songs" — that has to leave "21 Savage" alone. */
    private static let tally = NSRegularExpression(
        #"[\d.,]+\s*[KMB]?\s+(plays|views|likes|songs|tracks|subscribers|hours?|minutes?|seconds?)\b.*"#, caseInsensitive: true)
    private static let releaseWords: Set<String> = ["album", "single", "ep"]
    private static let headerRenderers = ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer"]
    private static let headerCreditLines = ["straplineTextOne", "subtitle"]
    private static let typeWords: Set<String> = ["song", "video", "album", "single", "ep", "artist", "playlist", "podcast", "episode"]
    private static let videoWord = NSRegularExpression(#"\bvideos?\b"#, caseInsensitive: true)
}
