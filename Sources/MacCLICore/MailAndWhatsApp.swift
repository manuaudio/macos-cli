import Foundation

public struct MailSenderAccount: Codable, Equatable {
    public let id: String
    public let name: String
    public let addresses: [String]
    public init(id: String, name: String, addresses: [String]) {
        self.id = id; self.name = name; self.addresses = addresses
    }
}

public enum SenderSelectionError: Error { case notFound, ambiguous }

public enum MessagingStore {
    public static func sender(_ address: String, accounts: [MailSenderAccount]) throws -> MailSenderAccount {
        let matches = accounts.filter { $0.addresses.contains { $0.caseInsensitiveCompare(address) == .orderedSame } }
        guard !matches.isEmpty else { throw SenderSelectionError.notFound }
        guard matches.count == 1 else { throw SenderSelectionError.ambiguous }
        return matches[0]
    }

    public static func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    public static func contains(_ value: String) -> String {
        literal("%" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%") + " ESCAPE '\\'"
    }

    public static func mailQuery(query: String?, messageID: String? = nil, mailbox: String? = nil,
                                 limit: Int = 10, after: Double? = nil, accountIDs: [String]? = nil) -> String {
        var filters = ["m.deleted = 0"]
        if let query = query {
            let pattern = contains(query)
            filters.append("(s.subject LIKE \(pattern) OR a.address LIKE \(pattern) OR a.comment LIKE \(pattern) OR EXISTS (SELECT 1 FROM recipients r JOIN addresses ra ON ra.ROWID=r.address WHERE r.message=m.ROWID AND ra.address LIKE \(pattern)))")
        }
        if let messageID = messageID { filters.append("trim(h.message_id_header,'<> ') = \(literal(messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))))") }
        if let mailbox = mailbox {
            let encoded = mailbox.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? mailbox
            filters.append("b.url LIKE " + literal("%/" + encoded.replacingOccurrences(of:"%",with:"\\%")) + " ESCAPE '\\'")
        }
        if let accountIDs = accountIDs {
            filters.append("(" + accountIDs.map { "instr(lower(b.url)," + literal("://" + $0.lowercased() + "/") + ")>0" }.joined(separator:" OR ") + ")")
        }
        if let after = after { filters.append("m.date_sent >= \(Int(after))") }
        return """
        SELECT m.ROWID AS id, h.message_id_header AS message_id, COALESCE(s.subject,'') AS subject,
        COALESCE(a.address,'') AS 'from', COALESCE(a.comment,'') AS sender_name,
        strftime('%Y-%m-%d',m.date_sent,'unixepoch') AS date,
        strftime('%Y-%m-%dT%H:%M:%SZ',m.date_sent,'unixepoch') AS date_sent,
        b.url AS mailbox_url FROM messages m
        JOIN subjects s ON s.ROWID=m.subject LEFT JOIN addresses a ON a.ROWID=m.sender
        JOIN mailboxes b ON b.ROWID=m.mailbox LEFT JOIN message_global_data h ON h.ROWID=m.global_message_id
        WHERE \(filters.joined(separator: " AND ")) ORDER BY m.date_sent DESC, m.ROWID DESC LIMIT \(max(0, limit))
        """
    }

    /// Positive filing evidence is required; an empty or stale index is inconclusive.
    public static func sentRecord(_ rows: [[String:Any]], from: String, subject: String, excluding baseline: Set<Int>) -> [String:Any]? {
        let matches = rows.filter {
            !baseline.contains($0["id"] as? Int ?? -1) && $0["subject"] as? String == subject &&
            ($0["from"] as? String)?.caseInsensitiveCompare(from) == .orderedSame
        }
        if matches.contains(where: { URL(string:$0["mailbox_url"] as? String ?? "")?.lastPathComponent.lowercased() == "outbox" }) { return nil }
        return matches.first {
            ["sent","sent messages","sent items"].contains(URL(string:$0["mailbox_url"] as? String ?? "")?.lastPathComponent.lowercased() ?? "")
        }
    }

    public static func whatsappChats(limit: Int) -> String {
        "SELECT Z_PK AS id, ZCONTACTJID AS jid, COALESCE(ZPARTNERNAME,'') AS name, ZUNREADCOUNT AS unread, strftime('%Y-%m-%dT%H:%M:%SZ',ZLASTMESSAGEDATE+978307200,'unixepoch') AS date FROM ZWACHATSESSION ORDER BY ZLASTMESSAGEDATE DESC LIMIT \(max(0,limit))"
    }

    public static func whatsappMessages(chatID: Int? = nil, text: String? = nil, since: Date? = nil, limit: Int) -> String {
        var filters = ["1=1"]
        if let chatID = chatID { filters.append("m.ZCHATSESSION=\(chatID)") }
        if let text = text { filters.append("m.ZTEXT LIKE \(contains(text))") }
        if let since = since { filters.append("m.ZMESSAGEDATE >= \(since.timeIntervalSinceReferenceDate)") }
        return """
        SELECT m.Z_PK AS id, m.ZCHATSESSION AS chat_id, c.ZCONTACTJID AS jid,
        COALESCE(c.ZPARTNERNAME,'') AS chat, COALESCE(m.ZFROMJID,'') AS 'from',
        m.ZISFROMME AS from_me, COALESCE(m.ZTEXT,'') AS text,
        strftime('%Y-%m-%dT%H:%M:%SZ',m.ZMESSAGEDATE+978307200,'unixepoch') AS date
        FROM ZWAMESSAGE m LEFT JOIN ZWACHATSESSION c ON c.Z_PK=m.ZCHATSESSION
        WHERE \(filters.joined(separator: " AND ")) ORDER BY m.ZMESSAGEDATE DESC, m.Z_PK DESC LIMIT \(max(0,limit))
        """
    }
}
