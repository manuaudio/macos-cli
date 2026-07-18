import Foundation
import Compression

/// Pure, hermetically-testable helpers shared by the macos-cli commands.
///
/// Nothing here touches EventKit, Contacts, or TCC — so it can be unit-tested
/// without triggering permission prompts. The security-sensitive decisions
/// (fail-closed list filtering, the agent-safe approval gate) live here on
/// purpose, so they are covered by deterministic tests.
public enum MacCLICore {

    // MARK: - Reminders authorization

    /// Map an `EKAuthorizationStatus.rawValue` to a stable name.
    ///
    /// The mapping is by rawValue so it is identical on Ventura and on macOS 14+
    /// (where rawValue 3 becomes `.fullAccess` and 4 becomes `.writeOnly`).
    public static func authorizationStatusName(_ raw: Int) -> String {
        switch raw {
        case 0: return "notDetermined"
        case 1: return "restricted"
        case 2: return "denied"
        case 3: return "authorized"   // macOS 14 SDK: .fullAccess occupies this slot
        case 4: return "writeOnly"
        default: return "unknown"
        }
    }

    /// True only when the process can actually read reminders (authorized / fullAccess).
    public static func authorizationCanRead(_ raw: Int) -> Bool { raw == 3 }

    // MARK: - Fail-closed reminder list resolution

    public struct ListResolution: Equatable {
        /// Indices into the input title array that the filter selected.
        public let indices: [Int]
        /// True when a non-nil filter matched nothing — callers MUST return zero
        /// rows in this case and never broaden to all lists.
        public let failClosed: Bool
        public init(indices: [Int], failClosed: Bool) {
            self.indices = indices
            self.failClosed = failClosed
        }
    }

    /// Resolve a `--list` filter against the available reminder-list titles.
    ///
    /// - `nil` filter selects every list (`failClosed == false`).
    /// - A filter matches by EXACT title (all duplicates included).
    /// - A filter that matches nothing yields zero indices and `failClosed == true`.
    public static func resolveReminderLists(allTitles: [String], filter: String?) -> ListResolution {
        guard let filter = filter else {
            return ListResolution(indices: Array(allTitles.indices), failClosed: false)
        }
        let matches = allTitles.indices.filter { allTitles[$0] == filter }
        return ListResolution(indices: matches, failClosed: matches.isEmpty)
    }

    /// Apple `EKReminder.priority` band: 0 = none; 1–4 = high; 5 = medium; 6–9 = low.
    public static func priorityBand(_ priority: Int) -> String {
        switch priority {
        case 0: return "none"
        case 1...4: return "high"
        case 5: return "medium"
        default: return "low"
        }
    }

    // MARK: - Agent-safe approval-token gate

    /// The mutation gate for `reminders complete-safe`.
    ///
    /// Valid ONLY when a non-empty expected token is configured in the environment
    /// AND the supplied token equals it exactly. An unset/empty configured token can
    /// never authorize a write, even if the caller passes an empty `--approve`.
    public static func isApprovalTokenValid(supplied: String?, expected: String?) -> Bool {
        guard let supplied = supplied, let expected = expected, !expected.isEmpty else { return false }
        return supplied == expected
    }

    // MARK: - Export machine-contract error envelope

    /// Structured JSON body emitted by `reminders export` when the EventKit fetch
    /// exceeds its timeout. A timeout is a HARD error, never a silent empty result:
    /// the command prints this object on stdout AND exits non-zero, so an ingestion
    /// pipeline can distinguish "genuinely zero reminders" from "the fetch failed".
    ///
    /// Deliberately carries NO `reminders`/`count` keys — the absence of a rows array,
    /// plus `ok == false`, makes it structurally impossible to mistake for an empty
    /// successful export.
    public static func fetchTimeoutErrorJSON(timeoutSeconds: Double) -> [String: Any] {
        return [
            "ok": false,
            "status": "error",
            "error": "fetch_timeout",
            "entity": "reminder",
            "timeout_seconds": timeoutSeconds,
            "message": "Reminders fetch exceeded the \(timeoutSeconds)s timeout; the EventKit "
                + "callback did not return in time. This is a hard error, not an empty result — "
                + "do not treat it as zero reminders.",
        ]
    }

    /// Human-readable reason a mutation was withheld. Never contains any token value.
    public static func approvalDenialReason(supplied: String?, expected: String?) -> String {
        if supplied == nil {
            return "no --approve token supplied; mutation is dry-run only"
        }
        if expected == nil || expected!.isEmpty {
            return "no APPLE_EVENTKIT_APPROVE_TOKEN configured; approval token cannot be verified"
        }
        return "supplied --approve token does not match APPLE_EVENTKIT_APPROVE_TOKEN"
    }

