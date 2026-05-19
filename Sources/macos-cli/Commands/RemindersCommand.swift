import ArgumentParser
import EventKit
import Foundation

struct RemindersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Manage Apple Reminders",
        subcommands: [Create.self, List.self, Done.self, Delete.self, Update.self, Uncomplete.self, Lists.self]
    )

    // MARK: - Create
    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new reminder")

        @Option(name: .long, help: "Reminder title (required)")
        var title: String

        @Option(name: .long, help: "Due date: YYYY-MM-DD or 'YYYY-MM-DD HH:MM'")
        var due: String?

        @Option(name: .long, help: "List name (default: default list)")
        var list: String?

        @Option(name: .long, help: "Notes / body text")
        var notes: String?

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let store = try EventKitStore.authorized(for: .reminder)
            let reminder = EKReminder(eventStore: store)
            reminder.title = title

            if let n = notes { reminder.notes = n }

            if let due = due {
                let fmts = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
                for fmt in fmts {
                    let df = DateFormatter()
                    df.dateFormat = fmt
                    if let d = df.date(from: due) {
                        let comps = Calendar.current.dateComponents(
                            [.year, .month, .day, .hour, .minute], from: d)
                        reminder.dueDateComponents = comps
                        break
                    }
                }
            }

            // Pick target list
            if let listName = list {
                let lists = store.calendars(for: .reminder)
                guard let target = lists.first(where: { $0.title == listName }) else {
                    throw ValidationError("List '\(listName)' not found")
                }
                reminder.calendar = target
            } else {
                guard let def = store.defaultCalendarForNewReminders() else {
                    throw CLIError.noDefaultList
                }
                reminder.calendar = def
            }

            do {
                try store.save(reminder, commit: true)
            } catch {
                throw CLIError.saveFailure(error.localizedDescription)
            }

            if json {
                let out: [String: Any] = [
                    "id": reminder.calendarItemIdentifier,
                    "title": reminder.title ?? "",
                    "list": reminder.calendar?.title ?? "",
                    "due": due ?? NSNull(),
                    "notes": reminder.notes ?? NSNull(),
                ]
                printJSON(out)
            } else {
                print("Created: \(reminder.title ?? "") (id: \(reminder.calendarItemIdentifier))")
            }
        }
    }

    // MARK: - List
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List reminders")

        @Option(name: .long, help: "List name filter")
        var list: String?

        @Flag(name: .long, help: "Include completed reminders")
        var completed = false

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let store = try EventKitStore.authorized(for: .reminder)
            let lists = store.calendars(for: .reminder)

            let targetLists: [EKCalendar]
            if let listName = list {
                targetLists = lists.filter { $0.title == listName }
                if targetLists.isEmpty {
                    throw ValidationError("List '\(listName)' not found")
                }
            } else {
                targetLists = Array(lists)
            }

            let pred = store.predicateForReminders(in: targetLists)
            var reminders: [EKReminder] = []
            let sema = DispatchSemaphore(value: 0)
            store.fetchReminders(matching: pred) { fetched in
                reminders = fetched ?? []
                sema.signal()
            }
            sema.wait()

            let filtered = completed ? reminders : reminders.filter { !$0.isCompleted }

            if json {
                let out = filtered.map { r -> [String: Any] in
                    var d: [String: Any] = [
                        "id": r.calendarItemIdentifier,
                        "title": r.title ?? "",
                        "list": r.calendar?.title ?? "",
                        "completed": r.isCompleted,
                    ]
                    if let notes = r.notes { d["notes"] = notes }
                    if let due = r.dueDateComponents {
                        d["due"] = "\(due.year ?? 0)-\(String(format: "%02d", due.month ?? 0))-\(String(format: "%02d", due.day ?? 0))"
                    }
                    return d
                }
                printJSON(out)
            } else {
                for r in filtered {
                    let status = r.isCompleted ? "✓" : "○"
                    let dueStr = r.dueDateComponents.flatMap { c -> String? in
                        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
                        return "\(y)-\(String(format: "%02d", m))-\(String(format: "%02d", d))"
                    } ?? ""
                    print("\(status) [\(r.calendar?.title ?? "?")] \(r.title ?? "") \(dueStr)")
                }
                print("\(filtered.count) reminders")
            }
        }
    }

    // MARK: - Done
    struct Done: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Mark a reminder as complete")

        @Argument(help: "Reminder calendar item identifier")
        var id: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let store = try EventKitStore.authorized(for: .reminder)
            let pred = store.predicateForReminders(in: nil)
            var found: EKReminder?
            let sema = DispatchSemaphore(value: 0)
            store.fetchReminders(matching: pred) { reminders in
                found = reminders?.first { $0.calendarItemIdentifier == self.id }
                sema.signal()
            }
            sema.wait()
            guard let reminder = found else {
                throw ValidationError("Reminder '\(id)' not found")
            }
            reminder.isCompleted = true
            reminder.completionDate = Date()
            do {
                try store.save(reminder, commit: true)
            } catch {
                throw CLIError.saveFailure(error.localizedDescription)
            }
            if json {
                printJSON([
                    "id": reminder.calendarItemIdentifier,
                    "title": reminder.title ?? "",
                    "completed": true,
                    "completion_date": ISO8601DateFormatter().string(from: reminder.completionDate ?? Date()),
                ])
            } else {
                print("Done: \(reminder.title ?? id)")
            }
        }
    }

    // MARK: - Delete
    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a reminder by ID")

        @Option(name: .long, help: "Reminder calendarItemIdentifier")
        var id: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let store = try EventKitStore.authorized(for: .reminder)
            let pred = store.predicateForReminders(in: nil)
            var found: EKReminder?
            let sema = DispatchSemaphore(value: 0)
            store.fetchReminders(matching: pred) { reminders in
                found = reminders?.first { $0.calendarItemIdentifier == self.id }
                sema.signal()
            }
            sema.wait()
            guard let reminder = found else {
                throw ValidationError("Reminder '\(id)' not found")
            }
            let savedTitle = reminder.title ?? id
            do {
                try store.remove(reminder, commit: true)
            } catch {
                throw CLIError.saveFailure(error.localizedDescription)
            }
            if json {
                printJSON(["deleted": true, "id": id, "title": savedTitle])
            } else {
                print("Deleted: \(savedTitle)")
            }
        }
    }

    // MARK: - Update
    struct Update: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update a reminder by ID")

        @Option(name: .long, help: "Reminder calendarItemIdentifier")
        var id: String

        @Option(name: .long, help: "New title")
        var title: String?

        @Option(name: .long, help: "New due date: YYYY-MM-DD or 'YYYY-MM-DD HH:MM'")
        var due: String?

        @Option(name: .long, help: "New notes")
        var notes: String?

        @Option(name: .long, help: "Move to a different list by name")
        var list: String?

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            guard title != nil || due != nil || notes != nil || list != nil else {
                throw ValidationError("Specify at least one field to update: --title, --due, --notes, --list")
            }
            let store = try EventKitStore.authorized(for: .reminder)
            let pred = store.predicateForReminders(in: nil)
            var found: EKReminder?
            let sema = DispatchSemaphore(value: 0)
            store.fetchReminders(matching: pred) { reminders in
                found = reminders?.first { $0.calendarItemIdentifier == self.id }
                sema.signal()
            }
            sema.wait()
            guard let reminder = found else {
                throw ValidationError("Reminder '\(id)' not found")
            }

            if let t = title { reminder.title = t }
            if let n = notes { reminder.notes = n }
            if let due = due {
                let fmts = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
                var parsed = false
                for fmt in fmts {
                    let df = DateFormatter()
                    df.dateFormat = fmt
                    if let d = df.date(from: due) {
                        reminder.dueDateComponents = Calendar.current.dateComponents(
                            [.year, .month, .day, .hour, .minute], from: d)
                        parsed = true
                        break
                    }
                }
                if !parsed {
                    throw ValidationError("Invalid due format — use YYYY-MM-DD or 'YYYY-MM-DD HH:MM'")
                }
            }
            if let listName = list {
                let lists = store.calendars(for: .reminder)
                guard let target = lists.first(where: { $0.title == listName }) else {
                    throw ValidationError("List '\(listName)' not found")
                }
                reminder.calendar = target
            }

            do {
                try store.save(reminder, commit: true)
            } catch {
                throw CLIError.saveFailure(error.localizedDescription)
            }

            if json {
                var d: [String: Any] = [
                    "id": reminder.calendarItemIdentifier,
                    "title": reminder.title ?? "",
                    "list": reminder.calendar?.title ?? "",
                    "completed": reminder.isCompleted,
                ]
                if let n = reminder.notes { d["notes"] = n }
                if let dc = reminder.dueDateComponents,
                   let y = dc.year, let m = dc.month, let day = dc.day {
                    d["due"] = "\(y)-\(String(format: "%02d", m))-\(String(format: "%02d", day))"
                }
                printJSON(d)
            } else {
                print("Updated: \(reminder.title ?? id)")
            }
        }
    }

    // MARK: - Uncomplete
    struct Uncomplete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Mark a reminder as not complete")

        @Option(name: .long, help: "Reminder calendarItemIdentifier")
        var id: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let store = try EventKitStore.authorized(for: .reminder)
            let pred = store.predicateForReminders(in: nil)
            var found: EKReminder?
            let sema = DispatchSemaphore(value: 0)
            store.fetchReminders(matching: pred) { reminders in
                found = reminders?.first { $0.calendarItemIdentifier == self.id }
                sema.signal()
            }
            sema.wait()
            guard let reminder = found else {
                throw ValidationError("Reminder '\(id)' not found")
            }
            reminder.isCompleted = false
            reminder.completionDate = nil
            do {
                try store.save(reminder, commit: true)
            } catch {
                throw CLIError.saveFailure(error.localizedDescription)
            }
            if json {
                printJSON([
                    "id": reminder.calendarItemIdentifier,
                    "title": reminder.title ?? "",
                    "completed": false,
                ])
            } else {
                print("Uncompleted: \(reminder.title ?? id)")
            }
        }
    }

    // MARK: - Lists
    struct Lists: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all reminder lists")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let store = try EventKitStore.authorized(for: .reminder)
            let lists = store.calendars(for: .reminder)
            if json {
                printJSON(lists.map { ["name": $0.title, "id": $0.calendarIdentifier] })
            } else {
                lists.forEach { print($0.title) }
            }
        }
    }
}

// MARK: - JSON helpers

func printJSON(_ value: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let str = String(data: data, encoding: .utf8) else {
        fputs("JSON serialization failed\n", stderr)
        return
    }
    print(str)
}
