// Sources/macos-cli/Commands/MenuCommand.swift
import ArgumentParser
import Foundation

struct MenuCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menu",
        abstract: "Application menu bar — list items and click by path",
        subcommands: [List.self, Click.self]
    )

    // MARK: - List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List top-level menu items for an app (or the focused app)")
        @Option(name: .long, help: "App name (default: frontmost app)") var app: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("menu.read")

            let procClause: String
            if let app = app {
                let escaped = app.replacingOccurrences(of: "\"", with: "\\\"")
                procClause = "se.applicationProcesses.whose({name: \"\(escaped)\"})[0]"
            } else {
                procClause = "se.applicationProcesses.whose({frontmost: true})[0]"
            }

            let script = """
            const se = Application('System Events');
            const proc = \(procClause);
            if (!proc) throw new Error('App not found');
            const items = proc.menuBars[0].menuBarItems();
            JSON.stringify(items.map(i => {
                try { return { title: i.title(), enabled: i.enabled() }; }
                catch(e) { return null; }
            }).filter(Boolean));
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                throw ValidationError(
                    "Could not read menu bar. Requires Automation permission for System Events in System Settings → Privacy & Security.\nRaw: \(raw.prefix(200))"
                )
            }
            if json {
                printJSON(items)
            } else {
                for item in items {
                    let title   = item["title"] as? String ?? ""
                    let enabled = item["enabled"] as? Bool ?? true
                    print(enabled ? title : "(\(title))")
                }
            }
        }
    }

    // MARK: - Click

    struct Click: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Click a menu item by path, e.g. 'View > Show Sidebar'")
        @Argument(help: "Menu path separated by ' > ', e.g. \"View > Show Sidebar\"") var path: String
        @Option(name: .long, help: "App name (default: frontmost app)") var app: String?

        func run() throws {
            try Auth.check("menu.click")

            let parts = path.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !parts.isEmpty else { throw ValidationError("Menu path cannot be empty.") }

            let procClause: String
            if let app = app {
                let escaped = app.replacingOccurrences(of: "\"", with: "\\\"")
                procClause = "se.applicationProcesses.whose({name: \"\(escaped)\"})[0]"
            } else {
                procClause = "se.applicationProcesses.whose({frontmost: true})[0]"
            }

            // Build JSON array of path parts for JXA
            let partsJSON = parts.map { part -> String in
                let escaped = part.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }.joined(separator: ", ")

            let script = """
            const se = Application('System Events');
            const proc = \(procClause);
            if (!proc) throw new Error('App not found');
            const path = [\(partsJSON)];
            let target = proc.menuBars[0].menuBarItems.whose({title: path[0]})[0].menus[0];
            for (let i = 1; i < path.length - 1; i++) {
                target = target.menuItems.whose({title: path[i]})[0].menus[0];
            }
            target.menuItems.whose({title: path[path.length - 1]})[0].click();
            'ok';
            """
            let result = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "error")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result.lowercased().contains("error") || result == "error" {
                throw ValidationError(
                    "Could not click '\(path)'. Verify the path is correct and the app is frontmost. Automation permission for System Events is required.\nRaw: \(result.prefix(300))"
                )
            }
            print("Clicked: \(path)")
        }
    }
}
