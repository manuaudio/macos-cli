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

            let paths: [String] = output.components(separatedBy: "\n")
                .filter { $0.contains("_CFURLString\"") && $0.contains(" = ") }
                .compactMap { line -> String? in
                    // line format: `"_CFURLString" = "file:///...";` or `_CFURLString = "/path/...";`
                    guard let eqRange = line.range(of: " = ") else { return nil }
                    let raw = String(line[eqRange.upperBound...])
                        .trimmingCharacters(in: .init(charactersIn: "\" ;"))
                    if raw.hasPrefix("file://") {
                        let decoded = raw.replacingOccurrences(of: "file://", with: "")
                            .removingPercentEncoding ?? raw
                        return decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
                    }
                    return raw
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
            try Auth.check("dock.write")
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ValidationError("App not found: \(path)")
            }
            let name = URL(fileURLWithPath: expanded).deletingPathExtension().lastPathComponent

            let newEntry: [String: Any] = [
                "tile-data": [
                    "file-data": [
                        "_CFURLString": "file://" + expanded,
                        "_CFURLStringType": 15
                    ]
                ],
                "tile-type": "file-tile"
            ]

            let plistPath = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"
            guard let plistData = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                  var plist = try? PropertyListSerialization.propertyList(from: plistData, options: [.mutableContainersAndLeaves], format: nil) as? [String: Any] else {
                throw ValidationError("Could not read Dock preferences plist at \(plistPath)")
            }

            var apps = plist["persistent-apps"] as? [[String: Any]] ?? []
            apps.append(newEntry)
            plist["persistent-apps"] = apps

            let outData: Data
            do {
                outData = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            } catch {
                throw ValidationError("Could not serialize Dock plist: \(error.localizedDescription)")
            }
            do {
                try outData.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            } catch {
                throw ValidationError("Could not write Dock plist: \(error.localizedDescription)")
            }

            _ = Process.run(args: ["/usr/bin/killall", "Dock"])
            if json {
                let payload: [String: Any] = ["added": true, "name": name, "path": expanded]
                printJSON(payload)
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
            try Auth.check("dock.write")
            let plistPath = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"
            guard let plistData = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                  var plist = try? PropertyListSerialization.propertyList(from: plistData, options: [.mutableContainersAndLeaves], format: nil) as? [String: Any] else {
                throw ValidationError("Could not read Dock preferences plist at \(plistPath)")
            }
            var apps = plist["persistent-apps"] as? [[String: Any]] ?? []

            let lowerName = name.lowercased()
            let beforeCount = apps.count
            apps.removeAll { entry in
                let tileData = entry["tile-data"] as? [String: Any]
                let fileData = tileData?["file-data"] as? [String: Any]
                guard let urlStr = fileData?["_CFURLString"] as? String else { return false }
                let posix: String = {
                    if urlStr.hasPrefix("file://") {
                        let decoded = urlStr.replacingOccurrences(of: "file://", with: "").removingPercentEncoding ?? urlStr
                        return decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
                    }
                    return urlStr
                }()
                let entryName = URL(fileURLWithPath: posix).deletingPathExtension().lastPathComponent
                return entryName.lowercased() == lowerName
            }
            guard apps.count < beforeCount else {
                throw ValidationError("App not found in Dock: \(name). Use 'dock list' to see pinned apps.")
            }
            plist["persistent-apps"] = apps

            let outData: Data
            do {
                outData = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            } catch {
                throw ValidationError("Could not serialize Dock plist: \(error.localizedDescription)")
            }
            do {
                try outData.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            } catch {
                throw ValidationError("Could not write Dock plist: \(error.localizedDescription)")
            }
            _ = Process.run(args: ["/usr/bin/killall", "Dock"])
            if json {
                printJSON(["removed": true, "name": name] as [String: Any])
            } else {
                print("Removed from Dock: \(name) (Dock restarted)")
            }
        }
    }

    struct RestartCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart the Dock (applies pending changes)")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("dock.write")
            Process.run(args: ["/usr/bin/killall", "Dock"])
            if json {
                print("{\"restarted\": true}")
            } else {
                print("Dock restarted.")
            }
        }
    }
}
