import SwiftUI

/**
 * The first-run welcome (OnboardingScreen): what to call you, then connecting
 * a YouTube account or skipping it. The phone drifts and cycles the mesh
 * behind it; here it is the palette's still frame.
 */
struct OnboardingView: View {
    @Environment(Account.self) private var account
    @Environment(AppSettings.self) private var settings
    @State private var page = 0
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if page == 0 {
                    StaticMesh(scrim: (0.05, 0.45))
                } else {
                    // ConnectPalettes' first: YouTube's red.
                    StaticMesh(colors: [Color(hex: 0xFF1E3C), Color(hex: 0xC2185B), Color(hex: 0xFF8F3D), Color(hex: 0x4A1C8C)],
                               base: Color(hex: 0x3A0710), scrim: (0.05, 0.45))
                }
            }
            .ignoresSafeArea()
            .transition(.opacity.animation(.linear(duration: 0.4)))
            Group {
                if page == 0 { namePage.transition(slide(forward: true)) } else { connectPage.transition(slide(forward: false)) }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 28)
        }
        .contentShape(Rectangle())
        .onTapGesture { nameFocused = false }
        .onAppear { name = settings.nickname }
        .onChange(of: account.isSignedIn) { _, signedIn in if signedIn, page == 1 { finish() } }
        .environment(\.colorScheme, .dark)
    }

    private func slide(forward: Bool) -> AnyTransition {
        .asymmetric(insertion: .offset(x: forward ? -120 : 120).combined(with: .opacity),
                    removal: .offset(x: forward ? -120 : 120).combined(with: .opacity))
    }

    private var namePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !nameFocused {
                Image("Logo").resizable().renderingMode(.template).scaledToFit().foregroundStyle(.white)
                    .frame(width: 46, height: 30)
                    .padding(.top, 56)
            }
            title("Millions of songs, stream on BitChord").padding(.top, 24)
            Spacer()
            Text("What should we call you?").font(.sfDisplay(17, .semibold)).foregroundStyle(.white.opacity(0.78)).padding(.leading, 4)
            TextField("", text: $name, prompt: Text("Your name").foregroundStyle(.white.opacity(0.38)))
                .font(.sfDisplay(26, .heavy)).tracking(-0.6).foregroundStyle(.white)
                .textInputAutocapitalization(.words).autocorrectionDisabled()
                .submitLabel(.next)
                .focused($nameFocused)
                .onSubmit(next)
                .onChange(of: name) { _, value in if value.count > 40 { name = String(value.prefix(40)) } }
                .padding(.horizontal, 24)
                .frame(height: 64)
                .background(.white.opacity(0.14), in: Capsule())
                .padding(.top, 12)
            Text("Friends see this when you Listen Together. You can change it later in Settings.")
                .textStyle(.bodyMedium).foregroundStyle(.white.opacity(0.55)).padding(.horizontal, 4).padding(.top, 10)
            pill("Next", primary: true, enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty, action: next).padding(.top, 28)
            Spacer().frame(height: 16)
        }
        .animation(.fastOutSlowIn(0.25), value: nameFocused)
    }

    private var connectPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.fastOutSlowIn(0.42)) { page = 0 } } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .padding(.top, 16)
            title("Connect your YouTube account").padding(.top, 20)
            Text("Bring your library, playlists and mixes with you, and start a Listen Together party with friends.")
                .font(.sfDisplay(17, .regular)).lineSpacing(6).foregroundStyle(.white.opacity(0.72)).padding(.top, 14)
            Spacer()
            pill("Sign in with Google", primary: true) { account.presentSignIn = true }
            pill("Skip sign in", primary: false, action: finish).padding(.top, 12)
            Spacer().frame(height: 16)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.sfDisplay(40, .heavy)).tracking(-1.2).lineSpacing(4).foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pill(_ label: String, primary: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if label == "Sign in with Google" {
                    Text("G").font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [Color(hex: 0x4285F4), Color(hex: 0xEA4335), Color(hex: 0xFBBC05), Color(hex: 0x34A853)],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 20, height: 20)
                }
                Text(label).font(.sfDisplay(17, .bold)).foregroundStyle(primary ? .black : .white).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(primary ? .white : .white.opacity(0.16), in: Capsule())
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(PressScale(scale: 0.97))
        .disabled(!enabled)
    }

    private func next() {
        let chosen = name.trimmingCharacters(in: .whitespaces)
        guard !chosen.isEmpty else { return }
        nameFocused = false
        settings.nickname = chosen
        if account.isSignedIn { finish() } else { withAnimation(.fastOutSlowIn(0.42)) { page = 1 } }
    }

    private func finish() {
        settings.onboardingComplete = true
    }
}
