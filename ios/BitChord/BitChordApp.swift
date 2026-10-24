import AVFoundation
import SwiftUI

@main
struct BitChordApp: App {
    @State private var player = PlayerModel.shared
    @State private var router = Router.shared
    @State private var account = Account.shared
    @State private var lyrics = LyricsModel.shared
    @State private var settings = AppSettings.shared

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(player)
                .environment(router)
                .environment(account)
                .environment(lyrics)
                .environment(settings)
                .tint(Theme.primary)
                // The phone's default theme is dark.
                .preferredColorScheme(.dark)
        }
    }
}
