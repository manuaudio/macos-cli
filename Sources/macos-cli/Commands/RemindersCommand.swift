import ArgumentParser
import EventKit
import Foundation
import MacCLICore

struct RemindersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Manage Apple Reminders",
        subcommands: [Create.self, List.self, Complete.self, Done.self, Delete.self, Update.self, Uncomplete.self,
                      Lists.self, Status.self, Export.self]
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
            try Auth.check("reminders.write")
            let store = try EventKitStore.authorized(for: .reminder)
            let reminder = EKReminder(eventStore: store)
            reminder.title = title

            if let n = notes { reminder.notes = n }

            if let due = due {
                let fmts = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
                var parsed = false
                for fmt in fmts {
                    let df = DateFormatter()
                    df.dateFormat = fmt
                    if let d = df.date(from: due) {
                        let comps = Calendar.current.dateComponents(
                            [.year, .month, .day, .hour, .minute], from: d)
                        reminder.dueDateComponents = comps
                        parsed = true
                        break
                    }
                }
                if !parsed {
                    throw ValidationError("Invalid date format for --due: use YYYY-MM-DD or 'YYYY-MM-DD HH:MM'")
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
            try Auth.check("reminders.read")
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
    // RETIRED. `done` used to be an ungated write — it completed a reminder with no
    // approval-token check, bypassing the exact policy that gates `complete`. That is
    // the P1-1 finding. Rather than duplicate the gated mutation here, `done` now
    // performs NO EventKit access at all: it can never complete a reminder. It exists
    // only to give a clear migration error pointing at the single canonical, fail-closed
    // entrypoint (`reminders complete`). This makes EVERY completion entrypoint
    // fail-closed without the token.
    struct Done: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "(retired) Use 'reminders complete' — completion is gated by APPLE_EVENTKIT_APPROVE_TOKEN")

        @Argument(help: "Reminder calendarItemIdentifier")
        var id: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let msg = "`reminders done` is retired because it was an ungated write. "
                + "Use `reminders complete --id \(id)`, which defaults to a dry run and only "
                + "writes when --approve exactly matches the non-empty APPLE_EVENTKIT_APPROVE_TOKEN "
                + "environment variable."
            if json {
                printJSON([
                    "ok": false,
                    "status": "error",
                    "error": "command_retired",
                    "retired": "done",
                    "use_instead": "complete",
                    "target_id": id,
                    "wrote": false,
                    "message": msg,
                ])
            } else {
                FileHandle.standardError.write(Data((msg + "\n").utf8))
            }
            // No EventKit store is ever constructed on this path — provably no write.
            throw ExitCode.failure
        }
    }

    // MARK: - Delete
    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a reminder by ID")

        @Argument(help: "Reminder calendarItemIdentifier")
        var id: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("reminders.delete")
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

        @Argument(help: "Reminder calendarItemIdentifier")
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
            try Auth.check("reminders.write")
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

        @Argument(help: "Reminder calendarItemIdentifier")
        var id: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("reminders.write")
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
            try Auth.check("reminders.read")
            let store = try EventKitStore.authorized(for: .reminder)
            let lists = store.calendars(for: .reminder)
            if json {
                printJSON(lists.map { ["name": $0.title, "id": $0.calendarIdentifier] })
            } else {
                lists.forEach { print($0.title) }
            }
        }
    }

    // MARK: - Status
    //
    // Reports Reminders authorization WITHOUT prompting — a pure diagnostic, so it
    // is intentionally not gated behind auth.json. Automations call this first to
    // decide whether a read/export will succeed.
    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report Reminders authorization status without prompting")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() {
            let raw = Int(EKEventStore.authorizationStatus(for: .reminder).rawValue)
            let name = MacCLICore.authorizationStatusName(raw)
            let canRead = MacCLICore.authorizationCanRead(raw)
            if json {
                printJSON([
                    "authorization": name,
                    "authorization_raw": raw,
                    "can_read": canRead,
                    "entity": "reminder",
                ])
            } else {
                print("reminders authorization: \(name) (raw \(raw)) — can_read: \(canRead)")
            }
        }
    }

    // MARK: - Export
    //
    // Rich, read-only export suitable for ingestion pipelines. Stable IDs, list
    // metadata, notes, URL, priority (+band), recurrence, alarms, and every
    // timestamp. `--list` is fail-closed: a nonexistent list yields zero rows and
    // never broadens to all lists. A fetch timeout is a hard error — never a
    // silent empty result.
    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Export reminders as rich JSON for ingestion (read-only)")

        @Option(name: .long, help: "Exact list-name filter (fail-closed: unknown list → zero rows)")
        var list: String?

        @Flag(name: .customLong("include-completed"), help: "Include completed reminders")
        var includeCompleted = false

        @Option(name: .long, help: "Fetch timeout in seconds (default: 25)")
        var timeout: Double = 25

        func run() throws {
            try Auth.check("reminders.read")
            let store = try EventKitStore.authorized(for: .reminder)
            let allCals = store.calendars(for: .reminder)
            let resolution = MacCLICore.resolveReminderLists(allTitles: allCals.map { $0.title }, filter: list)
            let cals = resolution.indices.map { allCals[$0] }

            func listMeta(_ c: EKCalendar) -> [String: Any] {
                ["id": c.calendarIdentifier, "title": c.title, "source": c.source.title]
            }

            // FAIL-CLOSED: a named list that matched nothing exports zero rows.
            if resolution.failClosed {
                printJSON([
                    "reminders": [],
                    "count": 0,
                    "lists": [],
                    "include_completed": includeCompleted,
                    "list_filter": list.map { $0 as Any } ?? NSNull(),
                    "authorization": MacCLICore.authorizationStatusName(
                        Int(EKEventStore.authorizationStatus(for: .reminder).rawValue)),
                ])
                return
            }

            let pred = store.predicateForReminders(in: list == nil ? nil : cals)
            let outcome = EventKitStore.fetchReminders(store, matching: pred, timeout: timeout)
            let reminders: [EKReminder]
            switch outcome {
            case .timedOut:
                // Machine contract: emit a structured JSON error envelope on stdout,
                // then fail with a non-zero exit. ExitCode.failure exits 1 WITHOUT
                // ArgumentParser printing its own plain-text "Error:" line, so the
                // only thing a caller sees on stdout is the parseable envelope.
                printJSON(MacCLICore.fetchTimeoutErrorJSON(timeoutSeconds: timeout))
                throw ExitCode.failure
            case .success(let r):
                reminders = r
            }

            let rows = reminders
                .filter { includeCompleted || !$0.isCompleted }
                .map { reminderExportDict($0) }

            printJSON([
                "reminders": rows,
                "count": rows.count,
                "lists": cals.map { listMeta($0) },
                "include_completed": includeCompleted,
                "list_filter": list.map { $0 as Any } ?? NSNull(),
                "authorization": MacCLICore.authorizationStatusName(
                    Int(EKEventStore.authorizationStatus(for: .reminder).rawValue)),
            ])
        }
    }

    // MARK: - Complete (the single, canonical, fail-closed completion command)
    //
    // This is the ONLY code path that can mark a reminder complete. It defaults to
    // DRY-RUN and only writes when `--approve` exactly matches the non-empty
    // APPLE_EVENTKIT_APPROVE_TOKEN environment variable. The gate is evaluated
    // BEFORE any EventKit store is constructed, so the dry-run path provably never
    // mutates. The old `complete-safe` name is preserved as an alias; the old
    // ungated `done` command is retired (see above).
    struct Complete: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "complete",
            abstract: "Complete a reminder: dry-run unless --approve matches APPLE_EVENTKIT_APPROVE_TOKEN",
            aliases: ["complete-safe"])

        @Option(name: .long, help: "Reminder calendarItemIdentifier")
        var id: String

        @Option(name: .long, help: "Approval token; must equal APPLE_EVENTKIT_APPROVE_TOKEN to write")
        var approve: String?

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let expected = ProcessInfo.processInfo.environment["APPLE_EVENTKIT_APPROVE_TOKEN"]
            let approved = MacCLICore.isApprovalTokenValid(supplied: approve, expected: expected)

            // Dry-run path — NO EventKit access at all.
            guard approved else {
                let reason = MacCLICore.approvalDenialReason(supplied: approve, expected: expected)
                if json {
                    printJSON([
                        "status": "dry_run",
                        "would_write": false,
                        "target_id": id,
                        "action": "mark_completed",
                        "reason": reason,
                    ])
                } else {
                    print("dry-run — would mark \(id) completed. \(reason)")
                }
                return
            }

            // Approved path — only reachable with the operator's secret token.
            try Auth.check("reminders.write")
            let store = try EventKitStore.authorized(for: .reminder)
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
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
                    "status": "written",
                    "would_write": true,
                    "wrote": true,
                    "target_id": id,
                    "title": reminder.title ?? "",
                    "action": "mark_completed",
                ])
            } else {
                print("Completed: \(reminder.title ?? id)")
            }
        }
    }
}

