import Foundation

/// The one error contract every command shares.
///
/// Under `--json` (and always for the `export` commands) a failure is a single JSON
/// object on stdout, stderr stays empty, and the process exits with the code below:
///
///     { "ok": false, "status": "error", "error": "<code>",
///       "message": "<what happened>", "hint": "<what to do>", "exit_code": <n> }
///
/// `error` is the stable code to branch on; `message` and `hint` are for people and
/// may change between releases. A command may add context keys (`field`, `id`, …).
extension MacCLICore {

    /// Exit status for an error code.
    ///
    ///  64  usage — the command line or a value in it was rejected (`usage`, `invalid_*`)
    ///   3  not found — the named calendar, event, file, app … does not exist
    ///   4  permission — denied by `auth.json` or by macOS privacy settings
    ///   5  timeout — the system or the app did not answer in time
    ///   6  app error — anything else the system or an app reported
    public static func exitCode(forErrorCode code: String) -> Int32 {
        switch code {
        case "usage", "invalid_argument": return 64
        case _ where code.hasPrefix("invalid_"): return 64
        case "not_found", "calendar_not_found", "event_not_found": return 3
        case "capability_denied", "access_denied": return 4
        case "timeout", "fetch_timeout": return 5
        default: return 6
        }
    }

    /// The error envelope. `extra` adds context keys; it can never override the
    /// contract keys.
    public static func errorEnvelope(code: String, message: String, hint: String? = nil,
                                     extra: [String: Any] = [:]) -> [String: Any] {
        var body = extra
        body["ok"] = false
        body["status"] = "error"
        body["error"] = code
        body["message"] = message
        body["exit_code"] = Int(exitCode(forErrorCode: code))
        if let hint = hint, !hint.isEmpty { body["hint"] = hint }
        return body
    }

    /// True when a failure should be reported as JSON: the caller asked for `--json`,
    /// or the command is one of the exports, which only ever speak JSON.
    public static func wantsMachineErrors(arguments: [String]) -> Bool {
        let operands = arguments.prefix { $0 != "--" }
        if operands.contains("--json") { return true }
        let words = operands.filter { !$0.hasPrefix("-") }
        guard words.count >= 2 else { return false }
        return ["calendar", "contacts", "notes", "reminders"].contains(words[0]) && words[1] == "export"
    }
}
