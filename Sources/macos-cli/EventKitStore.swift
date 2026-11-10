import EventKit
import Foundation

/// Shared EventKit store with synchronous access request.
/// Checks existing authorization first (synchronous). If not determined,
/// fires requestAccess from the main queue and spins the run loop.
enum EventKitStore {
    static func authorized(for type: EKEntityType) throws -> EKEventStore {
        let store = EKEventStore()

        // Fast path: already authorized — no need to request
        let status = EKEventStore.authorizationStatus(for: type)
        var isAuthorized = status == .authorized
        if #available(macOS 14.0, *) { isAuthorized = isAuthorized || status == .fullAccess }
        if isAuthorized {
            return store
        }
        if status == .denied || status == .restricted {
            throw CLIFailure.notAuthorized(type)
        }

        // Not determined — request access. Must spin the main run loop.
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
                case .event:
                    store.requestFullAccessToEvents(completion: completion)
                case .reminder:
                    store.requestFullAccessToReminders(completion: completion)
                @unknown default:
                    store.requestAccess(to: type, completion: completion)
                }
            } else {
                store.requestAccess(to: type, completion: completion)
            }
        }

        let deadline = CFAbsoluteTimeGetCurrent() + 15
        while !done && CFAbsoluteTimeGetCurrent() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.1, false)
        }

        if !done {
            throw CLIFailure.authTimeout(type)
        }
        if let err = authError {
            throw err
        }
        guard granted else {
            throw CLIFailure.notAuthorized(type)
        }
        return store
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
    static func notAuthorized(_ type: EKEntityType) -> CLIFailure {
        let area = type == .reminder ? "Reminders" : "Calendars"
        return CLIFailure(code: "access_denied",
                          message: "Access to \(area) is not authorized for this binary.",
                          hint: "Grant it in System Settings › Privacy & Security › \(area), then retry.",
                          extra: ["entity": type == .reminder ? "reminder" : "calendar"])
    }

    static func authTimeout(_ type: EKEntityType) -> CLIFailure {
        let area = type == .reminder ? "Reminders" : "Calendars"
        return CLIFailure(code: "timeout",
                          message: "The \(area) permission request was not answered within 15 s.",
                          hint: "Run the command once in a logged-in Terminal and allow access, "
                              + "or grant it in System Settings › Privacy & Security › \(area).",
                          extra: ["entity": type == .reminder ? "reminder" : "calendar"])
    }

    static func saveFailure(_ message: String) -> CLIFailure {
        .appError("Save failed: \(message)")
    }
}
