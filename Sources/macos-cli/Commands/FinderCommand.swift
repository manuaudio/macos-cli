import ArgumentParser
import Foundation
import AppKit

struct FinderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finder",
        abstract: "Interact with Finder — selected files, reveal, open",
        subcommands: [Selected.self, Reveal.self, Open.self, Cwd.self,
                      NewFolder.self, Rename.self, Tag.self, GoTo.self, ShowHidden.self]
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
        @Flag(name: .long, help: "Output JSON") var json = false

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
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if json {
                let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "\"", with: "\\\"")
                print("{\"path\":\"\(escaped)\"}")
            } else {
                print(path)
            }
        }
    }

    // MARK: - NewFolder

    struct NewFolder: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "new-folder",
            abstract: "Create a new folder and reveal it in Finder"
        )
        @Option(name: .long, help: "Full path for the new folder (required)") var path: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let expanded = (path as NSString).expandingTildeInPath
            do {
                try FileManager.default.createDirectory(atPath: expanded,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
            } catch {
                throw ValidationError("Could not create folder '\(expanded)': \(error.localizedDescription)")
            }
            // Reveal in Finder
            let escaped = expanded.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "'", with: "\\'")
            let script = """
            var finder = Application("Finder");
            finder.activate();
            finder.reveal(Path('\(escaped)'));
            'ok'
            """
            _ = jxa(script)
            if json {
                printJSON(["created": true, "path": expanded])
            } else {
                print("Created: \(expanded)")
            }
        }
    }

    // MARK: - Rename

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: "Rename a file or folder"
        )
        @Option(name: .long, help: "Current path (required)") var from: String
        @Option(name: .long, help: "New name (or full new path)") var to: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let fromExpanded = (from as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: fromExpanded) else {
                throw ValidationError("Source not found: \(fromExpanded)")
            }
            // If `to` contains a slash and starts with / or ~, treat it as a full path; else it's just a name
            let toExpanded: String
            if to.hasPrefix("/") || to.hasPrefix("~") {
                toExpanded = (to as NSString).expandingTildeInPath
            } else {
                let dir = (fromExpanded as NSString).deletingLastPathComponent
                toExpanded = (dir as NSString).appendingPathComponent(to)
            }
            do {
                try FileManager.default.moveItem(atPath: fromExpanded, toPath: toExpanded)
            } catch {
                throw ValidationError("Could not rename: \(error.localizedDescription)")
            }
            if json {
                printJSON(["renamed": true, "from": fromExpanded, "to": toExpanded])
            } else {
                print("Renamed: \(fromExpanded) → \(toExpanded)")
            }
        }
    }

    // MARK: - Tag

    struct Tag: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tag",
            abstract: "Read or write Finder color tags on a file or folder"
        )
        @Option(name: .long, help: "File or folder path (required)") var path: String
        @Option(name: .long, help: "Add tag: red, orange, yellow, green, blue, purple, gray") var add: String?
        @Option(name: .long, help: "Remove tag by color") var remove: String?
        @Flag(name: .long, help: "List current tags") var list = false
        @Flag(name: .long, help: "Output JSON") var json = false

        // Finder tag color names mapped to their Finder label index (1-7)
        private static let colorNames = ["gray", "green", "purple", "blue", "yellow", "red", "orange"]

        func run() throws {
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ValidationError("Path not found: \(expanded)")
            }

            if list || (add == nil && remove == nil) {
                // Read tags via xattr
                let raw = Process.capture(args: ["/usr/bin/xattr", "-p",
                    "com.apple.metadata:_kMDItemUserTags", expanded], timeout: 5, fallback: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty || raw.contains("No such xattr") {
                    if json { printJSON(["tags": []]) } else { print("No tags") }
                } else {
                    // xattr returns hex plist; decode via plutil
                    let hexDecoded = Process.capture(args: ["/usr/bin/xattr", "-pl",
                        "com.apple.metadata:_kMDItemUserTags", expanded], timeout: 5, fallback: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if json { printJSON(["tags": hexDecoded]) } else { print("Tags: \(hexDecoded)") }
                }
                return
            }

            // Write tags: use `tag` CLI if available, else fall back to xattr approach
            let tagCLI = "/usr/local/bin/tag"
            if FileManager.default.fileExists(atPath: tagCLI) {
                if let colorToAdd = add {
                    let result = Process.capture(args: [tagCLI, "--add", colorToAdd, expanded], timeout: 5, fallback: "")
                    if result.lowercased().contains("error") {
                        throw ValidationError("Could not add tag '\(colorToAdd)': \(result.prefix(200))")
                    }
                    if !json { print("Added tag '\(colorToAdd)' to \(expanded)") }
                }
                if let colorToRemove = remove {
                    let result = Process.capture(args: [tagCLI, "--remove", colorToRemove, expanded], timeout: 5, fallback: "")
                    if result.lowercased().contains("error") {
                        throw ValidationError("Could not remove tag '\(colorToRemove)': \(result.prefix(200))")
                    }
                    if !json { print("Removed tag '\(colorToRemove)' from \(expanded)") }
                }
                if json { printJSON(["path": expanded, "added": add ?? "", "removed": remove ?? ""]) }
            } else {
                // Fallback: use JXA labelIndex for color tags
                let colorIndex: Int
                if let c = add ?? remove {
                    switch c.lowercased() {
                    case "red":    colorIndex = 2
                    case "orange": colorIndex = 7
                    case "yellow": colorIndex = 5
                    case "green":  colorIndex = 6
                    case "blue":   colorIndex = 4
                    case "purple": colorIndex = 3
                    case "gray":   colorIndex = 1
                    default: throw ValidationError("Unknown color '\(c)'. Use: red, orange, yellow, green, blue, purple, gray")
                    }
                } else { colorIndex = 0 }

                let escaped = expanded.replacingOccurrences(of: "\\", with: "\\\\")
                                      .replacingOccurrences(of: "'", with: "\\'")
                let setIndex = remove != nil ? 0 : colorIndex
                let script = """
                var finder = Application("Finder");
                var item = finder.items.whose({url: 'file://\(escaped)'})[0];
                item.labelIndex = \(setIndex);
                'ok'
                """
                guard let r = jxa(script), r.contains("ok") else {
                    fputs("Warning: Could not set tag via JXA (install `tag` CLI for full support: brew install tag)\n", stderr)
                    throw ExitCode.failure
                }
                if json { printJSON(["path": expanded, "labelIndex": setIndex]) }
                else { print("Tag set (label index \(setIndex)) on \(expanded)") }
            }
        }
    }

    // MARK: - GoTo

    struct GoTo: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "go-to",
            abstract: "Navigate the front Finder window to a directory"
        )
        @Option(name: .long, help: "Directory path to navigate to (required)") var path: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let expanded = (path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                throw ValidationError("Not a directory: \(expanded)")
            }
            let escaped = expanded.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "'", with: "\\'")
            let script = """
            var finder = Application("Finder");
            finder.activate();
            var wins = finder.windows();
            if (wins.length > 0) {
                wins[0].target = Path('\(escaped)');
            } else {
                finder.open(Path('\(escaped)'));
            }
            'ok'
            """
            guard let r = jxa(script), r.contains("ok") else {
                fputs("Error: Could not navigate Finder to '\(expanded)'\n", stderr)
                throw ExitCode.failure
            }
            if json {
                printJSON(["navigated": true, "path": expanded])
            } else {
                print("Finder → \(expanded)")
            }
        }
    }

    // MARK: - ShowHidden

    struct ShowHidden: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show-hidden",
            abstract: "Toggle or check the 'Show hidden files' Finder setting"
        )
        @Flag(name: .long, help: "Enable showing hidden files") var on = false
        @Flag(name: .long, help: "Disable showing hidden files") var off = false
        @Flag(name: .long, help: "Print current state (default when no flag given)") var status = false
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            if !on && !off {
                // Status mode
                let raw = Process.capture(args: ["/usr/bin/defaults", "read",
                    "com.apple.finder", "AppleShowAllFiles"], timeout: 5, fallback: "0")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let isOn = raw == "1" || raw.lowercased() == "yes" || raw.lowercased() == "true"
                if json {
                    printJSON(["show_hidden": isOn])
                } else {
                    print("Show hidden files: \(isOn ? "on" : "off")")
                }
                return
            }
            if on && off { throw ValidationError("Specify either --on or --off, not both") }

            let value = on ? "YES" : "NO"
            _ = Process.run(args: ["/usr/bin/defaults", "write", "com.apple.finder", "AppleShowAllFiles", value])
            _ = Process.run(args: ["/usr/bin/killall", "Finder"])

            if json {
                printJSON(["show_hidden": on])
            } else {
                print("Show hidden files: \(on ? "on" : "off") (Finder restarted)")
            }
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
