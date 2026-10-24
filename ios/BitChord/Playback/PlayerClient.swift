import Foundation

/**
 * An identity the player request is made as — InnerTubeX's `YouTubeClient`
 * and its catalog entry, for the clients this engine walks. Order and
 * properties follow PlaybackClientCatalog.kt (v0.7.0): VISIONOS_0_1 is the
 * automatic first choice, VISIONOS 1.02 the probe-only twin the web player
 * leads with, and the Android VR profiles last, on their narrower ranges.
 */
struct PlayerClient: Hashable, Sendable {
    /** The catalog id exclusions key on. */
    let id: String
    let clientName: String
    let clientVersion: String
    let clientId: String
    let userAgent: String
    let osName: String?
    let osVersion: String?
    let deviceMake: String?
    let deviceModel: String?
    let platform: String?
    let androidSdkVersion: Int?
    /** Player requests go to music.youtube.com rather than www. */
    let useMusicPlayerEndpoint: Bool

    static let visionOS01 = PlayerClient(
        id: "VISIONOS_0_1", clientName: "VISIONOS", clientVersion: "0.1", clientId: "101",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
        osName: "VISION_OS", osVersion: "1.3", deviceMake: "Apple", deviceModel: "RealityDevice14,1",
        platform: "MOBILE", androidSdkVersion: nil, useMusicPlayerEndpoint: true)

    static let visionOS = PlayerClient(
        id: "VISIONOS", clientName: "VISIONOS", clientVersion: "1.02", clientId: "101",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        osName: "visionOS", osVersion: "26.5.23O471", deviceMake: "Apple", deviceModel: "RealityDevice17,1",
        platform: nil, androidSdkVersion: nil, useMusicPlayerEndpoint: true)

    static let androidVR143 = PlayerClient(
        id: "ANDROID_VR_1_43_32", clientName: "ANDROID_VR", clientVersion: "1.43.32", clientId: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.43.32 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)",
        osName: "Android", osVersion: "12", deviceMake: "Oculus", deviceModel: "Quest 3",
        platform: nil, androidSdkVersion: 32, useMusicPlayerEndpoint: false)

    static let androidVR165 = PlayerClient(
        id: "ANDROID_VR_1_65_10", clientName: "ANDROID_VR", clientVersion: "1.65.10", clientId: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        osName: "Android", osVersion: "12L", deviceMake: "Oculus", deviceModel: "Quest 3",
        platform: nil, androidSdkVersion: 32, useMusicPlayerEndpoint: false)

    /** The walk, best first: the catalog's priorities for the direct-URL clients that need no token. */
    static let catalog: [PlayerClient] = [.visionOS01, .visionOS, .androidVR143, .androidVR165]

    /**
     * Headers the media fetch must carry (InnerTubeExtractor.buildHeaders):
     * VISIONOS and ANDROID_VR fetch bare — googlevideo compares what comes back
     * against the client that minted the URL, and these send nothing.
     */
    var mediaHeaders: [String: String] {
        clientName == "VISIONOS" || clientName == "ANDROID_VR" ? [:] : ["User-Agent": userAgent, "Accept": "*/*"]
    }

    /** Largest single range googlevideo reliably serves this client (mediaRangeChunkSize). */
    var rangeBytes: Int64 { clientName == "ANDROID_VR" ? 512 * 1024 : 1024 * 1024 }

    func context(visitorData: String?) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "hl": Innertube.language,
            "gl": Innertube.region,
        ]
        if let osName { client["osName"] = osName }
        if let osVersion { client["osVersion"] = osVersion }
        if let deviceMake { client["deviceMake"] = deviceMake }
        if let deviceModel { client["deviceModel"] = deviceModel }
        if let platform { client["platform"] = platform }
        if let androidSdkVersion { client["androidSdkVersion"] = androidSdkVersion }
        if let visitorData { client["visitorData"] = visitorData }
        return ["client": client, "user": [String: Any]()]
    }
}
