import ArgumentParser
import Foundation

struct ShortcutsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shortcuts",
        abstract: "Run and list Apple Shortcuts",
        subcommands: [List.self, Run.self]
    )

    // MARK: - List
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all shortcuts")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            guard let output = Process.capture(args: ["/usr/bin/shortcuts", "list"], timeout: 15) else {
                throw ValidationError("shortcuts list timed out after 15s")
            }
            let names = output
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if json {
                printJSON(names)
            } else {
                names.forEach { print($0) }
                print("\(names.count) shortcuts")
            }
        }
    }

    // MARK: - Run
    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a shortcut by name")

        @Argument(help: "Shortcut name")
        var name: String

        @Option(name: .long, help: "Input text to pass to the shortcut via stdin")
        var input: String?

        @Flag(name: .long, help: "Output JSON (wraps shortcut output in {name, output})")
        var json = false

        func run() throws {
            try Auth.check("shortcuts.run")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            proc.arguments = ["run", name]

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            if let inp = input {
                let inPipe = Pipe()
                proc.standardInput = inPipe
                inPipe.fileHandleForWriting.write(inp.data(using: .utf8) ?? Data())
                inPipe.fileHandleForWriting.closeFile()
            }

            guard (try? proc.run()) != nil else {
                throw ValidationError("Failed to launch shortcuts binary")
            }

            let deadline = Date().addingTimeInterval(30)
            while proc.isRunning {
                if Date() > deadline {
                    proc.terminate()
                    throw ValidationError("Shortcut '\(name)' timed out after 30s")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }

            let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errOut = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            if proc.terminationStatus != 0 {
                let msg = errOut.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ValidationError(msg.isEmpty ? "Shortcut '\(name)' not found or failed (exit \(proc.terminationStatus))" : msg)
            }

            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if json {
                printJSON(["name": name, "output": trimmed])
            } else if trimmed.isEmpty {
                print("Ran: \(name)")
            } else {
                print(trimmed)
            }
        }
    }
}
