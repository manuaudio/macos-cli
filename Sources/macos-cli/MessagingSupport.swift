import Foundation
import MacCLICore
import ArgumentParser

/// sqlite3 opens only read-only connections, including when producing a consistent backup.
func messagingRows(_ path: String, _ sql: String, copyIfLocked: Bool = false) throws -> [[String: Any]] {
    let result = Process.captureWithStderr(args: ["/usr/bin/sqlite3", "-readonly", "-json", "-cmd", ".timeout 1000", path, sql], timeout: 10)
    if result.exitCode != 0 {
        if copyIfLocked && result.stderr.lowercased().contains("locked") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let copy = directory.appendingPathComponent("snapshot.sqlite").path
            let backup = Process.captureWithStderr(args: ["/usr/bin/sqlite3", "-readonly", "-cmd", ".timeout 5000", path, ".backup '\(copy)'"], timeout: 10)
            guard backup.exitCode == 0 else { throw CLIFailure.appError("Database is busy; try again.") }
            return try messagingRows(copy, sql)
        }
        if result.stderr.contains("authorization denied") || result.stderr.contains("unable to open") {
            throw CLIFailure.permission("Cannot read the messaging database.", hint: "Grant Full Disk Access to the terminal running macos.")
        }
        throw CLIFailure.appError("Unsupported or unavailable messaging database: \(result.stderr.prefix(200))")
    }
    if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
    guard let rows = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]] else {
        throw CLIFailure.appError("Unexpected database output.")
    }
    return rows
}

func mailScript(_ script: String, wait: Double) throws -> String {
    guard wait.isFinite && wait > 0 && wait < Double(Int.max) else { throw ValidationError("--wait must be positive and finite.") }
    let wrapped = """
    ObjC.import('Foundation');
    function operation() {
    \(script)
    }
    JSON.stringify(operation());
    """
    // The AppleScript timeout surrounds the JavaScript operation; the child
    // deadline also bounds the total, including a busy app.
    let escaped = wrapped.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
    let source = "with timeout of \(Int(wait.rounded(.up))) seconds\nrun script \"\(escaped)\" in \"JavaScript\"\nend timeout"
    let result = Process.captureWithStderr(args: ["/usr/bin/osascript", "-e", source], timeout: wait)
    if result.exitCode == -1 || (result.stderr.contains("-1712") || result.stderr.lowercased().contains("timed out")) {
        throw CLIFailure(code: "mail_busy", message: "Mail did not answer within \(Int(wait)) seconds.", hint: "Let Mail finish syncing, then retry with --wait 600. Check for an existing draft before retrying a write.")
    }
    guard result.exitCode == 0, !result.stdout.isEmpty else {
        throw CLIFailure.appError("Mail operation failed: \(result.stderr.prefix(200))", hint: "Check Automation permission for Mail.")
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Only read-only or idempotent operations may retry an Apple-event timeout.
func retryBusyMail<T>(wait: Double, operation: (Double) throws -> T) throws -> T {
    guard wait.isFinite && wait > 0 && wait < Double(Int.max) else { throw ValidationError("--wait must be positive and finite.") }
    let deadline=Date().addingTimeInterval(wait)
    while true {
        do { return try operation(max(0.001,deadline.timeIntervalSinceNow)) }
        catch let failure as CLIFailure where failure.code == "mail_busy" {
            guard Date() < deadline else { throw failure }
        }
    }
}

func mailAccounts(wait: Double = 600) throws -> [MailSenderAccount] {
    let raw = try retryBusyMail(wait:wait) { remaining in
        try mailScript("return Application('Mail').accounts().map(a => ({id:a.id(), name:a.name(), addresses:a.emailAddresses()}));", wait: remaining)
    }
    return try JSONDecoder().decode([MailSenderAccount].self, from: Data(raw.utf8))
}

func mailSender(_ address: String, wait: Double) throws -> MailSenderAccount {
    guard address.contains("@"), !address.contains(where: { $0.isWhitespace || "<>,;".contains($0) }) else { throw ValidationError("--from must be one email address.") }
    let accounts = try mailAccounts(wait: wait)
    do { return try MessagingStore.sender(address, accounts: accounts) }
    catch SenderSelectionError.notFound {
        throw CLIFailure(code: "sender_not_found", message: "No Mail account owns '\(address)'.", extra: ["accounts": accounts.map { ["id": $0.id, "name": $0.name, "addresses": $0.addresses] as [String: Any] }])
    } catch {
        throw CLIFailure(code: "invalid_sender", message: "More than one account owns '\(address)'; remove the duplicate before sending.")
    }
}

func messageBody(_ body: String, file: String?) throws -> String {
    guard let file = file else { return body }
    guard body.isEmpty else { throw ValidationError("Use --body or --body-file, not both.") }
    let data = file == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: file))
    guard let text = String(data: data, encoding: .utf8) else { throw ValidationError("The body must be UTF-8 text.") }
    return text
}

