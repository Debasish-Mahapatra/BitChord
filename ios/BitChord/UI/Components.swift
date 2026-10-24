import SwiftUI

// MARK: - Artwork

/** Artwork on a surfaceVariant tile with the 1pt rim (thumbnailBorder). */
struct Cover: View {
    let url: URL?
    var size: CGFloat? = nil
    var radius: CGFloat = 8
    var circle = false
    var border = true

    var body: some View {
        let shape = circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        Rectangle()
            .fill(Theme.surfaceVariant)
            .overlay { RemoteImage(url: url) }
            .clipShape(shape)
            .overlay { if border { shape.stroke(Theme.thumbnailBorder, lineWidth: 1) } }
            .frame(width: size, height: size)
    }
}

/** The explicit "E": a filled rounded rect with the letter cut out of it. */
struct ExplicitBadge: View {
    var color: Color = Theme.onSurfaceVariant
    var height: CGFloat = 14

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: height * 0.62 + 6, height: height)
            .overlay { Text("E").font(.sfDisplay(height * 0.78, .bold)).blendMode(.destinationOut) }
            .compositingGroup()
            .accessibilityLabel("Explicit")
    }
}

/** A title with the explicit badge before it, as ExplicitSongTitle. */
struct SongTitle: View {
    let text: String
    var explicit = false
    var style: TextStyle = .titleMedium
    var color: Color = Theme.onBackground

    var body: some View {
        HStack(spacing: 6) {
            if explicit { ExplicitBadge(color: color, height: style.size * 0.8) }
            Text(text).textStyle(style).foregroundStyle(color).lineLimit(1)
        }
    }
}

/**
 * The now-playing mark over a row's artwork. The phone animates these bars;
 * here they stand still at their mid heights — no pulsing.
 */
struct PlayingBars: View {
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach([0.69, 0.83, 0.64], id: \.self) { height in
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 3, height: 14 * height)
            }
        }
        .frame(width: 24, height: 24)
        .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 6))
    }
}

/** ⋮ in a 36pt circle that hangs into the gutter (layout width 22). */
struct MoreButton: View {
    var color: Color = Theme.onSurfaceVariant
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 22)
        .offset(x: 7)
        .accessibilityLabel("More")
    }
}

// MARK: - Rows

/** SongRow (Common.kt): 52pt art or a track number, title, credit, duration, ⋮. */
struct SongRow: View {
    enum Leading { case artwork, number(Int) }

    let song: Song
    var leading: Leading = .artwork
    var accent: Color = Theme.playingAccent
    var subtitleColor: Color = Theme.onSurfaceVariant
    var fallbackArtwork: String?
    var showDuration = true
    /** Set on the rows of the account's own playlist. */
    var ownPlaylistId: String? = nil
    var onTap: () -> Void

    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router

    var body: some View {
        let current = player.song?.videoId == song.videoId
        HStack(spacing: 0) {
            Group {
                switch leading {
                case .artwork:
                    Cover(url: Artwork.url(song.thumbnailUrl ?? fallbackArtwork, px: rowArtPx), size: 52, radius: 8)
                        .overlay { if current, player.isPlaying { PlayingBars() } }
                        .padding(.trailing, 14)
                case .number(let n):
                    ZStack {
                        if current, player.isPlaying {
                            PlayingBars()
                        } else if current {
                            Image(systemName: "play.fill").font(.system(size: 16)).foregroundStyle(accent)
                        } else {
                            Text("\(n)").textStyle(.bodyLarge).foregroundStyle(subtitleColor)
                        }
                    }
                    .frame(width: Metrics.trackNumberWidth, height: 52)
                    .padding(.trailing, 16)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                // The current track is marked by its bars alone (searchPlayingStyle): no tint, no highlight.
                SongTitle(text: song.title, explicit: song.isExplicit, color: Theme.onBackground)
                Text(song.artist).textStyle(.bodyMedium).foregroundStyle(subtitleColor).lineLimit(1)
            }
            Spacer(minLength: 8)
            if showDuration, let duration = song.durationText {
                Text(duration).textStyle(.labelMedium).foregroundStyle(subtitleColor).padding(.trailing, 2)
            }
            MoreButton(color: subtitleColor) {
                router.songMenuPlaylist = ownPlaylistId
                router.songMenu = song
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .songContextMenu(song)
        .swipeToQueue(song)
    }
}

/** An album, artist or playlist row (52pt art; a circle for artists). */
struct BrowseRow: View {
    let item: BrowseItem
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Cover(url: Artwork.url(item.thumbnailUrl, px: rowArtPx), size: 52, radius: 8, circle: item.type == .artist)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).textStyle(.titleMedium).foregroundStyle(Theme.onBackground).lineLimit(1)
                Text(item.subtitle).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .browseContextMenu(item)
    }
}

/** Compact rows (Recents, an artist's top songs): 48pt art at radius 7. */
struct CompactTrackRow: View {
    let song: Song
    /** A music video's row: 16:9 art at the same height. */
    var isVideo = false
    var onTap: () -> Void

    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router

