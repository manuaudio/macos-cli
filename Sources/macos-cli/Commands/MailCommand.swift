import ArgumentParser
import Foundation

// Mail control via JXA. Requires Automation permission for Mail in System Settings → Privacy.

struct MailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Apple Mail — create drafts, search messages",
        subcommands: [Draft.self, Search.self, Accounts.self, Refresh.self, Send.self, Read.self, Delete.self, Mark.self, Mailboxes.self, Reply.self]
    )

    // MARK: - Refresh (force Mail.app to check for new mail)

    struct Refresh: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Force Mail to check all accounts for new messages now")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("mail.read")
            // Mail.app exposes no direct EventKit-style API; AppleScript is the
            // only path. We wrap it inside the CLI so callers don't have to
            // construct an osascript shell command themselves.
            let script = """
            (function() {
              try {
                const Mail = Application('Mail');
                Mail.checkForNewMail();
                return JSON.stringify({ok: true, result: "refreshed", error: ""});
              } catch(e) {
                return JSON.stringify({ok: false, result: "", error: e.toString()});
              }
            })()
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
                                      timeout: 30, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw CLIFailure.appError("Mail refresh failed: \(errMsg.prefix(200))")
            }
            if json {
                printJSON(["refresh_requested": true])
            } else {
                print("Mail refresh requested.")
            }
        }
    }

    // MARK: - Draft

    struct Draft: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a draft email in Mail")

        @Option(name: .long, help: "Recipient email address") var to: String
        @Option(name: .long, help: "Subject line") var subject: String
        @Option(name: .long, help: "Email body") var body: String = ""
        @Option(name: .long, help: "CC address (optional)") var cc: String?

        @Flag(name: .long, help: "Open the draft in Mail after creating") var open = false
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("mail.send")
            let escapedTo      = jxaEscape(to)
            let escapedSubject = jxaEscape(subject)
            let escapedBody    = jxaEscape(body)
            let ccLine = cc.map { addr -> String in
                let ea = jxaEscape(addr)
                return "const ccR = Mail.CcRecipient({address: '\(ea)'}); msg.ccRecipients.push(ccR);"
            } ?? ""

            let script = """
            try {
            const Mail = Application('Mail');
            const msg = Mail.OutgoingMessage({
                subject: '\(escapedSubject)',
                content: '\(escapedBody)',
                visible: \(open)
            });
            Mail.outgoingMessages.push(msg);
            const rec = Mail.Recipient({address: '\(escapedTo)'});
            msg.toRecipients.push(rec);
            \(ccLine)
            \(open ? "Mail.activate();" : "")
            JSON.stringify({ok:true, result:{to: '\(escapedTo)', subject: '\(escapedSubject)'}});
            } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw CLIFailure.appError("Could not create draft — check Automation permission for Mail in System Settings\n\(errMsg.prefix(200))")
            }
            if json {
                printJSON(["draft_created": true, "to": to, "subject": subject])
            } else {
                print("Draft created: to=\(to) subject='\(subject)'")
            }
        }
    }

    // MARK: - Search

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search Apple Mail messages by subject, sender or body")

        @Argument(help: "Search query (case-insensitive)")
        var query: String

        @Option(name: .long, help: "Only this mailbox (e.g. INBOX); far faster than every mailbox") var mailbox: String?
        @Option(name: .long, help: "Only this account") var account: String?
        @Option(name: .long, help: "Max results (default: 10)") var limit: Int = 10
        @Option(name: .long, help: "Seconds to wait for Mail (default: 45)") var timeout: Double = 45
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("mail.read")
            let msgs = try findMail(.query(query), mailbox: mailbox, account: account, limit: limit,
                                    withContent: false, timeout: timeout)
            if json {
                printJSON(msgs)
            } else {
                for m in msgs {
                    print("[\(m["date"] as? String ?? "")] \(m["subject"] as? String ?? "")")
                    print("  From: \(m["from"] as? String ?? "")  Mailbox: \(m["mailbox"] as? String ?? "")")
                    print("  Message-ID: \(m["message_id"] as? String ?? "")")
                }
                print("\(msgs.count) message(s)")
            }
        }
    }

    // MARK: - Send

    struct Send: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "send", abstract: "Send an email immediately via Mail")

        @Option(name: .long, help: "Recipient email address") var to: String
        @Option(name: .long, help: "Subject line") var subject: String
        @Option(name: .long, help: "Email body") var body: String = ""
        @Option(name: .long, help: "CC address (optional)") var cc: String?

        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("mail.send")
            let escapedTo      = jxaEscape(to)
            let escapedSubject = jxaEscape(subject)
            let escapedBody    = jxaEscape(body)
            let ccLine = cc.map { addr -> String in
                let ea = jxaEscape(addr)
                return "const ccR = Mail.CcRecipient({address: '\(ea)'}); msg.ccRecipients.push(ccR);"
            } ?? ""
            let script = """
            try {
            const Mail = Application('Mail');
            const msg = Mail.OutgoingMessage({
                subject: '\(escapedSubject)',
                content: '\(escapedBody)',
                visible: false
            });
            Mail.outgoingMessages.push(msg);
            const rec = Mail.Recipient({address: '\(escapedTo)'});
            msg.toRecipients.push(rec);
            \(ccLine)
            msg.send();
            JSON.stringify({ok:true, result:{sent: true, to: '\(escapedTo)', subject: '\(escapedSubject)'}});
            } catch(e) { JSON.stringify({ok:false, error: String(e&&e.message?e.message:e)}); }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 30, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw CLIFailure.appError("Could not send email — check Automation permission for Mail in System Settings\n\(errMsg.prefix(200))")
            }
            if json {
                if let data = env.resultJSON.data(using: .utf8),
                   let result = try? JSONSerialization.jsonObject(with: data) {
                    printJSON(result)
                } else {
                    printJSON(["sent": true, "to": to, "subject": subject])
                }
            } else {
                print("Sent to \(to): \(subject)")
            }
        }
    }

    // MARK: - Read

    struct Read: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "read", abstract: "Read full message content, by Message-ID or by query")

        @Option(name: .long, help: "The Message-ID header (from `mail search --json`, message_id)") var id: String?
        @Option(name: .long, help: "Search query") var query: String?
        @Option(name: .long, help: "Only this mailbox (e.g. INBOX)") var mailbox: String?
        @Option(name: .long, help: "Only this account") var account: String?
        @Option(name: .long, help: "Max results (default: 1)") var limit: Int = 1
        @Option(name: .long, help: "Seconds to wait for Mail (default: 60)") var timeout: Double = 60

        @Flag(name: .long, help: "Output JSON") var json = false

        func validate() throws {
            guard (id == nil) != (query == nil) else {
                throw ValidationError("Give --id or --query, not both and not neither.")
            }
        }

        func run() throws {
            try Auth.check("mail.read")
            let match: MailMatch = id.map { .messageId($0) } ?? .query(query ?? "")
            let msgs = try findMail(match, mailbox: mailbox, account: account, limit: limit,
                                    withContent: true, timeout: timeout)
            if let id = id, msgs.isEmpty {
                throw CLIFailure.notFound("No message has the Message-ID '\(id)'.",
                                          hint: mailbox == nil ? nil : "It may be in another mailbox; drop --mailbox.")
            }
            if json {
                printJSON(msgs)
            } else {
                for m in msgs {
                    print("[\(m["date"] as? String ?? "")] \(m["subject"] as? String ?? "")")
                    print("  From: \(m["from"] as? String ?? "")  Mailbox: \(m["mailbox"] as? String ?? "")")
                    print("---")
                    print(m["content"] as? String ?? "")
                    print("")
                }
                print("\(msgs.count) message(s)")
            }
        }
    }

    // MARK: - Delete

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete messages matching a query")

        @Option(name: .long, help: "Search query to find messages") var query: String
        @Option(name: .long, help: "Max messages to delete (default: 1)") var limit: Int = 1

        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("mail.delete")
            let escaped = jxaEscape(query)
            let script = """
            const Mail = Application('Mail');
            const q = '\(escaped)'.toLowerCase();
            const toDelete = [];
            Mail.accounts().forEach(acct => {
                try {
                    acct.mailboxes().forEach(mb => {
                        try {
                            mb.messages().slice(0, 500).forEach(m => {
                                try {
                                    const subj = (m.subject() || '').toLowerCase();
                                    const from = (m.sender() || '').toLowerCase();
                                    if (subj.includes(q) || from.includes(q)) {
                                        toDelete.push(m);
                                    }
                                } catch(e) {}
                            });
                        } catch(e) {}
                    });
                } catch(e) {}
            });
            const batch = toDelete.slice(0, \(limit));
            batch.forEach(m => { try { m.delete(); } catch(e) {} });
            JSON.stringify({deleted: batch.length});
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 60, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIFailure.appError("Could not delete messages — check Automation permission for Mail in System Settings\n\(raw.prefix(200))")
            }
            if json {
                printJSON(result)
            } else {
                let n = result["deleted"] as? Int ?? 0
                print("Deleted \(n) message\(n == 1 ? "" : "s") matching '\(query)'")
            }
        }
    }

    // MARK: - Mark

    struct Mark: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "mark", abstract: "Mark messages as read/unread/flagged")

        @Option(name: .long, help: "Search query to find messages") var query: String

        @Flag(name: .long, help: "Mark as read")     var read     = false
        @Flag(name: .long, help: "Mark as unread")   var unread   = false
        @Flag(name: .long, help: "Mark as flagged")  var flagged  = false
        @Flag(name: .long, help: "Remove flag")      var unflagged = false

        @Option(name: .long, help: "Max messages to mark (default: 500)") var limit: Int = 500
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("mail.write")
            guard read || unread || flagged || unflagged else {
                throw ValidationError("Specify at least one of: --read, --unread, --flagged, --unflagged")
            }
            let escaped = jxaEscape(query)
            // Build the property-set lines
            var sets: [String] = []
            if read     { sets.append("m.read = true;") }
            if unread   { sets.append("m.read = false;") }
            if flagged  { sets.append("m.flagged = true;") }
            if unflagged { sets.append("m.flagged = false;") }
            let setLines = sets.joined(separator: "\n                        ")
            let script = """
            const Mail = Application('Mail');
            const q = '\(escaped)'.toLowerCase();
            let count = 0;
            Mail.accounts().forEach(acct => {
                try {
                    acct.mailboxes().forEach(mb => {
                        try {
                            mb.messages().slice(0, \(limit)).forEach(m => {
                                try {
                                    const subj = (m.subject() || '').toLowerCase();
                                    const from = (m.sender() || '').toLowerCase();
                                    if (subj.includes(q) || from.includes(q)) {
                                        \(setLines)
                                        count++;
                                    }
                                } catch(e) {}
                            });
                        } catch(e) {}
                    });
                } catch(e) {}
            });
            JSON.stringify({marked: count});
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 60, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIFailure.appError("Could not mark messages — check Automation permission for Mail in System Settings\n\(raw.prefix(200))")
            }
            if json {
                printJSON(result)
            } else {
                let n = result["marked"] as? Int ?? 0
                print("Marked \(n) message\(n == 1 ? "" : "s") matching '\(query)'")
            }
        }
    }

    // MARK: - Mailboxes

    struct Mailboxes: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "mailboxes", abstract: "List all mailboxes across Mail accounts")

        @Option(name: .long, help: "Filter by account name (optional)") var account: String?

        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("mail.read")
            let filterAccount = account ?? ""
            let escaped = jxaEscape(filterAccount)
            let script = """
            const Mail = Application('Mail');
            const filter = '\(escaped)'.toLowerCase();
            const results = [];
            Mail.accounts().forEach(acct => {
                try {
                    const acctName = acct.name() || '';
                    if (filter && !acctName.toLowerCase().includes(filter)) return;
                    acct.mailboxes().forEach(mb => {
                        try {
                            results.push({
                                account: acctName,
                                name: mb.name(),
                                count: mb.messages().length
                            });
                        } catch(e) {}
                    });
                } catch(e) {}
            });
            JSON.stringify(results);
            """
            guard let rawOpt = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 45),
                  !rawOpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIFailure.timeout("Mail mailboxes timed out — large accounts may take longer.")
            }
            let raw = rawOpt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = raw.data(using: .utf8),
                  let mailboxes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw CLIFailure.appError("Could not list mailboxes — check Automation permission for Mail in System Settings\n\(raw.prefix(200))")
            }
            if json {
                printJSON(mailboxes)
            } else {
                var lastAcct = ""
                for mb in mailboxes {
                    let acctName = mb["account"] as? String ?? ""
                    let mbName   = mb["name"]    as? String ?? ""
                    let count    = mb["count"]   as? Int ?? 0
                    if acctName != lastAcct {
                        print("\n[\(acctName)]")
                        lastAcct = acctName
                    }
                    print("  \(mbName)  (\(count) message\(count == 1 ? "" : "s"))")
                }
                print("\n\(mailboxes.count) mailbox\(mailboxes.count == 1 ? "" : "es")")
            }
        }
    }

    // MARK: - Reply

    struct Reply: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reply", abstract: "Reply to a message matching a query")

        @Option(name: .long, help: "Search query to find the original message") var query: String
        @Option(name: .long, help: "Reply body text") var body: String

        @Option(name: .long, help: "Max messages to scan when searching (default: 500)") var limit: Int = 500
        @Flag(name: .long, help: "Reply-all") var all = false
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("mail.send")
            let escaped     = jxaEscape(query)
            let escapedBody = jxaEscape(body)
            let replyAll = all ? "true" : "false"
            let script = """
            const Mail = Application('Mail');
            const q = '\(escaped)'.toLowerCase();
            let found = null;
            outer: for (const acct of Mail.accounts()) {
                try {
                    for (const mb of acct.mailboxes()) {
                        try {
                            for (const m of mb.messages().slice(0, \(limit))) {
                                try {
                                    const subj = (m.subject() || '').toLowerCase();
                                    const from = (m.sender() || '').toLowerCase();
                                    if (subj.includes(q) || from.includes(q)) {
                                        found = m;
                                        break outer;
                                    }
                                } catch(e) {}
                            }
                        } catch(e) {}
                    }
                } catch(e) {}
            }
            if (!found) {
                JSON.stringify({replied: false, error: 'No matching message found'});
            } else {
                const subj = found.subject();
                const beforeCount = Mail.outgoingMessages().length;
                found.reply({replyToAll: \(replyAll)});
                const msgs = Mail.outgoingMessages();
                if (msgs.length > beforeCount) {
                    const outMsg = msgs[beforeCount];
                    outMsg.content = '\(escapedBody)\\n\\n' + (outMsg.content() || '');
                    outMsg.send();
                }
                JSON.stringify({replied: true, subject: subj});
            }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 60, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIFailure.appError("Could not reply — check Automation permission for Mail in System Settings\n\(raw.prefix(200))")
            }
            if result["replied"] as? Bool != true {
                throw CLIFailure.appError("Reply failed: \(result["error"] as? String ?? raw)")
            }
            if json {
                printJSON(result)
            } else {
                print("Replied to: \(result["subject"] as? String ?? query)")
            }
        }
    }

    // MARK: - Accounts

    struct Accounts: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List Mail accounts")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("mail.read")
            let script = """
            const Mail = Application('Mail');
            const out = Mail.accounts().map(a => {
                try { return {name: a.name(), email: a.emailAddresses()[0] || ''}; }
                catch(e) { return null; }
            }).filter(Boolean);
            JSON.stringify(out);
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let accounts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw CLIFailure.appError("Could not list Mail accounts — check Automation permission\n\(raw.prefix(200))")
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

// MARK: - Finding messages

enum MailMatch {
    case query(String)
    case messageId(String)
}

/// Find messages with one Apple-event query per mailbox (`whose`), which Mail answers
/// itself, instead of three or four events per message. `--mailbox` and `--account`
/// skip the rest. An unknown mailbox or account is `not_found`, never zero results.
func findMail(_ match: MailMatch, mailbox: String?, account: String?, limit: Int,
              withContent: Bool, timeout: Double) throws -> [[String: Any]] {
    let filter: String
    switch match {
    case .query(let q):
        let e = jxaEscape(q)
        filter = "{_or: [{subject: {_contains: '\(e)'}}, {sender: {_contains: '\(e)'}}, {content: {_contains: '\(e)'}}]}"
    case .messageId(let id):
        let bare = id.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        filter = "{messageId: '\(jxaEscape(bare))'}"
    }
    let script = """
    const Mail = Application('Mail');
    const wantMailbox = \(mailbox.map { "'\(jxaEscape($0))'" } ?? "null");
    const wantAccount = \(account.map { "'\(jxaEscape($0))'" } ?? "null");
    const limit = \(max(limit, 0));
    const out = [];
    let sawAccount = false, sawMailbox = false;
    outer:
    for (const acct of Mail.accounts()) {
        let acctName;
        try { acctName = acct.name(); } catch (e) { continue; }
        if (wantAccount !== null && acctName !== wantAccount) continue;
        sawAccount = true;
        let boxes;
        try { boxes = acct.mailboxes(); } catch (e) { continue; }
        for (const mb of boxes) {
            let mbName;
            try { mbName = mb.name(); } catch (e) { continue; }
            if (wantMailbox !== null && mbName !== wantMailbox) continue;
            sawMailbox = true;
            if (out.length >= limit) break outer;
            try {
                const found = mb.messages.whose(\(filter));
                const ids = found.id();
                if (!ids.length) continue;
                const subjects = found.subject(), senders = found.sender();
                const dates = found.dateSent(), mids = found.messageId();
                for (let i = 0; i < ids.length && out.length < limit; i++) {
                    const sent = dates[i] ? dates[i].toISOString() : null;
                    const row = { id: ids[i], message_id: mids[i], subject: subjects[i], from: senders[i],
                                  date: sent ? sent.split('T')[0] : '', date_sent: sent,
                                  mailbox: mbName, account: acctName };
                    if (\(withContent)) {
                        try { row.content = (found[i].content() || '').substring(0, 2000); } catch (e) { row.content = null; }
                    }
                    out.push(row);
                }
            } catch (e) {}
        }
    }
    JSON.stringify({ messages: out, sawAccount: sawAccount, sawMailbox: sawMailbox });
    """
    let result = Process.captureWithStderr(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
                                           timeout: timeout)
    let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else {
        if result.exitCode == -1 {
            throw CLIFailure.timeout("Mail did not answer within \(Int(timeout)) s.",
                                     hint: "Name the mailbox with --mailbox, or raise --timeout.")
        }
        if result.stderr.contains("-1743") || result.stderr.lowercased().contains("not allowed") {
            throw CLIFailure(code: "access_denied", message: "macOS does not let this binary control Mail.",
                             hint: "With Mail open, a person runs `macos authorize automation.mail` and clicks OK.",
                             extra: ["area": "automation.mail"])
        }
        throw CLIFailure.appError("Mail refused the search: \(result.stderr.prefix(200))")
    }
    guard let data = raw.data(using: .utf8),
          let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let messages = body["messages"] as? [[String: Any]] else {
        throw CLIFailure.appError("Mail returned something that is not a result: \(raw.prefix(200))")
    }
    if let account = account, body["sawAccount"] as? Bool != true {
        throw CLIFailure.notFound("No Mail account is named '\(account)'.", hint: "Run `macos mail accounts`.")
    }
    if let mailbox = mailbox, body["sawMailbox"] as? Bool != true {
        throw CLIFailure.notFound("No mailbox is named '\(mailbox)'.", hint: "Run `macos mail mailboxes`.")
    }
    return messages
}
