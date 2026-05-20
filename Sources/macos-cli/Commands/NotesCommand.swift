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
        subcommands: [List.self, Search.self, Read.self, Create.self, Delete.self, Update.self, Folders.self, CreateFolder.self]
    )

    // MARK: - List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all notes (title + modified date)")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("notes.read")
            let db = notesDBPath()
            let sql = "SELECT ZTITLE1, ZMODIFICATIONDATE1 FROM ZICCLOUDSYNCINGOBJECT WHERE ZTITLE1 IS NOT NULL ORDER BY ZMODIFICATIONDATE1 DESC;"
            let raw = Process.capture(args: ["/usr/bin/sqlite3", "-separator", "\t", db, sql], timeout: 5, fallback: "")
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
            try Auth.check("notes.read")
            let db = notesDBPath()
            let q = query.lowercased().replacingOccurrences(of: "'", with: "''")
            let sql = "SELECT ZTITLE1, ZMODIFICATIONDATE1 FROM ZICCLOUDSYNCINGOBJECT WHERE ZTITLE1 IS NOT NULL AND LOWER(ZTITLE1) LIKE '%\(q)%' ORDER BY ZMODIFICATIONDATE1 DESC;"
            let raw = Process.capture(args: ["/usr/bin/sqlite3", "-separator", "\t", db, sql], timeout: 5, fallback: "")
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
            try Auth.check("notes.read")
            let db = notesDBPath().replacingOccurrences(of: "'", with: "\\'")
            let q = title.lowercased()
                         .replacingOccurrences(of: "'", with: "\\'")
                         .replacingOccurrences(of: "\"", with: "\\\"")
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
            let raw = Process.capture(args: ["/usr/bin/python3", "-c", py], timeout: 5, fallback: "")
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

    // MARK: - Delete

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a note by title (partial match, first match)")

        @Option(name: .long, help: "Note title to delete (partial match)")
        var title: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("notes.delete")
            let escaped = jxaEscape(title)
            let script = """
            try {
            const Notes = Application('Notes');
            const matches = Notes.notes.whose({name: {_contains: '\(escaped)'}});
            if (!matches || matches.length === 0) {
                JSON.stringify({ok:false, error: 'No matching note found'});
            } else {
                const noteTitle = matches[0].name();
                matches[0].delete();
                JSON.stringify({ok:true, result:{deleted: true, title: noteTitle}});
            }
            } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 30, fallback: "")
            guard let env = parseJXAEnvelope(raw) else {
                throw ValidationError("Could not delete note — check Automation permission for Notes in System Settings\n\(raw.prefix(200))")
            }
            if !env.ok {
                throw ValidationError("Delete failed: \(env.error)")
            }
            guard let data = env.resultJSON.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ValidationError("Unexpected response from Notes: \(env.resultJSON.prefix(200))")
            }
            if json {
                printJSON(result)
            } else {
                let deleted = result["deleted"] as? Bool ?? false
                let noteTitle = result["title"] as? String ?? title
                print(deleted ? "Deleted: \(noteTitle)" : "No matching note found for '\(title)'")
            }
        }
    }

    // MARK: - Update

    struct Update: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a note's title and/or body")

        @Option(name: .long, help: "Note title to find (partial match)")
        var title: String

        @Option(name: .long, help: "New title (optional)")
        var newTitle: String?

        @Option(name: .long, help: "New body content (optional)")
        var body: String?

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("notes.write")
            guard newTitle != nil || body != nil else {
                throw ValidationError("Specify at least --new-title or --body to update")
            }
            let escaped = jxaEscape(title)
            let titleUpdate = newTitle.map { t -> String in
                let et = jxaEscape(t)
                return "note.name = '\(et)';"
            } ?? ""
            let bodyUpdate = body.map { b -> String in
                let eb = jxaEscape(b)
                return "note.body = '\(eb)';"
            } ?? ""
            let script = """
            const Notes = Application('Notes');
            const matches = Notes.notes.whose({name: {_contains: '\(escaped)'}});
            if (!matches || matches.length === 0) {
                JSON.stringify({updated: false, error: 'No matching note found'});
            } else {
                const note = matches[0];
                \(titleUpdate)
                \(bodyUpdate)
                JSON.stringify({updated: true});
            }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 30, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ValidationError("Could not update note — check Automation permission for Notes in System Settings\n\(raw.prefix(200))")
            }
            if result["updated"] as? Bool != true {
                throw ValidationError("Update failed: \(result["error"] as? String ?? raw)")
            }
            if json {
                printJSON(result)
            } else {
                print("Updated note matching '\(title)'")
            }
        }
    }

    // MARK: - Folders

    struct Folders: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "folders", abstract: "List all Notes folders")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("notes.read")
            let script = """
            const Notes = Application('Notes');
            const folders = Notes.folders().map(f => {
                try { return {name: f.name(), count: f.notes().length}; }
                catch(e) { return null; }
            }).filter(Boolean);
            JSON.stringify(folders);
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 30, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let folders = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not list Notes folders — check Automation permission for Notes in System Settings\n\(raw.prefix(200))")
            }
            if json {
                printJSON(folders)
            } else {
                for f in folders {
                    let name  = f["name"]  as? String ?? ""
                    let count = f["count"] as? Int ?? 0
                    print("\(name)  (\(count) note\(count == 1 ? "" : "s"))")
                }
                print("\(folders.count) folder\(folders.count == 1 ? "" : "s")")
            }
        }
    }

    // MARK: - CreateFolder

    struct CreateFolder: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "create-folder", abstract: "Create a new Notes folder")

        @Option(name: .long, help: "Folder name to create")
        var name: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let escaped = jxaEscape(name)
            let script = """
            try {
            const Notes = Application('Notes');
            Notes.make({new: 'folder', withProperties: {name: '\(escaped)'}});
            JSON.stringify({ok:true, result:{created: true, name: '\(escaped)'}});
            } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 30, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw ValidationError("Could not create folder — check Automation permission for Notes in System Settings\n\(errMsg.prefix(200))")
            }
            guard let data = env.resultJSON.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ValidationError("Unexpected response from Notes: \(env.resultJSON.prefix(200))")
            }
            if json {
                printJSON(result)
            } else {
                print("Created folder: \(name)")
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
            try Auth.check("notes.write")
            let escapedTitle = jxaEscape(title)
            let escapedBody  = jxaEscape(body)
            let folderPart: String
            if let f = folder {
                let ef = jxaEscape(f)
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
