import Network
import SwiftUI

// MARK: - Building blocks (SettingsGroup, SettingsRow, SettingsSubRow)

/** One inset card of rows, an uppercase header above and an optional footer below. */
struct SettingsGroup<Content: View>: View {
    var header: String?
    var footer: String?
    var topSpacing: CGFloat = 26
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header.uppercased()).textStyle(.labelSmall).foregroundStyle(Theme.onSurfaceVariant)
                    .padding(.leading, 20).padding(.trailing, 16).padding(.top, 26).padding(.bottom, 8)
            } else {
                Spacer().frame(height: topSpacing)
            }
            VStack(spacing: 0) { content }
                .background(Theme.surfaceVariant, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
            if let footer {
                Text(footer).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant)
                    .padding(.horizontal, 20).padding(.top, 8)
            }
        }
    }
}

/** Dividers start where a row's text does, as on iOS. */
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.outline).frame(height: 0.5).padding(.leading, 16 + 22 + 14)
    }
}

/** Glyph, title, optional subtitle; on the right a control, or a value and a chevron when it opens something. */
struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var value: String?
    var badge: String?
    var tint: Color = Theme.onBackground
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(tint).frame(width: 22)
            Spacer().frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(title).textStyle(.bodyLarge).foregroundStyle(tint).lineLimit(1)
                    if let badge { SettingsBadge(text: badge) }
                }
                if let subtitle {
                    Text(subtitle).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(5)
                }
            }
            Spacer(minLength: 12)
            trailing
            if Trailing.self == EmptyView.self, value != nil || action != nil {
                if let value { Text(value).textStyle(.bodyLarge).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1).padding(.trailing, 4) }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil, value: String? = nil, badge: String? = nil,
         tint: Color = Theme.onBackground, action: (() -> Void)? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle, value: value, badge: badge, tint: tint, action: action) { EmptyView() }
    }
}

/** A switch row. */
struct SettingsToggle: View {
    let icon: String
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(icon: icon, title: title, subtitle: subtitle, action: { isOn.toggle() }) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(MaterialSwitch())
        }
    }
}

/** A toggle that belongs to the option above it: no icon, no divider, pulled up close. */
struct SettingsSubRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).textStyle(.bodyLarge).foregroundStyle(Theme.onBackground).lineLimit(1)
                if let subtitle { Text(subtitle).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant) }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(MaterialSwitch())
        }
        .padding(.leading, 16 + 22 + 14).padding(.trailing, 16).padding(.bottom, 10)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}

struct SettingsBadge: View {
    let text: String

    var body: some View {
        Text(text.uppercased()).textStyle(.labelSmall).foregroundStyle(Theme.onPrimary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.primary, in: Capsule())
    }
}

/** The phone's switch: a filled track and dark thumb when on, an outlined track and grey thumb when off. */
struct MaterialSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Theme.primary : Theme.surfaceContainerHigh)
                .overlay(Capsule().stroke(on ? .clear : Theme.onSurfaceVariant, lineWidth: 2))
            Circle().fill(on ? Theme.onPrimary : Theme.onSurfaceVariant)
                .frame(width: on ? 24 : 16, height: on ? 24 : 16)
                .padding(on ? 4 : 8)
        }
        .frame(width: 52, height: 32)
        .animation(.compose(dampingRatio: 0.8, stiffness: 500), value: on)
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? "On" : "Off")
    }
}

// MARK: - Settings

/** Whether the phone is on a metered connection, for the quality rows' "In use". */
@MainActor
@Observable
final class NetworkWatch {
    static let shared = NetworkWatch()
    private(set) var metered: Bool?
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let expensive = path.isExpensive
            Task { @MainActor in NetworkWatch.shared.metered = expensive }
        }
        monitor.start(queue: .global(qos: .utility))
    }
}

/**
 * Settings (SettingsSheet.kt): the rows this phone can act on, in the phone's
 * groups and order, under a field that narrows them by name.
 */
