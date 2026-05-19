import ArgumentParser
import Foundation

struct DockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dock",
        abstract: "Manage Dock pinned apps — list, add, remove, restart",
        subcommands: [ListCmd.self, AddCmd.self, RemoveCmd.self, RestartCmd.self]
    )

    struct ListCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List pinned Dock apps")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            guard let output = Process.capture(
                args: ["/usr/bin/defaults", "read", "com.apple.dock", "persistent-apps"],
                timeout: 5), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if json { print("[]") } else { print("No pinned apps.") }
                return
            }

            let paths = output.components(separatedBy: "\n")
                .filter { $0.contains("_CFURLString = ") }
                .compactMap { line -> String? in
                    let parts = line.components(separatedBy: "= ")
                    guard parts.count >= 2 else { return nil }
                    return parts[1].trimmingCharacters(in: .init(charactersIn: "\" ;"))
                }

            if json {
                let items: [[String: Any]] = paths.map { path in
                    let url = URL(fileURLWithPath: path)
                    return [
                        "name": url.deletingPathExtension().lastPathComponent,
                        "path": path,
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted])
                print(String(data: data, encoding: .utf8)!)
            } else {
                if paths.isEmpty { print("No pinned apps."); return }
                for path in paths {
                    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                    print("\(name) — \(path)")
                }
            }
        }
    }

    struct AddCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Pin an app to the Dock")
        @Argument(help: "Path to .app bundle") var path: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ValidationError("App not found: \(path)")
            }
            let name = URL(fileURLWithPath: expanded).deletingPathExtension().lastPathComponent
            let entry = "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>\(expanded)</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
            let result = Process.run(args: [
                "/usr/bin/defaults", "write", "com.apple.dock",
                "persistent-apps", "-array-add", entry
            ])
            guard result == 0 else {
                throw ValidationError("Failed to add app to Dock (defaults write returned \(result))")
            }
            Process.run(args: ["/usr/bin/killall", "Dock"])
            if json {
                print("{\"added\": true, \"name\": \"\(name)\", \"path\": \"\(expanded)\"}")
            } else {
                print("Added to Dock: \(name) (Dock restarted)")
            }
        }
    }

    struct RemoveCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove an app from the Dock by name")
        @Argument(help: "App name (as shown in 'dock list')") var name: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let plistPath = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"
            guard let appsOutput = Process.capture(
                args: ["/usr/bin/defaults", "read", "com.apple.dock", "persistent-apps"],
                timeout: 5) else {
                throw ValidationError("Could not read Dock preferences.")
            }

            let lines = appsOutput.components(separatedBy: "\n")
            var currentIndex = -1
            var matchIndex = -1
            for line in lines {
                if line.contains("{") { currentIndex += 1 }
                if line.contains("_CFURLString = ") {
                    let path = line.components(separatedBy: "= ").last?
                        .trimmingCharacters(in: .init(charactersIn: "\" ;")) ?? ""
                    let appName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                    if appName.lowercased() == name.lowercased() {
                        matchIndex = currentIndex
                        break
                    }
                }
            }

            guard matchIndex >= 0 else {
                throw ValidationError("App not found in Dock: \(name). Use 'dock list' to see pinned apps.")
            }

            let result = Process.run(args: [
                "/usr/libexec/PlistBuddy", "-c",
                "Delete :persistent-apps:\(matchIndex)", plistPath
            ])
            guard result == 0 else {
                throw ValidationError("Failed to remove from Dock (PlistBuddy returned \(result))")
            }
            Process.run(args: ["/usr/bin/plutil", "-convert", "xml1", plistPath])
            Process.run(args: ["/usr/bin/killall", "Dock"])
            if json {
                print("{\"removed\": true, \"name\": \"\(name)\"}")
            } else {
                print("Removed from Dock: \(name) (Dock restarted)")
            }
        }
    }

    struct RestartCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart the Dock (applies pending changes)")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            Process.run(args: ["/usr/bin/killall", "Dock"])
            if json {
                print("{\"restarted\": true}")
            } else {
                print("Dock restarted.")
            }
        }
    }
}
