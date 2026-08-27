import ArgumentParser
import Foundation
import MacCLICore

// Mail control via JXA. Requires Automation permission for Mail in System Settings → Privacy.

struct MailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Apple Mail — create drafts, search messages",
        subcommands: [Draft.self, Search.self, Accounts.self, Refresh.self, Send.self, Read.self, Delete.self, Mark.self, Mailboxes.self, Reply.self, Inventory.self, Mutate.self]
    )

    // MARK: - Refresh (force Mail.app to check for new mail)

    struct Refresh: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Force Mail to check all accounts for new messages now",
            discussion: """
                Asks Mail to poll every configured account immediately. The request is \
                fire-and-forget: a successful exit means Mail accepted the request, not \
                that new mail has finished downloading.

                Human output is the single line "Mail refresh requested."; --json prints \
                {"refresh_requested": true}. Both exit 0. On failure the command prints \
                the underlying error and exits non-zero — it never reports success for a \
                refresh Mail refused.
                """)

        @Flag(name: .long, help: "Print {\"refresh_requested\": true} instead of the text line")
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
            // NOTE: this envelope's `result` is the bare string "refreshed", not an
            // object. parseJXAEnvelope encodes it via MacCLICore.encodeJXAResult,
            // which tolerates JSON fragments; handing a scalar straight to
            // JSONSerialization aborts the process.
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw ValidationError("Mail refresh failed: \(errMsg.prefix(200))")
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
                throw ValidationError("Could not create draft — check Automation permission for Mail in System Settings\n\(errMsg.prefix(200))")
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
        static let configuration = CommandConfiguration(abstract: "Search Apple Mail messages")

        @Argument(help: "Search query")
        var query: String

        @Option(name: .long, help: "Max results (default: 10)") var limit: Int = 10
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("mail.read")
            let escaped = jxaEscape(query)
            let script = """
            const Mail = Application('Mail');
            const q = '\(escaped)'.toLowerCase();
            const results = [];
            Mail.accounts().forEach(acct => {
                try {
                    acct.mailboxes().forEach(mb => {
                        try {
                            mb.messages().slice(0, 500).forEach(m => {
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
                throw ValidationError("Could not send email — check Automation permission for Mail in System Settings\n\(errMsg.prefix(200))")
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
        static let configuration = CommandConfiguration(commandName: "read", abstract: "Read full message content for messages matching a query")

        @Option(name: .long, help: "Search query") var query: String
        @Option(name: .long, help: "Max results (default: 1)") var limit: Int = 1

        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("mail.read")
            let escaped = jxaEscape(query)
            let script = """
            const Mail = Application('Mail');
            const q = '\(escaped)'.toLowerCase();
            const results = [];
            Mail.accounts().forEach(acct => {
                try {
                    acct.mailboxes().forEach(mb => {
                        try {
                            mb.messages().slice(0, 500).forEach(m => {
                                try {
                                    const subj = (m.subject() || '').toLowerCase();
                                    const from = (m.sender() || '').toLowerCase();
                                    const cont = (m.content() || '').toLowerCase();
                                    if (subj.includes(q) || from.includes(q) || cont.includes(q)) {
                                        const fullContent = m.content() || '';
                                        results.push({
                                            subject: m.subject(),
                                            from: m.sender(),
                                            date: m.dateSent() ? m.dateSent().toISOString().split('T')[0] : '',
                                            mailbox: mb.name(),
                                            content: fullContent.substring(0, 2000)
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
            guard let rawOpt = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 60),
                  !rawOpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("Mail read timed out — try a more specific query.")
            }
            let raw = rawOpt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = raw.data(using: .utf8),
                  let msgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not read Mail messages — check Automation permission\n\(raw.prefix(200))")
            }
            if json {
                printJSON(msgs)
            } else {
                for m in msgs {
                    let subj = m["subject"] as? String ?? ""
                    let from = m["from"]    as? String ?? ""
                    let date = m["date"]    as? String ?? ""
                    let mbox = m["mailbox"] as? String ?? ""
                    let cont = m["content"] as? String ?? ""
                    print("[\(date)] \(subj)")
                    print("  From: \(from)  Mailbox: \(mbox)")
                    print("---")
                    print(cont)
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
                throw ValidationError("Could not delete messages — check Automation permission for Mail in System Settings\n\(raw.prefix(200))")
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
                throw ValidationError("Could not mark messages — check Automation permission for Mail in System Settings\n\(raw.prefix(200))")
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
                throw ValidationError("Mail mailboxes timed out — large accounts may take longer.")
            }
            let raw = rawOpt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = raw.data(using: .utf8),
                  let mailboxes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("Could not list mailboxes — check Automation permission for Mail in System Settings\n\(raw.prefix(200))")
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
                throw ValidationError("Could not reply — check Automation permission for Mail in System Settings\n\(raw.prefix(200))")
            }
            if result["replied"] as? Bool != true {
                throw ValidationError("Reply failed: \(result["error"] as? String ?? raw)")
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

    // MARK: - Shared JXA prelude for the scoped machine API
    //
    // Lives in MacCLICore (`jxaMailPrelude`) so its exact-locator contract is covered by
    // pure tests. Both `inventory` and `mutate` build on it.
    static let jxaPrelude = MacCLICore.jxaMailPrelude

    /// A JS string literal, or the JS `null` literal when there is no value.
    static func jsLiteral(_ value: String?) -> String { return MacCLICore.jsLiteral(value) }

    /// Run one of the machine-API scripts and decode its object, or emit a structured
    /// refusal. Timeouts and unparseable output are HARD errors — never an empty result.
    static func runMachineScript(_ script: String, command: String, timeout: Double) throws -> [String: Any] {
        guard let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
                                        timeout: timeout),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            printJSON(MacCLICore.mailErrorJSON(
                command: command, error: "mail_timeout",
                message: "Mail did not respond within \(Int(timeout))s. Reduce --limit or pass "
                    + "--no-headers, then retry."))
            throw ExitCode(1)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            printJSON(MacCLICore.mailErrorJSON(
                command: command, error: "mail_unreadable",
                message: "Could not parse Mail's response — check Automation permission for Mail "
                    + "in System Settings › Privacy & Security › Automation.",
                extra: ["detail": MacCLICore.redactBoundedError(trimmed)]))
            throw ExitCode(1)
        }
        return obj
    }

    /// Turn a JXA-side refusal into the structured envelope and exit non-zero.
    static func failFromScript(_ obj: [String: Any], command: String, extra: [String: Any]) throws -> Never {
        let code = obj["error"] as? String ?? "mail_error"
        var context = extra
        if let matched = obj["matched"] as? Int { context["matched"] = matched }
        if let available = obj["available"] as? [String] { context["available"] = available }
        if let total = obj["total_in_mailbox"] as? Int { context["total_in_mailbox"] = total }
        if let affected = obj["affected_count"] as? Int { context["affected_count"] = affected }
        if let detail = obj["detail"] as? String {
            context["detail"] = MacCLICore.redactBoundedError(detail)
        }
        printJSON(MacCLICore.mailErrorJSON(command: command, error: code,
                                           message: explainMailError(code), extra: context))
        throw ExitCode(1)
    }

    /// Stable, non-leaking prose for each machine error code.
    static func explainMailError(_ code: String) -> String {
        switch code {
        case "mail_unavailable":
            return "Mail.app could not be reached. Is it installed and permitted under Automation?"
        case "account_not_found":
            return "No Mail account matches that exact name or address. Run `macos mail accounts`."
        case "account_ambiguous":
            return "More than one Mail account matches that name or address; refusing to guess."
        case "account_enumeration_failed":
            return "Mail refused to list its accounts — check Automation permission for Mail."
        case "mailbox_not_found":
            return "That account has no mailbox with that exact name. Run `macos mail mailboxes --account ...`."
        case "mailbox_ambiguous":
            return "That account has more than one mailbox with that exact name; refusing to guess."
        case "mailbox_enumeration_failed":
            return "Mail refused to list that account's mailboxes."
        case "mailbox_count_unavailable":
            return "Mail would not report how many messages the mailbox holds, so the window cannot be bounded."
        case "unread_filter_unavailable":
            return "Mail rejected the unread filter. Retry without --unread-only and filter on the `read` field."
        case "id_filter_unavailable":
            return "Mail rejected an exact filter on the numeric message id, so the target could not be "
                + "isolated. Nothing was changed."
        case "message_id_filter_unavailable":
            return "Mail rejected an exact filter on the RFC Message-ID, so the target could not be "
                + "isolated. Nothing was changed. Retry with --id from `mail inventory`."
        case "identity_mismatch":
            return "The message Mail returned does not carry the identity that was requested. Nothing was "
                + "changed; re-run inventory."
        case "destination_not_found":
            return "The --move-to mailbox does not exist in that account. Nothing was changed."
        case "destination_ambiguous":
            return "More than one mailbox in that account has the --move-to name; refusing to guess."
        case "read_setter_failed":
            return "Mail rejected the read-state change. Nothing was changed."
        case "move_failed":
            return "Mail rejected the move. The read-state change, if any, may already have been applied — re-run inventory."
        case "capability_denied":
            return "That capability is denied. Grant it with `macos auth grant ...`."
        default:
            return "Mail returned an error for this request."
        }
    }

    // MARK: - Inventory (read-only, scoped, bounded)

    struct Inventory: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "inventory",
            abstract: "Read-only, bounded inventory of ONE mailbox in ONE account (machine JSON)",
            discussion: """
            Built for external triage/classification. Unlike `mail search`, this command \
            never sweeps across accounts or mailboxes: --account and --mailbox are required \
            and matched EXACTLY, and the window is bounded by --limit (max 500) and --offset.

            Every row carries stable identity (`id`, `rfc_message_id`), scope, sender, \
            recipients, dates, read/flagged state and the classification-relevant RFC \
            headers (Message-ID, In-Reply-To, References, List-ID, List-Unsubscribe, \
            List-Unsubscribe-Post, Precedence, Auto-Submitted). Message BODIES are never \
            emitted.

            If any message or the candidate scan could not be read, the envelope comes back \
            ok=false / status="degraded" with a non-zero exit — a partial inventory is never \
            presented as a complete one.

            PAGING A CHANGING SET. `offset` indexes into Mail's live mailbox order, so it \
            is only stable while that set is not changing. When you are working through \
            --unread-only and marking messages read (or moving them out) as you go, every \
            item you handle LEAVES the result set and shifts everything after it down — \
            incrementing --offset would then skip exactly as many messages as you \
            processed. In that mode: repeatedly inventory from --offset 0, dedupe by the \
            stable `id`, and stop when a page yields nothing new. Advance --offset only \
            when you are purely reading and mutating nothing.
            """)

        @Option(name: .long, help: "Exact Mail account name, or one of its exact addresses (required)")
        var account: String

        @Option(name: .long, help: "Exact mailbox name within that account (required)")
        var mailbox: String

        @Option(name: .long, help: "Messages per page, 1–500 (default: 50)")
        var limit: Int = 50

        @Option(name: .long, help: "Zero-based offset into the mailbox's native order (default: 0)")
        var offset: Int = 0

        @Flag(name: .long, help: "Only return unread messages")
        var unreadOnly = false

        @Flag(name: .long, help: "Skip RFC header extraction (much faster, drops List-ID etc.)")
        var noHeaders = false

        @Flag(name: .long, help: "Output JSON (this command is machine-first; errors are always JSON)")
        var json = false

        /// Cap on the raw header block pulled per message. Exceeding it marks the row
        /// `truncated` and degrades the envelope — a silently clipped List-Unsubscribe
        /// would otherwise misclassify the message.
        static let headerCap = 20_000

        func run() throws {
            // Validate BEFORE any Apple Event, so a bad window can never reach Mail.
            let v = MacCLICore.validateMailInventoryArgs(
                account: account, mailbox: mailbox, limit: limit, offset: offset)
            guard v.valid else {
                printJSON(MacCLICore.mailErrorJSON(
                    command: "mail.inventory", error: v.error ?? "invalid_arguments",
                    message: v.message ?? "Invalid arguments.",
                    extra: v.field.map { ["field": $0] } ?? [:]))
                throw ExitCode(1)
            }
            do {
                try Auth.check("mail.read")
            } catch {
                printJSON(MacCLICore.mailErrorJSON(
                    command: "mail.inventory", error: "capability_denied",
                    message: "The 'mail.read' capability is denied. Run `macos auth grant mail.read`.",
                    extra: ["capability": "mail.read"]))
                throw ExitCode(1)
            }

            let script = """
            (function () {
            \(MailCommand.jxaPrelude)
            var WANT_ACCOUNT = \(MailCommand.jsLiteral(account));
            var WANT_MAILBOX = \(MailCommand.jsLiteral(mailbox));
            var LIMIT = \(limit);
            var OFFSET = \(offset);
            var UNREAD_ONLY = \(unreadOnly);
            var WITH_HEADERS = \(!noHeaders);
            var HEADER_CAP = \(Inventory.headerCap);

            var Mail;
            try { Mail = Application('Mail'); } catch (e) { return fail('mail_unavailable', e); }

            var ar = resolveAccount(Mail, WANT_ACCOUNT);
            if (ar.err) return fail(ar.err, ar.detail, {matched: ar.matched, available: ar.available});
            var mr = resolveMailbox(ar.acct.obj, WANT_MAILBOX);
            if (mr.err) return fail(mr.err, mr.detail, {matched: mr.matched, available: mr.available});

            var out = {ok: true, account: ar.acct.name, account_email: ar.acct.email,
                       mailbox: WANT_MAILBOX, total_in_mailbox: 0, total_matching: 0,
                       degraded: [], messages: []};
            function degrade(s) {
              if (out.degraded.length < 25) { out.degraded.push(String(s).slice(0, 200)); }
            }
            function addressesOf(m, kind) {
              var res = {list: [], failed: false}, recips = null;
              try { recips = (kind === 'to') ? m.toRecipients() : m.ccRecipients(); }
              catch (e) { res.failed = true; return res; }
              if (!recips) return res;
              var n = Math.min(recips.length, 50);
              for (var i = 0; i < n; i++) {
                try { var a = recips[i].address(); if (a) { res.list.push(String(a)); } }
                catch (e) { res.failed = true; }
              }
              return res;
            }

            var total = 0;
            try { total = mr.mbox.messages.length; }
            catch (e) { return fail('mailbox_count_unavailable', e); }
            out.total_in_mailbox = total;

            var sel = mr.mbox.messages;
            if (UNREAD_ONLY) {
              try {
                sel = mr.mbox.messages.whose({readStatus: false});
                out.total_matching = sel.length;
              } catch (e) { return fail('unread_filter_unavailable', e); }
            } else {
              out.total_matching = total;
            }

            var end = Math.min(OFFSET + LIMIT, out.total_matching);
            for (var k = OFFSET; k < end; k++) {
              var m = null;
              try { m = sel[k]; } catch (e) { degrade('message[' + k + ']: ' + e); continue; }
              var row = {index: k, id: null, rfc_message_id: null, subject: null, sender: null,
                         to: [], cc: [], date_sent: null, date_received: null,
                         read: null, flagged: null, headers_raw: '',
                         headers_status: WITH_HEADERS ? 'ok' : 'skipped', errors: []};
              try { row.id = String(m.id()); } catch (e) { row.errors.push('id'); }
              try { var mid = m.messageId(); row.rfc_message_id = mid ? String(mid) : null; }
              catch (e) { row.errors.push('rfc_message_id'); }
              try { row.subject = m.subject(); } catch (e) { row.errors.push('subject'); }
              try { row.sender = m.sender(); } catch (e) { row.errors.push('sender'); }
              try { row.date_sent = isoDate(m.dateSent()); } catch (e) { row.errors.push('date_sent'); }
              try { row.date_received = isoDate(m.dateReceived()); } catch (e) { row.errors.push('date_received'); }
              try { row.read = m.readStatus(); } catch (e) { row.errors.push('read'); }
              try { row.flagged = m.flaggedStatus(); } catch (e) { row.errors.push('flagged'); }
              var ta = addressesOf(m, 'to'); row.to = ta.list; if (ta.failed) { row.errors.push('to'); }
              var ca = addressesOf(m, 'cc'); row.cc = ca.list; if (ca.failed) { row.errors.push('cc'); }
              if (WITH_HEADERS) {
                try {
                  var ah = m.allHeaders();
                  ah = ah ? String(ah) : '';
                  if (ah.length > HEADER_CAP) {
                    row.headers_raw = ah.slice(0, HEADER_CAP);
                    row.headers_status = 'truncated';
                  } else {
                    row.headers_raw = ah;
                    row.headers_status = 'ok';
                  }
                } catch (e) { row.headers_status = 'unavailable'; row.errors.push('headers'); }
              }
              if (row.errors.length > 0) { degrade('message[' + k + ']: ' + row.errors.join(',')); }
              if (row.headers_status === 'truncated') { degrade('message[' + k + ']: headers_truncated'); }
              out.messages.push(row);
            }
            return JSON.stringify(out);
            })()
            """

            let obj = try MailCommand.runMachineScript(script, command: "mail.inventory", timeout: 180)
            if (obj["ok"] as? Bool) != true {
                try MailCommand.failFromScript(obj, command: "mail.inventory",
                                               extra: ["account": account, "mailbox": mailbox])
            }

            let acctName = obj["account"] as? String ?? account
            let mboxName = obj["mailbox"] as? String ?? mailbox
            let degraded = (obj["degraded"] as? [String] ?? []).map { MacCLICore.redactBoundedError($0) }

            // `headers_raw` is parsed here and DROPPED — only the allowlisted header
            // fields reach the caller, so no Received chain or body text can escape.
            let rows: [[String: Any]] = (obj["messages"] as? [[String: Any]] ?? []).map { r in
                let rawHeaders = r["headers_raw"] as? String ?? ""
                return MacCLICore.mailInventoryItemJSON(
                    account: acctName,
                    mailbox: mboxName,
                    index: r["index"] as? Int ?? -1,
                    id: r["id"] as? String,
                    rfcMessageID: r["rfc_message_id"] as? String,
                    subject: r["subject"] as? String,
                    sender: r["sender"] as? String,
                    toRecipients: r["to"] as? [String] ?? [],
                    ccRecipients: r["cc"] as? [String] ?? [],
                    dateSent: r["date_sent"] as? String,
                    dateReceived: r["date_received"] as? String,
                    read: r["read"] as? Bool,
                    flagged: r["flagged"] as? Bool,
                    headers: rawHeaders.isEmpty ? [:] : MacCLICore.mailClassificationHeaders(rawHeaders),
                    headersStatus: r["headers_status"] as? String ?? "unknown",
                    errors: r["errors"] as? [String] ?? [])
            }

            let envelope = MacCLICore.mailInventoryEnvelope(
                messages: rows, account: acctName, mailbox: mboxName,
                unreadOnly: unreadOnly, limit: limit, offset: offset,
                totalMatching: obj["total_matching"] as? Int ?? rows.count,
                totalInMailbox: obj["total_in_mailbox"] as? Int ?? 0,
                degraded: degraded)

            if json {
                printJSON(envelope)
            } else {
                print("[\(acctName)] \(mboxName) — \(rows.count) of \(envelope["total_matching"] as? Int ?? 0) "
                    + "matching (\(envelope["total_in_mailbox"] as? Int ?? 0) in mailbox)")
                for r in rows {
                    let date = r["date_received"] as? String ?? (r["date_sent"] as? String ?? "")
                    let read = (r["read"] as? Bool ?? false) ? " " : "•"
                    print("\(read) [\(date)] \(r["subject"] as? String ?? "(no subject)")")
                    print("    from: \(r["sender"] as? String ?? "(unknown)")")
                    print("    id: \(r["id"] as? String ?? "-")  message-id: \(r["rfc_message_id"] as? String ?? "-")")
                    if let h = r["headers"] as? [String: String], let listID = h["list-id"] {
                        print("    list-id: \(listID)")
                    }
                }
                if let next = envelope["next_offset"] as? Int { print("next --offset \(next)") }
                if !degraded.isEmpty { print("DEGRADED (\(degraded.count)): \(degraded.joined(separator: "; "))") }
            }
            if (envelope["ok"] as? Bool) != true { throw ExitCode(1) }
        }
    }

    // MARK: - Mutate (exact identity, reversible, verified)

    struct Mutate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mutate",
            abstract: "Mark read/unread or move EXACTLY ONE message, located by stable id (machine JSON)",
            discussion: """
            The safe counterpart to `mail mark`. It requires an explicit --account, an \
            explicit source --mailbox, and a stable identity (--id and/or --message-id). \
            There is no subject or sender selector: substring matching is never used to \
            choose what to mutate, and there is no delete or expunge path.

            The message is located by an exact Mail-side filter, so the cost is \
            proportional to the number of MATCHES, not to the size of the mailbox — this \
            works against a 30,000-message inbox. --id is the efficient stable locator and \
            is what `mail inventory` reports; prefer it. --message-id matches the RFC \
            Message-ID exactly (with or without angle brackets). If you pass both, they \
            must identify the SAME single message or the command refuses.

            It fails closed. If the identity does not select EXACTLY ONE message in exactly \
            that account and mailbox, nothing is changed and the command exits non-zero. \
            The --move-to destination is resolved BEFORE anything is mutated, so a bad \
            destination cannot leave a message marked read with nowhere to go.

            Both actions are reversible (--read/--unread, and --move-to back again). After \
            mutating, both mailboxes are read back through the same exact filters: a move \
            counts as verified only when the message is found exactly once in the \
            destination and zero times in the source, and a read-state change only when \
            the flag is observed to equal what was asked for. A setter that did not throw \
            is never treated as evidence. `status: "unverified"` means the change may have \
            landed — re-run `mail inventory`, do not blindly retry.
            """)

        @Option(name: .long, help: "Exact Mail account name, or one of its exact addresses (required)")
        var account: String

        @Option(name: .long, help: "Exact source mailbox name within that account (required)")
        var mailbox: String

        @Option(name: .long, help: "Mail's numeric message id, as reported by `mail inventory` (preferred)")
        var id: String?

        @Option(name: .long, help: "Exact RFC Message-ID, with or without angle brackets")
        var messageId: String?

        @Flag(name: .long, help: "Mark the message read")
        var read = false

        @Flag(name: .long, help: "Mark the message unread (the inverse of --read)")
        var unread = false

        @Option(name: .long, help: "Move the message to this mailbox in the same account (reversible)")
        var moveTo: String?

        @Flag(name: .long, help: "Output JSON (this command is machine-first; output is always JSON)")
        var json = false

        func run() throws {
            let v = MacCLICore.validateMailMutateArgs(
                account: account, mailbox: mailbox, id: id, rfcMessageID: messageId,
                read: read, unread: unread, moveTo: moveTo)
            guard v.valid else {
                printJSON(MacCLICore.mailErrorJSON(
                    command: "mail.mutate", error: v.error ?? "invalid_arguments",
                    message: v.message ?? "Invalid arguments.",
                    extra: v.field.map { ["field": $0] } ?? [:]))
                throw ExitCode(1)
            }
            // Marking and moving are both writes; `mail.write` gates them. Neither this
            // command nor its script ever calls delete()/expunge.
            do {
                try Auth.check("mail.write")
            } catch {
                printJSON(MacCLICore.mailErrorJSON(
                    command: "mail.mutate", error: "capability_denied",
                    message: "The 'mail.write' capability is denied. Run `macos auth grant mail.write`.",
                    extra: ["capability": "mail.write"]))
                throw ExitCode(1)
            }

            let destination = moveTo?.trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = MacCLICore.MailMessageRef(account: account, mailbox: mailbox,
                                                id: id, rfcMessageID: messageId)

            // ONE script window: resolve scope, resolve the destination, locate the message
            // by exact filter, mutate it, and read the result back. Splitting this up is
            // what created the index race the previous design had to detect after the fact.
            let script = MacCLICore.mailMutateScript(
                account: account, mailbox: mailbox, destination: destination,
                id: id, rfcMessageID: messageId, read: read, unread: unread)

            let obj = try MailCommand.runMachineScript(script, command: "mail.mutate", timeout: 180)
            if (obj["ok"] as? Bool) != true {
                try MailCommand.failFromScript(obj, command: "mail.mutate",
                                               extra: ["requested": ref.jsonObject, "affected_count": 0])
            }

            let matchedCount = obj["matched_count"] as? Int ?? 0
            if (obj["refused"] as? Bool) == true || matchedCount != 1 {
                // Zero or many matched: the script mutated nothing.
                printJSON(MacCLICore.mailMatchRefusalJSON(requested: ref, matchedCount: matchedCount))
                throw ExitCode(1)
            }

            // Independent Swift-side confirmation that the message actually acted on is the
            // one that was asked for. The script already checks this, but the check that
            // decides the exit status is the tested pure one, applied to the identity Mail
            // reported back.
            let acted = MacCLICore.MailCandidate(id: obj["result_id"] as? String,
                                                 rfcMessageID: obj["result_rfc"] as? String)
            guard MacCLICore.mailSelectUnique(candidates: [acted], id: id,
                                              rfcMessageID: messageId).verdict == .unique else {
                printJSON(MacCLICore.mailErrorJSON(
                    command: "mail.mutate", error: "identity_mismatch",
                    message: MailCommand.explainMailError("identity_mismatch"),
                    extra: ["requested": ref.jsonObject,
                            "matched_count": matchedCount,
                            "affected_count": obj["affected"] as? Int ?? 0]))
                throw ExitCode(1)
            }

            let outcome = MacCLICore.MailMutationOutcome(
                readRequested: read ? true : (unread ? false : nil),
                readAfter: obj["read_after"] as? Bool,
                readVerified: obj["read_verified"] as? Bool ?? false,
                moveRequestedTo: destination,
                moveVerified: obj["move_verified"] as? Bool ?? false,
                unverifiedReason: obj["unverified_reason"] as? String)

            let result = MacCLICore.mailMutationResultJSON(
                requested: ref,
                matchedCount: matchedCount,
                affectedCount: obj["affected"] as? Int ?? 0,
                resultID: obj["result_id"] as? String,
                resultRFCMessageID: obj["result_rfc"] as? String,
                finalMailbox: obj["final_mailbox"] as? String ?? mailbox,
                readBefore: obj["read_before"] as? Bool,
                outcome: outcome)

            printJSON(result)
            if (result["ok"] as? Bool) != true { throw ExitCode(1) }
        }
    }
}
