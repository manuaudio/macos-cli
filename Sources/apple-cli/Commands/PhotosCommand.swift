import ArgumentParser
import Foundation

// Photos control via JXA. May require Automation permission for Photos.

struct PhotosCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "photos",
        abstract: "Apple Photos — list albums, search photos",
        subcommands: [Albums.self, Search.self, Recent.self]
    )

    // MARK: - Albums

    struct Albums: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all photo albums")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let script = """
            const Photos = Application('Photos');
            const out = Photos.albums().map(a => {
                try { return {name: a.name(), count: a.mediaItems().length}; }
                catch(e) { return null; }
            }).filter(Boolean);
            JSON.stringify(out);
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let albums = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not read Photos — check Automation permission for Photos in System Settings\n\(raw.prefix(200))")
            }
            if json {
                printJSON(albums)
            } else {
                for a in albums {
                    let name  = a["name"]  as? String ?? ""
                    let count = a["count"] as? Int ?? 0
                    print("\(name)  (\(count) items)")
                }
                print("\(albums.count) album(s)")
            }
        }
    }

    // MARK: - Search

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search photos by keyword")

        @Argument(help: "Search query (searches titles and descriptions)")
        var query: String

        @Option(name: .long, help: "Max results (default: 20)") var limit: Int = 20
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let escaped = query.replacingOccurrences(of: "'", with: "\\'")
            let script = """
            const Photos = Application('Photos');
            const q = '\(escaped)'.toLowerCase();
            const results = [];
            Photos.mediaItems().slice(0, 2000).forEach(item => {
                try {
                    const name = (item.filename() || '').toLowerCase();
                    const desc = (item.description ? item.description() || '' : '').toLowerCase();
                    if (name.includes(q) || desc.includes(q)) {
                        results.push({
                            filename: item.filename(),
                            date: item.date() ? item.date().toISOString().split('T')[0] : '',
                            description: item.description ? (item.description() || '').substring(0, 100) : ''
                        });
                    }
                } catch(e) {}
            });
            JSON.stringify(results.slice(0, \(limit)));
            """
            guard let rawOpt = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 45),
                  !rawOpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("Photos search timed out — large libraries may take longer. Try a more specific query.")
            }
            let raw = rawOpt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = raw.data(using: .utf8),
                  let photos = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not search Photos — check Automation permission\n\(raw.prefix(200))")
            }
            if json {
                printJSON(photos)
            } else {
                for p in photos {
                    let fn   = p["filename"] as? String ?? ""
                    let date = p["date"]     as? String ?? ""
                    let desc = p["description"] as? String ?? ""
                    print("[\(date)] \(fn)")
                    if !desc.isEmpty { print("  \(desc)") }
                }
                print("\(photos.count) result(s)")
            }
        }
    }

    // MARK: - Recent

    struct Recent: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List recently added photos")

        @Option(name: .long, help: "Number of recent items (default: 10)") var limit: Int = 10
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let script = """
            const Photos = Application('Photos');
            const items = Photos.mediaItems().slice(-\(limit)).reverse();
            const out = items.map(item => {
                try {
                    return {
                        filename: item.filename(),
                        date: item.date() ? item.date().toISOString().split('T')[0] : '',
                        width: item.width ? item.width() : 0,
                        height: item.height ? item.height() : 0
                    };
                } catch(e) { return null; }
            }).filter(Boolean);
            JSON.stringify(out);
            """
            guard let rawOpt = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 30),
                  !rawOpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("Photos timed out — check Automation permission for Photos in System Settings")
            }
            let raw = rawOpt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = raw.data(using: .utf8),
                  let photos = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not read Photos — check Automation permission\n\(raw.prefix(200))")
            }
            if json {
                printJSON(photos)
            } else {
                for p in photos {
                    let fn   = p["filename"] as? String ?? ""
                    let date = p["date"]     as? String ?? ""
                    let w    = p["width"]  as? Int ?? 0
                    let h    = p["height"] as? Int ?? 0
                    print("[\(date)] \(fn)  \(w > 0 ? "\(w)×\(h)" : "")")
                }
                print("\(photos.count) recent item(s)")
            }
        }
    }
}
