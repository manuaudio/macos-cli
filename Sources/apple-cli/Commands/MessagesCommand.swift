import ArgumentParser
import Foundation

// Messages control via JXA. Requires Automation permission for Messages in System Settings.

struct MessagesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "Apple Messages — send iMessages and list conversations",
        subcommands: [Send.self, Conversations.self]
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
            let result = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script])
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
                    const parts = c.participants().map(p => {
                        try { return p.name() || p.handle(); } catch { return ''; }
                    }).filter(Boolean);
                    const msgs = c.messages();
                    const last = msgs.length > 0 ? msgs[msgs.length - 1] : null;
                    return {
                        id: c.id(),
                        participants: parts,
                        lastMessage: last ? (last.content() || '').substring(0, 100) : '',
                        lastDate: last && last.dateSent() ? last.dateSent().toISOString().split('T')[0] : ''
                    };
                } catch(e) { return null; }
            }).filter(Boolean);
            JSON.stringify(chats);
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let chats = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not read Messages — check Automation permission\n\(raw.prefix(200))")
            }
            if json {
                printJSON(chats)
            } else {
                for c in chats {
                    let parts = (c["participants"] as? [String] ?? []).joined(separator: ", ")
                    let last  = c["lastMessage"] as? String ?? ""
                    let date  = c["lastDate"]    as? String ?? ""
                    print("[\(date)] \(parts)")
                    if !last.isEmpty { print("  \(last.prefix(80))") }
                }
                print("\(chats.count) conversation(s)")
            }
        }
    }
}
