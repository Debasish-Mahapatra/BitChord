import CryptoKit
import Foundation
import Observation
import Security

/**
 * A signed-in YouTube Music session (AuthStore / CapturedSession): the cookie
 * jar the in-app Google sign-in left, and which identity the page was acting
 * as. Kept in the Keychain; the credential itself never passes through here.
 */
struct Session: Codable, Sendable {
    var cookie: String
    var dataSyncId: String?
    var pageId: String?
    var authUser: String?
    var visitorData: String?
    var clientVersion: String?

    /** Which listener this is: the login and the channel it acts as. What a page reloads on. */
    var key: String { cookie + "|" + (pageId ?? dataSyncId ?? "") }

    /** SAPISID (or its __Secure- forms): what signs a request. */
    var sapisid: String? {
        let pairs = cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for name in ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"] {
            if let pair = pairs.first(where: { $0.hasPrefix(name + "=") }) { return String(pair.dropFirst(name.count + 1)) }
        }
        return nil
    }

    /** `SAPISIDHASH <ts>_<sha1(ts SAPISID origin)>`, as DesktopYouTubeAuth / the extension sign it. */
    func authorization(origin: String) -> String? {
        guard let sapisid else { return nil }
        let timestamp = Int(Date().timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(origin)".utf8))
        return "SAPISIDHASH \(timestamp)_" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

/** A channel one login can act as (YouTubeProfile): its own, or a brand channel. */
struct AccountProfile: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var handle: String
    var avatar: String?
    var pageId: String?
    var dataSyncId: String?
    var isBrand: Bool
}

/** One Google login (GoogleAccountSession): its cookie and the channels it has been seen to act as. */
struct GoogleAccount: Codable, Identifiable, Sendable {
    var id: String
    var session: Session
    var email: String?
    var profiles: [AccountProfile]
    var activeProfileId: String?

    var activeProfile: AccountProfile? { profiles.first { $0.id == activeProfileId } ?? profiles.first }
}

@MainActor
@Observable
final class Account {
    static let shared = Account()

    private(set) var accounts: [GoogleAccount] = []
    private(set) var activeAccountId: String?
    var presentSignIn = false

    private init() {
        if let stored = Keychain.read() {
            accounts = stored.accounts
            activeAccountId = stored.active
        }
        Innertube.setSession(session)
        if session != nil { Task { await refreshProfile() } }
    }

    var active: GoogleAccount? { accounts.first { $0.id == activeAccountId } }

    /** The login's cookie, acting as the selected channel. */
    var session: Session? {
        guard let account = active else { return nil }
        var session = account.session
        if let profile = account.activeProfile {
            session.pageId = profile.isBrand ? profile.pageId : nil
            session.dataSyncId = profile.dataSyncId ?? session.dataSyncId
        }
        return session
    }

    var isSignedIn: Bool { session != nil }
    var name: String? { active?.activeProfile?.name.nonBlank }
    var handle: String? { active?.activeProfile?.handle.nonBlank ?? active?.email }
    var photo: String? { active?.activeProfile?.avatar }

    /** A sign-in: a new login is added and made active; the same login again replaces its cookie. */
    func signIn(_ captured: Session) {
        let id = captured.dataSyncId?.components(separatedBy: "||").first?.nonBlank ?? String(captured.cookie.hashValue)
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].session = captured
        } else {
            accounts.append(GoogleAccount(id: id, session: captured, profiles: [], activeProfileId: nil))
        }
        activeAccountId = id
        apply()
        Task {
            await refreshProfile()
            await loadChannels()
        }
    }

    /** Signs out of [accountId] (the active one by default); another login, if any, takes over. */
    func signOut(_ accountId: String? = nil) {
        let id = accountId ?? activeAccountId
        accounts.removeAll { $0.id == id }
        if activeAccountId == id { activeAccountId = accounts.first?.id }
        apply()
    }

    func select(account accountId: String, profile profileId: String) {
        guard let index = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        guard accountId != activeAccountId || profileId != accounts[index].activeProfileId else { return }
        accounts[index].activeProfileId = profileId
        activeAccountId = accountId
        apply()
    }

    /** Hands the effective session to the requests and drops what belonged to the last listener. */
    private func apply() {
        Keychain.write(.init(accounts: accounts, active: activeAccountId))
        Innertube.setSession(session)
        Likes.shared.reset()
        TrackLinks.shared.reset()
    }

    /** The active channel's name, handle and photo off `account/account_menu` (parseAccount). */
    func refreshProfile() async {
        guard let accountId = activeAccountId,
              let response = try? await Innertube.shared.accountMenu(),
              let header = response.collect("activeAccountHeaderRenderer").first,
              let index = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        let name = header["accountName"].runs.nonBlank ?? "YouTube Music"
        let handle = header["channelHandle"].runs.nonBlank ?? ""
        let email = header["email"].runs.nonBlank
        let avatar = header["accountPhoto"]["thumbnails"].bestThumbnail
        if let email { accounts[index].email = email }
        var account = accounts[index]
        if let profile = account.activeProfile, let at = account.profiles.firstIndex(of: profile) {
            account.profiles[at].name = name
            account.profiles[at].avatar = avatar ?? profile.avatar
            if !handle.isEmpty { account.profiles[at].handle = handle }
        } else {
            let own = AccountProfile(id: "own", name: name, handle: handle, avatar: avatar, pageId: nil, dataSyncId: account.session.dataSyncId, isBrand: false)
            account.profiles = [own]
            account.activeProfileId = own.id
        }
        accounts[index] = account
        // Signing in again to the same Google account replaces the older login.
        if let email { accounts.removeAll { $0.id != accountId && $0.email == email } }
        Keychain.write(.init(accounts: accounts, active: activeAccountId))
    }

    /** The channels this login can act as (accountChannels): its own first, then any brand channels. */
    func loadChannels() async {
        guard let accountId = activeAccountId, let response = try? await Innertube.shared.accountsList() else { return }
        let channels = InnertubeParser.parseAccountChannels(response)
        guard !channels.isEmpty, let index = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        var account = accounts[index]
        let activeName = account.activeProfile?.name
        account.profiles = channels
        if account.activeProfileId == nil || !channels.contains(where: { $0.id == account.activeProfileId }) {
            account.activeProfileId = (channels.first { $0.name == activeName } ?? channels.first)?.id
        }
        accounts[index] = account
        Keychain.write(.init(accounts: accounts, active: activeAccountId))
    }
}

/** One generic-password item holding every login and which one is active. */
private enum Keychain {
    static let service = "com.personal.bitchord.session"

    struct Stored: Codable {
        var accounts: [GoogleAccount]
        var active: String?
    }

    static func read() -> Stored? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        if let stored = try? JSONDecoder().decode(Stored.self, from: data) { return stored }
        // A single session from before there could be several.
        guard let session = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
        let id = session.dataSyncId?.components(separatedBy: "||").first?.nonBlank ?? "account"
        return Stored(accounts: [GoogleAccount(id: id, session: session, profiles: [], activeProfileId: nil)], active: id)
    }

    static func write(_ stored: Stored) {
        delete()
        guard !stored.accounts.isEmpty, let data = try? JSONEncoder().encode(stored) else { return }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
