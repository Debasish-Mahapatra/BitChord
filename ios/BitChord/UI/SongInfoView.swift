import SwiftUI

/** Song Info's rows, loaded once per open and again on Retry. */
@MainActor
@Observable
final class SongInfoModel {
    let song: Song
    private(set) var info: SongInfo?

    init(song: Song) { self.song = song }

    func load() async {
        info = nil
        info = await SongInfo.load(song)
    }

    /** Label and value; a nil value is still loading, unless the info is in, when it isn't available. */
    var rows: [(label: String, value: String?)] {
        let unavailable = info == nil ? nil : "Not available"
        return [
            ("Album", info?.album ?? song.albumName ?? unavailable),
            ("Release date", info?.releaseDate ?? info?.releaseYear ?? unavailable),
            ("Plays / views", info?.views.map(SongInfo.compactCount) ?? unavailable),
            ("Likes", info?.likes ?? unavailable),
            ("Comments", info?.comments ?? unavailable),
        ]
    }
}

/** The ⋮ sheet's own Song Info page: a back arrow and title over a hairline, then full-width rows. */
struct SongInfoPage: View {
    let song: Song
    var accent: Color = .white
    var onBack: () -> Void
    @State private var model: SongInfoModel

    init(song: Song, accent: Color = .white, onBack: @escaping () -> Void) {
        self.song = song
        self.accent = accent
        self.onBack = onBack
        _model = State(initialValue: SongInfoModel(song: song))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button(action: onBack) {
                    Image(systemName: "arrow.left").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                VStack(alignment: .leading, spacing: 0) {
                    Text("Song Info").textStyle(.titleLarge).foregroundStyle(.white)
                    Text([song.title, song.artist].filter { !$0.isEmpty }.joined(separator: " · "))
                        .textStyle(.bodyMedium).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8).padding(.trailing, 22).padding(.top, 18).padding(.bottom, 8)
            Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
            ForEach(model.rows, id: \.label) { row in
                HStack(spacing: 16) {
                    Text(row.label).textStyle(.bodyLarge).foregroundStyle(.white)
                    Spacer(minLength: 0)
                    if let value = row.value {
                        Text(value).textStyle(.bodyLarge).foregroundStyle(accent).multilineTextAlignment(.trailing)
                    } else {
                        ProgressView().controlSize(.small).tint(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 15)
            }
            if model.info?.failed == true {
                Button { Task { await model.load() } } label: {
                    HStack(spacing: 18) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 19)).frame(width: 22)
                        Text("Retry").textStyle(.bodyLarge)
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Some information could not be loaded.").font(.sfDisplay(12, .regular)).foregroundStyle(Color(hex: 0xFF453A))
                    .padding(.horizontal, 22)
            }
            Spacer(minLength: 24)
        }
        .task { await model.load() }
    }
}

/**
 * The held-row menu has no pages to swap, so there Song Info is an alert card:
 * centred title over hairlines, label and value rows, then Done.
 */
struct SongInfoCard: View {
    let song: Song
    var onDismiss: () -> Void
    @State private var model: SongInfoModel

    init(song: Song, onDismiss: @escaping () -> Void) {
        self.song = song
        self.onDismiss = onDismiss
        _model = State(initialValue: SongInfoModel(song: song))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture(perform: onDismiss)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text("Song Info").font(.sfDisplay(17, .semibold)).foregroundStyle(Theme.onSurface)
                    Text(song.title).font(.sfDisplay(13, .regular)).foregroundStyle(Theme.onSurface)
                        .multilineTextAlignment(.center).lineLimit(2).padding(.top, 4)
                    if !song.artist.isEmpty {
                        Text(song.artist).font(.sfDisplay(13, .regular)).foregroundStyle(Theme.onSurface.opacity(0.6)).lineLimit(1)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 19)
                rule
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { rule.padding(.leading, 16) }
                            HStack(spacing: 12) {
                                Text(row.label).font(.sfDisplay(15, .regular)).foregroundStyle(Theme.onSurface.opacity(0.6))
                                Spacer(minLength: 0)
                                if let value = row.value {
                                    Text(value).font(.sfDisplay(15, .regular)).foregroundStyle(Theme.onSurface).multilineTextAlignment(.trailing)
                                } else {
                                    ProgressView().controlSize(.mini).tint(Theme.onSurface.opacity(0.5))
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .frame(minHeight: 44)
                        }
                        if model.info?.failed == true {
                            Text("Some information could not be loaded.").font(.sfDisplay(12, .regular)).foregroundStyle(Color(hex: 0xFF453A))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.bottom, 10)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                rule
                if model.info?.failed == true {
                    action("Retry", emphasised: false) { Task { await model.load() } }
                    rule
                }
                action("Done", emphasised: true, perform: onDismiss)
            }
            .frame(width: 270)
            .background(Theme.surfaceVariant, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .task { await model.load() }
    }

    private var rule: some View { Rectangle().fill(Theme.onSurface.opacity(0.15)).frame(height: 0.5) }

    private func action(_ label: String, emphasised: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(label).font(.sfDisplay(17, emphasised ? .semibold : .regular)).foregroundStyle(Color(hex: 0x0A84FF))
                .frame(maxWidth: .infinity).frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
