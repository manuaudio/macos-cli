import Foundation

// What an agent needs to trust the tool: one report of every privacy area it may
// need, and calendar selection that never guesses between two calendars of one name.
extension MacCLICore {

    // MARK: - Privacy areas (`macos doctor`)

    /// One macOS privacy area as `doctor` reports it.
    public struct PrivacyArea {
        public let id: String
        /// granted | denied | not_determined | restricted | write_only | unknown
        public let state: String
        /// The commands that stop working when the area is not granted.
        public let neededBy: [String]
        /// What a person does to grant it; nil when granted.
        public let hint: String?
        /// The command that asks macOS for it, when one exists.
        public let authorize: String?
        /// Anything else worth knowing (why the state is `unknown`, …).
        public let detail: String?

        public init(id: String, state: String, neededBy: [String], hint: String?,
                    authorize: String?, detail: String? = nil) {
            self.id = id
            self.state = state
            self.neededBy = neededBy
            self.hint = state == "granted" ? nil : hint
            self.authorize = authorize
            self.detail = detail
        }

        public var json: [String: Any] {
            var body: [String: Any] = ["area": id, "state": state, "granted": state == "granted",
                                       "needed_by": neededBy]
            body["hint"] = hint ?? NSNull()
            body["authorize"] = authorize ?? NSNull()
            if let detail = detail { body["detail"] = detail }
            return body
        }
    }

    /// EventKit and Contacts authorization rawValues as one vocabulary. macOS 14's
    /// `.fullAccess` takes rawValue 3, the slot of the older `.authorized`.
    public static func privacyState(eventKitOrContactsRaw raw: Int) -> String {
        switch raw {
        case 0: return "not_determined"
        case 1: return "restricted"
        case 2: return "denied"
        case 3: return "granted"
        case 4: return "write_only"
        default: return "unknown"
        }
    }

    /// The `doctor --json` body. `ready` is true only when every area is granted;
    /// `missing` names the rest, in report order.
    public static func doctorReport(areas: [PrivacyArea], binary: [String: Any], session: [String: Any],
                                    capabilities: [String: Bool]) -> [String: Any] {
        let missing = areas.filter { $0.state != "granted" }.map { $0.id }
        return [
            "ok": true,
            "ready": missing.isEmpty,
            "missing": missing,
            "areas": areas.map { $0.json },
            "binary": binary,
            "session": session,
            "capabilities": capabilities,
        ]
    }

    // MARK: - Calendar selection

    public struct CalendarRef: Equatable {
        public let id: String
        public let title: String
        public let source: String
        public init(id: String, title: String, source: String) {
            self.id = id
            self.title = title
            self.source = source
        }
    }

    public enum CalendarSelection: Equatable {
        /// No calendar named: the caller uses its default (all calendars, or the default one).
        case none
        case calendar(Int)
        /// A read by name: every calendar with that title.
        case calendars([Int])
        /// The error envelope to report.
        case failure([String: Any])

        public static func == (lhs: CalendarSelection, rhs: CalendarSelection) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none): return true
            case let (.calendar(a), .calendar(b)): return a == b
            case let (.calendars(a), .calendars(b)): return a == b
            case let (.failure(a), .failure(b)): return a["error"] as? String == b["error"] as? String
            default: return false
            }
        }
    }

    /// Resolve `--calendar <name>` / `--calendar-id <id>`.
    ///
    /// An id always names exactly one calendar. A name names one calendar for a write;
    /// when two calendars share it the write is refused with both ids, never sent to the
    /// first one found. A read (`forWrite: false`) by name takes every calendar of that
    /// name. Unknown name or id: `calendar_not_found`.
    public static func selectCalendar(_ calendars: [CalendarRef], name: String?, id: String?,
                                      forWrite: Bool) -> CalendarSelection {
        if name != nil && id != nil {
            return .failure(errorEnvelope(code: "invalid_argument",
                                          message: "Give --calendar or --calendar-id, not both.",
                                          hint: "--calendar-id is exact; prefer it."))
        }
        if let id = id {
            guard let index = calendars.firstIndex(where: { $0.id == id }) else {
                return .failure(errorEnvelope(code: "calendar_not_found",
                                              message: "No calendar has the id '\(id)'.",
                                              hint: "Run `macos calendar calendars --json` to see the ids.",
                                              extra: ["calendar_id": id]))
            }
            return .calendar(index)
        }
        guard let name = name else { return .none }
        let matches = calendars.indices.filter { calendars[$0].title == name }
        if matches.isEmpty {
            return .failure(errorEnvelope(code: "calendar_not_found",
                                          message: "No calendar is named '\(name)'.",
                                          hint: "Run `macos calendar calendars` to see the names.",
                                          extra: ["calendar": name]))
        }
        if !forWrite { return .calendars(matches) }
        if matches.count > 1 {
            let candidates = matches.map { ["id": calendars[$0].id, "source": calendars[$0].source] }
            return .failure(errorEnvelope(
                code: "ambiguous_calendar",
                message: "\(matches.count) calendars are named '\(name)'.",
                hint: "Name one with --calendar-id: "
                    + matches.map { "\(calendars[$0].id) (\(calendars[$0].source))" }.joined(separator: ", ") + ".",
                extra: ["calendar": name, "candidates": candidates]))
        }
        return .calendar(matches[0])
    }

    /// `--since` for exports: an ISO 8601 date-time with an offset, or YYYY-MM-DD
    /// (local midnight). Nil when the value is neither.
    public static func parseSince(_ value: String, timeZone: TimeZone = .current) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.isLenient = false
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: value)
    }
}
