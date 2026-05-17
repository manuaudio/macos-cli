import ArgumentParser
import Foundation

// Safari control via JXA. Requires Automation permission for Safari in System Settings → Privacy.

struct SafariCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "safari",
        abstract: "Control Safari — list tabs, open URLs, read page content",
        subcommands: [Tabs.self, Open.self, Read.self, Execute.self]
    )

    // MARK: - Tabs

    struct Tabs: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List open Safari tabs")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let script = """
            const Safari = Application('Safari');
            const out = [];
            Safari.windows().forEach((w, wi) => {
                try {
                    w.tabs().forEach((t, ti) => {
                        try {
                            out.push({window: wi, tab: ti, title: t.name(), url: t.url(),
                                      current: t === w.currentTab()});
                        } catch(e) {}
                    });
                } catch(e) {}
            });
            JSON.stringify(out);
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let tabs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not read Safari tabs — check Automation permission for Safari in System Settings")
            }
            if json {
                printJSON(tabs)
            } else {
                for t in tabs {
                    let cur   = (t["current"] as? Bool ?? false) ? " ←" : ""
                    let title = t["title"] as? String ?? ""
                    let url   = t["url"]   as? String ?? ""
                    let wi    = t["window"] as? Int ?? 0
                    let ti    = t["tab"]   as? Int ?? 0
                    print("[\(wi):\(ti)]\(cur) \(title)")
                    print("       \(url.prefix(80))")
                }
                print("\(tabs.count) tab(s)")
            }
        }
    }

    // MARK: - Open

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a URL in Safari")

        @Argument(help: "URL to open")
        var url: String

        @Flag(name: .long, help: "Open in new tab (default: new tab)") var newTab = false

        func run() throws {
            let escaped = url.replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            const Safari = Application('Safari');
            Safari.activate();
            Safari.openLocation('\(escaped)');
            'ok';
            """
            let result = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script])
            if result.lowercased().contains("error") {
                throw ValidationError("Could not open URL — check Automation permission for Safari\n\(result.prefix(200))")
            }
            print("Opened: \(url)")
        }
    }

    // MARK: - Read

    struct Read: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get text content of current Safari tab")

        @Option(name: .long, help: "Window index (default: 0)") var window: Int = 0
        @Option(name: .long, help: "Tab index (default: current tab)") var tab: Int = -1
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let tabSelector = tab >= 0 ? ".tabs()[\(tab)]" : ".currentTab()"
            let script = """
            const Safari = Application('Safari');
            const w = Safari.windows()[\(window)];
            const t = w\(tabSelector);
            const title = t.name();
            const url = t.url();
            // Execute JS to get innerText
            const body = Safari.doJavaScript('document.body ? document.body.innerText.substring(0, 5000) : ""', {in: t});
            JSON.stringify({title, url, body});
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ValidationError("Could not read Safari tab — check Automation permission\n\(raw.prefix(200))")
            }
            if json {
                printJSON(page)
            } else {
                print("Title: \(page["title"] as? String ?? "")")
                print("URL:   \(page["url"] as? String ?? "")")
                print("---")
                print(page["body"] as? String ?? "")
            }
        }
    }

    // MARK: - Execute

    struct Execute: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Execute JavaScript in the current Safari tab")

        @Argument(help: "JavaScript to execute")
        var js: String

        @Option(name: .long, help: "Window index (default: 0)") var window: Int = 0

        func run() throws {
            let escaped = js.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "'", with: "\\'")
            let script = """
            const Safari = Application('Safari');
            const w = Safari.windows()[\(window)];
            const t = w.currentTab();
            String(Safari.doJavaScript('\(escaped)', {in: t}));
            """
            let result = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result.lowercased().contains("error") {
                throw ValidationError("JS execution failed\n\(result.prefix(200))")
            }
            print(result)
        }
    }
}
