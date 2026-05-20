import ArgumentParser
import Foundation

// Safari control via JXA. Requires Automation permission for Safari in System Settings → Privacy.

struct SafariCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "safari",
        abstract: "Control Safari — list tabs, open URLs, read page content",
        subcommands: [Tabs.self, Open.self, Read.self, Execute.self,
                      NewTab.self, Close.self, Reload.self, History.self, Bookmarks.self]
    )

    // MARK: - Tabs

    struct Tabs: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List open Safari tabs")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let script = """
            try {
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
            JSON.stringify({ok:true, result:out});
            } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw ValidationError("Could not read Safari tabs — check Automation permission for Safari in System Settings\n\(errMsg.prefix(200))")
            }
            guard let data = env.resultJSON.data(using: .utf8),
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
            try Auth.check("safari.execute")
            let escaped = jxaEscape(url)
            let script = """
            try {
            const Safari = Application('Safari');
            Safari.activate();
            Safari.openLocation('\(escaped)');
            JSON.stringify({ok:true, result:'opened'});
            } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw ValidationError("Could not open URL — check Automation permission for Safari\n\(errMsg.prefix(200))")
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
            try {
            const Safari = Application('Safari');
            const w = Safari.windows()[\(window)];
            const t = w\(tabSelector);
            const title = t.name();
            const url = t.url();
            // Execute JS to get innerText
            const body = Safari.doJavaScript('document.body ? document.body.innerText.substring(0, 5000) : ""', {in: t});
            JSON.stringify({ok:true, result:{title, url, body}});
            } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw ValidationError("Could not read Safari tab — check Automation permission\n\(errMsg.prefix(200))")
            }
            guard let data = env.resultJSON.data(using: .utf8),
                  let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ValidationError("Could not read Safari tab — check Automation permission\n\(env.resultJSON.prefix(200))")
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
            try Auth.check("safari.execute")
            let escaped = jxaEscape(js)
            let script = """
            try {
            const Safari = Application('Safari');
            const w = Safari.windows()[\(window)];
            const t = w.currentTab();
            const jsResult = String(Safari.doJavaScript('\(escaped)', {in: t}));
            JSON.stringify({ok:true, result:jsResult});
            } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw ValidationError("JS execution failed\n\(errMsg.prefix(200))")
            }
            // env.resultJSON is a JSON-encoded string; decode it to get the actual JS result
            if let data = env.resultJSON.data(using: .utf8),
               let jsResult = try? JSONSerialization.jsonObject(with: data) as? String {
                print(jsResult)
            } else {
                print(env.resultJSON)
            }
        }
    }

    // MARK: - NewTab

    struct NewTab: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "new-tab", abstract: "Open a new Safari tab at a URL")

        @Option(name: .long, help: "URL to open (required)") var url: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("safari.execute")
            let escaped = jxaEscape(url)
            let script = """
            try {
            const Safari = Application('Safari');
            Safari.activate();
            const wins = Safari.windows();
            if (wins.length === 0) {
                Safari.openLocation('\(escaped)');
            } else {
                const tab = Safari.Tab({url: '\(escaped)'});
                wins[0].tabs.push(tab);
                wins[0].currentTab = tab;
            }
            JSON.stringify({ok:true, result:'opened'});
            } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw ValidationError("Could not open new tab — check Automation permission for Safari\n\(errMsg.prefix(200))")
            }
            if json {
                printJSON(["opened": url])
            } else {
                print("Opened: \(url)")
            }
        }
    }

    // MARK: - Close

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "close", abstract: "Close a Safari tab")

        @Option(name: .long, help: "Close tab matching this URL substring") var url: String?
        @Option(name: .long, help: "Close tab at window:tab index (e.g. 0:1)") var index: String?
        @Flag(name: .long, help: "Close the current active tab") var current = false
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("safari.execute")
            let script: String
            if current {
                script = """
                try {
                const Safari = Application('Safari');
                const w = Safari.windows()[0];
                const t = w.currentTab();
                t.close();
                JSON.stringify({ok:true, result:{closed: 1}});
                } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
                """
            } else if let idx = index {
                let parts = idx.split(separator: ":").map { Int($0) ?? 0 }
                guard parts.count == 2 else { throw ValidationError("--index must be in format window:tab (e.g. 0:1)") }
                let wi = parts[0], ti = parts[1]
                script = """
                try {
                const Safari = Application('Safari');
                Safari.windows()[\(wi)].tabs()[\(ti)].close();
                JSON.stringify({ok:true, result:{closed: 1}});
                } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
                """
            } else if let urlSubstr = url {
                let escaped = jxaEscape(urlSubstr)
                script = """
                try {
                const Safari = Application('Safari');
                let closed = 0;
                Safari.windows().forEach(w => {
                    w.tabs().forEach(t => {
                        try {
                            if ((t.url() || '').includes('\(escaped)')) {
                                t.close();
                                closed++;
                            }
                        } catch(e) {}
                    });
                });
                JSON.stringify({ok:true, result:{closed}});
                } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
                """
            } else {
                throw ValidationError("Specify --url, --index, or --current")
            }

            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw ValidationError("Could not close tab\n\(errMsg.prefix(200))")
            }
            if json {
                print(env.resultJSON.isEmpty ? "{\"closed\":0}" : env.resultJSON)
            } else {
                if let data = env.resultJSON.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let n = obj["closed"] as? Int {
                    print("Closed \(n) tab(s)")
                } else {
                    print("Closed tab")
                }
            }
        }
    }

    // MARK: - Reload

    struct Reload: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reload", abstract: "Reload a Safari tab")

        @Option(name: .long, help: "Reload tab matching this URL substring (default: current tab)") var url: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("safari.execute")
            let script: String
            if let urlSubstr = url {
                let escaped = jxaEscape(urlSubstr)
                script = """
                try {
                const Safari = Application('Safari');
                let reloaded = 0;
                outer: for (const w of Safari.windows()) {
                    for (const t of w.tabs()) {
                        try {
                            if ((t.url() || '').includes('\(escaped)')) {
                                Safari.doJavaScript('location.reload()', {in: t});
                                reloaded++;
                                break outer;
                            }
                        } catch(e) {}
                    }
                }
                JSON.stringify({ok:true, result:{reloaded}});
                } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
                """
            } else {
                script = """
                try {
                const Safari = Application('Safari');
                const t = Safari.windows()[0].currentTab();
                Safari.doJavaScript('location.reload()', {in: t});
                JSON.stringify({ok:true, result:{reloaded: 1, url: t.url()}});
                } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
                """
            }

            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw ValidationError("Could not reload tab\n\(errMsg.prefix(200))")
            }
            if json {
                print(env.resultJSON.isEmpty ? "{\"reloaded\":0}" : env.resultJSON)
            } else {
                print("Reloaded")
            }
        }
    }

    // MARK: - History

    struct History: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "history", abstract: "Browse Safari history via History.db")

        @Option(name: .long, help: "Max items to return (default: 20)") var limit: Int = 20
        @Option(name: .long, help: "Filter by title or URL substring") var query: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let dbPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Safari/History.db")
            guard FileManager.default.fileExists(atPath: dbPath) else {
                throw ValidationError("Safari History.db not found at \(dbPath)")
            }

            // Apple epoch: seconds since 2001-01-01
            let baseSQL: String
            if let q = query {
                let safe = q.replacingOccurrences(of: "'", with: "''")
                baseSQL = """
                SELECT v.title, i.url, CAST(v.visit_time + 978307200 AS INTEGER) as ts
                FROM history_visits v
                JOIN history_items i ON v.history_item = i.id
                WHERE v.title LIKE '%\(safe)%' OR i.url LIKE '%\(safe)%'
                ORDER BY v.visit_time DESC
                LIMIT \(limit);
                """
            } else {
                baseSQL = """
                SELECT v.title, i.url, CAST(v.visit_time + 978307200 AS INTEGER) as ts
                FROM history_visits v
                JOIN history_items i ON v.history_item = i.id
                ORDER BY v.visit_time DESC
                LIMIT \(limit);
                """
            }

            let raw = Process.capture(args: ["/usr/bin/sqlite3", "-separator", "\t", dbPath, baseSQL], timeout: 15, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if raw.isEmpty {
                if json { print("[]") } else { print("No history found") }
                return
            }

            let rows: [[String: Any]] = raw.components(separatedBy: "\n").compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 3 else { return nil }
                let ts = Int(parts[2]) ?? 0
                let date = ts > 0 ? Date(timeIntervalSince1970: Double(ts)) : Date()
                let fmt = ISO8601DateFormatter()
                return ["title": parts[0], "url": parts[1], "visited": fmt.string(from: date)]
            }

            if json {
                printJSON(rows)
            } else {
                for row in rows {
                    let title = row["title"] as? String ?? ""
                    let url   = row["url"]   as? String ?? ""
                    let vis   = row["visited"] as? String ?? ""
                    print("\(vis)  \(title.isEmpty ? "(no title)" : title)")
                    print("  \(url.prefix(100))")
                }
            }
        }
    }

    // MARK: - Bookmarks

    struct Bookmarks: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "bookmarks", abstract: "List Safari bookmarks")

        @Option(name: .long, help: "Filter by title or URL substring") var query: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let plistPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Safari/Bookmarks.plist")
            guard FileManager.default.fileExists(atPath: plistPath) else {
                throw ValidationError("Bookmarks.plist not found at \(plistPath)")
            }

            // Convert plist to JSON using plutil
            let jsonStr = Process.capture(args: ["/usr/bin/plutil", "-convert", "json", "-o", "-", plistPath], timeout: 10, fallback: "")
            guard !jsonStr.isEmpty, let data = jsonStr.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ValidationError("Could not parse Bookmarks.plist")
            }

            // Recursively extract leaf bookmarks
            var results: [[String: String]] = []
            func extract(_ node: Any) {
                if let dict = node as? [String: Any] {
                    let btype = dict["WebBookmarkType"] as? String ?? ""
                    if btype == "WebBookmarkTypeLeaf" {
                        let urlStr = dict["URLString"] as? String ?? ""
                        let uriDict = dict["URIDictionary"] as? [String: Any]
                        let title = uriDict?["title"] as? String ?? ""
                        if !urlStr.isEmpty {
                            results.append(["title": title, "url": urlStr])
                        }
                    }
                    // Recurse into children
                    if let children = dict["Children"] as? [Any] {
                        for child in children { extract(child) }
                    }
                } else if let arr = node as? [Any] {
                    for item in arr { extract(item) }
                }
            }
            extract(root)

            // Apply optional filter
            let filtered: [[String: String]]
            if let q = query?.lowercased(), !q.isEmpty {
                filtered = results.filter {
                    ($0["title"] ?? "").lowercased().contains(q) ||
                    ($0["url"]   ?? "").lowercased().contains(q)
                }
            } else {
                filtered = results
            }

            if json {
                printJSON(filtered)
            } else {
                if filtered.isEmpty { print("No bookmarks found"); return }
                for bm in filtered {
                    print("\(bm["title"] ?? "(no title)") — \(bm["url"] ?? "")")
                }
            }
        }
    }
}
