import ArgumentParser
import Foundation
import MacCLICore

/// A failure that is not a usage mistake: something was not found, was denied,
/// timed out or broke. `MacOSCLI.main` reports it as the JSON error envelope under
/// `--json` and as one `Error:` line otherwise, and exits with its code's status
/// (see `MacCLICore.exitCode(forErrorCode:)`).
///
/// A rejected command line stays an ArgumentParser `ValidationError` (exit 64).
struct CLIFailure: Error, CustomStringConvertible {
    let code: String
    let message: String
    var hint: String?
    var extra: [String: Any] = [:]

    var description: String { message }
    var exitCode: Int32 { MacCLICore.exitCode(forErrorCode: code) }
    var envelope: [String: Any] {
        MacCLICore.errorEnvelope(code: code, message: message, hint: hint, extra: extra)
    }

    init(code: String, message: String, hint: String? = nil, extra: [String: Any] = [:]) {
        self.code = code
        self.message = message
        self.hint = hint
        self.extra = extra
    }

    /// Wrap a ready-made envelope from `MacCLICore` (`dateParseErrorJSON` and friends).
    init(envelope: [String: Any]) {
        var extra = envelope
        for key in ["ok", "status", "error", "message", "hint", "exit_code"] { extra[key] = nil }
        self.init(code: envelope["error"] as? String ?? "app_error",
                  message: envelope["message"] as? String ?? "",
                  hint: envelope["hint"] as? String,
                  extra: extra)
    }

    static func notFound(_ message: String, hint: String? = nil) -> CLIFailure {
        CLIFailure(code: "not_found", message: message, hint: hint)
    }

    static func timeout(_ message: String, hint: String? = nil) -> CLIFailure {
        CLIFailure(code: "timeout", message: message, hint: hint)
    }

    static func permission(_ message: String, hint: String? = nil) -> CLIFailure {
        CLIFailure(code: "access_denied", message: message, hint: hint)
    }

    static func appError(_ message: String, hint: String? = nil) -> CLIFailure {
        CLIFailure(code: "app_error", message: message, hint: hint)
    }
}

extension MacOSCLI {
    /// Parse, run, and report every failure through one path.
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let machine = MacCLICore.wantsMachineErrors(arguments: arguments)

        var command: ParsableCommand
        do {
            command = try parseAsRoot(arguments)
        } catch {
            // --help and --version arrive here as clean exits; they print as usual.
            guard machine, exitCode(for: error) != .success else { exit(withError: error) }
            var message = MacOSCLI.message(for: error)
            var hint = "Run the command with --help to see its options."
            if message.contains("'--json'") {
                message = "This command has no --json output."
                hint = "Run it without --json; the README lists the commands that print JSON."
            }
            report(CLIFailure(code: "usage", message: message, hint: hint), machine: true)
        }

        do {
            try command.run()
            Foundation.exit(0)
        } catch let failure as CLIFailure {
            report(failure, machine: machine)
        } catch let error as ValidationError {
            report(CLIFailure(code: "usage", message: error.message,
                              hint: "Run the command with --help to see its options."),
                   machine: machine)
        } catch let error as ExitCode {
            // The command has already reported; keep its status.
            exit(withError: error)
        } catch {
            if exitCode(for: error) == .success { exit(withError: error) }
            report(.appError(error.localizedDescription), machine: machine)
        }
    }

    private static func report(_ failure: CLIFailure, machine: Bool) -> Never {
        if machine {
            printJSON(failure.envelope)
        } else {
            var text = "Error: \(failure.message)\n"
            if let hint = failure.hint { text += "Hint: \(hint)\n" }
            fputs(text, stderr)
        }
        Foundation.exit(failure.exitCode)
    }
}
