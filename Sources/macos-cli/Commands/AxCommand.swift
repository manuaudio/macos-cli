import ArgumentParser
import Foundation
import ApplicationServices
import AppKit

// Accessibility tree (AX) control via osascript System Events.
// Requires Accessibility permission: System Settings → Privacy → Accessibility → Terminal

struct AxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ax",
        abstract: "Accessibility tree — find/click elements by name, or list interactive hints",
        subcommands: [Find.self, Click.self, Read.self, Hints.self]
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
            let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
            let procExpr = app == nil
                ? "se.applicationProcesses()[0]"
                : "se.applicationProcesses.whose({name: \"\(app!.replacingOccurrences(of: "\"", with: "\\\""))\"})(  )[0]"
            let script = """
            const se = Application('System Events');
            const proc = \(procExpr);
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
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
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
            try Auth.check("ax.write")
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
            let result = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
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

        @Argument(help: "App name (default: frontmost app)") var app: String?
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
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
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

    // MARK: - Hints

    struct Hints: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List all interactive UI elements with hint numbers (for agent use)"
        )

        @Option(name: .long, help: "App name (default: frontmost)") var app: String?
        @Flag(name: .long, help: "Output JSON") var json = false
        @Option(name: .long, help: "Click the element with this hint number") var click: Int?

        func run() throws {
            let appName = app ?? ""
            let elements = try collectHints(appName: appName)

            if let n = click {
                try Auth.check("ax.write")
                guard n >= 1 && n <= elements.count else {
                    throw ValidationError("Hint \(n) out of range (1–\(elements.count))")
                }
                let el = elements[n - 1]
                var err: AXError = .success
                err = AXUIElementPerformAction(el.ref, kAXPressAction as CFString)
                if err != .success {
                    err = AXUIElementPerformAction(el.ref, kAXConfirmAction as CFString)
                }
                if err != .success {
                    throw ValidationError("Could not activate hint \(n) (AXError \(err.rawValue))")
                }
                print("Clicked hint \(n): \(el.title)")
                return
            }

            if json {
                let arr = elements.enumerated().map { (i, e) -> [String: Any] in
                    var d: [String: Any] = ["hint": i + 1, "role": e.role, "title": e.title]
                    if !e.value.isEmpty { d["value"] = e.value }
                    return d
                }
                printJSON(arr)
            } else {
                for (i, e) in elements.enumerated() {
                    let detail = [e.role, e.title.isEmpty ? nil : "'\(e.title)'", e.value.isEmpty ? nil : "= \(e.value.prefix(40))"]
                        .compactMap { $0 }.joined(separator: " ")
                    print("[\(i + 1)] \(detail)")
                }
                print("\(elements.count) interactive element(s)")
            }
        }

        private struct HintElement {
            let ref: AXUIElement
            let role: String
            let title: String
            let value: String
        }

        private static let interactiveRoles: Set<String> = [
            "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXLink",
            "AXMenuItem", "AXRadioButton", "AXComboBox", "AXPopUpButton",
            "AXSlider", "AXIncrementor", "AXDecrementor", "AXTab"
        ]

        private func collectHints(appName: String) throws -> [HintElement] {
            let systemWide = AXUIElementCreateSystemWide()

            let target: AXUIElement
            if appName.isEmpty {
                var focused: CFTypeRef?
                AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focused)
                guard let app = focused else {
                    throw ValidationError("No focused application — pass --app <name>")
                }
                target = app as! AXUIElement
            } else {
                let ws = NSWorkspace.shared
                guard let runningApp = ws.runningApplications.first(where: {
                    $0.localizedName?.lowercased() == appName.lowercased()
                }) else {
                    throw ValidationError("App '\(appName)' not running")
                }
                target = AXUIElementCreateApplication(runningApp.processIdentifier)
            }

            var results: [HintElement] = []
            walk(element: target, results: &results, depth: 0)
            return results
        }

        private func walk(element: AXUIElement, results: inout [HintElement], depth: Int) {
            guard depth < 12 else { return }

            var roleVal: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal)
            let role = (roleVal as? String) ?? ""

            if Self.interactiveRoles.contains(role) {
                var titleVal: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleVal)
                let title = (titleVal as? String) ?? ""

                var valueVal: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueVal)
                let value = (valueVal as? String) ?? ""

                var enabled: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
                let isEnabled = (enabled as? Bool) ?? true

                if isEnabled && results.count < 200 {
                    results.append(HintElement(ref: element, role: role, title: title, value: value))
                }
            }

            var childrenVal: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal)
            guard let children = childrenVal as? [AXUIElement] else { return }
            for child in children.prefix(100) {
                walk(element: child, results: &results, depth: depth + 1)
            }
        }
    }
}
