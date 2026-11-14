import Foundation
import XCTest
@testable import MacCLICore

final class MessagingTests: XCTestCase {
    func testSenderNeverFallsBack() throws {
        let accounts=[MailSenderAccount(id:"a",name:"Work",addresses:["alex@example.com","alias@example.com"]),MailSenderAccount(id:"b",name:"Personal",addresses:["home@example.com"])]
        XCTAssertEqual(try MessagingStore.sender("ALIAS@example.com",accounts:accounts).id,"a")
        XCTAssertThrowsError(try MessagingStore.sender("nobody@example.com",accounts:accounts)) { error in
            guard case SenderSelectionError.notFound = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertThrowsError(try MessagingStore.sender("alex@example.com",accounts:accounts + [accounts[0]]))
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode:"sender_not_found"),3)
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode:"mail_busy"),5)
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode:"still_in_outbox"),5)
    }

    func testSentConfirmationNeedsNewMatchingSentRecord() {
        let sent: [String:Any] = ["id":2,"subject":"Review","from":"alex@example.com","mailbox_url":"imap://account/Sent%20Messages"]
        XCTAssertNil(MessagingStore.sentRecord([],from:"alex@example.com",subject:"Review",excluding:[]))
        XCTAssertNil(MessagingStore.sentRecord([sent],from:"alex@example.com",subject:"Review",excluding:[2]))
        XCTAssertNil(MessagingStore.sentRecord([sent],from:"home@example.com",subject:"Review",excluding:[]))
        var outbox=sent;outbox["id"]=3;outbox["mailbox_url"]="local://account/Outbox"
        XCTAssertNil(MessagingStore.sentRecord([sent,outbox],from:"alex@example.com",subject:"Review",excluding:[]))
        XCTAssertNotNil(MessagingStore.sentRecord([sent],from:"alex@example.com",subject:"Review",excluding:[]))
    }

    func sqlite(_ path: String,_ sql: String) throws -> [[String:Any]] {
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/sqlite3")
        process.arguments=["-json",path,sql]
        let pipe=Pipe();process.standardOutput=pipe
        try process.run()
        let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0)
        if data.isEmpty { return [] }
        return try JSONSerialization.jsonObject(with:data) as? [[String:Any]] ?? []
    }

    func testEnvelopeQueryUsesMetadataAndEscapesPatterns() throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath:path) }
        _ = try sqlite(path,"""
        CREATE TABLE messages (subject INTEGER,sender INTEGER,mailbox INTEGER,global_message_id INTEGER,deleted INTEGER,date_sent INTEGER);
        CREATE TABLE subjects (subject TEXT);
        CREATE TABLE addresses (address TEXT,comment TEXT);
        CREATE TABLE recipients (message INTEGER,address INTEGER);
        CREATE TABLE mailboxes (url TEXT);
        CREATE TABLE message_global_data (message_id_header TEXT);
        INSERT INTO subjects VALUES ('100%_ ready'),('unrelated');
        INSERT INTO addresses VALUES ('alex@example.com','Alex'),('reader@example.com','Reader');
        INSERT INTO mailboxes VALUES ('imap://account/INBOX');
        INSERT INTO message_global_data VALUES ('message@example.com');
        INSERT INTO messages VALUES (1,1,1,1,0,1700000000),(2,1,1,1,0,1700000001);
        INSERT INTO recipients VALUES (1,2);
        """)
        let rows=try sqlite(path,MessagingStore.mailQuery(query:"100%_"))
        XCTAssertEqual(rows.count,1)
        XCTAssertEqual(rows.first?["message_id"] as? String,"message@example.com")
        XCTAssertEqual(try sqlite(path,MessagingStore.mailQuery(query:"reader@example.com")).count,1)
        XCTAssertTrue(try sqlite(path,MessagingStore.mailQuery(query:"' OR 1=1 --")).isEmpty)
        XCTAssertEqual(try sqlite(path,MessagingStore.mailQuery(query:nil,messageID:"<message@example.com>",limit:1)).count,1)
    }

    func testWhatsAppSyntheticRowsAndSince() throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath:path) }
        _ = try sqlite(path,"""
        CREATE TABLE ZWACHATSESSION (Z_PK INTEGER,ZCONTACTJID TEXT,ZPARTNERNAME TEXT,ZUNREADCOUNT INTEGER,ZLASTMESSAGEDATE REAL);
        CREATE TABLE ZWAMESSAGE (Z_PK INTEGER,ZCHATSESSION INTEGER,ZFROMJID TEXT,ZISFROMME INTEGER,ZTEXT TEXT,ZMESSAGEDATE REAL);
        INSERT INTO ZWACHATSESSION VALUES (1,'15555550100@s.whatsapp.net','Alex',2,100);
        INSERT INTO ZWAMESSAGE VALUES (1,1,'15555550100@s.whatsapp.net',0,'Hello 100%',100),(2,1,NULL,1,NULL,50);
        """)
        let chats=try sqlite(path,MessagingStore.whatsappChats(limit:3))
        XCTAssertEqual(chats.first?["name"] as? String,"Alex")
        let rows=try sqlite(path,MessagingStore.whatsappMessages(chatID:1,text:"100%",since:Date(timeIntervalSinceReferenceDate:75),limit:20))
        XCTAssertEqual(rows.count,1)
        XCTAssertEqual(rows.first?["date"] as? String,"2001-01-01T00:01:40Z")
        XCTAssertEqual(rows.first?["from_me"] as? Int,0)
        XCTAssertEqual(try sqlite(path,MessagingStore.whatsappMessages(chatID:1,limit:20)).last?["text"] as? String,"")
        XCTAssertTrue(try sqlite(path,MessagingStore.whatsappMessages(text:"' OR 1=1 --",limit:20)).isEmpty)
    }
}