func envelopeIndex() throws -> String {
    let base = userHome().appendingPathComponent("Library/Mail")
    let versions = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix("V") }.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
    for version in versions {
        let path = base.appendingPathComponent("\(version)/MailData/Envelope Index").path
        if FileManager.default.fileExists(atPath: path) { return path }
    }
    throw CLIFailure.permission("Mail's Envelope Index is unavailable.", hint: "Open Mail and grant Full Disk Access to the terminal.")
}

func indexedMail(_ match: MailMatch, mailbox: String?, account: String?, limit: Int, withContent: Bool, timeout: Double) throws -> [[String: Any]] {
    let query: String?, id: String?
    switch match { case .query(let value): query = value; id = nil
    case .messageId(let value): query = nil; id = value }
    // Account labels come from the system account database without waking Mail.
    let accountPath = userHome().appendingPathComponent("Library/Accounts/Accounts4.sqlite").path
    let metadata = try messagingRows(accountPath, "SELECT a.ZIDENTIFIER AS id,COALESCE(p.ZACCOUNTDESCRIPTION,a.ZACCOUNTDESCRIPTION,a.ZUSERNAME,'') AS name FROM ZACCOUNT a LEFT JOIN ZACCOUNT p ON p.Z_PK=a.ZPARENTACCOUNT")
    let accounts = metadata.compactMap { row -> MailSenderAccount? in
        guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
        return MailSenderAccount(id:id,name:name,addresses:[])
    }
    if let account = account, !accounts.contains(where: { $0.name == account }) { throw CLIFailure.notFound("No Mail account is named '\(account)'.") }
    let indexPath = try envelopeIndex()
    if let mailbox = mailbox {
        let boxes = try messagingRows(indexPath,"SELECT url FROM mailboxes")
        let found = boxes.contains { row in
            guard let raw=row["url"] as? String, let url=URL(string:raw), url.lastPathComponent == mailbox else { return false }
            return account == nil || accounts.contains { $0.name == account && $0.id.caseInsensitiveCompare(url.host ?? "") == .orderedSame }
        }
        guard found else { throw CLIFailure.notFound("No Mail mailbox is named '\(mailbox)' in the selected account.") }
    }
    var rows = try messagingRows(indexPath, MessagingStore.mailQuery(query: query, messageID: id, mailbox: mailbox, limit: limit, accountIDs: account.map { name in accounts.filter { $0.name == name }.map(\.id) }))
    rows = rows.compactMap { row in
        var row = row
        guard let raw = row.removeValue(forKey: "mailbox_url") as? String, let url = URL(string: raw) else { return nil }
        let box = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let owner = accounts.first { $0.id.caseInsensitiveCompare(url.host ?? "") == .orderedSame || $0.addresses.contains { raw.lowercased().contains($0.lowercased()) } }
        row["mailbox"] = box; row["account"] = owner?.name ?? url.host ?? ""
        guard mailbox == nil || mailbox == box, account == nil || account == row["account"] as? String else { return nil }
        return row
    }
    rows = Array(rows.prefix(max(0,limit)))
    if withContent {
        for index in rows.indices {
            guard let messageID = rows[index]["message_id"] as? String else { rows[index]["content"] = NSNull(); continue }
            let raw = try mailScript("""
            const Mail=Application('Mail');
            for (const a of Mail.accounts()) for (const b of a.mailboxes()) {
              const ms=b.messages.whose({messageId:'\(jxaEscape(messageID))'})();
              if(ms.length) return {content:ms[0].content()};
            }
            return {content:null};
            """, wait: timeout)
            let content = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String:Any]
            rows[index]["content"] = content?["content"] ?? NSNull()
        }
    }
    return rows
}



func createMail(to: String, subject: String, body: String, cc: String?, from: String,
                sender: MailSenderAccount, send: Bool, open: Bool, wait: Double) throws -> [String:Any] {
    let started = Date()
    let baseline = send ? try sentMailIDs(from:from,subject:subject,started:started,account:sender) : Set<Int>()
    let raw = try mailScript("""
    const Mail=Application('Mail');
    const account=Mail.accounts.byId('\(jxaEscape(sender.id))');
    if(!account.emailAddresses().some(a=>a.toLowerCase()==='\(jxaEscape(from.lowercased()))')) throw Error('Sender address changed; refusing');
    const msg=Mail.OutgoingMessage({subject:'\(jxaEscape(subject))',content:'\(jxaEscape(body))',sender:'\(jxaEscape(from))',visible:\(open)});
    Mail.outgoingMessages.push(msg);
    msg.sender='\(jxaEscape(from))';
    if(msg.sender().replace(/^.*<([^<>]+)>$/, '$1').trim().toLowerCase()!=='\(jxaEscape(from.lowercased()))') throw Error('Mail refused the requested sender');
    msg.toRecipients.push(Mail.Recipient({address:'\(jxaEscape(to))'}));
    \(cc.map { "msg.ccRecipients.push(Mail.CcRecipient({address:'\(jxaEscape($0))'}));" } ?? "")
    const id=msg.id();
    const actualSender=msg.sender();
    \(send ? "if(!msg.send()) throw Error('Mail refused to send');" : "")
    \(open ? "Mail.activate();" : "")
    return {id:id,from:actualSender};
    """, wait: wait)
    let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String:Any] ?? [:]
    if !send { return ["draft_created":true,"from":result["from"] ?? from,"account":sender.name,"to":to,"subject":subject] }
    return try confirmMailSent(from: from, account: sender, subject: subject, started: started, wait: wait, excluding: baseline)
}

