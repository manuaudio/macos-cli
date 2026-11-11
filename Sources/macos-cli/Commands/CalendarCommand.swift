import AppKit
import ArgumentParser
import EventKit
import Foundation
import MacCLICore

// MARK: - EKEvent → rich JSON (pure assembly lives in MacCLICore; this only extracts)

private let calISO: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

private func calEventStatusName(_ s: EKEventStatus) -> String? {
    switch s {
    case .confirmed: return "confirmed"
    case .tentative: return "tentative"
    case .canceled: return "canceled"
    default: return nil  // .none
    }
}

private func calAvailabilityName(_ a: EKEventAvailability) -> String? {
    switch a {
    case .busy: return "busy"
    case .free: return "free"
    case .tentative: return "tentative"
    case .unavailable: return "unavailable"
    default: return nil  // .notSupported
    }
}

private func calParticipantString(_ p: EKParticipant) -> String? {
    if let name = p.name, !name.isEmpty { return name }
    let s = p.url.absoluteString
    return s.hasPrefix("mailto:") ? String(s.dropFirst("mailto:".count)) : s
}

/// Minutes-before values recovered from an event's relative alarms (absolute-date
/// alarms cannot be expressed as minutes-before and are skipped).
private func calAlarmMinutes(_ event: EKEvent) -> [Int] {
    guard let alarms = event.alarms else { return [] }
    return alarms.compactMap { alarm in
        guard alarm.absoluteDate == nil else { return nil }
        let offset = alarm.relativeOffset
        guard offset < 0 else { return nil }
        return Int((-offset / 60).rounded())
    }
}

/// Extract every EventKit field this build can read and hand plain values to the
/// pure `MacCLICore.calendarEventJSON` assembler (which owns the machine contract).
private func calRichEventDict(_ e: EKEvent, in zone: TimeZone? = nil) -> [String: Any] {
    let calISO = zone.map { tz -> ISO8601DateFormatter in
        let f = ISO8601DateFormatter()
        f.timeZone = tz
        return f
    } ?? calISO
    let attendees = (e.attendees ?? []).compactMap(calParticipantString)
    return MacCLICore.calendarEventJSON(
        id: e.eventIdentifier ?? "",
        title: e.title ?? "",
        calendar: e.calendar?.title ?? "",
        source: e.calendar?.source.title,
        start: calISO.string(from: e.startDate),
        end: calISO.string(from: e.endDate),
        allDay: e.isAllDay,
        location: e.location,
        notes: e.notes,
        url: e.url?.absoluteString,
        timeZone: e.timeZone?.identifier,
        created: e.creationDate.map { calISO.string(from: $0) },
        lastModified: e.lastModifiedDate.map { calISO.string(from: $0) },
        status: calEventStatusName(e.status),
        availability: calAvailabilityName(e.availability),
        hasRecurrence: e.hasRecurrenceRules,
        organizer: e.organizer.flatMap(calParticipantString),
        attendees: attendees,
        alarmsMinutes: calAlarmMinutes(e)
    )
}

extension CLIFailure {
    static func calendarNotFound(_ name: String) -> CLIFailure {
        CLIFailure(code: "calendar_not_found", message: "No calendar is named '\(name)'.",
                   hint: "Run `macos calendar calendars` to see the names.", extra: ["calendar": name])
    }
}

/// `--calendar` / `--calendar-id` against the store's calendars. Nil when neither is
/// given. A write by a name two calendars share is refused with both ids.
private func pickCalendars(_ all: [EKCalendar], name: String?, id: String?, forWrite: Bool) throws -> [EKCalendar]? {
    let refs = all.map { MacCLICore.CalendarRef(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title) }
    switch MacCLICore.selectCalendar(refs, name: name, id: id, forWrite: forWrite) {
    case .none: return nil
    case .calendar(let index): return [all[index]]
    case .calendars(let indices): return indices.map { all[$0] }
    case .failure(let envelope): throw CLIFailure(envelope: envelope)
    }
}

/// `--timezone <IANA name>`: the zone dates on the command line are read in and the
/// zone times are printed in. Default: this Mac's zone for input, UTC for output.
private func parseTimeZone(_ name: String?) throws -> TimeZone? {
    guard let name = name else { return nil }
    guard let zone = TimeZone(identifier: name) else {
        throw CLIFailure(code: "invalid_timezone", message: "'\(name)' is not a time zone.",
                         hint: "Use an IANA name such as America/Los_Angeles or UTC.", extra: ["value": name])
    }
    return zone
}

