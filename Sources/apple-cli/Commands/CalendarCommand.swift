import ArgumentParser
import EventKit
import Foundation

struct CalendarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Manage Apple Calendar events",
        subcommands: [Events.self, Create.self, Delete.self, Calendars.self]
    )

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
            let store = try EventKitStore.authorized(for: .event)

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"

            let start = from.flatMap { df.date(from: $0) } ?? Calendar.current.startOfDay(for: Date())
            let end = to.flatMap { df.date(from: $0) } ?? Calendar.current.date(byAdding: .day, value: 7, to: start)!

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
                let out = events.map { e -> [String: Any] in
                    var d: [String: Any] = [
                        "id": e.eventIdentifier ?? "",
                        "title": e.title ?? "",
                        "calendar": e.calendar?.title ?? "",
                        "start": ISO8601DateFormatter().string(from: e.startDate),
                        "end": ISO8601DateFormatter().string(from: e.endDate),
                        "all_day": e.isAllDay,
                    ]
                    if let loc = e.location { d["location"] = loc }
                    if let notes = e.notes { d["notes"] = notes }
                    return d
                }
                printJSON(out)
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

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
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

            // Alerts: 1 day before + 1 hour before (per CLAUDE.md rule)
            event.addAlarm(EKAlarm(relativeOffset: -86400))  // 1 day
            event.addAlarm(EKAlarm(relativeOffset: -3600))   // 1 hour

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
                printJSON([
                    "id": event.eventIdentifier ?? "",
                    "title": event.title ?? "",
                    "calendar": event.calendar?.title ?? "",
                    "start": ISO8601DateFormatter().string(from: event.startDate),
                    "end": ISO8601DateFormatter().string(from: event.endDate),
                    "all_day": event.isAllDay,
                ])
            } else {
                print("Created: \(event.title ?? "") on \(event.calendar?.title ?? "?")")
            }
        }
    }

    // MARK: - Delete
    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete calendar events by title and date")

        @Option(name: .long, help: "Event title")
        var title: String

        @Option(name: .long, help: "Date YYYY-MM-DD — searches ±1 day window to catch all-day storage variants")
        var date: String

        @Option(name: .long, help: "Calendar name filter")
        var calendar: String?

        @Flag(name: .long, help: "Match title as substring (default: exact)")
        var contains = false

        @Flag(name: .long, help: "Delete all matching events (default: first match only)")
        var all = false

        func run() throws {
            let store = try EventKitStore.authorized(for: .event)

            let dateDf = DateFormatter()
            dateDf.dateFormat = "yyyy-MM-dd"

            guard let baseDate = dateDf.date(from: date) else {
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
                return contains ? t.localizedCaseInsensitiveContains(title) : t == title
            }

            if matches.isEmpty {
                print("0 deleted")
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
            print("deleted \(deleted)")
        }
    }

    // MARK: - Calendars
    struct Calendars: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all calendars")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
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
