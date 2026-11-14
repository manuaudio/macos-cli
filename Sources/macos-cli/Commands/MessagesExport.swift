import ArgumentParser
import Foundation
import MacCLICore
import SQLite3

// `messages export` and `messages latest` read chat.db directly, read-only (SQLite's
// `mode=ro`), the way ingest jobs did with their own SQL. Needs Full Disk Access and the
// messages.read capability.

/// A read-only connection to chat.db.
final class MessagesDB {
    private var db: OpaquePointer?

    init() throws {
        let path = try DiskAccess.readableMessagesStore()
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            sqlite3_close(db)
            throw CLIFailure.appError("Could not open the Messages database: \(message)")
        }
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit { sqlite3_close(db) }

    /// Runs `sql` with integer bindings, calling `row` for each result row.
    func query(_ sql: String, _ bindings: [Int64] = [], row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CLIFailure.appError("Messages database query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bindings.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), value) }
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW { row(stmt!) } else if step == SQLITE_DONE { return } else {
                throw CLIFailure.appError("Messages database read failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    static func bytes(_ stmt: OpaquePointer, _ column: Int32) -> [UInt8]? {
        guard let p = sqlite3_column_blob(stmt, column) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, column))
        return Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: n))
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

extension MessagesCommand {

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Export messages newer than a rowid as JSON for ingestion (read-only)",
            discussion: """
            Every message row after --since-rowid, oldest first: its rowid, guid, date, \\
            handle, service, text (from attributedBody when the text column is empty), \\
            is_from_me, the chat and its handles, attachments, and the reaction and item \\
            types so a caller can leave tapbacks and system rows out. last_rowid is the \\
            next --since-rowid.
            """
        )

        @Option(name: .long, help: "Only messages with a rowid above this (default: 0, every message)")
        var sinceRowid: Int64 = 0

        @Option(name: .long, help: "Max messages to export (default: all)")
        var limit: Int?

        @Flag(name: .long, help: "Accepted for consistency; export always prints JSON")
        var json = false

        func run() throws {
            try Auth.check("messages.read")
            let db = try MessagesDB()
            var messages: [[String: Any]] = []
            var index: [Int64: Int] = [:]
            let sql = """
                SELECT m.ROWID, m.guid, m.date, h.id, m.service, m.text, m.attributedBody, m.is_from_me,
                       m.associated_message_type, m.item_type, c.guid,
                       (SELECT group_concat(h2.id, char(31)) FROM chat_handle_join chj
                          JOIN handle h2 ON h2.ROWID = chj.handle_id WHERE chj.chat_id = c.ROWID),
                       a.filename, a.mime_type, a.transfer_name
                  FROM (SELECT * FROM message WHERE ROWID > ?1 ORDER BY ROWID LIMIT ?2) m
                  LEFT JOIN handle h ON m.handle_id = h.ROWID
                  LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                  LEFT JOIN chat c ON c.ROWID = cmj.chat_id
                  LEFT JOIN message_attachment_join maj ON maj.message_id = m.ROWID
                  LEFT JOIN attachment a ON a.ROWID = maj.attachment_id
                 ORDER BY m.ROWID
                """
            let cap = limit.map { Int64($0) } ?? -1
            try db.query(sql, [sinceRowid, cap]) { s in
                let rowid = sqlite3_column_int64(s, 0)
                if index[rowid] == nil {
                    var text = MessagesDB.text(s, 5) ?? ""
                    if text.isEmpty, let blob = MessagesDB.bytes(s, 6) {
                        text = MacCLICore.attributedBodyText(blob) ?? ""
                    }
                    let chatHandles = MessagesDB.text(s, 11)?.split(separator: "\u{1F}").map(String.init) ?? []
                    index[rowid] = messages.count
                    messages.append([
                        "rowid": rowid,
                        "guid": MessagesDB.text(s, 1) ?? "",
                        "date": isoFormatter.string(from: MacCLICore.messagesDate(sqlite3_column_int64(s, 2))),
                        "handle": MessagesDB.text(s, 3) as Any? ?? NSNull(),
                        "service": MessagesDB.text(s, 4) ?? "",
                        "text": text,
                        "is_from_me": sqlite3_column_int64(s, 7) != 0,
                        "associated_message_type": sqlite3_column_int64(s, 8),
                        "item_type": sqlite3_column_int64(s, 9),
                        "chat_guid": MessagesDB.text(s, 10) as Any? ?? NSNull(),
                        "chat_handles": chatHandles,
                        "attachments": [[String: Any]](),
                    ])
                }
                if let filename = MessagesDB.text(s, 12), let i = index[rowid] {
                    var attachments = messages[i]["attachments"] as? [[String: Any]] ?? []
                    attachments.append([
                        "path": (filename as NSString).expandingTildeInPath(relativeTo: userHome().path),
                        "mime_type": MessagesDB.text(s, 13) as Any? ?? NSNull(),
                        "name": MessagesDB.text(s, 14) as Any? ?? NSNull(),
                    ])
                    messages[i]["attachments"] = attachments
                }
            }
            let last = messages.last?["rowid"] as? Int64 ?? sinceRowid
            printJSON([
                "messages": messages,
                "count": messages.count,
                "since_rowid": sinceRowid,
                "last_rowid": last,
                "truncated": limit.map { messages.count >= $0 } ?? false,
            ])
        }
    }

    struct Latest: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "The newest message's time and rowid per service (iMessage, SMS, RCS…), read-only")

        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("messages.read")
            let db = try MessagesDB()
            var rows: [[String: Any]] = []
            let sql = """
                SELECT coalesce(service, ''), max(date), max(ROWID) FROM message GROUP BY 1 ORDER BY 2 DESC
                """
            try db.query(sql) { s in
                rows.append([
                    "service": MessagesDB.text(s, 0) ?? "",
                    "latest": isoFormatter.string(from: MacCLICore.messagesDate(sqlite3_column_int64(s, 1))),
                    "rowid": sqlite3_column_int64(s, 2),
                ])
            }
            if json {
                printJSON(rows)
            } else {
                for r in rows { print("\(r["service"] ?? "")\t\(r["latest"] ?? "")") }
            }
        }
    }
}

private extension NSString {
    /// chat.db stores attachment paths as `~/Library/Messages/Attachments/…`.
    func expandingTildeInPath(relativeTo home: String) -> String {
        hasPrefix("~/") ? home + substring(from: 1) : self as String
    }
}
