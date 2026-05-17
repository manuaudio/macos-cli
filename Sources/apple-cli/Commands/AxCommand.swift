import ArgumentParser
import Foundation

// Accessibility tree (AX) control via osascript System Events.
// Requires Accessibility permission: System Settings → Privacy → Accessibility → Terminal

struct AxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ax",
        abstract: "Accessibility tree — find and click UI elements by name",
        subcommands: [Find.self, Click.self, Read.self]
    )

    // MARK: - Find

    struct Find: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Find UI elements matching a name")

        @Argument(help: "Element name to find (button title, label text, etc.)")
        var name: String

        @Option(name: .long, help: "App name to inspect (default: frontmost)")
        var app: String?

        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let appSelector = app.map { "application process \"\($0)\"" } ?? "application process 1"
            let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            const se = Application('System Events');
            const proc = se.\(appSelector.contains("1") ? "applicationProcesses()[0]" : "applicationProcesses.whose({name: \"\(app ?? "")\"})()[0]");
            if (!proc) { JSON.stringify([]); }
            else {
                const found = [];
                function search(el) {
                    try {
                        const role = el.role ? el.role() : '';
                        const title = el.title ? el.title() : '';
                        const val = el.value ? el.value() : '';
                        const desc = el.description ? el.description() : '';
                        const q = '\(escaped)'.toLowerCase();
                        if ([title, val, desc].some(s => (s || '').toLowerCase().includes(q))) {
                            found.push({role, title, value: val, description: desc});
                        }
                        (el.uiElements ? el.uiElements() : []).slice(0, 50).forEach(search);
                    } catch(e) {}
                }
                try { proc.windows().slice(0, 3).forEach(w => search(w)); } catch(e) {}
                JSON.stringify(found.slice(0, 20));
            }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let elements = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                if raw.lowercased().contains("error") {
                    throw ValidationError("AX access failed — grant Accessibility to Terminal in System Settings\n\(raw.prefix(200))")
                }
                print("No elements found matching '\(name)'")
                return
            }
            if json {
                printJSON(elements)
            } else {
                for el in elements {
                    let role  = el["role"] as? String ?? ""
                    let title = el["title"] as? String ?? ""
                    let val   = el["value"] as? String ?? ""
                    print("[\(role)] title='\(title)' value='\(val)'")
                }
                print("\(elements.count) element(s) matching '\(name)'")
            }
        }
    }

    // MARK: - Click

    struct Click: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Click a UI element by name")

        @Argument(help: "Element name to click")
        var name: String

        @Option(name: .long, help: "App name") var app: String?

        func run() throws {
            let appName = app ?? ""
            let appSelector = appName.isEmpty
                ? "se.applicationProcesses()[0]"
                : "se.applicationProcesses.whose({name: \"\(appName)\"})()"
            let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            const se = Application('System Events');
            const procs = \(appName.isEmpty ? "[se.applicationProcesses()[0]]" : "se.applicationProcesses.whose({name: \"\(appName)\"})()");
            let clicked = false;
            function tryClick(el) {
                if (clicked) return;
                try {
                    const t = el.title ? el.title() : '';
                    const v = el.value ? el.value() : '';
                    const d = el.description ? el.description() : '';
                    const q = '\(escaped)'.toLowerCase();
                    if ([t, v, d].some(s => (s || '').toLowerCase().includes(q))) {
                        el.click();
                        clicked = true;
                        return;
                    }
                    (el.uiElements ? el.uiElements() : []).slice(0, 50).forEach(tryClick);
                } catch(e) {}
            }
            procs.slice(0, 1).forEach(p => {
                try { p.windows().slice(0, 3).forEach(w => tryClick(w)); } catch(e) {}
            });
            clicked ? 'clicked' : 'not found';
            """
            let result = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result == "clicked" {
                print("Clicked '\(name)'")
            } else if result.lowercased().contains("error") {
                throw ValidationError("AX click failed — grant Accessibility to Terminal\n\(result.prefix(200))")
            } else {
                throw ValidationError("Element '\(name)' not found in \(appName.isEmpty ? "frontmost app" : appName)")
            }
        }
    }

    // MARK: - Read

    struct Read: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Dump the UI tree of an app (top 2 levels)")

        @Option(name: .long, help: "App name (default: frontmost)") var app: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let appName = app ?? ""
            let script = """
            const se = Application('System Events');
            const proc = \(appName.isEmpty
                ? "se.applicationProcesses()[0]"
                : "se.applicationProcesses.whose({name: \"\(appName)\"})()" + "[0]");
            if (!proc) { JSON.stringify(null); }
            else {
                function dump(el, depth) {
                    const node = {};
                    try { node.role = el.role(); } catch {}
                    try { node.title = el.title(); } catch {}
                    try { node.value = String(el.value()).substring(0, 80); } catch {}
                    try { node.description = el.description(); } catch {}
                    if (depth < 2) {
                        try { node.children = (el.uiElements() || []).slice(0, 30).map(c => dump(c, depth+1)); } catch {}
                    }
                    return node;
                }
                const wins = [];
                try { proc.windows().slice(0, 3).forEach(w => wins.push(dump(w, 0))); } catch {}
                JSON.stringify({app: proc.name(), windows: wins});
            }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw != "null", !raw.isEmpty, let data = raw.data(using: .utf8),
                  let tree = try? JSONSerialization.jsonObject(with: data) else {
                if raw.lowercased().contains("error") {
                    throw ValidationError("AX read failed — grant Accessibility to Terminal\n\(raw.prefix(200))")
                }
                throw ValidationError("Could not read UI tree for \(appName.isEmpty ? "frontmost app" : appName)")
            }
            if json {
                printJSON(tree)
            } else {
                func printNode(_ node: Any, indent: String = "") {
                    guard let d = node as? [String: Any] else { return }
                    let role  = d["role"]  as? String ?? ""
                    let title = d["title"] as? String ?? ""
                    let val   = d["value"] as? String ?? ""
                    var parts: [String] = []
                    if !role.isEmpty  { parts.append("[\(role)]") }
                    if !title.isEmpty { parts.append("'\(title)'") }
                    if !val.isEmpty && val != "null" { parts.append("= \(val.prefix(60))") }
                    if !parts.isEmpty { print(indent + parts.joined(separator: " ")) }
                    if let children = d["children"] as? [Any] {
                        children.forEach { printNode($0, indent: indent + "  ") }
                    }
                }
                if let d = tree as? [String: Any] {
                    print("App: \(d["app"] as? String ?? "")")
                    (d["windows"] as? [Any] ?? []).forEach { printNode($0) }
                }
            }
        }
    }
}
