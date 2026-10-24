import AVFoundation
import Observation

/**
 * Where the music is coming out (rememberOutputGlyph, AudioOutputLabels.kt):
 * the phone, buds, a speaker, the car — drawn and named as the thing itself,
 * the way Apple Music's AirPlay button does, rather than headphones whatever
 * is actually playing it.
 */
@MainActor
@Observable
final class AudioOutput {
    static let shared = AudioOutput()

    private(set) var port: AVAudioSession.Port = .builtInSpeaker
    private(set) var portName = ""

    private init() {
        read()
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AudioOutput.shared.read() }
        }
    }

    private func read() {
        let output = AVAudioSession.sharedInstance().currentRoute.outputs.first
        port = output?.portType ?? .builtInSpeaker
        portName = output?.portName ?? ""
    }

    /** The SF Symbol for the device. A Bluetooth device that won't say what it is gets headphones, not a guess. */
    var glyph: String {
        switch port {
        case .builtInSpeaker, .builtInReceiver: return "iphone"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            let name = portName.lowercased()
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") || name.contains("buds") || name.contains("earbuds") { return "airpods" }
            if name.contains("homepod") { return "homepod.fill" }
            if name.contains("speaker") || name.contains("boom") || name.contains("flip") || name.contains("charge") { return "hifispeaker.fill" }
            if name.contains("car") { return "car.fill" }
            return "headphones"
        case .carAudio: return "car.fill"
        case .airPlay: return "airplay.audio"
        case .HDMI: return "tv"
        case .headphones, .usbAudio, .lineOut: return "headphones"
        default: return "hifispeaker.fill"
        }
    }

    /**
     * What to call it under the transport. Bluetooth, AirPlay and USB devices
     * keep their own names; the phone's speaker is the listener's phone.
     */
    func label(accountName: String?) -> String {
        switch port {
        case .headphones: return "Wired headphones"
        case .HDMI: return "HDMI"
        case .builtInSpeaker, .builtInReceiver:
            if let first = accountName?.split(whereSeparator: \.isWhitespace).first { return "\(first)’s Phone" }
            return "This phone"
        default:
            if !portName.isEmpty { return portName }
            return port == .usbAudio ? "USB audio" : "This phone"
        }
    }
}
