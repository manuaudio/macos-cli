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

    // MARK: - Calendar: fail-closed calendar filter

    /// Resolve a `--calendar` filter against the titles of every linked event calendar.
    ///
    /// Semantics are IDENTICAL to `resolveReminderLists` and deliberately share its
    /// fail-closed contract: a `nil` filter enumerates ALL linked calendars from ALL
    /// sources, an exact title match selects those calendars (all duplicates), and an
    /// unknown title selects ZERO calendars with `failClosed == true`. An unknown
    /// filter must never broaden the ingestion surface to every calendar.
    public static func resolveCalendarFilter(allTitles: [String], filter: String?) -> ListResolution {
        return resolveReminderLists(allTitles: allTitles, filter: filter)
    }

    // MARK: - Calendar: date-range validation

    public struct DateRangeValidation: Equatable {
        /// True when `startEpoch <= endEpoch` (the range is inclusive of equal endpoints).
        public let valid: Bool
        /// Human-readable reason the range was rejected; nil when `valid`.
        public let reason: String?
        public init(valid: Bool, reason: String?) {
            self.valid = valid
            self.reason = reason
        }
    }

    /// Validate an ingestion date range. `from == to` is accepted (inclusive lower bound);
    /// `from > to` is rejected so a mis-ordered range fails loudly instead of scanning nothing.
    public static func validateDateRange(startEpoch: Double, endEpoch: Double) -> DateRangeValidation {
        if startEpoch <= endEpoch {
            return DateRangeValidation(valid: true, reason: nil)
        }
        return DateRangeValidation(valid: false, reason: "from date (\(startEpoch)) is after to date (\(endEpoch))")
    }

    /// Structured error body for a mis-ordered `--from`/`--to` range. Carries NO events
    /// array, so it can never be mistaken for an empty successful export.
    public static func dateRangeErrorJSON(from: String, to: String) -> [String: Any] {
        return [
            "ok": false,
            "status": "error",
            "error": "invalid_date_range",
            "from": from,
            "to": to,
            "message": "The --from date is after the --to date; supply a range where from <= to.",
        ]
    }

    /// Structured error body for an unparseable date argument.
    public static func dateParseErrorJSON(field: String, value: String) -> [String: Any] {
        return [
            "ok": false,
            "status": "error",
            "error": "invalid_date",
            "field": field,
            "value": value,
            "message": "Could not parse the --\(field) value; use YYYY-MM-DD or 'YYYY-MM-DD HH:MM'.",
        ]
    }

    /// Structured, REDACTED error body for an EventKit authorization/access failure.
    ///
    /// Emitted on stdout (stderr stays empty) with a non-zero exit so an ingestion
    /// pipeline can branch on a stable machine code instead of scraping stderr. It
    /// deliberately carries NO calendar names, NO event content, and NO raw localized
    /// system-error string — only `entity` and a fixed, non-leaking message. Because it
    /// carries no `events`/`calendars`/`count`, it can never be mistaken for a
    /// successful (possibly empty) export.
    public static func accessErrorJSON(entity: String) -> [String: Any] {
        return [
            "ok": false,
            "status": "error",
            "error": "access_denied",
            "entity": entity,
            "message": "EventKit access to \(entity) is not authorized for this binary. "
                + "Grant it in System Settings › Privacy & Security, then retry.",
        ]
    }

    // MARK: - Calendar: delete-mode resolution (exactly one of --id | --title+--date)

    public enum CalendarDeleteMode: Equatable {
        /// Delete a single event by its stable EventKit identifier.
        case byId(String)
        /// Delete by exact/substring title within a date window (legacy behavior).
        case byTitleDate(title: String, date: String)
        /// The supplied flags do not name exactly one valid mode; carries the reason.
        case invalid(String)
    }

    /// Enforce mutually-exclusive deletion modes. `--id` may not be combined with
    /// `--title`/`--date`; the title-mode requires BOTH `--title` and `--date`.
    public static func resolveDeleteMode(id: String?, title: String?, date: String?) -> CalendarDeleteMode {
        let hasId = id != nil
        let hasTitle = title != nil
        let hasDate = date != nil
        if hasId {
            if hasTitle || hasDate {
                return .invalid("--id is mutually exclusive with --title/--date")
            }
            return .byId(id!)
        }
        if hasTitle && hasDate {
            return .byTitleDate(title: title!, date: date!)
        }
        if hasTitle || hasDate {
            return .invalid("--title and --date must be used together")
        }
        return .invalid("specify either --id or both --title and --date")
    }

    /// Structured error body when an `--id`-mode delete finds no such event. Non-zero
    /// exit is the caller's responsibility; this body carries `deleted: false` and the id.
    public static func calendarDeleteNotFoundJSON(id: String) -> [String: Any] {
        return [
            "ok": false,
            "status": "error",
            "error": "event_not_found",
            "id": id,
            "deleted": false,
            "message": "No calendar event has identifier '\(id)'.",
        ]
    }

    /// Structured success body for an `--id`-mode delete. Deliberately carries NO event
    /// title, notes, or other private content — only the requested id and the outcome.
    public static func calendarDeleteResultJSON(id: String, deleted: Bool) -> [String: Any] {
        return [
            "ok": true,
            "status": "ok",
            "id": id,
            "deleted": deleted,
        ]
    }

    /// Structured error body for an invalid delete-mode combination.
    public static func calendarDeleteModeErrorJSON(reason: String) -> [String: Any] {
        return [
            "ok": false,
            "status": "error",
            "error": "invalid_delete_mode",
            "message": reason,
        ]
    }

    // MARK: - Calendar: alarm validation + offset conversion

    /// Convert a "minutes before the event" alarm into an `EKAlarm.relativeOffset`
    /// (negative seconds). Only strictly-positive minute values are valid; 0 or
    /// negative returns nil so the caller can reject it.
    public static func alarmOffsetSeconds(minutesBefore: Int) -> Double? {
        guard minutesBefore > 0 else { return nil }
        return Double(-minutesBefore * 60)
    }

    /// The subset of supplied alarm-minute values that are NOT strictly positive.
    /// An empty result means every value is usable.
    public static func invalidAlarmMinutes(_ minutes: [Int]) -> [Int] {
        return minutes.filter { $0 <= 0 }
    }

    /// The alarm minutes a `calendar create` will actually apply, given the repeatable
    /// `--alarm` values the caller supplied.
    ///
    /// Explicit-only by contract: an empty input yields an EMPTY result — the CLI
    /// inserts ZERO default alarms, exactly as the pre-0.8 CLI did. There is NO silent
    /// `[1440, 60]` default. A caller that wants the old 1-day + 1-hour alerts must pass
    /// them itself (`--alarm 1440 --alarm 60`). The order the caller gave is preserved.
    public static func creationAlarmMinutes(_ supplied: [Int]) -> [Int] {
        return supplied
    }

    /// Map a list of (assumed-valid) alarm minutes to relative offsets in seconds,
    /// preserving order. Non-positive values are skipped (validate first with
    /// `invalidAlarmMinutes`).
    public static func alarmOffsets(_ minutes: [Int]) -> [Double] {
        return minutes.compactMap { alarmOffsetSeconds(minutesBefore: $0) }
    }

    /// Structured error body for one or more invalid `--alarm` values.
    public static func alarmValidationErrorJSON(invalid: [Int]) -> [String: Any] {
        return [
            "ok": false,
            "status": "error",
            "error": "invalid_alarm",
            "invalid": invalid,
            "message": "Each --alarm value must be a positive integer number of minutes before the event.",
        ]
    }

    // MARK: - Calendar: rich event serialization

    /// Assemble one event's JSON object from plain (already-extracted) values.
    ///
    /// Backward compatibility: the six keys `id`, `title`, `calendar`, `start`, `end`,
    /// `all_day` are ALWAYS present, exactly as the pre-0.8.0 `calendar events --json`
    /// array emitted. Every richer field is additive and appears ONLY when it has a
    /// value, so no consumer sees new null noise. Dates are pre-formatted ISO8601
    /// strings supplied by the caller. `notes` is included when present (event bodies
    /// are user content the ingestion pipeline needs); the delete/alarm result contracts
    /// remain notes-free.
    public static func calendarEventJSON(
        id: String,
        title: String,
        calendar: String,
        source: String?,
        start: String,
        end: String,
        allDay: Bool,
        location: String?,
        notes: String?,
        url: String?,
        timeZone: String?,
        created: String?,
        lastModified: String?,
        status: String?,
        availability: String?,
        hasRecurrence: Bool,
        organizer: String?,
        attendees: [String],
        alarmsMinutes: [Int]
    ) -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "title": title,
            "calendar": calendar,
            "start": start,
            "end": end,
            "all_day": allDay,
            "recurring": hasRecurrence,
        ]
        func put(_ key: String, _ value: String?) {
            if let v = value, !v.isEmpty { d[key] = v }
        }
        put("source", source)
        put("location", location)
        put("notes", notes)
        put("url", url)
        put("timezone", timeZone)
        put("created", created)
        put("last_modified", lastModified)
        put("status", status)
        put("availability", availability)
        put("organizer", organizer)
        if !attendees.isEmpty { d["attendees"] = attendees }
        if !alarmsMinutes.isEmpty { d["alarms"] = alarmsMinutes }
        return d
    }

    /// Wrap serialized events in the rich ingestion envelope. `count` always equals the
    /// number of events, `calendars` lists exactly the resolved (never broadened) target
    /// set, and `filter` echoes the requested filter (JSON `null` when none was given).
    public static func calendarExportEnvelope(events: [[String: Any]], calendars: [String], filter: String?) -> [String: Any] {
        return [
            "ok": true,
            "status": "ok",
            "count": events.count,
            "filter": filter ?? NSNull(),
            "calendars": calendars,
            "events": events,
        ]
    }

    // MARK: - Contacts: get/export serialization (job_title parity)

    /// Assemble one contact's `contacts get --json` object from plain, already-extracted
    /// values — no Contacts.framework, so it is hermetically testable without TCC.
    ///
    /// Backward compatibility: `id`, `name`, `organization`, `phones`, `emails` are always
    /// present exactly as the pre-0.8.1 output. `job_title` is additive and always present
    /// as a string (empty string when the contact has no title — never null, matching the
    /// export convention so an ingestion consumer sees one stable shape). `birthday` is
    /// included only when supplied, so no null noise appears for the common no-birthday case.
    /// Special characters survive verbatim through normal dictionary JSON serialization.
    public static func contactGetJSON(
        id: String,
        name: String,
        organization: String,
        jobTitle: String,
        phones: [[String: Any]],
        emails: [[String: Any]],
        birthday: String?
    ) -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "name": name,
            "organization": organization,
            "job_title": jobTitle,
            "phones": phones,
            "emails": emails,
        ]
        if let birthday = birthday {
            d["birthday"] = birthday
        }
        return d
    }

    /// Assemble one contact's rich `contacts export` object from plain, already-extracted
    /// values. Every pre-0.8.1 key is preserved with its original convention: scalar name
    /// parts / organization / department / `job_title` / `contact_type` are strings (empty
    /// string when absent, never null); the multi-value arrays pass through as-is; and
    /// `birthday` / `display_name` are `Any` so the caller can supply either a formatted
    /// string or `NSNull()` when the value is absent. `job_title` is threaded through
    /// verbatim — special characters survive normal dictionary JSON serialization.
    public static func contactExportJSON(
        id: String,
        givenName: String,
        middleName: String,
        familyName: String,
        nickname: String,
        organization: String,
        department: String,
        jobTitle: String,
        contactType: String,
        phones: [[String: Any]],
        emails: [[String: Any]],
        urls: [[String: Any]],
        instantMessages: [[String: Any]],
        socialProfiles: [[String: Any]],
        relations: [[String: Any]],
        postalAddresses: [[String: Any]],
        dates: [[String: Any]],
        birthday: Any,
        displayName: Any
    ) -> [String: Any] {
        return [
            "id": id,
            "given_name": givenName,
            "middle_name": middleName,
            "family_name": familyName,
            "nickname": nickname,
            "organization": organization,
            "department": department,
            "job_title": jobTitle,
            "contact_type": contactType,
            "phones": phones,
            "emails": emails,
            "urls": urls,
            "instant_messages": instantMessages,
            "social_profiles": socialProfiles,
            "relations": relations,
            "postal_addresses": postalAddresses,
            "dates": dates,
            "birthday": birthday,
            "display_name": displayName,
        ]
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
