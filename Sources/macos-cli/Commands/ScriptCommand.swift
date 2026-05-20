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

            let result = Process.capture(args: args, timeout: TimeInterval(timeout), fallback: "")
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.lowercased().hasPrefix("error:") || trimmed.lowercased().hasPrefix("execution error:") {
                throw ValidationError("Script error: \(trimmed)")
            }

            if !silent {
                print(trimmed)
            }
        }
    }
}
