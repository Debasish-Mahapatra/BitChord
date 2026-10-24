import SwiftUI
import WebKit

/**
 * In-app Google sign-in (YtMusicLoginScreen.kt): Google's own login page with
 * `continue=music.youtube.com`. Reaching YouTube Music only enables "Done" —
 * a multi-channel account still gets to pick its channel on that page — and
 * the session is read when the listener says so, from the page's own ytcfg.
 */
struct SignInView: View {
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var ready = false
    @State private var captureRequest = 0
    @State private var failed = false

    var body: some View {
        NavigationStack {
            SignInWebView(captureRequest: captureRequest, ready: $ready) { session in
                if let session {
                    account.signIn(session)
                    dismiss()
                } else {
                    failed = true
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { captureRequest += 1 }.disabled(!ready)
                }
            }
            .alert("Not signed in yet", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Finish signing in to YouTube Music on this page, then tap Done.")
            }
        }
    }
}

private struct SignInWebView: UIViewRepresentable {
    static let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&prompt=select_account&continue=https%3A%2F%2Fmusic.youtube.com%2F")!
    static let musicOrigin = "https://music.youtube.com"
    /** Safari's own identity: Google turns away sign-in from an agent that reads as an embedded view. */
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"

    let captureRequest: Int
    @Binding var ready: Bool
    let onCaptured: (Session?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        // A fresh, non-persistent jar: signing in again never reuses or logs out another session.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: Self.loginURL))
        context.coordinator.webView = view
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if captureRequest != context.coordinator.handledRequest {
            context.coordinator.handledRequest = captureRequest
            context.coordinator.capture()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SignInWebView
        weak var webView: WKWebView?
        var handledRequest = 0

        init(_ parent: SignInWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.ready = webView.url?.absoluteString.hasPrefix(SignInWebView.musicOrigin) == true
        }

        /** The page's identity (ytcfg) and the cookie jar, or nil when there's no signed-in session yet. */
        @MainActor
        func capture() {
            guard let webView else { return }
            let probe = """
            (function () {
              try {
                if (!window.ytcfg || !window.ytcfg.get) return null;
                var get = function (k) { var v = window.ytcfg.get(k); return (v === undefined || v === null || v === '') ? null : String(v); };
                return JSON.stringify({ loggedIn: String(!!window.ytcfg.get('LOGGED_IN')), pageId: get('DELEGATED_SESSION_ID'),
                  dataSyncId: get('DATASYNC_ID'), authUser: get('SESSION_INDEX'), visitorData: get('VISITOR_DATA'),
                  clientVersion: get('INNERTUBE_CLIENT_VERSION') });
              } catch (e) { return null; }
            })()
            """
            webView.evaluateJavaScript(probe) { [weak self] result, _ in
                guard let self else { return }
                guard let text = result as? String, let config = try? JSON(data: Data(text.utf8)),
                      config["loggedIn"].string == "true" else {
                    self.parent.onCaptured(nil)
                    return
                }
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let youtube = cookies.filter { $0.domain.hasSuffix("youtube.com") }
                    let header = youtube.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    let pageId = config["pageId"].string
                    var session = Session(cookie: header,
                                          dataSyncId: pageId ?? InnertubeParser.normalizeDataSyncId(config["dataSyncId"].string),
                                          pageId: pageId,
                                          authUser: config["authUser"].string,
                                          visitorData: config["visitorData"].string,
                                          clientVersion: config["clientVersion"].string)
                    if session.sapisid == nil { session.cookie = "" }
                    self.parent.onCaptured(session.cookie.isEmpty ? nil : session)
                }
            }
        }

        /** DataSyncId.kt: the part after "||" when there is one, else the part before it. */
    }
}
