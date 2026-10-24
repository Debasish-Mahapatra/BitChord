import SwiftUI

/** "Up Next" (PlayerQueue.kt): now playing, the hand-queued tracks, the rest of the list, then AutoPlay. */
struct QueuePanel: View {
    @Environment(PlayerModel.self) private var player

    private struct Row: Identifiable {
        let index: Int
        let entry: QueueEntry
        var id: UUID { entry.id }
    }

    var body: some View {
        let timeline = player.timeline
        let now = player.index
        let upcoming = timeline.indices.filter { $0 > now }.map { Row(index: $0, entry: timeline[$0]) }
        let user = upcoming.filter { $0.entry.tier == .user }
        let context = upcoming.filter { $0.entry.tier == .context }
        let autoplay = upcoming.filter { $0.entry.tier == .autoplay }
        // Show queue history: up to 25 played tracks above Now playing.
        let history = AppSettings.shared.showQueueHistory
            ? timeline.indices.filter { $0 < now }.suffix(25).map { Row(index: $0, entry: timeline[$0]) } : []

        VStack(spacing: 0) {
            HStack {
                Text("Queue").textStyle(.titleLarge).foregroundStyle(.white)
                Spacer()
                if !user.isEmpty {
                    Button("Clear") { withAnimation(.fastOutSlowIn(0.2)) { player.clearUserQueue() } }
                        .textStyle(.titleMedium).foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 4)
            ScrollViewReader { proxy in
                List {
                    if !history.isEmpty {
                        Section {
                            ForEach(history) { row($0, isCurrent: false) }
                        } header: { heading("Previously played") }
                    }
                    if let current = player.current {
                        Section {
                            row(Row(index: now, entry: current), isCurrent: true)
                                .id("now")
                        } header: { heading("Now playing") }
                    }
                    if !user.isEmpty {
                        Section {
                            ForEach(user) { row($0, isCurrent: false) }
                                .onMove { move(user, $0, $1) }
                        } header: {
                            HStack {
                                heading("Next in queue")
                                Spacer()
                                Button("Clear") { withAnimation(.fastOutSlowIn(0.2)) { player.clearUserQueue() } }
                                    .textStyle(.labelLarge).foregroundStyle(.white.opacity(0.75))
                            }
                        }
                    }
                    if !context.isEmpty {
                        Section {
                            ForEach(context) { row($0, isCurrent: false) }
                                .onMove { move(context, $0, $1) }
                        } header: {
                            heading("Next from: \(player.current?.source?.title ?? player.song?.albumName ?? "Queue")")
                        }
                    }
                    if player.autoplay || !autoplay.isEmpty {
                        Section {
                            ForEach(autoplay) { row($0, isCurrent: false) }
                                .onMove { move(autoplay, $0, $1) }
                        } header: { autoplayHeading(hasTracks: !autoplay.isEmpty) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 28)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                    }
                }
                .onAppear { proxy.scrollTo("now", anchor: .top) }
                .onChange(of: player.current?.id) { _, _ in
                    withAnimation(.fastOutSlowIn(0.3)) { proxy.scrollTo("now", anchor: .top) }
                }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).textStyle(.titleMedium).foregroundStyle(.white.opacity(0.75))
            .padding(.vertical, 6)
            .listRowInsets(EdgeInsets(top: 0, leading: 30, bottom: 0, trailing: 30))
    }

    private func autoplayHeading(hasTracks: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "infinity").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("AutoPlay").textStyle(.titleMedium).foregroundStyle(.white)
                Text(hasTracks ? "Similar music, selected to play next" : "Similar music will keep playing")
                    .textStyle(.bodyMedium).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.vertical, 14)
    }

    private func row(_ row: Row, isCurrent: Bool) -> some View {
        let song = row.entry.song
        return HStack(spacing: 12) {
            Cover(url: song.artwork(rowArtPx), size: 44, radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).textStyle(.titleMedium).foregroundStyle(.white.opacity(isCurrent ? 1 : 0.92)).lineLimit(1)
                Text(song.artist).textStyle(.bodyMedium).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "waveform").font(.system(size: 16)).foregroundStyle(.white.opacity(0.75)).padding(.trailing, 10)
            } else {
                Button { withAnimation(.fastOutSlowIn(0.2)) { player.remove(at: row.index) } } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { if !isCurrent { player.jump(to: row.index) } }
        .listRowInsets(EdgeInsets(top: 0, leading: 30, bottom: 0, trailing: 22))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /** A drag inside one section, translated to timeline positions. */
    private func move(_ rows: [Row], _ offsets: IndexSet, _ destination: Int) {
        guard let from = offsets.first else { return }
        let source = rows[from].index
        let target: Int
        if destination >= rows.count {
            target = rows[rows.count - 1].index
        } else {
            target = destination > from ? rows[destination - 1].index : rows[destination].index
        }
        player.move(from: source, to: target)
    }
}