struct SettingsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(Account.self) private var account
    @Environment(AppSettings.self) private var settings
    @State private var query = ""
    @State private var imageCacheCleared = false

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings").textStyle(.displayLarge).foregroundStyle(Theme.onBackground)
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
                searchField
                if shows("Account & integrations", "account", "sign in", "google", "channel", "profile") {
                    SettingsGroup {
                        SettingsRow(icon: "person.fill", title: "Account & integrations",
                                    subtitle: account.handle ?? (account.isSignedIn ? "Signed in" : "Not signed in")) { router.push(.account) }
                    }
                }
                if shows("Sources", "quality", "On Wi-Fi", "On mobile data", "lossless", "audio quality") {
                    SettingsGroup(header: "Audio quality") {
                        if shows("Sources", "source", "addon", "lossless") {
                            SettingsRow(icon: "puzzlepiece.extension.fill", title: "Sources",
                                        subtitle: "Where audio comes from and the order used") { router.push(.sources) }
                            SettingsDivider()
                        }
                        qualityRow(icon: "wifi", title: "On Wi-Fi", selection: $settings.audioQualityWifi, inUse: NetworkWatch.shared.metered == false)
                        SettingsDivider()
                        qualityRow(icon: "cellularbars", title: "On mobile data", selection: $settings.audioQualityCellular, inUse: NetworkWatch.shared.metered == true)
                    }
                }
                if shows("Loudness normalization", "volume", "level", "speaker") {
                    SettingsGroup(header: "Playback") {
                        SettingsToggle(icon: "speaker.wave.2.fill", title: "Loudness normalization",
                                       subtitle: "Levels every track to the same loudness", isOn: $settings.loudnessNormalization)
                        if settings.loudnessNormalization {
                            SettingsSubRow(title: "Disable on Phone Speaker", isOn: $settings.loudnessOffOnSpeaker)
                        }
                    }
                }
                if shows("Reduce dynamic blur", "Synced lyrics", "Blur unfocused lyrics", "appearance", "lyrics", "glass") {
                    SettingsGroup(header: "Appearance") {
                        if shows("Reduce dynamic blur", "blur", "glass", "frosted") {
                            SettingsToggle(icon: "drop.halffull", title: "Reduce dynamic blur",
                                           subtitle: "Swaps frosted glass for solid fills across the app", isOn: $settings.reduceDynamicBlur)
                            SettingsDivider()
                        }
                        if shows("Synced lyrics", "Blur unfocused lyrics", "lyrics") {
                            SettingsToggle(icon: "sparkles", title: "Synced lyrics",
                                           subtitle: "Lights up the words on the player as they’re sung", isOn: $settings.syncedLyrics)
                            if settings.syncedLyrics {
                                SettingsDivider()
                                SettingsToggle(icon: "text.alignleft", title: "Blur unfocused lyrics",
                                               subtitle: "Keeps the spotlight on the current line", isOn: $settings.lyricsBlur)
                            }
                        }
                    }
                }
                if shows("Clear image cache", "storage", "cache", "artwork") {
                    SettingsGroup(header: "Storage") {
                        SettingsRow(icon: "trash", title: "Clear image cache",
                                    subtitle: imageCacheCleared ? "Cleared" : "Frees space used by album artwork") {
                            ImageLoader.shared.clear()
                            imageCacheCleared = true
                        }
                    }
                }
                miscellaneous
                if shows("Show stats for nerds", "advanced", "codec", "bitrate", "nerd") {
                    SettingsGroup(header: "Advanced & experimental options") {
                        SettingsToggle(icon: "chart.bar.fill", title: "Show stats for nerds",
                                       subtitle: "Codec, bitrate and client on the player", isOn: $settings.showNerdStats)
                    }
                }
                Text(Self.version).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity).padding(.top, 28)
            }
            .padding(.top, Metrics.contentTop)
            .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private var miscellaneous: some View {
        @Bindable var settings = settings
        let rows: [(String, String, String, ReferenceWritableKeyPath<AppSettings, Bool>, [String])] = [
            ("text.line.first.and.arrowtriangle.forward", "Play next on swipe",
             settings.playNextOnSwipe ? "Swiping a song plays it next" : "When disabled, swiping adds the song to the end of the queue",
             \.playNextOnSwipe, ["swipe", "queue"]),
            ("clock.arrow.circlepath", "Don’t repeat songs in current session",
             "AutoPlay won’t suggest a song already played or suggested this session", \.dontRepeatSongs, ["autoplay", "repeat"]),
            ("speaker.slash.fill", "Hide volume bar", "Removes the volume slider from the main player", \.hideVolumeBar, ["volume"]),
            ("rectangle.slash", "Hide status bar in player",
             "Hides the clock, battery and notification icons while the main player is open", \.hideStatusBarInPlayer, ["status bar", "clock"]),
            ("list.bullet.rectangle", "Show queue history",
             "Show up to 25 previously played songs above Now playing in the queue", \.showQueueHistory, ["queue", "history"]),
            ("eye.slash.fill", "Hide Song Status", "Hides the “Playing from” text in the main player", \.hideSongStatus, ["playing from"]),
        ]
        let shown = rows.filter { shows($0.1, $0.4) }
        if !shown.isEmpty {
            SettingsGroup(header: "Miscellaneous") {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, row in
                    if index > 0 { SettingsDivider() }
                    SettingsToggle(icon: row.0, title: row.1, subtitle: row.2, isOn: Binding(
                        get: { settings[keyPath: row.3] }, set: { settings[keyPath: row.3] = $0 }))
                }
            }
        }
    }

    private func qualityRow(icon: String, title: String, selection: Binding<AudioQuality>, inUse: Bool) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(AudioQuality.allCases, id: \.self) { quality in
                    Text("\(quality.label) — \(quality.detail)").tag(quality)
                }
            }
        } label: {
            SettingsRow(icon: icon, title: title, subtitle: selection.wrappedValue.detail, value: selection.wrappedValue.label,
                        badge: inUse ? "In use" : nil, action: {})
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Theme.onSurfaceVariant)
            TextField("", text: $query, prompt: Text("Search settings").foregroundStyle(Theme.onSurfaceVariant))
                .textStyle(.bodyLarge).foregroundStyle(Theme.onBackground)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onSurfaceVariant)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(Theme.surfaceVariant, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20).padding(.bottom, 4)
    }

    /** Whether a row survives the search: its title or any word it answers to contains every typed word. */
    private func shows(_ title: String, _ keywords: String...) -> Bool { shows(title, keywords) }

    private func shows(_ title: String, _ keywords: [String]) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = ([title] + keywords).joined(separator: " ").lowercased()
        return words.allSatisfy(haystack.contains)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "BitChord \(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }
}