    var body: some View {
        let current = player.song?.videoId == song.videoId
        HStack(spacing: 12) {
            Cover(url: song.artwork(rowArtPx), radius: 7)
                .frame(width: isVideo ? 48 * 16 / 9 : 48, height: 48)
                .overlay { if current, player.isPlaying { PlayingBars() } }
            VStack(alignment: .leading, spacing: 2) {
                SongTitle(text: song.title, explicit: song.isExplicit, color: Theme.onBackground)
                Text(song.artist).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
            }
            Spacer(minLength: 0)
            MoreButton { router.songMenu = song }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .songContextMenu(song)
    }
}

/** A 0.5pt divider inset from the leading edge. */
struct InsetDivider: View {
    var inset: CGFloat = Metrics.rowDividerInset
    var color: Color = Theme.outline

    var body: some View {
        Rectangle().fill(color).frame(height: 0.5).padding(.leading, inset)
    }
}

// MARK: - Shelves

/** SectionHeader: headlineMedium title and YouTube's strapline under it. */
struct SectionHeader<Trailing: View>: View {
    let title: String
    var strapline: String = ""
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).textStyle(.headlineMedium).foregroundStyle(Theme.onBackground).lineLimit(2)
                if !strapline.isEmpty {
                    Text(strapline).textStyle(.titleMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, strapline: String = "") {
        self.init(title: title, strapline: strapline) { EmptyView() }
    }
}

/** ShelfCard: a 150pt square at radius 12, title and subtitle under it. */
struct ShelfCard: View {
    let item: ShelfItem
    var width: CGFloat = Metrics.shelfCardWidth
    var radius: CGFloat = 12
    /** A Library playlist card that's pinned: a pin before its title. */
    var isPinned = false
    var onTap: () -> Void

    @Environment(PlayerModel.self) private var player

    var body: some View {
        let current = item.videoId != nil && player.song?.videoId == item.videoId
        VStack(alignment: .leading, spacing: 0) {
            Cover(url: Artwork.url(item.thumbnailUrl, px: cardArtPx), radius: radius)
                .frame(width: width, height: width)
                .overlay { if current, player.isPlaying { PlayingBars() } }
            HStack(spacing: 4) {
                if isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Theme.onSurfaceVariant)
                        .accessibilityLabel("Pinned")
                }
                Text(item.title).textStyle(.titleMedium).foregroundStyle(Theme.onBackground)
                    .lineLimit(1)
            }
            .padding(.top, 10)
            Text(item.subtitle.isEmpty ? " " : item.subtitle).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .shelfContextMenu(item)
    }
}

/** The first shelf as hero cards: 0.92 aspect, radius 18, a caption on a dark gradient. */
struct HeroCard: View {
    let item: ShelfItem
    let width: CGFloat
    var onTap: () -> Void

    @Environment(PlayerModel.self) private var player

    var body: some View {
        let current = item.videoId != nil && player.song?.videoId == item.videoId
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Theme.surfaceVariant)
                .overlay { RemoteImage(url: Artwork.url(item.thumbnailUrl, px: 720)) }
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).textStyle(.titleLarge).foregroundStyle(.white).lineLimit(1)
                Text(item.subtitle).textStyle(.bodyMedium).foregroundStyle(.white.opacity(0.72)).lineLimit(2)
            }
            .padding(EdgeInsets(top: 34, leading: 16, bottom: 14, trailing: 16))
        }
        .frame(width: width, height: width / 0.92)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.thumbnailBorder, lineWidth: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .shelfContextMenu(item)
    }
}

/** A horizontal shelf that snaps so the leading card lines up with the gutter. */
struct HorizontalShelf<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: spacing) { content() }
                .scrollTargetLayout()
        }
        .contentMargins(.horizontal, Metrics.gutter, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
    }
}

// MARK: - States

/** MessageState: a centred line of text and an optional capsule button. */
struct MessageState: View {
    let text: String
    var button: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Text(text).textStyle(.bodyLarge).foregroundStyle(Theme.onSurfaceVariant).multilineTextAlignment(.center)
            if let button, let action {
                Button(action: action) {
                    Text(button).textStyle(.labelLarge).foregroundStyle(.black)
                        .padding(.horizontal, 24).frame(height: 40)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 48)
    }
}

/**
 * A loading placeholder. The phone sweeps a shimmer band across these every
 * 1.4 s; here they stay flat, which is how they look between passes.
 */
struct SkeletonBlock: View {
    var radius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.surfaceVariant)
    }
}

struct ShelfSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonBlock().frame(width: 180, height: 18).padding(.horizontal, Metrics.gutter).padding(.vertical, 10)
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 0) {
                        SkeletonBlock(radius: 12).frame(width: 150, height: 150)
                        SkeletonBlock().frame(width: 150 * [0.68, 0.46, 0.58][i], height: 13).padding(.top, 12)
                        SkeletonBlock().frame(width: 150 * [0.34, 0.44, 0.27][i], height: 11).padding(.top, 6)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RowSkeleton: View {
    var index = 0
    var circle = false

    var body: some View {
        HStack(spacing: 14) {
            if circle { Circle().fill(Theme.surfaceVariant).frame(width: 52, height: 52) } else { SkeletonBlock(radius: 8).frame(width: 52, height: 52) }
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock().frame(width: 220 * [0.68, 0.46, 0.58, 0.74, 0.52][index % 5], height: 14)
                SkeletonBlock().frame(width: 220 * [0.34, 0.44, 0.27, 0.38, 0.31][index % 5], height: 11)
            }
            Spacer()
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 4)
    }
}

/** The big in-list heading every tab carries (displayLarge). */
struct PageTitle: View {
    let text: String

    var body: some View {
        Text(text).textStyle(.displayLarge).foregroundStyle(Theme.onBackground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 14)
    }
}
