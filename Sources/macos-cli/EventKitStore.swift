import EventKit
import Foundation

/// Shared EventKit store.
///
/// A command reads the authorization state first. Granted: the store. Undecided and a
/// person at the terminal: macOS is asked, and the answer awaited at most 60 s.
/// Anywhere else (an agent's shell, cron, launchd) nobody can answer the prompt, so
/// waiting only ever ended in a timeout; the command fails at once with the state and
/// the command that grants it (`macos authorize calendars`).
enum EventKitStore {
    static func authorized(for type: EKEntityType) throws -> EKEventStore {
        let store = EKEventStore()
        switch PrivacyAccess.state(type) {
        case "granted":
            return store
        case "not_determined" where personAtTerminal:
            try request(type, store: store, timeout: 60)
            return store
        case let state:
            throw CLIFailure.notGranted(areaName(type), state: state)
        }
    }

    static func areaName(_ type: EKEntityType) -> String { type == .reminder ? "Reminders" : "Calendars" }

    /// Ask macOS for full access and wait for the answer, at most `timeout` seconds.
    /// The completion arrives on the main run loop, so the loop is spun while waiting.
    static func request(_ type: EKEntityType, store: EKEventStore, timeout: Double) throws {
        var granted = false
        var authError: Error?
        var done = false

        DispatchQueue.main.async {
            let completion: (Bool, Error?) -> Void = { ok, err in
                granted = ok
                authError = err
                done = true
                CFRunLoopStop(CFRunLoopGetMain())
            }
            if #available(macOS 14.0, *) {
                switch type {
                case .event: store.requestFullAccessToEvents(completion: completion)
                case .reminder: store.requestFullAccessToReminders(completion: completion)
                @unknown default: store.requestAccess(to: type, completion: completion)
                }
            } else {
                store.requestAccess(to: type, completion: completion)
            }
        }

        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while !done && CFAbsoluteTimeGetCurrent() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.1, false)
        }

        if !done { throw CLIFailure.permissionTimeout(areaName(type), seconds: timeout) }
        if let err = authError { throw CLIFailure.appError(err.localizedDescription) }
        guard granted else { throw CLIFailure.notGranted(areaName(type), state: "denied") }
    }

    /// One reminder by its `calendarItemIdentifier`, without fetching every reminder.
    static func reminder(_ store: EKEventStore, id: String) throws -> EKReminder {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw CLIFailure.notFound("Reminder '\(id)' not found")
        }
        return reminder
    }

    /// Outcome of a bounded reminder fetch. `.timedOut` is distinct from
    /// `.success([])`: an empty result means "no matching reminders", a timeout
    /// means "the async callback never fired" — callers must not conflate them.
    enum FetchOutcome {
        case success([EKReminder])
        case timedOut
    }

    /// Fetch reminders with a hard timeout, distinguishing a genuine empty result
    /// from the callback never returning.
    static func fetchReminders(_ store: EKEventStore,
                               matching predicate: NSPredicate,
                               timeout seconds: Double = 25) -> FetchOutcome {
        let sema = DispatchSemaphore(value: 0)
        var fetched: [EKReminder] = []
        store.fetchReminders(matching: predicate) { reminders in
            fetched = reminders ?? []
            sema.signal()
        }
        if sema.wait(timeout: .now() + seconds) == .timedOut {
            return .timedOut
        }
        return .success(fetched)
    }
}

extension CLIFailure {
    static func saveFailure(_ message: String) -> CLIFailure {
        .appError("Save failed: \(message)")
    }
}
