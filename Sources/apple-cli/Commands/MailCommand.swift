import ArgumentParser
import Foundation

// Mail control via JXA. Requires Automation permission for Mail in System Settings → Privacy.

struct MailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Apple Mail — create drafts, search messages",
        subcommands: [Draft.self, Search.self, Accounts.self]
    )

    // MARK: - Draft

    struct Draft: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a draft email in Mail")

        @Option(name: .long, help: "Recipient email address") var to: String
        @Option(name: .long, help: "Subject line") var subject: String
        @Option(name: .long, help: "Email body") var body: String = ""
        @Option(name: .long, help: "CC address (optional)") var cc: String?

        @Flag(name: .long, help: "Open the draft in Mail after creating") var open = false

        func run() throws {
            let escapedTo      = to.replacingOccurrences(of: "'", with: "\\'")
            let escapedSubject = subject.replacingOccurrences(of: "'", with: "\\'")
                                        .replacingOccurrences(of: "\\n", with: "\\\\n")
            let escapedBody    = body.replacingOccurrences(of: "'", with: "\\'")
                                      .replacingOccurrences(of: "\\n", with: "\\\\n")
            let ccPart = cc.map { "cc: [{ address: '\($0.replacingOccurrences(of: "'", with: "\\'"))' }]," } ?? ""

            let script = """
            const Mail = Application('Mail');
            const msg = Mail.OutgoingMessage({
                subject: '\(escapedSubject)',
                content: '\(escapedBody)',
                visible: \(open)
            });
            Mail.outgoingMessages.push(msg);
            const rec = Mail.Recipient({address: '\(escapedTo)'});
            msg.toRecipients.push(rec);
            \(cc != nil ? "const cc = Mail.CcRecipient({address: '\(cc!.replacingOccurrences(of: "'", with: "\\'"))'}); msg.ccRecipients.push(cc);" : "")
            \(open ? "Mail.activate();" : "")
            JSON.stringify({to: '\(escapedTo)', subject: '\(escapedSubject)'});
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.lowercased().contains("error") || raw.isEmpty {
                throw ValidationError("Could not create draft — check Automation permission for Mail in System Settings\n\(raw.prefix(200))")
            }
            print("Draft created: to=\(to) subject='\(subject)'")
        }
    }

    // MARK: - Search

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search Apple Mail messages")

        @Argument(help: "Search query")
        var query: String

        @Option(name: .long, help: "Max results (default: 10)") var limit: Int = 10
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let escaped = query.replacingOccurrences(of: "'", with: "\\'")
            let script = """
            const Mail = Application('Mail');
            const q = '\(escaped)'.toLowerCase();
            const results = [];
            Mail.accounts().forEach(acct => {
                try {
                    acct.mailboxes().forEach(mb => {
                        try {
                            mb.messages().slice(0, 200).forEach(m => {
                                try {
                                    const subj = (m.subject() || '').toLowerCase();
                                    const from = (m.sender() || '').toLowerCase();
                                    const cont = (m.content() || '').toLowerCase();
                                    if (subj.includes(q) || from.includes(q) || cont.includes(q)) {
                                        results.push({
                                            subject: m.subject(),
                                            from: m.sender(),
                                            date: m.dateSent() ? m.dateSent().toISOString().split('T')[0] : '',
                                            mailbox: mb.name()
                                        });
                                    }
                                } catch(e) {}
                            });
                        } catch(e) {}
                    });
                } catch(e) {}
            });
            JSON.stringify(results.slice(0, \(limit)));
            """
            guard let rawOpt = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 45),
                  !rawOpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("Mail search timed out — large mailboxes may take longer. Try a more specific query.")
            }
            let raw = rawOpt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = raw.data(using: .utf8),
                  let msgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not search Mail — check Automation permission\n\(raw.prefix(200))")
            }
            if json {
                printJSON(msgs)
            } else {
                for m in msgs {
                    let subj = m["subject"] as? String ?? ""
                    let from = m["from"]    as? String ?? ""
                    let date = m["date"]    as? String ?? ""
                    print("[\(date)] \(subj)")
                    print("  From: \(from)")
                }
                print("\(msgs.count) message(s)")
            }
        }
    }

    // MARK: - Accounts

    struct Accounts: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List Mail accounts")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let script = """
            const Mail = Application('Mail');
            const out = Mail.accounts().map(a => {
                try { return {name: a.name(), email: a.emailAddresses()[0] || ''}; }
                catch(e) { return null; }
            }).filter(Boolean);
            JSON.stringify(out);
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let accounts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not list Mail accounts — check Automation permission\n\(raw.prefix(200))")
            }
            if json {
                printJSON(accounts)
            } else {
                for a in accounts {
                    print("\(a["name"] as? String ?? "")  <\(a["email"] as? String ?? "")>")
                }
            }
        }
    }
}
