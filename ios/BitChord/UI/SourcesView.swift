import SwiftUI

/**
 * Sources (SourcesScreen): every source in the order it is tried — the addons
 * the user added (theirs to reorder), JioSaavn, then YouTube Music, always on
 * — with the row that adds an addon at the foot.
 */
struct SourcesView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @State private var registry = SourceRegistry.shared
    @State private var editing: SourceConfig?
    @State private var confirmJioSaavn = false

    var body: some View {
        let ordered = registry.ordered
        let addons = ordered.filter { $0.kind == .addon }
        let fixed = ordered.filter { $0.kind != .addon }
        let ceiling = settings.audioQuality
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Sources").textStyle(.displayLarge).foregroundStyle(Theme.onBackground)
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
                SettingsGroup(header: "Sources, tried in this order", footer: footer(ordered: ordered, ceiling: ceiling), topSpacing: 0) {
                    ForEach(Array(addons.enumerated()), id: \.element.id) { index, config in
                        row(index + 1, config, movable: addons.count > 1, at: index, of: addons.count)
                        SettingsDivider()
                    }
                    ForEach(Array(fixed.enumerated()), id: \.element.id) { index, config in
                        if index > 0 { SettingsDivider() }
                        row(addons.count + index + 1, config, movable: false, at: index, of: fixed.count)
                    }
                    SettingsDivider()
                    SettingsRow(icon: "plus.circle.fill", title: "Add an addon",
                                subtitle: "Point BitChord at an addon server you host or were given a link to") {
                        editing = SourceConfig(kind: .addon)
                    }
                }
            }
            .padding(.top, Metrics.contentTop)
            .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
        }
        .task { await registry.checkAll() }
        .sheet(item: $editing) { AddonEditor(config: $0) }
        .alert("Enable JioSaavn?", isPresented: $confirmJioSaavn) {
            Button("Cancel", role: .cancel) {}
            Button("Enable anyway") {
                if let saavn = registry.configs.first(where: { $0.kind == .jioSaavn }) { registry.setEnabled(saavn.id, true) }
            }
        } message: {
            Text("May match the wrong version of a song. Enable at your own risk.")
        }
    }

    private func footer(ordered: [SourceConfig], ceiling: AudioQuality) -> String {
        var text = "If a source does not have a track or cannot be reached, BitChord tries the next one. Sources above YouTube can replace its recording when they return a better version."
        if ceiling == .low || ceiling == .medium {
            text += "\n\nThis connection is set below High quality, so streams are transcoded to fit that limit. Downloads are unaffected."
        } else if !ordered.contains(where: { $0.enabled && $0.kind.canServeLossless }) {
            text += "\n\nNo enabled source can provide lossless audio. Add an addon to play lossless files without transcoding."
        }
        return text
    }

    private func row(_ position: Int, _ config: SourceConfig, movable: Bool, at index: Int, of count: Int) -> some View {
        let dimmed = !config.enabled
        return HStack(spacing: 0) {
            Text("\(position)").textStyle(.bodyLarge).foregroundStyle(Theme.onSurfaceVariant)
                .frame(width: 18, alignment: .leading).opacity(dimmed ? 0.4 : 1)
            Spacer().frame(width: 6)
            Image(systemName: icon(config.kind)).font(.system(size: 18)).foregroundStyle(Theme.onBackground)
                .frame(width: 22).opacity(dimmed ? 0.4 : 1)
            Spacer().frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.displayName).textStyle(.bodyLarge).foregroundStyle(Theme.onBackground).lineLimit(1)
                Text(status(config)).textStyle(.bodyMedium).foregroundStyle(statusColor(config)).lineLimit(2)
            }
            .opacity(dimmed ? 0.4 : 1)
            Spacer(minLength: 8)
            if config.kind == .youtube {
                Text("Always on").textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant)
            } else {
                Toggle("", isOn: Binding(get: { config.enabled }, set: { on in
                    if config.kind == .jioSaavn, on, !config.enabled { confirmJioSaavn = true } else { registry.setEnabled(config.id, on) }
                }))
                .labelsHidden().toggleStyle(MaterialSwitch())
            }
            if movable {
                // The addons' order is the user's: up and down, where the phone drags.
                Menu {
                    if index > 0 { Button("Move up", systemImage: "arrow.up") { registry.moveAddon(from: [index], to: index - 1) } }
                    if index < count - 1 { Button("Move down", systemImage: "arrow.down") { registry.moveAddon(from: [index], to: index + 2) } }
                } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 17)).foregroundStyle(Theme.onSurfaceVariant)
                        .frame(width: 32, height: 40)
                }
                .padding(.leading, 4)
                .accessibilityLabel("Drag to reorder")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .onTapGesture { if config.kind == .addon { editing = config } }
    }

    private func icon(_ kind: SourceKind) -> String {
        switch kind {
        case .addon: return "puzzlepiece.extension.fill"
        case .jioSaavn: return "waveform"
        case .youtube: return "play.circle.fill"
        }
    }

    /** What a source is, or what is wrong with it. */
    private func status(_ config: SourceConfig) -> String {
        if config.kind == .addon, config.baseUrl.isEmpty { return "Tap to finish setting up" }
        if config.kind == .jioSaavn { return "May match the wrong version of a song. Enable at your own risk." }
        switch registry.health[config.id] {
        case .ok(let detail)?: return ([detail] + config.kind.labels.prefix(3).map { $0 }).compactMap { $0 }.joined(separator: " · ")
        case .rejected(let reason)?: return reason
        case .unreachable(let reason)?: return "Can’t reach it right now · \(reason)"
        case nil: return config.kind == .addon ? "Checking…" : config.kind.labels.prefix(3).joined(separator: " · ")
        }
    }

    private func statusColor(_ config: SourceConfig) -> Color {
        if case .rejected? = registry.health[config.id] { return Color(hex: 0xFF453A) }
        return Theme.onSurfaceVariant
    }
}