    // MARK: - Apple Notes body decoding (Unicode-preserving)

    /// If `data` starts with the gzip magic (0x1f 0x8b) decompress it; otherwise
    /// return it unchanged. Returns nil only when a gzip stream fails to inflate.
    public static func gunzipIfNeeded(_ data: Data) -> Data? {
        guard data.count >= 2 else { return data }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b else { return data }
        guard bytes.count > 18 else { return nil }  // header(10)+trailer(8) minimum

        let flags = bytes[3]
        var idx = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard idx + 2 <= bytes.count else { return nil }
            let xlen = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2 + xlen
        }
        if flags & 0x08 != 0 {  // FNAME
            while idx < bytes.count, bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            while idx < bytes.count, bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if flags & 0x02 != 0 { idx += 2 }  // FHCRC

        let trailerStart = bytes.count - 8
        guard idx < trailerStart else { return nil }
        let deflate = Data(bytes[idx..<trailerStart])
        // ISIZE (uncompressed size mod 2^32) is a decompression-buffer size hint.
        let isize = UInt32(bytes[bytes.count - 4])
            | (UInt32(bytes[bytes.count - 3]) << 8)
            | (UInt32(bytes[bytes.count - 2]) << 16)
            | (UInt32(bytes[bytes.count - 1]) << 24)
        return inflateRaw(deflate, sizeHint: Int(isize))
    }

    private static func inflateRaw(_ data: Data, sizeHint: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        var capacity = max(sizeHint, data.count * 4, 64 * 1024)
        for _ in 0..<8 {
            var dst = Data(count: capacity)
            let written = dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
                data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
                    guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                          let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dstPtr, capacity, srcPtr, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written == 0 { return nil }
            if written < capacity {
                dst.removeSubrange(written..<dst.count)
                return dst
            }
            capacity *= 2  // buffer was filled exactly — may be truncated, grow and retry
        }
        return nil
    }

    /// Walk a schema-less protobuf message, collecting length-delimited fields that
    /// decode as coherent UTF-8 text and recursing into the rest. Unicode is preserved.
    public static func extractProtobufText(_ data: Data, minAlphaRatio: Double = 0.3, minLen: Int = 4) -> [String] {
        let bytes = [UInt8](data)
        var results: [String] = []
        var pos = 0
        while pos < bytes.count {
            guard let (tag, afterTag) = readVarint(bytes, pos) else { break }
            let wire = Int(tag & 0x7)
            pos = afterTag
            switch wire {
            case 0:  // varint
                guard let (_, next) = readVarint(bytes, pos) else { return results }
                pos = next
            case 1:  // 64-bit
                pos += 8
            case 5:  // 32-bit
                pos += 4
            case 2:  // length-delimited
                guard let (len, afterLen) = readVarint(bytes, pos) else { return results }
                let start = afterLen
                let end = afterLen + Int(len)
                guard end <= bytes.count, end >= start else { return results }
                let sub = Data(bytes[start..<end])
                pos = end
                if let s = String(data: sub, encoding: .utf8), s.count >= minLen {
                    let alpha = s.reduce(0) { $0 + (($1.isLetter || $1.isWhitespace) ? 1 : 0) }
                    let ratio = Double(alpha) / Double(s.count)
                    if ratio >= minAlphaRatio {
                        results.append(s)
                    } else {
                        results.append(contentsOf: extractProtobufText(sub, minAlphaRatio: minAlphaRatio, minLen: minLen))
                    }
                } else {
                    results.append(contentsOf: extractProtobufText(sub, minAlphaRatio: minAlphaRatio, minLen: minLen))
                }
            default:
                pos += 1
            }
        }
        return results
    }

    private static func readVarint(_ bytes: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var pos = start
        while pos < bytes.count {
            let b = bytes[pos]
            result |= UInt64(b & 0x7F) << shift
            pos += 1
            if b & 0x80 == 0 { return (result, pos) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    /// Decode a `ZICNOTEDATA.ZDATA` blob into the plain-text note body.
    ///
    /// The blob is gzip-compressed protobuf; field 2 of the top-level message holds
    /// the body. We take the longest coherent text found, which is robust to the
    /// exact field layout across Notes schema versions. Returns nil on failure.
    public static func decodeNoteBody(_ zdata: Data) -> String? {
        guard let decompressed = gunzipIfNeeded(zdata) else { return nil }
        let texts = extractProtobufText(decompressed, minAlphaRatio: 0.3, minLen: 4)
        guard let longest = texts.max(by: { $0.count < $1.count }) else { return nil }
        let trimmed = longest.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
