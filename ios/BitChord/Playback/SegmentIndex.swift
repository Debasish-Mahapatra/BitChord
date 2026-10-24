import Foundation

/**
 * The `sidx` box of a YouTube DASH audio file, turned into an HLS playlist.
 *
 * ExoPlayer reads these files as they are. AVPlayer doesn't use the index of
 * a progressive fragmented MP4: it guesses time from byte position, and
 * YouTube's init segment states the full duration in the (empty) movie box as
 * well, so it reported every track at twice its length and seeked to the
 * wrong place. Read as HLS — the init segment as EXT-X-MAP, each indexed
 * subsegment as one bounded googlevideo range — the same bytes, fetched in the
 * same bounded pieces, play with exact timing.
 */
struct SegmentIndex: Sendable {
    struct Segment: Sendable {
        let offset: Int64
        let size: Int64
        let duration: Double
    }

    let initRange: ClosedRange<Int64>
    let segments: [Segment]

    var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    enum ParseError: Error { case noIndex }

    /**
     * Parses the first `sidx` at or after [indexOffset] in [data] (the file's
     * first bytes). Without a stated [initRange], everything before the index is the init segment.
     */
    static func parse(_ data: Data, initRange: ClosedRange<Int64>?, indexOffset: Int64) throws -> SegmentIndex {
        let bytes = [UInt8](data)
        var cursor = Int(indexOffset)
        func u32(_ at: Int) -> UInt64 {
            UInt64(bytes[at]) << 24 | UInt64(bytes[at + 1]) << 16 | UInt64(bytes[at + 2]) << 8 | UInt64(bytes[at + 3])
        }
        func u64(_ at: Int) -> UInt64 { u32(at) << 32 | u32(at + 4) }

        // Find the sidx box at or after the stated offset.
        while cursor + 8 <= bytes.count {
            let size = Int(u32(cursor))
            let type = String(bytes: bytes[(cursor + 4)..<(cursor + 8)], encoding: .ascii)
            if type == "sidx" { break }
            guard size > 0 else { throw ParseError.noIndex }
            cursor += size
        }
        guard cursor + 32 <= bytes.count else { throw ParseError.noIndex }
        let boxStart = cursor
        let boxSize = Int(u32(boxStart))
        let version = bytes[boxStart + 8]
        let timescale = Double(u32(boxStart + 16))
        var q = boxStart + 20
        let firstOffset: UInt64
        if version == 0 {
            firstOffset = u32(q + 4)
            q += 8
        } else {
            firstOffset = u64(q + 8)
            q += 16
        }
        let count = Int(UInt16(bytes[q + 2]) << 8 | UInt16(bytes[q + 3]))
        q += 4
        guard timescale > 0, q + count * 12 <= bytes.count else { throw ParseError.noIndex }

        var offset = Int64(boxStart + boxSize) + Int64(firstOffset)
        var segments: [Segment] = []
        segments.reserveCapacity(count)
        for i in 0..<count {
            let at = q + i * 12
            let size = Int64(u32(at) & 0x7FFF_FFFF)
            let duration = Double(u32(at + 4)) / timescale
            segments.append(Segment(offset: offset, size: size, duration: duration))
            offset += size
        }
        guard !segments.isEmpty, boxStart > 0 else { throw ParseError.noIndex }
        return SegmentIndex(initRange: initRange ?? 0...Int64(boxStart - 1), segments: segments)
    }

    /** A VOD media playlist whose every URI is [stream]'s URL with a bounded `range`. */
    func playlist(for stream: ResolvedStream) -> String {
        let target = Int((segments.map(\.duration).max() ?? 10).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(stream.url(for: initRange).absoluteString)\"",
        ]
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append(stream.url(for: segment.offset...(segment.offset + segment.size - 1)).absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