/**
 * Add or edit an addon (SourceEditorAlert): its URL, Test to hear what is
 * there, Save to keep it — saving asks the same question first, so nothing
 * unidentified is stored.
 */
private struct AddonEditor: View {
    let config: SourceConfig
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var busy = false
    @State private var status: String?
    @State private var good = false

    private var isNew: Bool { !SourceRegistry.shared.configs.contains { $0.id == config.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add an addon" : config.displayName).textStyle(.titleLarge).foregroundStyle(.white)
            Text("Paste the addon’s URL — either its root or its manifest.json. BitChord reads what it can search and stream, then asks it for tracks over plain HTTP.")
                .textStyle(.bodyMedium).foregroundStyle(.white.opacity(0.6))
            TextField("", text: $url, prompt: Text("https://my-addon.example.com").foregroundStyle(.white.opacity(0.4)))
                .textStyle(.bodyLarge).foregroundStyle(.white)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12)
                .background(Theme.surfaceVariant, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .onChange(of: url) { _, _ in status = nil }
            if let status {
                Text(status).textStyle(.bodyMedium).foregroundStyle(good ? Color(hex: 0x30D158) : Color(hex: 0xFF453A))
            }
            HStack(spacing: 10) {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        SourceRegistry.shared.remove(config.id)
                        dismiss()
                    }
                    .textStyle(.titleMedium).foregroundStyle(Color(hex: 0xFF453A))
                }
                Spacer()
                Button(busy ? "Testing…" : "Test") { run(save: false) }
                    .textStyle(.titleMedium).foregroundStyle(.white.opacity(url.isEmpty ? 0.4 : 0.85))
                    .disabled(url.isEmpty || busy)
                Button { run(save: true) } label: {
                    Text("Save").textStyle(.titleMedium).foregroundStyle(.black)
                        .padding(.horizontal, 20).frame(height: 40)
                        .background(.white.opacity(url.isEmpty ? 0.4 : 1), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(url.isEmpty || busy)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .onAppear { url = config.baseUrl }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(Color(hex: 0x121212))
        .environment(\.colorScheme, .dark)
    }

    private func run(save: Bool) {
        let base = AddonClient.normalizeBase(url)
        busy = true
        status = nil
        Task {
            defer { busy = false }
            if let existing = SourceRegistry.shared.duplicate(of: base, except: isNew ? nil : config.id) {
                good = false
                status = "Already added as \(existing.displayName)"
                return
            }
            guard URL(string: base)?.host != nil else {
                good = false
                status = "BitChord could not tell what that link is"
                return
            }
            let health = await AddonClient(base).health()
            switch health {
            case .ok(let detail):
                good = true
                status = ["Connected", "Addon", detail].compactMap { $0 }.joined(separator: " · ")
            case .rejected(let reason), .unreachable(let reason):
                good = false
                status = reason
            }
            guard save else { return }
            var saved = config
            saved.baseUrl = base
            if case .ok(let detail) = health, saved.label.isEmpty, let name = detail?.components(separatedBy: " v").first?.nonBlank {
                saved.label = name
            }
            if isNew { SourceRegistry.shared.add(saved) } else { SourceRegistry.shared.update(saved) }
            dismiss()
        }
    }
}
