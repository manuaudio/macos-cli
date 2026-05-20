// Sources/macos-cli/Commands/ScriptCommand.swift
import ArgumentParser
import Foundation

struct ScriptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "script",
        abstract: "Run arbitrary JXA or AppleScript — agent escape hatch for one-off automation",
        subcommands: [Run.self]
    )

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Execute a script and return its result")

        @Option(name: .long, help: "JavaScript for Automation (JXA) code")
        var jxa: String?

        @Option(name: .long, help: "AppleScript code")
        var applescript: String?

        @Option(name: .long, help: "Path to a .js (JXA) or .scpt (AppleScript) file")
        var file: String?

        @Option(name: .long, help: "Timeout in seconds (default: 30)")
        var timeout: Int = 30

        @Flag(name: .long, help: "Suppress output, only report errors")
        var silent = false

        func run() throws {
            try Auth.check("script.run")

            var args = ["/usr/bin/osascript"]

            if let jxa = jxa {
                args += ["-l", "JavaScript", "-e", jxa]
            } else if let as_ = applescript {
                args += ["-e", as_]
            } else if let path = file {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                if url.pathExtension.lowercased() == "js" {
                    args += ["-l", "JavaScript", url.path]
                } else {
                    args.append(url.path)
                }
            } else {
                throw ValidationError("Specify --jxa, --applescript, or --file.")
            }

            let (out, err, code) = Process.captureWithStderr(args: args, timeout: TimeInterval(timeout))
            let stdoutTrim = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderrTrim = err.trimmingCharacters(in: .whitespacesAndNewlines)

            if code == -1 {
                throw ValidationError("Script timed out after \(timeout)s")
            }

            if code != 0 {
                let detail = stderrTrim.isEmpty ? stdoutTrim : stderrTrim
                throw ValidationError("Script exited \(code): \(detail)")
            }

            if !silent {
                if !stdoutTrim.isEmpty { print(stdoutTrim) }
                if !stderrTrim.isEmpty { fputs(stderrTrim + "\n", stderr) }
            }
        }
    }
}
