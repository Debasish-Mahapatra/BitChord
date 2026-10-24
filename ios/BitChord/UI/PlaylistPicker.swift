import SwiftUI

/** One of the account's own playlists, as the picker lists them. */
struct UserPlaylist: Identifiable, Hashable {
    let playlistId: String
    let title: String
    let subtitle: String
    let thumbnailUrl: String?

    var id: String { playlistId }
    var browseId: String { "VL" + playlistId }

    /**
     * The playlists a track can be added to (parseUserPlaylists): saved `VL…`
     * playlists, less Liked Music, Episodes for Later, radio mixes and albums
     * wearing a playlist id.
     */
    static func from(_ items: [ShelfItem]) -> [UserPlaylist] {
        items.compactMap { item in
            guard let id = item.browseId, id.hasPrefix("VL") else { return nil }
            guard !["LM", "SE", "RD", "OLAK", "MPRE"].contains(where: { id.hasPrefix("VL" + $0) }) else { return nil }
            return UserPlaylist(playlistId: String(id.dropFirst(2)), title: item.title, subtitle: item.subtitle, thumbnailUrl: item.thumbnailUrl)
        }
    }
}

/** PlaylistPickerSheet: tick any number of playlists, or make a new one with the track in it. */
struct PlaylistPicker: View {
    /** Nil: the Library's "New playlist" tile, which opens straight onto the form. */
    let song: Song?
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [UserPlaylist]?
    @State private var selected: Set<String> = []
    @State private var creating = false
    @State private var name = ""
    @State private var privacy: Innertube.Privacy = .private
    @State private var working = false

    init(song: Song?) {
        self.song = song
        _creating = State(initialValue: song == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !account.isSignedIn {
                MessageState(text: "Sign in to add songs to your playlists.", button: "Sign in") {
                    dismiss()
                    account.presentSignIn = true
                }
            } else if creating {
                createForm
            } else {
                list
            }
        }
        .padding(.bottom, 20)
        .task { await load() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(Color(hex: 0x121212))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var header: some View {
        if let song {
            HStack(spacing: 14) {
                Cover(url: song.artwork(rowArtPx), size: 52, radius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).textStyle(.titleMedium).foregroundStyle(.white).lineLimit(1)
                    Text(song.artist).textStyle(.bodyMedium).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 10)
        } else {
            Spacer().frame(height: 20)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased()).textStyle(.labelMedium).foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 4)
    }

    @ViewBuilder
    private var list: some View {
        heading("Add to playlist")
        Button { creating = true } label: {
            HStack(spacing: 18) {
                Image(systemName: "plus").font(.system(size: 19)).frame(width: 22)
                Text("New playlist").textStyle(.bodyLarge)
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if let playlists {
            if playlists.isEmpty {
                Text("No playlists yet. Use the row above to create one.").textStyle(.bodyMedium)
                    .foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 22).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(playlists) { playlist in row(playlist) }
                    }
                }
                .frame(maxHeight: 320)
                Button { add() } label: {
                    Text(selected.isEmpty ? "Add to playlist" : "Add to \(selected.count) \(selected.count == 1 ? "playlist" : "playlists")")
                        .textStyle(.titleMedium)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(.white.opacity(selected.isEmpty ? 0.4 : 1), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty || working)
                .padding(.horizontal, 22).padding(.top, 12)
            }
        } else {
            ProgressView().tint(.white).frame(maxWidth: .infinity).padding(24)
        }
    }

    private func row(_ playlist: UserPlaylist) -> some View {
        let ticked = selected.contains(playlist.playlistId)
        return HStack(spacing: 16) {
            Cover(url: Artwork.url(playlist.thumbnailUrl, px: rowArtPx), size: 44, radius: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).textStyle(.bodyLarge).foregroundStyle(.white).lineLimit(1)
                Text(playlist.subtitle).textStyle(.bodyMedium).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: ticked ? "checkmark.circle.fill" : "circle").font(.system(size: 22))
                .foregroundStyle(ticked ? .white : .white.opacity(0.5))
        }
        .padding(.horizontal, 22).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if ticked { selected.remove(playlist.playlistId) } else { selected.insert(playlist.playlistId) }
        }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if song != nil {
                    Button { creating = false } label: {
                        Image(systemName: "arrow.left").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("New playlist").textStyle(.titleMedium).foregroundStyle(.white)
                    Text("Saved to your YouTube Music account").textStyle(.bodyMedium).foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            TextField("", text: $name, prompt: Text("Playlist name").foregroundStyle(.white.opacity(0.5)))
                .textStyle(.bodyLarge).foregroundStyle(.white)
                .padding(12)
                .background(Theme.surfaceVariant, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(.horizontal, 22).padding(.top, 14)
            heading("Who can see it")
            HStack(spacing: 8) {
                ForEach(Innertube.Privacy.allCases) { option in
                    let on = option == privacy
                    HStack(spacing: 6) {
                        Image(systemName: option.icon).font(.system(size: 14))
                        Text(option.label).textStyle(.titleMedium)
                    }
                    .foregroundStyle(on ? .black : .white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(on ? .white : .white.opacity(0.10), in: Capsule())
                    .onTapGesture { privacy = option }
                }
            }
            .padding(.horizontal, 22).padding(.top, 4)
            Button { create() } label: {
                Text("Create playlist").textStyle(.titleMedium).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(working)
            .padding(.horizontal, 22).padding(.top, 18)
        }
    }

    // MARK: Requests

    private func load() async {
        guard account.isSignedIn, playlists == nil,
              let response = try? await Innertube.shared.browse("FEmusic_liked_playlists") else { return }
        playlists = UserPlaylist.from(InnertubeParser.parseLibraryItems(response).items)
    }

    /** Each ticked playlist gets the track, unless it's already in it. */
    private func add() {
        guard let song else { return }
        let targets = (playlists ?? []).filter { selected.contains($0.playlistId) }
        working = true
        Task {
            var added = 0, already = 0, failed = 0
            for playlist in targets {
                let page = try? await Innertube.shared.browse(playlist.browseId)
                if let page, InnertubeParser.collectSongsDeep(page).contains(where: { $0.videoId == song.videoId }) {
                    already += 1
                    continue
                }
                do {
                    try await Innertube.shared.addToPlaylist(playlist.playlistId, videoIds: [song.videoId])
                    added += 1
                } catch {
                    failed += 1
                }
            }
            working = false
            dismiss()
            let player = PlayerModel.shared
            if failed > 0 {
                player.showNotice("Couldn’t add to \(failed) \(failed == 1 ? "playlist" : "playlists")")
            } else if added > 0 {
                player.showNotice("Added to \(added) \(added == 1 ? "playlist" : "playlists")")
            } else if already > 0 {
                player.showNotice("Already in \(already == 1 ? "that playlist" : "those playlists")")
            }
        }
    }

    /** A new playlist with the track already in it: one request, so it can't half-succeed. */
    private func create() {
        let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? "New playlist" : name.trimmingCharacters(in: .whitespaces)
        working = true
        Task {
            do {
                _ = try await Innertube.shared.createPlaylist(title: title, privacy: privacy, videoIds: song.map { [$0.videoId] } ?? [])
                PlayerModel.shared.showNotice("Created “\(title)”")
                Router.shared.playlistDidChange()
            } catch {
                PlayerModel.shared.showNotice(error.localizedDescription)
            }
            working = false
            dismiss()
        }
    }
}