func confirmMailSent(from: String, account: MailSenderAccount, subject: String, started: Date, wait: Double, excluding baseline: Set<Int>) throws -> [String:Any] {
    let deadline = Date().addingTimeInterval(wait)
    let path = try envelopeIndex()
    repeat {
        let rows = try messagingRows(path, MessagingStore.mailQuery(query: subject, limit: 100, after: started.timeIntervalSince1970 - 2, accountIDs:[account.id]))
        if let sent = MessagingStore.sentRecord(rows,from:from,subject:subject,excluding:baseline) {
            return ["sent":true,"from":from,"account":account.name,"mailbox":URL(string:sent["mailbox_url"] as? String ?? "")?.lastPathComponent ?? "Sent"]
        }
        if Date() >= deadline { break }
        Thread.sleep(forTimeInterval: min(0.5, max(0,deadline.timeIntervalSinceNow)))
    } while Date() < deadline
    throw CLIFailure(code:"still_in_outbox",message:"Mail has not confirmed this message left the Outbox.",hint:"Check Mail before retrying; sending again may create a duplicate.",extra:["from":from,"account":account.name,"subject":subject])
}

extension MailCommand {
    struct Addresses: ParsableCommand {
        static let configuration = CommandConfiguration(abstract:"Manage an account's sending addresses", subcommands:[Add.self, Remove.self])
        struct Add: ParsableCommand {
            static let configuration = CommandConfiguration(abstract:"Add an account sending address, idempotently")
            @Argument var account: String
            @Argument var address: String
            @Option(name:.long) var wait: Double = 600
            @Flag(name:.long) var json = false
            func run() throws { try changeMailAddress(account:account,address:address,remove:false,wait:wait,json:json) }
        }
        struct Remove: ParsableCommand {
            static let configuration = CommandConfiguration(abstract:"Remove an account sending address, idempotently")
            @Argument var account: String
            @Argument var address: String
            @Option(name:.long) var wait: Double = 600
            @Flag(name:.long) var json = false
            func run() throws { try changeMailAddress(account:account,address:address,remove:true,wait:wait,json:json) }
        }
    }
}

func changeMailAddress(account: String, address: String, remove: Bool, wait: Double, json: Bool) throws {
    try Auth.check("mail.write")
    guard address.contains("@"), !address.contains(where: { $0.isWhitespace || $0 == "\"" }) else { throw ValidationError("Supply one email address.") }
    let deadline=Date().addingTimeInterval(wait)
    let accounts = try mailAccounts(wait:wait)
    let matches = accounts.filter { $0.id == account || $0.name == account }
    guard matches.count == 1, let selected = matches.first else { throw CLIFailure.notFound("Name exactly one Mail account by name or id.") }
    let raw = try retryBusyMail(wait:max(0.001,deadline.timeIntervalSinceNow)) { remaining in
    try mailScript("""
    const a=Application('Mail').accounts.byId('\(jxaEscape(selected.id))');
    const old=a.emailAddresses();
    const address='\(jxaEscape(address))';
    const exists=old.some(v=>v.toLowerCase()===address.toLowerCase());
    if(\(remove) ? exists : !exists) a.emailAddresses=\(remove) ? old.filter(v=>v.toLowerCase()!==address.toLowerCase()) : old.concat([address]);
    const actual=a.emailAddresses();
    if(actual.some(v=>v.toLowerCase()===address.toLowerCase())===\(remove)) throw Error('Mail did not retain the address change');
    return {account:a.name(),id:a.id(),addresses:actual,changed:\(remove) ? exists : !exists};
    """, wait:min(remaining,max(0.001,deadline.timeIntervalSinceNow)))
    }
    let result = try JSONSerialization.jsonObject(with:Data(raw.utf8))
    if json { printJSON(result) } else { print(raw) }
}

func sentMailIDs(from: String, subject: String, started: Date, account: MailSenderAccount) throws -> Set<Int> {
    let rows = try messagingRows(envelopeIndex(), MessagingStore.mailQuery(query:subject,limit:100,after:started.timeIntervalSince1970 - 2,accountIDs:[account.id]))
    return Set(rows.compactMap { $0["id"] as? Int })
}
