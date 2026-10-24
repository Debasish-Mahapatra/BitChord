import Foundation

/**
 * What Apple Music's artist page shows at the top (AppleArtistArt.kt): a hero
 * photograph and, for some artists, their title logo as a separate transparent
 * PNG, with Apple's own colours for the photograph. The looping artist video
 * Apple also offers is left out: it moves, and the still is always there.
 */
struct AppleArtistArt: Codable, Sendable {
    var heroUrl: String
    var logoUrl: String?
    /** The logo's width over its height, to size it before it decodes. */
    var logoAspect: Double
    /** Apple's background and first text colour for the photo, as 0xRRGGBB. */
    var background: Int
    var accent: Int
    /** The colour Apple fills the artist's Play button with; absent for some artists. */
    var keyColor: Int?
}

/**
 * Finds [AppleArtistArt] from an artist's name: the iTunes search turns it
 * into Apple artist ids, and the first same-named one whose catalogue shares
 * a song or release title with the YouTube page's own is taken — a name is
 * not an identity. Then the artist's music.apple.com page, whose header art
 * sits in the JSON it embeds for hydration. Settled answers, misses included,
 * are kept per YouTube browse id; a network hiccup is not an answer.
 */
actor AppleArtistArtRepository {
    static let shared = AppleArtistArtRepository()

    private static let heroWidth = 1200
    private static let logoWidth = 1000
    private static let storeKey = "apple.artistArt"

    /** browse id → art; a stored nil is "Apple has none that's provably this artist". */
    private var cache: [String: AppleArtistArt?] = {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let stored = try? JSONDecoder().decode([String: AppleArtistArt?].self, from: data) else { return [:] }
        return stored
    }()

    func cached(_ browseId: String) -> AppleArtistArt? { cache[browseId] ?? nil }

    func art(for browseId: String, name: String, catalogue: () async -> [String]) async -> AppleArtistArt? {
        let key = AppleCatalogue.matchKey(name)
        guard !key.isEmpty else { return nil }
        if let known = cache[browseId] { return known }
        let titles = Set(await catalogue().compactMap(AppleCatalogue.titleKey))
        guard !titles.isEmpty, let settled = await lookup(name, key: key, titles: titles) else { return nil }
        cache[browseId] = .some(settled)
        if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
        return settled
    }

    /** Nil is a network miss; a settled answer may still hold no art. */
    private func lookup(_ name: String, key: String, titles: Set<String>) async -> AppleArtistArt?? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [.init(name: "term", value: name), .init(name: "entity", value: "musicArtist"), .init(name: "limit", value: "5")]
        guard let (data, _) = try? await HTTP.session.data(from: components.url!), let json = try? JSON(data: data) else { return nil }
        var page: String?
        // Every same-named candidate is checked: the one Apple ranks highest is often the wrong one of two.
        for result in json["results"].array where AppleCatalogue.matchKey(result["artistName"].string ?? "") == key {
            guard let id = result["artistId"].double.map({ Int($0) }), id > 0,
                  await AppleCatalogue.sharesTitles(artistId: id, keys: titles) else { continue }
            page = result["artistLinkUrl"].string.map { String($0.split(separator: "?").first ?? Substring($0)) }
                ?? "https://music.apple.com/us/artist/\(id)"
            break
        }
        guard let page, let url = URL(string: page) else { return .some(nil) }
        var request = URLRequest(url: url)
        request.setValue(HTTP.webUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (body, response) = try? await HTTP.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return .some(Self.parse(String(decoding: body, as: UTF8.self)))
    }

    private static func parse(_ html: String) -> AppleArtistArt? {
        guard let marker = html.range(of: "id=\"serialized-server-data\""),
              let open = html[marker.upperBound...].firstIndex(of: ">"),
              let close = html.range(of: "</script>", range: html.index(after: open)..<html.endIndex),
              let data = String(html[html.index(after: open)..<close.lowerBound]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let header = findHeader(root) else { return nil }
        let headerJSON = JSON(header)
        let logo = headerJSON["artistLogo"]["dictionary"]
        var hero = headerJSON["artwork"]["dictionary"]
        if !hero.exists { hero = headerJSON["colorBackdropArtwork"]["dictionary"] }
        guard let heroW = hero["width"].double, heroW > 0, let heroH = hero["height"].double, heroH > 0,
              let heroUrl = fill(hero["url"].string, width: heroWidth, height: Int(Double(heroWidth) * heroH / heroW), format: "jpg"),
              let background = rgb(hero["bgColor"].string) else { return nil }
        let logoW = logo["width"].double ?? 0, logoH = logo["height"].double ?? 0
        let logoUrl = logoW > 0 && logoH > 0
            ? fill(logo["url"].string, width: logoWidth, height: Int(Double(logoWidth) * logoH / logoW), format: "png") : nil
        return AppleArtistArt(heroUrl: heroUrl, logoUrl: logoUrl, logoAspect: logoUrl != nil ? logoW / logoH : 1,
                              background: background, accent: rgb(hero["textColor1"].string) ?? background,
                              keyColor: rgb(headerJSON["keyColor"].string))
    }

    /** The first object anywhere with an `artistLogo` key: the page header. */
    private static func findHeader(_ node: Any) -> [String: Any]? {
        if let object = node as? [String: Any] {
            if object.keys.contains("artistLogo") { return object }
            for value in object.values { if let found = findHeader(value) { return found } }
        } else if let array = node as? [Any] {
            for value in array { if let found = findHeader(value) { return found } }
        }
        return nil
    }

    /** Apple's colours are six hex digits with no prefix. */
    private static func rgb(_ hex: String?) -> Int? {
        guard let hex, hex.count == 6 else { return nil }
        return Int(hex, radix: 16)
    }

    private static func fill(_ template: String?, width: Int, height: Int, format: String) -> String? {
        guard let template, template.contains("{w}") else { return nil }
        return template.replacingOccurrences(of: "{w}", with: "\(width)").replacingOccurrences(of: "{h}", with: "\(height)")
            .replacingOccurrences(of: "{c}", with: "bb").replacingOccurrences(of: "{f}", with: format)
    }
}
