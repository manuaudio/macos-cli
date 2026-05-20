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
            throw CLIError.notAuthorized(type)
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
            throw CLIError.authTimeout
        }
        if let err = authError {
            throw err
        }
        guard granted else {
            throw CLIError.notAuthorized(type)
        }
        return store
    }
}

enum CLIError: LocalizedError {
    case authTimeout
    case notAuthorized(EKEntityType)
    case noDefaultList
    case saveFailure(String)

    var errorDescription: String? {
        switch self {
        case .authTimeout:
            return "TCC authorization timed out — grant access in System Preferences > Privacy & Security"
        case .notAuthorized(let t):
            return "Access denied to \(t == .reminder ? "Reminders" : "Calendar") — grant in Privacy & Security"
        case .noDefaultList:
            return "No default list found"
        case .saveFailure(let msg):
            return "Save failed: \(msg)"
        }
    }
}