/// Hex `#RRGGBB` of a calendar's color, nil when it has none.
private func calColorHex(_ cal: EKCalendar) -> String? {
    guard let color = cal.color?.usingColorSpace(.sRGB) else { return nil }
    let channel = { (v: CGFloat) in Int((v * 255).rounded()) }
    return String(format: "#%02X%02X%02X", channel(color.redComponent), channel(color.greenComponent),
                  channel(color.blueComponent))
}

private func calTypeName(_ type: EKCalendarType) -> String {
    switch type {
    case .local: return "local"
    case .calDAV: return "caldav"
    case .exchange: return "exchange"
    case .subscription: return "subscription"
    case .birthday: return "birthday"
    @unknown default: return "unknown"
    }
}

struct CalendarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Manage Apple Calendar events",
        subcommands: [Events.self, Export.self, Create.self, Delete.self, Update.self, Calendars.self, Reload.self]
    )

    // MARK: - Reload (force iCloud sync)
    struct Reload: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Force Calendar to refresh from iCloud / CalDAV sources")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let store = try EventKitStore.authorized(for: .event)
            // EventKit-native refresh — no AppleScript / Calendar.app dependency.
            store.refreshSourcesIfNecessary()
            if json {
                printJSON(["reloaded": true])
            } else {
                print("Calendar sources refresh requested.")
            }
        }
    }

    // MARK: - Events
    struct Events: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List events in a date range")

        @Option(name: [.customLong("from"), .customLong("start")], help: "Start date YYYY-MM-DD (default: today)")
        var from: String?

        @Option(name: [.customLong("to"), .customLong("end")], help: "End date YYYY-MM-DD (default: 7 days from start)")
        var to: String?

        @Option(name: .long, help: "Calendar name filter (every calendar of that name)")
        var calendar: String?

        @Option(name: .customLong("calendar-id"), help: "Exactly one calendar, by the id `calendar calendars --json` prints")
        var calendarId: String?

        @Option(name: .long, help: "IANA time zone the dates are read in and times printed in")
        var timezone: String?

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            // POSIX + strict parsing: reject locale surprises AND impossible calendar
            // dates (e.g. 2026-02-30) instead of rolling them over.
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            let zone = try parseTimeZone(timezone)
            df.timeZone = zone ?? TimeZone.current
            df.isLenient = false
            df.dateFormat = "yyyy-MM-dd"

            // Validate supplied dates BEFORE any TCC access. A malformed or impossible
            // supplied date is a hard error — never silently replaced with a default.
            let start: Date
            if let s = from {
                guard let d = df.date(from: s) else {
                    throw CLIFailure(envelope: MacCLICore.dateParseErrorJSON(field: "from", value: s))
                }
                start = d
            } else {
                start = Calendar.current.startOfDay(for: Date())
            }

            let end: Date
            if let s = to {
                guard let d = df.date(from: s) else {
                    throw CLIFailure(envelope: MacCLICore.dateParseErrorJSON(field: "to", value: s))
                }
                end = d
            } else {
                end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
            }

            let rangeCheck = MacCLICore.validateDateRange(
                startEpoch: start.timeIntervalSince1970, endEpoch: end.timeIntervalSince1970)
            guard rangeCheck.valid else {
                throw CLIFailure(envelope: MacCLICore.dateRangeErrorJSON(from: from ?? df.string(from: start),
                                                                         to: to ?? df.string(from: end)))
            }

            // Validation passed — NOW touch TCC. A denial (auth.json or macOS) or an
            // unanswered permission request is a typed failure with its own code.
            try Auth.check("calendar.read")
            let store = try EventKitStore.authorized(for: .event)

            let allCalendars = store.calendars(for: .event)
            let targetCals = try pickCalendars(allCalendars, name: calendar, id: calendarId, forWrite: false)
                ?? allCalendars

            let pred = store.predicateForEvents(withStart: start, end: end, calendars: targetCals)
            let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }

            if json {
                // Backward-compatible ARRAY (unchanged shape); each element now carries
                // the six legacy keys plus additive rich fields. For the ingestion
                // envelope (events/count/calendars/filter) use `calendar export`.
                printJSON(events.map { calRichEventDict($0, in: zone) })
            } else {
                let display = DateFormatter()
                display.dateFormat = "EEE MMM d, h:mm a"
                for e in events {
                    let time = e.isAllDay ? "all day" : display.string(from: e.startDate)
                    print("[\(e.calendar?.title ?? "?")] \(e.title ?? "") — \(time)")
                }
                print("\(events.count) events")
            }
        }
    }

    // MARK: - Export (rich ingestion envelope)
    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Export events as a rich JSON envelope (events/count/calendars/filter) for ingestion")

        @Option(name: [.customLong("from"), .customLong("start")], help: "Start date YYYY-MM-DD (default: 1 year ago). Inclusive.")
        var from: String?

        @Option(name: [.customLong("to"), .customLong("end")], help: "End date YYYY-MM-DD (default: 1 year ahead). Exclusive upper bound.")
        var to: String?

        @Option(name: .long, help: "Exact calendar name filter (fail-closed: unknown name => zero events, never all)")
        var calendar: String?

        @Option(name: .customLong("calendar-id"), help: "Exactly one calendar, by id (unknown id => calendar_not_found)")
        var calendarId: String?

        @Option(name: .long, help: "Only events created or changed since: ISO 8601 date-time, or YYYY-MM-DD")
        var since: String?

        @Option(name: .long, help: "IANA time zone the dates are read in and times printed in")
        var timezone: String?

        @Flag(name: .long, help: "Accepted for consistency; export always prints JSON")
        var json = false

        func run() throws {
            // POSIX + strict parsing: reject locale surprises AND impossible calendar
            // dates (e.g. 2026-02-30) instead of rolling them over.
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            let zone = try parseTimeZone(timezone)
            df.timeZone = zone ?? TimeZone.current
            df.isLenient = false
            df.dateFormat = "yyyy-MM-dd"

            // Bounded defaults; explicit --from/--to override for multi-year ranges.
            let today = Calendar.current.startOfDay(for: Date())
            let defaultStart = Calendar.current.date(byAdding: .year, value: -1, to: today)!
            let defaultEnd = Calendar.current.date(byAdding: .year, value: 1, to: today)!

            // Strict date validation runs BEFORE any TCC access. Export is always machine
            // JSON, so every failure — bad date, mis-ordered range, denied access — is a
            // structured object on stdout (stderr empty) with a non-zero exit. An invalid
            // supplied date is NEVER silently replaced with a default.
            let start: Date
            if let s = from {
                guard let d = df.date(from: s) else {
                    throw CLIFailure(envelope: MacCLICore.dateParseErrorJSON(field: "from", value: s))
                }
                start = d
            } else { start = defaultStart }

            let end: Date
            if let s = to {
                guard let d = df.date(from: s) else {
                    throw CLIFailure(envelope: MacCLICore.dateParseErrorJSON(field: "to", value: s))
                }
                end = d
            } else { end = defaultEnd }

            let rangeCheck = MacCLICore.validateDateRange(
                startEpoch: start.timeIntervalSince1970, endEpoch: end.timeIntervalSince1970)
            guard rangeCheck.valid else {
                throw CLIFailure(envelope: MacCLICore.dateRangeErrorJSON(from: from ?? df.string(from: start),
                                                                         to: to ?? df.string(from: end)))
            }

            var sinceDate: Date?
            if let since = since {
                guard let date = MacCLICore.parseSince(since, timeZone: df.timeZone) else {
                    throw CLIFailure(code: "invalid_date",
                                     message: "Could not parse the --since value; use an ISO 8601 date-time "
                                         + "(2026-11-10T09:00:00-08:00) or YYYY-MM-DD.",
                                     extra: ["field": "since", "value": since])
                }
                sinceDate = date
            }

            // Validation passed — NOW touch TCC. A policy denial (`capability_denied`), a
            // macOS denial (`access_denied`) and an unanswered request (`timeout`) are
            // distinct codes; none carries calendar content.
            try Auth.check("calendar.read")
            let store = try EventKitStore.authorized(for: .event)

            // Enumerate ALL linked event calendars from ALL sources, then resolve the
            // optional filter fail-closed (an unknown name never broadens to all).
            let allCals = store.calendars(for: .event)
            let targetCals: [EKCalendar]
            if calendarId != nil {
                targetCals = try pickCalendars(allCals, name: calendar, id: calendarId, forWrite: false) ?? []
            } else {
                let resolution = MacCLICore.resolveCalendarFilter(allTitles: allCals.map { $0.title }, filter: calendar)
                targetCals = resolution.indices.map { allCals[$0] }
            }
            let calendarNames = targetCals.map { $0.title }
            let filter = calendar ?? calendarId

            // Empty target set (fail-closed unknown filter, or no calendars): honest zero.
            guard !targetCals.isEmpty else {
                printJSON(MacCLICore.calendarExportEnvelope(events: [], calendars: calendarNames, filter: filter))
                return
            }

            let pred = store.predicateForEvents(withStart: start, end: end, calendars: targetCals)
            var events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
            if let cutoff = sinceDate {
                events = events.filter { ($0.lastModifiedDate ?? $0.creationDate ?? .distantPast) >= cutoff }
            }
            let dicts = events.map { calRichEventDict($0, in: zone) }
            var envelope = MacCLICore.calendarExportEnvelope(events: dicts, calendars: calendarNames, filter: filter)
            if let since = since { envelope["since"] = since }
            printJSON(envelope)
        }
    }

    // MARK: - Create
    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a calendar event")

        @Option(name: .long, help: "Event title")
        var title: String

        @Option(name: .long, help: "Start: YYYY-MM-DD HH:MM")
        var start: String

        @Option(name: .long, help: "End: YYYY-MM-DD HH:MM (default: 1h after start)")
        var end: String?

        @Option(name: .long, help: "Calendar name (refused when two calendars share it; use --calendar-id)")
        var calendar: String?

        @Option(name: .customLong("calendar-id"), help: "Calendar id, from `calendar calendars --json`")
        var calendarId: String?

        @Option(name: .long, help: "IANA time zone the start and end are in, and the event keeps (default: this Mac's)")
        var timezone: String?

        @Option(name: .long, help: "Location")
        var location: String?

        @Option(name: .long, help: "Notes")
        var notes: String?

        @Flag(name: .long, help: "All-day event (ignore times)")
        var allDay = false

        @Option(name: .long, help: "Alarm minutes before start (repeatable, e.g. --alarm 1440 --alarm 60). No default — with no --alarm the event is created with ZERO alarms.")
        var alarm: [Int] = []

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("calendar.write")

            // Validate alarms BEFORE touching EventKit so a bad value never opens the store.
            let invalidAlarms = MacCLICore.invalidAlarmMinutes(alarm)
            if !invalidAlarms.isEmpty {
                throw CLIFailure(envelope: MacCLICore.alarmValidationErrorJSON(invalid: invalidAlarms))
            }

            let zone = try parseTimeZone(timezone)
            let store = try EventKitStore.authorized(for: .event)

            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = zone ?? TimeZone.current

            func parseDate(_ s: String) -> Date? {
                df.dateFormat = "yyyy-MM-dd HH:mm"; if let d = df.date(from: s) { return d }
                df.dateFormat = "yyyy-MM-dd";       if let d = df.date(from: s) { return d }
                return nil
            }

            guard let startDate = parseDate(start) else {
                throw ValidationError("Invalid start date format — use YYYY-MM-DD or YYYY-MM-DD HH:MM")
            }

            let endDate: Date
            if let endStr = end, let d = parseDate(endStr) {
                endDate = d
            } else if allDay {
                endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate)!
            } else {
                endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate)!
            }

            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = startDate
            event.endDate = endDate
            event.isAllDay = allDay
            if let zone = zone, !allDay { event.timeZone = zone }
            if let loc = location { event.location = loc }
            if let n = notes { event.notes = n }

            // Alerts: explicit-only. No default alarms — with no --alarm the event is
            // created with ZERO alarms, exactly as the pre-0.8 CLI did. A caller that
            // wants the old 1-day + 1-hour alerts passes them (`--alarm 1440 --alarm 60`).
            let alarmMinutes = MacCLICore.creationAlarmMinutes(alarm)
            for offset in MacCLICore.alarmOffsets(alarmMinutes) {
                event.addAlarm(EKAlarm(relativeOffset: offset))
            }

            let allCalendars = store.calendars(for: .event)
            event.calendar = try pickCalendars(allCalendars, name: calendar, id: calendarId, forWrite: true)?.first
                ?? store.defaultCalendarForNewEvents

            do {
                try store.save(event, span: .thisEvent, commit: true)
            } catch {
                throw CLIFailure.saveFailure(error.localizedDescription)
            }

            if json {
                // id + alarm minute list; deliberately no private notes.
                printJSON([
                    "id": event.eventIdentifier ?? "",
                    "title": event.title ?? "",
                    "calendar": event.calendar?.title ?? "",
                    "calendar_id": event.calendar?.calendarIdentifier ?? "",
                    "start": ISO8601DateFormatter().string(from: event.startDate),
                    "end": ISO8601DateFormatter().string(from: event.endDate),
                    "all_day": event.isAllDay,
                    "alarms": alarmMinutes,
                ])
            } else {
                print("Created: \(event.title ?? "") on \(event.calendar?.title ?? "?")")
            }
        }
    }

    // MARK: - Delete
    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete calendar events by stable id (--id) OR by title+date (mutually exclusive)")

        @Option(name: .long, help: "Event identifier (from `calendar events`/`export`). Mutually exclusive with --title/--date.")
        var id: String?

        @Option(name: .long, help: "Event title (requires --date). Mutually exclusive with --id.")
        var title: String?

        @Option(name: .long, help: "Date YYYY-MM-DD — searches a 1-day window to catch all-day storage variants. Requires --title.")
        var date: String?

        @Option(name: .long, help: "Calendar name filter (title/date mode only; refused when two calendars share it)")
        var calendar: String?

        @Option(name: .customLong("calendar-id"), help: "Calendar id filter (title/date mode only)")
        var calendarId: String?

        @Flag(name: .long, help: "Match title as substring (default: exact) — title/date mode only")
        var contains = false

        @Flag(name: .long, help: "Delete all matching events (default: first match only) — title/date mode only")
        var all = false

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("calendar.delete")

            switch MacCLICore.resolveDeleteMode(id: id, title: title, date: date) {
            case .invalid(let reason):
                throw CLIFailure(envelope: MacCLICore.calendarDeleteModeErrorJSON(reason: reason))

            case .byId(let eventId):
                let store = try EventKitStore.authorized(for: .event)
                guard let event = store.event(withIdentifier: eventId) else {
                    throw CLIFailure(envelope: MacCLICore.calendarDeleteNotFoundJSON(id: eventId))
                }
                // Removes only this occurrence (EKSpanThisEvent) by default.
                try store.remove(event, span: .thisEvent, commit: true)
                if json {
                    printJSON(MacCLICore.calendarDeleteResultJSON(id: eventId, deleted: true))
                } else {
                    print("deleted \(eventId)")
                }

            case .byTitleDate(let matchTitle, let dateStr):
                let store = try EventKitStore.authorized(for: .event)

                let dateDf = DateFormatter()
                dateDf.dateFormat = "yyyy-MM-dd"
                guard let baseDate = dateDf.date(from: dateStr) else {
                    throw ValidationError("Invalid date format — use YYYY-MM-DD")
                }

                // Search local midnight of given date to local midnight of next day.
                // All-day events created on this machine store as next-day midnight UTC
                // (= 17:00 PT of the intended date), which falls within this window.
                let searchStart = Calendar.current.startOfDay(for: baseDate)
                let searchEnd = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: searchStart)!

                let allCalendars = store.calendars(for: .event)
                let targetCals = try pickCalendars(allCalendars, name: calendar, id: calendarId, forWrite: true)
                    ?? allCalendars

                let pred = store.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: targetCals)
                let events = store.events(matching: pred)
                let matches = events.filter { event in
                    let t = event.title ?? ""
                    return contains ? t.localizedCaseInsensitiveContains(matchTitle) : t == matchTitle
                }

                if matches.isEmpty {
                    if json { printJSON(["deleted": 0]) } else { print("0 deleted") }
                    return
                }

                let toDelete = all ? matches : [matches[0]]
                var deleted = 0
                for event in toDelete {
                    do {
                        try store.remove(event, span: .thisEvent, commit: true)
                        deleted += 1
                    } catch {
                        fputs("error: \(error.localizedDescription)\n", stderr)
                    }
                }
                if json {
                    printJSON(["deleted": deleted])
                } else {
                    print("deleted \(deleted)")
                }
            }
        }
    }

    // MARK: - Update
    struct Update: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update an existing calendar event by ID")

        @Option(name: .long, help: "Event identifier (from `macos calendar events --json`, the 'id' field)")
        var id: String

        @Option(name: .long, help: "New title")
        var title: String?

        @Option(name: .long, help: "New start: YYYY-MM-DD HH:MM")
        var start: String?

        @Option(name: .long, help: "New end: YYYY-MM-DD HH:MM")
        var end: String?

        @Option(name: .long, help: "New location")
        var location: String?

        @Option(name: .long, help: "New notes")
        var notes: String?

        @Option(name: .long, help: "Move to a different calendar by name (refused when two calendars share it)")
        var calendar: String?

        @Option(name: .customLong("calendar-id"), help: "Move to a different calendar by id")
        var calendarId: String?

        @Option(name: .long, help: "Set the alarms, minutes before start (repeatable); replaces the event's alarms")
        var alarm: [Int] = []

        @Flag(name: .customLong("clear-alarms"), help: "Remove every alarm")
        var clearAlarms = false

        @Option(name: .long, help: "IANA time zone --start and --end are in, and the event keeps")
        var timezone: String?

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("calendar.write")
            guard title != nil || start != nil || end != nil || location != nil || notes != nil || calendar != nil
                    || calendarId != nil || !alarm.isEmpty || clearAlarms || timezone != nil else {
                throw ValidationError("Specify at least one field to update: --title, --start, --end, --location, "
                    + "--notes, --calendar, --calendar-id, --alarm, --clear-alarms, --timezone")
            }
            if clearAlarms && !alarm.isEmpty {
                throw ValidationError("--alarm already replaces the alarms; give it or --clear-alarms, not both.")
            }
            let invalidAlarms = MacCLICore.invalidAlarmMinutes(alarm)
            if !invalidAlarms.isEmpty {
                throw CLIFailure(envelope: MacCLICore.alarmValidationErrorJSON(invalid: invalidAlarms))
            }
            let zone = try parseTimeZone(timezone)

            let store = try EventKitStore.authorized(for: .event)

            guard let event = store.event(withIdentifier: id) else {
                throw CLIFailure(envelope: MacCLICore.calendarDeleteNotFoundJSON(id: id).filter { $0.key != "deleted" })
            }

            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = zone ?? event.timeZone ?? TimeZone.current

            func parseDate(_ s: String) -> Date? {
                df.dateFormat = "yyyy-MM-dd HH:mm"; if let d = df.date(from: s) { return d }
                df.dateFormat = "yyyy-MM-dd";       if let d = df.date(from: s) { return d }
                return nil
            }

            if let zone = zone, !event.isAllDay { event.timeZone = zone }
            if let t = title { event.title = t }
            if let s = start {
                guard let d = parseDate(s) else {
                    throw ValidationError("Invalid start format — use YYYY-MM-DD HH:MM")
                }
                event.startDate = d
            }
            if let e = end {
                guard let d = parseDate(e) else {
                    throw ValidationError("Invalid end format — use YYYY-MM-DD HH:MM")
                }
                event.endDate = d
            }
            if let loc = location { event.location = loc }
            if let n = notes { event.notes = n }
            if let target = try pickCalendars(store.calendars(for: .event), name: calendar, id: calendarId,
                                              forWrite: true)?.first {
                event.calendar = target
            }
            if clearAlarms || !alarm.isEmpty {
                event.alarms?.forEach { event.removeAlarm($0) }
                for offset in MacCLICore.alarmOffsets(alarm) {
                    event.addAlarm(EKAlarm(relativeOffset: offset))
                }
            }

            do {
                try store.save(event, span: .thisEvent, commit: true)
            } catch {
                throw CLIFailure.saveFailure(error.localizedDescription)
            }

            if json {
                var d: [String: Any] = [
                    "id": event.eventIdentifier ?? "",
                    "title": event.title ?? "",
                    "calendar": event.calendar?.title ?? "",
                    "calendar_id": event.calendar?.calendarIdentifier ?? "",
                    "start": ISO8601DateFormatter().string(from: event.startDate),
                    "end": ISO8601DateFormatter().string(from: event.endDate),
                    "all_day": event.isAllDay,
                    "alarms": calAlarmMinutes(event),
                ]
                if let loc = event.location { d["location"] = loc }
                if let n = event.notes { d["notes"] = n }
                printJSON(d)
            } else {
                print("Updated: \(event.title ?? id)")
            }
        }
    }

    // MARK: - Calendars
    struct Calendars: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all calendars")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("calendar.read")
            let store = try EventKitStore.authorized(for: .event)
            let cals = store.calendars(for: .event)
            if json {
                printJSON(cals.map { cal -> [String: Any] in
                    [
                        "name": cal.title,
                        "id": cal.calendarIdentifier,
                        "type": cal.type.rawValue,
                        "kind": calTypeName(cal.type),
                        "source": cal.source.title,
                        "writable": cal.allowsContentModifications,
                        "color": calColorHex(cal).map { $0 as Any } ?? NSNull(),
                    ]
                })
            } else {
                cals.forEach { cal in
                    let access = cal.allowsContentModifications ? "" : ", read-only"
                    print("\(cal.title) (\(cal.source.title)\(access))  \(cal.calendarIdentifier)")
                }
            }
        }
    }
}
