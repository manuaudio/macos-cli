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
