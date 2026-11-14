import Foundation

// Pure pieces of `messages export` / `messages latest`, which read Messages' chat.db.
extension MacCLICore {

    /// The plain text inside a message's `attributedBody`: on macOS 11+ `message.text` is
    /// often NULL and the body is a typedstream-archived NSAttributedString. After the
    /// preamble the string is `NSString 01 <94…97> 84 01 2B <length> <UTF-8 bytes>`, the
    /// length one byte (< 0x80), or 0x81 + UInt16 LE, or 0x82 + UInt32 LE. Nil when the
    /// blob holds no string or is cut short.
    public static func attributedBodyText(_ blob: [UInt8]) -> String? {
        let marker: [UInt8] = Array("NSString".utf8) + [0x01]
        guard blob.count > marker.count + 4 else { return nil }
        var i = 0
        while i + marker.count + 4 <= blob.count {
            if Array(blob[i..<(i + marker.count)]) == marker,
               (0x94...0x97).contains(blob[i + marker.count]),
               blob[i + marker.count + 1] == 0x84, blob[i + marker.count + 2] == 0x01,
               blob[i + marker.count + 3] == 0x2B {
                return lengthPrefixedText(blob, at: i + marker.count + 4)
            }
            i += 1
        }
        return nil
    }

    static func lengthPrefixedText(_ blob: [UInt8], at start: Int) -> String? {
        guard start < blob.count else { return nil }
        var pos = start
        let length: Int
        switch blob[pos] {
        case 0x81:
            guard pos + 3 <= blob.count else { return nil }
            length = Int(blob[pos + 1]) | Int(blob[pos + 2]) << 8
            pos += 3
        case 0x82:
            guard pos + 5 <= blob.count else { return nil }
            length = (0..<4).reduce(0) { $0 | Int(blob[pos + 1 + $1]) << (8 * $1) }
            pos += 5
        default:
            length = Int(blob[pos])
            pos += 1
        }
        let end = min(pos + length, blob.count)
        let text = String(decoding: blob[pos..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// chat.db's `message.date`: nanoseconds since 2001-01-01 UTC (seconds before High Sierra).
    public static func messagesDate(_ raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
