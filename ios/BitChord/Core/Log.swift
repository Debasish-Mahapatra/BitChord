import Foundation
import os

/** TrackLog's equivalent: one subsystem, the track's id alongside when there is one. */
enum Log {
    private static let logger = Logger(subsystem: "com.personal.bitchord", category: "playback")

    static func d(_ message: String, about videoId: String? = nil) {
        let line = videoId.map { "[\($0)] \(message)" } ?? message
        logger.debug("\(line, privacy: .public)")
    }

    static func w(_ message: String, about videoId: String? = nil) {
        let line = videoId.map { "[\($0)] \(message)" } ?? message
        logger.warning("\(line, privacy: .public)")
    }
}