// MARK: - Account & integrations

/** Who is signed in, which profile is listening, and the way out (AccountAndScrobblingScreen). */
struct AccountPage: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(Account.self) private var account

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Account & integrations").textStyle(.displayLarge).foregroundStyle(Theme.onBackground)
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
                SettingsGroup(footer: account.isSignedIn ? "A Google account can have Personal and Brand profiles. Each has its own library, likes and history." : nil,
                              topSpacing: 0) {
                    card
                    if account.isSignedIn {
                        Rectangle().fill(Theme.outline).frame(height: 0.5)
                        SettingsRow(icon: "person.2.fill", title: "Listen as",
                                    subtitle: account.name ?? "YouTube Music default profile") { router.accountPopup = true }
                        Rectangle().fill(Theme.outline).frame(height: 0.5)
                        Button { account.signOut() } label: {
                            Text("Sign out").textStyle(.bodyLarge).foregroundStyle(Color(hex: 0xFF453A))
                                .frame(maxWidth: .infinity).frame(minHeight: 52)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, Metrics.contentTop)
            .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
        }
    }

    private var card: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.surfaceContainerHigh)
                if let photo = account.photo {
                    RemoteImage(url: URL(string: photo)).clipShape(Circle())
                } else {
                    Image(systemName: "person.fill").font(.system(size: 22)).foregroundStyle(Theme.onSurfaceVariant)
                }
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.isSignedIn ? (account.name ?? "YouTube Music") : "Sign in").textStyle(.titleMedium).foregroundStyle(Theme.onBackground)
                Text(account.isSignedIn ? "Signed in as \(account.active?.email ?? account.handle ?? "")" : "Tap to sign in")
                    .textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))
        }
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture {
            if account.isSignedIn { router.accountPopup = true } else { account.presentSignIn = true }
        }
    }
}

