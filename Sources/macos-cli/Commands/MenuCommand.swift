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
                procClause = "se.applicationProcesses.whose({name: \"\(jxaEscape(app))\"})[0]"
            } else {
                procClause = "se.applicationProcesses.whose({frontmost: true})[0]"
            }

            let script = """
            try {
            const se = Application('System Events');
            const proc = \(procClause);
            if (!proc) throw new Error('App not found');
            const items = proc.menuBars[0].menuBarItems();
            JSON.stringify({ok:true, result:items.map(i => {
                try { return { title: i.title(), enabled: i.enabled() }; }
                catch(e) { return null; }
            }).filter(Boolean)});
            } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw ValidationError(
                    "Could not read menu bar. Requires Automation permission for System Events in System Settings → Privacy & Security.\nRaw: \(errMsg.prefix(200))"
                )
            }
            guard let data = env.resultJSON.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                throw ValidationError(
                    "Could not read menu bar. Requires Automation permission for System Events in System Settings → Privacy & Security.\nRaw: \(env.resultJSON.prefix(200))"
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
                procClause = "se.applicationProcesses.whose({name: \"\(jxaEscape(app))\"})[0]"
            } else {
                procClause = "se.applicationProcesses.whose({frontmost: true})[0]"
            }

            // Build JSON array of path parts for JXA
            let partsJSON = parts.map { "\"\(jxaEscape($0))\"" }.joined(separator: ", ")

            let script: String
            if parts.count == 1 {
                script = """
                try {
                    const se = Application('System Events');
                    const proc = \(procClause);
                    if (!proc) { JSON.stringify({ok:false, error:'App not found'}); }
                    else {
                        const path = [\(partsJSON)];
                        proc.menuBars[0].menuBarItems.whose({title: path[0]})[0].click();
                        JSON.stringify({ok:true, result:'clicked'});
                    }
                } catch (e) {
                    JSON.stringify({ok:false, error: String(e && e.message ? e.message : e)});
                }
                """
            } else {
                script = """
                try {
                    const se = Application('System Events');
                    const proc = \(procClause);
                    if (!proc) { JSON.stringify({ok:false, error:'App not found'}); }
                    else {
                        const path = [\(partsJSON)];
                        let target = proc.menuBars[0].menuBarItems.whose({title: path[0]})[0].menus[0];
                        for (let i = 1; i < path.length - 1; i++) {
                            target = target.menuItems.whose({title: path[i]})[0].menus[0];
                        }
                        target.menuItems.whose({title: path[path.length - 1]})[0].click();
                        JSON.stringify({ok:true, result:'clicked'});
                    }
                } catch (e) {
                    JSON.stringify({ok:false, error: String(e && e.message ? e.message : e)});
                }
                """
            }
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
            guard let env = parseJXAEnvelope(raw) else {
                throw ValidationError("Could not click '\(path)'. Empty or unparseable JXA result.\nRaw: \(raw.prefix(300))")
            }
            if !env.ok {
                throw ValidationError(
                    "Could not click '\(path)'. Verify the path is correct and Automation permission for System Events is granted.\n\(env.error)"
                )
            }
            print("Clicked: \(path)")
        }
    }
}
