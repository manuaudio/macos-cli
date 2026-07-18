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
private func calRichEventDict(_ e: EKEvent) -> [String: Any] {
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

        @Option(name: .long, help: "Start date YYYY-MM-DD (default: today)")
        var from: String?

        @Option(name: .long, help: "End date YYYY-MM-DD (default: 7 days from start)")
        var to: String?

        @Option(name: .long, help: "Calendar name filter")
        var calendar: String?

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            // POSIX + strict parsing: reject locale surprises AND impossible calendar
            // dates (e.g. 2026-02-30) instead of rolling them over.
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
            df.isLenient = false
            df.dateFormat = "yyyy-MM-dd"

            // Validate supplied dates BEFORE any TCC access. A malformed or impossible
            // supplied date is a hard error — never silently replaced with a default.
            let start: Date
            if let s = from {
                guard let d = df.date(from: s) else {
                    if json { printJSON(MacCLICore.dateParseErrorJSON(field: "from", value: s)); throw ExitCode(1) }
                    throw ValidationError("Invalid --from date '\(s)' — use YYYY-MM-DD")
                }
                start = d
            } else {
                start = Calendar.current.startOfDay(for: Date())
            }

            let end: Date
            if let s = to {
                guard let d = df.date(from: s) else {
                    if json { printJSON(MacCLICore.dateParseErrorJSON(field: "to", value: s)); throw ExitCode(1) }
                    throw ValidationError("Invalid --to date '\(s)' — use YYYY-MM-DD")
                }
                end = d
            } else {
                end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
            }

            let rangeCheck = MacCLICore.validateDateRange(
                startEpoch: start.timeIntervalSince1970, endEpoch: end.timeIntervalSince1970)
            guard rangeCheck.valid else {
                if json {
                    printJSON(MacCLICore.dateRangeErrorJSON(from: from ?? df.string(from: start),
                                                            to: to ?? df.string(from: end)))
                    throw ExitCode(1)
                }
                throw ValidationError("Invalid range: --from must be on or before --to")
            }

            // Validation passed — NOW touch TCC. An authorization/access failure while
            // acquiring the store becomes a stable redacted error under --json (stdout,
            // stderr empty, non-zero); human mode surfaces the readable CLIError.
            let store: EKEventStore
            do {
                try Auth.check("calendar.read")
                store = try EventKitStore.authorized(for: .event)
            } catch {
                if json { printJSON(MacCLICore.accessErrorJSON(entity: "calendar")); throw ExitCode(1) }
                throw error
            }

            let allCalendars = store.calendars(for: .event)
            let targetCals: [EKCalendar]
            if let name = calendar {
                targetCals = allCalendars.filter { $0.title == name }
                if targetCals.isEmpty { throw ValidationError("Calendar '\(name)' not found") }
            } else {
                targetCals = Array(allCalendars)
            }

            let pred = store.predicateForEvents(withStart: start, end: end, calendars: targetCals)
            let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }

            if json {
                // Backward-compatible ARRAY (unchanged shape); each element now carries
                // the six legacy keys plus additive rich fields. For the ingestion
                // envelope (events/count/calendars/filter) use `calendar export`.
                printJSON(events.map { calRichEventDict($0) })
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

        @Option(name: .long, help: "Start date YYYY-MM-DD (default: 1 year ago). Inclusive.")
        var from: String?

        @Option(name: .long, help: "End date YYYY-MM-DD (default: 1 year ahead). Exclusive upper bound.")
        var to: String?

        @Option(name: .long, help: "Exact calendar name filter (fail-closed: unknown name => zero events, never all)")
        var calendar: String?

        func run() throws {
            // POSIX + strict parsing: reject locale surprises AND impossible calendar
            // dates (e.g. 2026-02-30) instead of rolling them over.
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
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
                    printJSON(MacCLICore.dateParseErrorJSON(field: "from", value: s))
                    throw ExitCode(1)
                }
                start = d
            } else { start = defaultStart }

            let end: Date
            if let s = to {
                guard let d = df.date(from: s) else {
                    printJSON(MacCLICore.dateParseErrorJSON(field: "to", value: s))
                    throw ExitCode(1)
                }
                end = d
            } else { end = defaultEnd }

            let rangeCheck = MacCLICore.validateDateRange(
                startEpoch: start.timeIntervalSince1970, endEpoch: end.timeIntervalSince1970)
            guard rangeCheck.valid else {
                printJSON(MacCLICore.dateRangeErrorJSON(from: from ?? df.string(from: start),
                                                        to: to ?? df.string(from: end)))
                throw ExitCode(1)
            }

            // Validation passed — NOW touch TCC. Catch ONLY authorization/access failures
            // around store acquisition and redact them: a stable machine code on stdout,
            // no calendar content, no raw localized system strings, stderr empty, exit 1.
            let store: EKEventStore
            do {
                try Auth.check("calendar.read")
                store = try EventKitStore.authorized(for: .event)
            } catch {
                printJSON(MacCLICore.accessErrorJSON(entity: "calendar"))
                throw ExitCode(1)
            }

            // Enumerate ALL linked event calendars from ALL sources, then resolve the
            // optional filter fail-closed (an unknown name never broadens to all).
            let allCals = store.calendars(for: .event)
            let resolution = MacCLICore.resolveCalendarFilter(allTitles: allCals.map { $0.title }, filter: calendar)
            let targetCals = resolution.indices.map { allCals[$0] }
            let calendarNames = targetCals.map { $0.title }

            // Empty target set (fail-closed unknown filter, or no calendars): honest zero.
            guard !targetCals.isEmpty else {
                printJSON(MacCLICore.calendarExportEnvelope(events: [], calendars: calendarNames, filter: calendar))
                return
            }

            let pred = store.predicateForEvents(withStart: start, end: end, calendars: targetCals)
            let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
            let dicts = events.map { calRichEventDict($0) }
            printJSON(MacCLICore.calendarExportEnvelope(events: dicts, calendars: calendarNames, filter: calendar))
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

        @Option(name: .long, help: "Calendar name")
        var calendar: String?

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
                if json {
                    printJSON(MacCLICore.alarmValidationErrorJSON(invalid: invalidAlarms))
                    throw ExitCode(1)
                }
                throw ValidationError("--alarm values must be positive minutes; invalid: \(invalidAlarms)")
            }

            let store = try EventKitStore.authorized(for: .event)

            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")

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
            if let name = calendar {
                guard let cal = allCalendars.first(where: { $0.title == name }) else {
                    throw ValidationError("Calendar '\(name)' not found")
                }
                event.calendar = cal
            } else {
                event.calendar = store.defaultCalendarForNewEvents
            }

            do {
                try store.save(event, span: .thisEvent, commit: true)
            } catch {
                throw CLIError.saveFailure(error.localizedDescription)
            }

            if json {
                // id + alarm minute list; deliberately no private notes.
                printJSON([
                    "id": event.eventIdentifier ?? "",
                    "title": event.title ?? "",
                    "calendar": event.calendar?.title ?? "",
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

        @Option(name: .long, help: "Calendar name filter (title/date mode only)")
        var calendar: String?

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
                if json {
                    printJSON(MacCLICore.calendarDeleteModeErrorJSON(reason: reason))
                    throw ExitCode(1)
                }
                throw ValidationError(reason)

            case .byId(let eventId):
                let store = try EventKitStore.authorized(for: .event)
                guard let event = store.event(withIdentifier: eventId) else {
                    if json {
                        printJSON(MacCLICore.calendarDeleteNotFoundJSON(id: eventId))
                    } else {
                        fputs("error: no event with id '\(eventId)'\n", stderr)
                    }
                    throw ExitCode(1)
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
                let targetCals: [EKCalendar]
                if let calName = calendar {
                    targetCals = allCalendars.filter { $0.title == calName }
                    if targetCals.isEmpty { throw ValidationError("Calendar '\(calName)' not found") }
                } else {
                    targetCals = Array(allCalendars)
                }

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

        @Option(name: .long, help: "Move to a different calendar by name")
        var calendar: String?

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("calendar.write")
            guard title != nil || start != nil || end != nil || location != nil || notes != nil || calendar != nil else {
                throw ValidationError("Specify at least one field to update: --title, --start, --end, --location, --notes, --calendar")
            }

            let store = try EventKitStore.authorized(for: .event)

            guard let event = store.event(withIdentifier: id) else {
                throw ValidationError("Event '\(id)' not found")
            }

            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")

            func parseDate(_ s: String) -> Date? {
                df.dateFormat = "yyyy-MM-dd HH:mm"; if let d = df.date(from: s) { return d }
                df.dateFormat = "yyyy-MM-dd";       if let d = df.date(from: s) { return d }
                return nil
            }

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
            if let calName = calendar {
                let allCalendars = store.calendars(for: .event)
                guard let cal = allCalendars.first(where: { $0.title == calName }) else {
                    throw ValidationError("Calendar '\(calName)' not found")
                }
                event.calendar = cal
            }

            do {
                try store.save(event, span: .thisEvent, commit: true)
            } catch {
                throw CLIError.saveFailure(error.localizedDescription)
            }

            if json {
                var d: [String: Any] = [
                    "id": event.eventIdentifier ?? "",
                    "title": event.title ?? "",
                    "calendar": event.calendar?.title ?? "",
                    "start": ISO8601DateFormatter().string(from: event.startDate),
                    "end": ISO8601DateFormatter().string(from: event.endDate),
                    "all_day": event.isAllDay,
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
                printJSON(cals.map { ["name": $0.title, "id": $0.calendarIdentifier, "type": $0.type.rawValue] })
            } else {
                cals.forEach { print("\($0.title) (\($0.type == .calDAV ? "iCloud" : "local"))") }
            }
        }
    }
}
