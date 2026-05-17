import ArgumentParser
import Foundation

struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Read and create Apple Notes",
        subcommands: [List.self, Search.self, Read.self, Create.self]
    )

    // MARK: - List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all notes (title + folder)")

        @Option(name: .long, help: "Filter by folder name")
        var folder: String?

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let folderFilter = folder.map { "'\($0)'" } ?? "null"
            let script = """
            const Notes = Application('Notes');
            const folder = \(folderFilter);
            const all = Notes.notes();
            const out = all.filter(n => {
                try { return !folder || n.container().name() === folder; } catch { return false; }
            }).map(n => {
                try {
                    return {id: n.id(), title: n.name(), folder: n.container().name(),
                            modified: n.modificationDate().toISOString()};
                } catch(e) { return {id: '', title: '', folder: '', modified: ''}; }
            });
            JSON.stringify(out);
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let notes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not read Notes — check Automation permissions in System Settings")
            }
            if json {
                printJSON(notes)
            } else {
                for n in notes {
                    let title = n["title"] as? String ?? ""
                    let fldr = n["folder"] as? String ?? ""
                    let mod = (n["modified"] as? String ?? "").prefix(10)
                    print("[\(fldr)] \(title)  (\(mod))")
                }
                print("\(notes.count) notes")
            }
        }
    }

    // MARK: - Search

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search notes by text")

        @Argument(help: "Search query")
        var query: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let escaped = query.replacingOccurrences(of: "'", with: "\\'")
            let script = """
            const Notes = Application('Notes');
            const q = '\(escaped)'.toLowerCase();
            const out = Notes.notes().filter(n => {
                try {
                    return (n.name() || '').toLowerCase().includes(q) ||
                           (n.plaintext() || '').toLowerCase().includes(q);
                } catch { return false; }
            }).map(n => {
                try {
                    return {id: n.id(), title: n.name(), folder: n.container().name(),
                            snippet: (n.plaintext() || '').substring(0, 200)};
                } catch(e) { return {id:'', title:'', folder:'', snippet:''}; }
            });
            JSON.stringify(out);
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let notes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("No results — check Automation permissions in System Settings")
            }
            if json {
                printJSON(notes)
            } else {
                for n in notes {
                    let title = n["title"] as? String ?? ""
                    let fldr = n["folder"] as? String ?? ""
                    let snippet = n["snippet"] as? String ?? ""
                    print("[\(fldr)] \(title)")
                    if !snippet.isEmpty { print("  \(snippet.prefix(120))") }
                }
                print("\(notes.count) result(s) for '\(query)'")
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
            let escaped = title.replacingOccurrences(of: "'", with: "\\'")
            let script = """
            const Notes = Application('Notes');
            const q = '\(escaped)'.toLowerCase();
            const match = Notes.notes().find(n => {
                try { return (n.name() || '').toLowerCase().includes(q); } catch { return false; }
            });
            if (!match) { JSON.stringify(null); }
            else {
                JSON.stringify({id: match.id(), title: match.name(),
                    folder: match.container().name(), body: match.plaintext() || '',
                    modified: match.modificationDate().toISOString()});
            }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw != "null", !raw.isEmpty, let data = raw.data(using: .utf8),
                  let note = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ValidationError("Note matching '\(title)' not found")
            }
            if json {
                printJSON(note)
            } else {
                print("Title:   \(note["title"] as? String ?? "")")
                print("Folder:  \(note["folder"] as? String ?? "")")
                print("Updated: \((note["modified"] as? String ?? "").prefix(10))")
                print("---")
                print(note["body"] as? String ?? "")
            }
        }
    }

    // MARK: - Create

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
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let note = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError.saveFailure("Could not create note")
            }
            if json {
                printJSON(note)
            } else {
                print("Created: \(note["title"] as? String ?? title) in \(note["folder"] as? String ?? "Notes")")
            }
        }
    }
}