/**
 * "Switch account" (AccountProfileSelector): every login's channels, the one
 * listening ticked, then Add account, Manage accounts and Settings, on a
 * frosted panel under the top bar.
 */
struct AccountPopup: View {
    var onDismiss: () -> Void
    @Environment(Router.self) private var router
    @Environment(Account.self) private var account
    @State private var managing = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.48).ignoresSafeArea().onTapGesture(perform: onDismiss)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Switch account").textStyle(.titleLarge).foregroundStyle(Theme.onSurface)
                        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
                    ForEach(account.accounts) { login in
                        Text(login.email ?? login.activeProfile?.name ?? "Accounts").textStyle(.labelLarge).foregroundStyle(Theme.onSurfaceVariant)
                            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                        ForEach(login.profiles.isEmpty ? [placeholder(login)] : login.profiles) { profile in
                            profileRow(login, profile)
                        }
                    }
                    action("plus", "Add account") {
                        onDismiss()
                        account.presentSignIn = true
                    }
                    action("person.2.badge.gearshape", "Manage accounts") { managing.toggle() }
                    action("gearshape", "Settings") {
                        onDismiss()
                        router.push(.settings)
                    }
                    Spacer().frame(height: 6)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
            .background { FrostedBackground(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)) }
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 0.5))
            .padding(.top, Metrics.topBarHeight + 4)
            .padding(.horizontal, 20)
        }
        .task { await account.loadChannels() }
    }

    private func placeholder(_ login: GoogleAccount) -> AccountProfile {
        AccountProfile(id: "own", name: login.email ?? "YouTube Music", handle: "", avatar: nil, pageId: nil, dataSyncId: nil, isBrand: false)
    }

    private func profileRow(_ login: GoogleAccount, _ profile: AccountProfile) -> some View {
        let selected = login.id == account.activeAccountId && profile.id == (login.activeProfile?.id ?? "own")
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.surfaceContainerHigh)
                if let avatar = profile.avatar {
                    RemoteImage(url: URL(string: avatar)).clipShape(Circle())
                } else {
                    Image(systemName: "person.fill").font(.system(size: 18)).foregroundStyle(Theme.onSurfaceVariant)
                }
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).textStyle(.bodyLarge).foregroundStyle(Theme.onSurface).lineLimit(1)
                Text(profile.handle.nonBlank ?? (profile.isBrand ? "Brand account" : "Personal"))
                    .font(.sfDisplay(12, .regular)).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
            }
            Spacer(minLength: 0)
            if managing {
                Text("Sign out").textStyle(.bodyLarge).foregroundStyle(Color(hex: 0xFF453A))
            } else if selected {
                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                    .accessibilityLabel("Selected account")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .onTapGesture {
            if managing {
                account.signOut(login.id)
                onDismiss()
            } else {
                account.select(account: login.id, profile: profile.id)
                onDismiss()
            }
        }
    }

    private func action(_ icon: String, _ title: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 24)
            Text(title).textStyle(.bodyLarge)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.onSurface)
        .padding(.horizontal, 20)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .onTapGesture(perform: perform)
    }
}