// MARK: - Rich reminder export

private let reminderISO: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func isoOrNull(_ date: Date?) -> Any {
    guard let date = date else { return NSNull() }
    return reminderISO.string(from: date)
}

private func reminderFreqString(_ raw: Int) -> String {
    switch raw {
    case 0: return "daily"
    case 1: return "weekly"
    case 2: return "monthly"
    case 3: return "yearly"
    default: return "unknown"
    }
}

private func reminderProximityString(_ raw: Int) -> Any {
    switch raw {
    case 1: return "enter"
    case 2: return "leave"
    default: return NSNull()
    }
}

/// Build the rich export dictionary for one reminder.
func reminderExportDict(_ r: EKReminder) -> [String: Any] {
    var dueISO: Any = NSNull()
    var dueHasTime = false
    if let comps = r.dueDateComponents {
        dueHasTime = (comps.hour != nil)
        if let dt = Calendar.current.date(from: comps) { dueISO = reminderISO.string(from: dt) }
    }

    let alarms: [[String: Any]] = (r.alarms ?? []).map { a in
        [
            "absolute_date": isoOrNull(a.absoluteDate),
            "relative_offset_seconds": a.absoluteDate == nil ? a.relativeOffset : NSNull(),
            "proximity": reminderProximityString(Int(a.proximity.rawValue)),
        ]
    }

    let rules: [[String: Any]] = (r.recurrenceRules ?? []).map { rule in
        var end: Any = NSNull()
        if let re = rule.recurrenceEnd {
            if let ed = re.endDate { end = ["end_date": reminderISO.string(from: ed)] }
            else { end = ["occurrence_count": re.occurrenceCount] }
        }
        return [
            "frequency": reminderFreqString(Int(rule.frequency.rawValue)),
            "interval": rule.interval,
            "end": end,
        ]
    }

    return [
        "id": r.calendarItemIdentifier,
        "external_id": (r.calendarItemExternalIdentifier as String?).map { $0 as Any } ?? NSNull(),
        "list": (r.calendar?.title as String?).map { $0 as Any } ?? NSNull(),
        "list_id": (r.calendar?.calendarIdentifier as String?).map { $0 as Any } ?? NSNull(),
        "title": (r.title as String?).map { $0 as Any } ?? NSNull(),
        "notes": (r.notes as String?).map { $0 as Any } ?? NSNull(),
        "url": (r.url?.absoluteString as String?).map { $0 as Any } ?? NSNull(),
        "due_date": dueISO,
        "has_due_date": r.dueDateComponents != nil,
        "due_has_time": dueHasTime,
        "completed": r.isCompleted,
        "completion_date": isoOrNull(r.completionDate),
        "priority": r.priority,
        "priority_band": MacCLICore.priorityBand(r.priority),
        "alarms": alarms,
        "recurrence": rules,
        "creation_date": isoOrNull(r.creationDate),
        "last_modified": isoOrNull(r.lastModifiedDate),
    ]
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
