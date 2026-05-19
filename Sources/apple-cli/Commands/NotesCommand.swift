import ArgumentParser
import Foundation

// Apple Notes SQLite store — no Automation TCC permission required.
// ZTEXT body is gzip+protobuf; we use a Python one-liner to decompress.
private func notesDBPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
}

// Core Data timestamps are seconds since 2001-01-01 (not Unix epoch).
private func cdateToISO(_ seconds: Double) -> String {
    let unix = seconds + 978307200  // seconds between 1970 and 2001
    let date = Date(timeIntervalSince1970: unix)
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withFullDate]
    return fmt.string(from: date)
}

struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Read and create Apple Notes",
        subcommands: [List.self, Search.self, Read.self, Create.self]
    )

    // MARK: - List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all notes (title + modified date)")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let db = notesDBPath()
            let sql = "SELECT ZTITLE1, ZMODIFICATIONDATE1 FROM ZICCLOUDSYNCINGOBJECT WHERE ZTITLE1 IS NOT NULL ORDER BY ZMODIFICATIONDATE1 DESC;"
            let raw = Process.capture(args: ["/usr/bin/sqlite3", "-separator", "\t", db, sql])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                if json { print("[]") } else { print("0 notes") }
                return
            }
            let rows: [[String: String]] = raw.components(separatedBy: "\n").compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 1, !parts[0].isEmpty else { return nil }
                let modified = parts.count >= 2 ? (Double(parts[1]).map { cdateToISO($0) } ?? "") : ""
                return ["title": parts[0], "modified": modified]
            }
            if json {
                printJSON(rows)
            } else {
                for r in rows {
                    print("\(r["title"] ?? "")  (\(r["modified"] ?? ""))")
                }
                print("\(rows.count) notes")
            }
        }
    }

    // MARK: - Search

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search notes by title")

        @Argument(help: "Search query")
        var query: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let db = notesDBPath()
            let q = query.lowercased().replacingOccurrences(of: "'", with: "''")
            let sql = "SELECT ZTITLE1, ZMODIFICATIONDATE1 FROM ZICCLOUDSYNCINGOBJECT WHERE ZTITLE1 IS NOT NULL AND LOWER(ZTITLE1) LIKE '%\(q)%' ORDER BY ZMODIFICATIONDATE1 DESC;"
            let raw = Process.capture(args: ["/usr/bin/sqlite3", "-separator", "\t", db, sql])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rows: [[String: String]] = raw.isEmpty ? [] : raw.components(separatedBy: "\n").compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 1, !parts[0].isEmpty else { return nil }
                let modified = parts.count >= 2 ? (Double(parts[1]).map { cdateToISO($0) } ?? "") : ""
                return ["title": parts[0], "modified": modified]
            }
            if json {
                printJSON(rows)
            } else {
                for r in rows { print("\(r["title"] ?? "")  (\(r["modified"] ?? ""))") }
                print("\(rows.count) result(s) for '\(query)'")
            }
        }
    }

    // MARK: - Read

    struct Read: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read a note's full content by title")

        @Argument(help: "Note title (exact or partial match)")
        var title: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let db = notesDBPath().replacingOccurrences(of: "'", with: "\\'")
            let q = title.lowercased().replacingOccurrences(of: "\"", with: "\\\"")
            // Body is gzip-compressed protobuf in ZICNOTEDATA.ZDATA — use Python to decompress
            let py = """
import sqlite3, gzip, re, json, sys
db = sqlite3.connect('\(db)', check_same_thread=False)
row = db.execute('''
    SELECT o.ZTITLE1, n.ZDATA, o.ZMODIFICATIONDATE1
    FROM ZICCLOUDSYNCINGOBJECT o
    JOIN ZICNOTEDATA n ON o.Z_PK = n.ZNOTE
    WHERE o.ZTITLE1 IS NOT NULL AND LOWER(o.ZTITLE1) LIKE ?
    ORDER BY o.ZMODIFICATIONDATE1 DESC LIMIT 1
''', ('%\(q)%',)).fetchone()
if not row:
    print(json.dumps(None))
    sys.exit(0)
title, blob, mdate = row
body = ''
if blob:
    try:
        raw = gzip.decompress(bytes(blob))
        body = re.sub(rb'[^\\x20-\\x7E\\n\\t]+', b' ', raw).decode('utf-8', errors='replace').strip()
    except Exception:
        pass
modified = ''
if mdate:
    import datetime
    ts = float(mdate) + 978307200
    modified = datetime.datetime.utcfromtimestamp(ts).strftime('%Y-%m-%d')
print(json.dumps({'title': title, 'body': body, 'modified': modified}))
"""
            let raw = Process.capture(args: ["/usr/bin/python3", "-c", py])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw != "null", !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let note = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ValidationError("Note matching '\(title)' not found")
            }
            if json {
                printJSON(note)
            } else {
                print("Title:   \(note["title"] as? String ?? "")")
                print("Updated: \(note["modified"] as? String ?? "")")
                print("---")
                print(note["body"] as? String ?? "")
            }
        }
    }

    // MARK: - Create (still uses JXA — writing to Notes.sqlite directly is unsafe)

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new note")

        @Option(name: .long, help: "Note title")
        var title: String

        @Option(name: .long, help: "Note body / content")
        var body: String = ""

        @Option(name: .long, help: "Folder name (default: Notes)")
        var folder: String?

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let escapedTitle = title.replacingOccurrences(of: "'", with: "\\'")
                                   .replacingOccurrences(of: "\\n", with: "\\\\n")
            let escapedBody  = body.replacingOccurrences(of: "'", with: "\\'")
                                   .replacingOccurrences(of: "\\n", with: "\\\\n")
            let folderPart: String
            if let f = folder {
                let ef = f.replacingOccurrences(of: "'", with: "\\'")
                folderPart = "at Notes.folders.whose({name: '\(ef)'})[0]"
            } else {
                folderPart = ""
            }
            let script = """
            const Notes = Application('Notes');
            const n = Notes.make({new: 'note', \(folderPart.isEmpty ? "" : "at: \(folderPart),") withProperties: {name: '\(escapedTitle)', body: '\(escapedBody)'}});
            JSON.stringify({id: n.id(), title: n.name(), folder: n.container().name()});
            """
            guard let rawOpt = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10) else {
                throw ValidationError("Could not create note — osascript timed out. Ensure Notes has Automation permission in System Settings.")
            }
            let raw = rawOpt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let note = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ValidationError("Could not create note — check Automation permission for Notes in System Settings")
            }
            if json {
                printJSON(note)
            } else {
                print("Created: \(note["title"] as? String ?? title) in \(note["folder"] as? String ?? "Notes")")
            }
        }
    }
}
