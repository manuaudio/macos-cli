import ArgumentParser
import Foundation

struct LoginItemsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login-items",
        abstract: "Manage login items (apps that launch at startup)",
        subcommands: [ListCmd.self, AddCmd.self, RemoveCmd.self]
    )

    struct ListCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List current login items")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let script = """
            tell application "System Events"
                set itemList to {}
                repeat with li in login items
                    set end of itemList to (name of li) & "|" & (path of li) & "|" & (hidden of li as string)
                end repeat
                return itemList
            end tell
            """
            guard let output = Process.capture(args: ["/usr/bin/osascript", "-e", script], timeout: 10) else {
                throw ValidationError("Login items query timed out — Automation permission for System Events may be missing.")
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let items: [[String: Any]] = trimmed.isEmpty ? [] : trimmed
                .components(separatedBy: ", ")
                .compactMap { entry -> [String: Any]? in
                    let parts = entry.components(separatedBy: "|")
                    guard parts.count >= 3 else { return nil }
                    return [
                        "name": parts[0].trimmingCharacters(in: .whitespaces),
                        "path": parts[1].trimmingCharacters(in: .whitespaces),
                        "hidden": parts[2].trimmingCharacters(in: .whitespaces) == "true",
                    ]
                }
            if json {
                let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted])
                print(String(data: data, encoding: .utf8)!)
            } else {
                if items.isEmpty { print("No login items."); return }
                print(String(format: "%-30s %s", "NAME", "PATH"))
                print(String(repeating: "-", count: 70))
                for item in items {
                    print(String(format: "%-30s %s",
                        String((item["name"] as? String ?? "").prefix(28)),
                        item["path"] as? String ?? ""))
                }
            }
        }
    }

    struct AddCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Add an app to login items")
        @Argument(help: "Path to the .app bundle") var path: String
        @Flag(name: .long, help: "Launch hidden (no window on startup)") var hidden = false
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("login-items.write")
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ValidationError("Path not found: \(path)")
            }
            let hiddenStr = hidden ? "true" : "false"
            let script = """
            tell application "System Events"
                make new login item at end with properties {hidden:\(hiddenStr), path:"\(expanded)"}
            end tell
            """
            guard Process.capture(args: ["/usr/bin/osascript", "-e", script], timeout: 10) != nil else {
                throw ValidationError("Add login item timed out.")
            }
            let name = URL(fileURLWithPath: expanded).deletingPathExtension().lastPathComponent
            if json {
                print("{\"added\": true, \"name\": \"\(name)\", \"path\": \"\(expanded)\"}")
            } else {
                print("Added login item: \(name)")
            }
        }
    }

    struct RemoveCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a login item by name")
        @Argument(help: "App name (as shown in 'login-items list')") var name: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("login-items.write")
            let script = """
            tell application "System Events"
                delete (first login item whose name is "\(name)")
            end tell
            """
            guard let result = Process.capture(args: ["/usr/bin/osascript", "-e", script], timeout: 10) else {
                throw ValidationError("Remove login item timed out.")
            }
            if result.lowercased().contains("error") {
                throw ValidationError("Login item not found: \(name)")
            }
            if json {
                print("{\"removed\": true, \"name\": \"\(name)\"}")
            } else {
                print("Removed login item: \(name)")
            }
        }
    }
}
