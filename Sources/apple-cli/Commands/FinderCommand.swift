import ArgumentParser
import Foundation
import AppKit

struct FinderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finder",
        abstract: "Interact with Finder — selected files, reveal, open",
        subcommands: [Selected.self, Reveal.self, Open.self, Cwd.self]
    )

    struct Selected: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "selected",
            abstract: "Get paths of currently selected files in Finder"
        )
        @Flag(name: .long, help: "Output JSON array") var json = false

        func run() throws {
            let script = """
            var finder = Application("Finder");
            var sel = finder.selection();
            var paths = [];
            for (var i = 0; i < sel.length; i++) {
              try {
                var raw = sel[i].url();
                paths.push(decodeURIComponent(raw).replace("file://", ""));
              } catch(e) {
                try { paths.push(sel[i].name()); } catch(e2) {}
              }
            }
            JSON.stringify(paths);
            """
            guard let raw = jxa(script) else {
                fputs("Error: Could not reach Finder — check Automation permission\n", stderr)
                throw ExitCode.failure
            }
            if json {
                print(raw)
            } else {
                guard let data = raw.data(using: .utf8),
                      let paths = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                    print(raw); return
                }
                if paths.isEmpty {
                    print("Nothing selected in Finder")
                } else {
                    paths.forEach { print($0) }
                }
            }
        }
    }

    struct Reveal: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reveal",
            abstract: "Reveal a file or folder in Finder"
        )
        @Argument(help: "Path to reveal") var path: String

        func run() throws {
            let expanded = (path as NSString).expandingTildeInPath
            let escaped = expanded.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "'", with: "\\'")
            let script = """
            var finder = Application("Finder");
            finder.activate();
            finder.reveal(Path('\(escaped)'));
            'ok'
            """
            guard let r = jxa(script), r.contains("ok") else {
                fputs("Error: Could not reveal '\(path)'\n", stderr)
                throw ExitCode.failure
            }
            print("Revealed: \(expanded)")
        }
    }

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "open",
            abstract: "Open a file or folder in Finder"
        )
        @Argument(help: "Path to open") var path: String

        func run() throws {
            let expanded = (path as NSString).expandingTildeInPath
            // Use macOS open command — works for any path
            let result = Process.run(args: ["/usr/bin/open", expanded])
            guard result == 0 else {
                fputs("Error: Could not open '\(path)'\n", stderr)
                throw ExitCode.failure
            }
            print("Opened: \(expanded)")
        }
    }

    struct Cwd: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cwd",
            abstract: "Get the current folder shown in the front Finder window"
        )

        func run() throws {
            let script = """
            var finder = Application("Finder");
            var win = finder.windows()[0];
            try {
              var url = win.target().url();
              decodeURIComponent(url).replace("file://","");
            } catch(e) {
              win.name();
            }
            """
            guard let raw = jxa(script) else {
                fputs("Error: Could not read Finder window\n", stderr)
                throw ExitCode.failure
            }
            print(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private func jxa(_ expr: String) -> String? {
    guard let raw = Process.capture(
        args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", expr],
        timeout: 8
    ) else { return nil }
    let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !r.lowercased().contains("not allowed"), !r.lowercased().contains("error") else { return nil }
    return r
}
