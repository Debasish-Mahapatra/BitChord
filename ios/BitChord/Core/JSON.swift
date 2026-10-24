import Foundation

/**
 * Null-safe navigation over a decoded InnerTube response, the Swift twin of the
 * `o` / `a` / `s` helpers at the foot of InnertubeParser.kt: every step answers,
 * and a missing key reads as an empty value rather than a crash.
 */
struct JSON: @unchecked Sendable {
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = raw is NSNull ? nil : raw
    }

    init(data: Data) throws {
        self.init(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    static let null = JSON(nil)

    subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], array.indices.contains(index) else { return .null }
        return JSON(array[index])
    }

    var exists: Bool { raw != nil }
    var isObject: Bool { raw is [String: Any] }
    var object: [String: Any]? { raw as? [String: Any] }
    var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }
    var first: JSON { self[0] }
    var last: JSON { array.last ?? .null }

    /** A string, or a number or flag as written — as kotlinx's `contentOrNull`. */
    var string: String? {
        switch raw {
        case let value as String: return value
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "true" : "false" }
            return value.stringValue
        default: return nil
        }
    }

    var bool: Bool? {
        switch raw {
        case let value as NSNumber: return value.boolValue
        case let value as String: return value == "true" ? true : value == "false" ? false : nil
        default: return nil
        }
    }

    var double: Double? {
        switch raw {
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    /** `{ "runs": [{ "text": … }] }` joined, or `simpleText`, or "". */
    var runs: String {
        if let runs = self["runs"].raw as? [Any] {
            return runs.map { JSON($0)["text"].string ?? "" }.joined()
        }
        return self["simpleText"].string ?? ""
    }

    /** The first run's text alone — for a count or a label, never a sentence. */
    var firstRunText: String? {
        self["runs"].first["text"].string ?? self["simpleText"].string
    }

    /**
     * Every object under [name] anywhere in the tree, depth first. Arrays keep
     * their order; an object's own keys are walked sorted, so the result is the
     * same every time even though JSONSerialization doesn't keep key order.
     */
    func collect(_ name: String) -> [JSON] {
        var out: [JSON] = []
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if let hit = object[name] as? [String: Any] { out.append(JSON(hit)) }
                for key in object.keys.sorted() { walk(object[key]!) }
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        if let raw { walk(raw) }
        return out
    }

    /** The first string under [key] anywhere in the subtree. */
    func findString(_ key: String) -> String? {
        func walk(_ node: Any) -> String? {
            if let object = node as? [String: Any] {
                if let value = JSON(object[key]).string { return value }
                for key in object.keys.sorted() {
                    if let found = walk(object[key]!) { return found }
                }
            } else if let array = node as? [Any] {
                for item in array {
                    if let found = walk(item) { return found }
                }
            }
            return nil
        }
        return raw.flatMap(walk)
    }

    /** The last (largest) thumbnail's URL, taken as offered. */
    var bestThumbnail: String? { last["url"].string }

    /**
     * Catalogue art is square; a music-video upload's is widescreen. Missing
     * dimensions count as square so a row is never dropped for lack of them.
     */
    var isNotSquare: Bool {
        guard let width = last["width"].double, let height = last["height"].double,
              width > 0, height > 0 else { return false }
        return !(0.85...1.15).contains(width / height)
    }
}

extension String {
    var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }

    func matches(_ regex: NSRegularExpression) -> Bool {
        regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil
    }

    func wholeMatch(_ regex: NSRegularExpression) -> Bool {
        guard let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return false }
        return match.range.location == 0 && match.range.length == (self as NSString).length
    }
}

extension NSRegularExpression {
    convenience init(_ pattern: String, caseInsensitive: Bool = false) {
        try! self.init(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }
}
