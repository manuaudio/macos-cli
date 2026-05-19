import ArgumentParser
import Foundation

// Messages control via JXA. Requires Automation permission for Messages in System Settings.

struct MessagesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "Apple Messages — send iMessages and list conversations",
        subcommands: [Send.self, Conversations.self, Read.self, Delete.self]
    )

    // MARK: - Send

    struct Send: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Send an iMessage or SMS")

        @Option(name: .long, help: "Recipient name, phone number, or email")
        var to: String

        @Option(name: .long, help: "Message text")
        var text: String

        func run() throws {
            let escapedTo   = to.replacingOccurrences(of: "'", with: "\\'")
            let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
                                   .replacingOccurrences(of: "\\n", with: "\\\\n")
            let script = """
            const Messages = Application('Messages');
            const buddy = Messages.buddies.whose({name: '\(escapedTo)'})(  )[0]
                       || Messages.buddies.whose({handle: '\(escapedTo)'})(  )[0];
            if (!buddy) {
                // Try sending to handle directly
                const targetService = Messages.services()[0];
                const participant = targetService.participants.whose({handle: '\(escapedTo)'})(  )[0];
                if (participant) {
                    Messages.send('\(escapedText)', {to: participant});
                    'sent-participant';
                } else {
                    'not-found';
                }
            } else {
                Messages.send('\(escapedText)', {to: buddy});
                'sent-buddy';
            }
            """
            let result = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result == "not-found" {
                throw ValidationError("Recipient '\(to)' not found in Messages contacts")
            } else if result.lowercased().contains("error") {
                throw ValidationError("Could not send — check Automation permission for Messages\n\(result.prefix(200))")
            } else {
                print("Sent to \(to): \(text.prefix(60))\(text.count > 60 ? "..." : "")")
            }
        }
    }

    // MARK: - Read

    struct Read: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "read", abstract: "Read messages from a conversation")

        @Option(name: .long, help: "Participant name, phone, or email to find conversation")
        var with: String

        @Option(name: .long, help: "Max messages to return (default: 20)") var limit: Int = 20
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let escapedWith = with.replacingOccurrences(of: "'", with: "\\'")
            let script = """
            const Messages = Application('Messages');
            const q = '\(escapedWith)'.toLowerCase();
            let found = null;
            const allChats = Messages.chats();
            for (let i = 0; i < allChats.length; i++) {
                try {
                    const c = allChats[i];
                    let nameMatch = false;
                    try { nameMatch = (c.name() || '').toLowerCase().includes(q); } catch(e) {}
                    let partMatch = false;
                    try {
                        partMatch = c.participants().some(p => {
                            try { return (p.name() || '').toLowerCase().includes(q) || (p.handle() || '').toLowerCase().includes(q); }
                            catch(e) { return false; }
                        });
                    } catch(e) {}
                    if (nameMatch || partMatch) { found = c; break; }
                } catch(e) {}
            }
            if (!found) { JSON.stringify([]); }
            else {
                const msgs = found.messages().slice(-\(limit)).map(m => {
                    try {
                        return {
                            from: (function() { try { return m.sender ? m.sender().name() || m.sender().handle() || ''; } catch(e) { return ''; } })(),
                            text: (function() { try { return m.content ? m.content() : ''; } catch(e) { return ''; } })(),
                            date: (function() { try { return m.dateSent ? m.dateSent().toISOString() : ''; } catch(e) { return ''; } })()
                        };
                    } catch(e) { return null; }
                }).filter(Boolean);
                JSON.stringify(msgs);
            }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let msgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not read Messages — check Automation permission\n\(raw.prefix(200))")
            }
            if msgs.isEmpty {
                throw ValidationError("No conversation found matching '\(with)'")
            }
            if json {
                printJSON(msgs)
            } else {
                for m in msgs {
                    let from = m["from"] as? String ?? "unknown"
                    let text = m["text"] as? String ?? ""
                    let date = m["date"] as? String ?? ""
                    let shortDate = date.isEmpty ? "" : String(date.prefix(16)).replacingOccurrences(of: "T", with: " ")
                    print("[\(shortDate)] From: \(from)")
                    print("  \(text)")
                }
                print("\(msgs.count) message(s)")
            }
        }
    }

    // MARK: - Delete

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a conversation")

        @Option(name: .long, help: "Participant name, phone, or email to find conversation")
        var with: String

        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let escapedWith = with.replacingOccurrences(of: "'", with: "\\'")
            let script = """
            const Messages = Application('Messages');
            const q = '\(escapedWith)'.toLowerCase();
            let found = null;
            const allChats = Messages.chats();
            for (let i = 0; i < allChats.length; i++) {
                try {
                    const c = allChats[i];
                    let nameMatch = false;
                    try { nameMatch = (c.name() || '').toLowerCase().includes(q); } catch(e) {}
                    let partMatch = false;
                    try {
                        partMatch = c.participants().some(p => {
                            try { return (p.name() || '').toLowerCase().includes(q) || (p.handle() || '').toLowerCase().includes(q); }
                            catch(e) { return false; }
                        });
                    } catch(e) {}
                    if (nameMatch || partMatch) { found = c; break; }
                } catch(e) {}
            }
            if (!found) { 'not-found'; }
            else { found.delete(); 'deleted'; }
            """
            let result = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result == "not-found" {
                throw ValidationError("No conversation found matching '\(with)'")
            } else if result.lowercased().contains("error") {
                throw ValidationError("Could not delete conversation\n\(result.prefix(200))")
            }
            if json {
                printJSON(["deleted": true])
            } else {
                print("Deleted conversation with \(with)")
            }
        }
    }

    // MARK: - Conversations

    struct Conversations: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List recent conversations")

        @Option(name: .long, help: "Max results (default: 10)") var limit: Int = 10
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let script = """
            const Messages = Application('Messages');
            const chats = Messages.chats().slice(0, \(limit)).map(c => {
                try {
                    var name = '';
                    try { name = c.name() || ''; } catch(e) {}
                    var parts = [];
                    try {
                        parts = c.participants().map(p => {
                            try { return p.name() || p.handle() || ''; } catch(e) { return ''; }
                        }).filter(Boolean);
                    } catch(e) {}
                    return { id: c.id(), name: name, participants: parts };
                } catch(e) { return null; }
            }).filter(Boolean);
            JSON.stringify(chats);
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let chats = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not read Messages — check Automation permission\n\(raw.prefix(200))")
            }
            if json {
                printJSON(chats)
            } else {
                for c in chats {
                    let name  = c["name"]  as? String ?? ""
                    let parts = (c["participants"] as? [String] ?? []).joined(separator: ", ")
                    let label = name.isEmpty ? parts : name
                    print(label.isEmpty ? "(unknown)" : label)
                }
                print("\(chats.count) conversation(s)")
            }
        }
    }
}
