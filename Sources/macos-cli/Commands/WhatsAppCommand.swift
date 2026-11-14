import ArgumentParser
import Foundation
import MacCLICore
import AppKit
import ApplicationServices

struct WhatsAppCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName:"whatsapp", abstract:"WhatsApp chats and messages", subcommands:[Chats.self, Read.self, Search.self, Send.self, Doctor.self])
    static var database: String { userHome().appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite").path }
    static func rows(_ sql: String) throws -> [[String:Any]] {
        try Auth.check("whatsapp.read")
        return try messagingRows(database,sql,copyIfLocked:true)
    }
    static func output(_ rows: [[String:Any]], json: Bool) {
        if json { printJSON(rows) } else {
            for row in rows { print(["id","name","chat","date","text"].compactMap { row[$0].map { String(describing:$0) } }.joined(separator:"  ")) }
        }
    }
    static func chat(_ value: String) throws -> [String:Any] {
        let sql = "SELECT Z_PK AS id,ZCONTACTJID AS jid,COALESCE(ZPARTNERNAME,'') AS name FROM ZWACHATSESSION WHERE CAST(Z_PK AS TEXT)=\(MessagingStore.literal(value)) OR ZCONTACTJID=\(MessagingStore.literal(value)) OR ZPARTNERNAME=\(MessagingStore.literal(value)) LIMIT 2"
        let found = try rows(sql)
        guard found.count == 1 else {
            if found.isEmpty { throw CLIFailure.notFound("No WhatsApp chat matches '\(value)'.") }
            throw ValidationError("More than one chat has that name; use its id or JID.")
        }
        return found[0]
    }
    struct Chats: ParsableCommand {
        static let configuration = CommandConfiguration(abstract:"List recent WhatsApp chats")
        @Option(name:.long) var limit: Int = 20
        @Flag(name:.long) var json = false
        func run() throws { WhatsAppCommand.output(try WhatsAppCommand.rows(MessagingStore.whatsappChats(limit:limit)),json:json) }
    }
    struct Read: ParsableCommand {
        static let configuration = CommandConfiguration(abstract:"Read one WhatsApp chat by id, name or JID")
        @Argument var chat: String
        @Option(name:.long) var limit: Int = 20
        @Option(name:.long,help:"ISO 8601 timestamp") var since: String?
        @Flag(name:.long) var json = false
        func run() throws {
            var date: Date?
            if let since = since {
                guard let parsed=ISO8601DateFormatter().date(from:since) else { throw ValidationError("--since must be an ISO 8601 timestamp.") }
                date=parsed
            }
            let selected=try WhatsAppCommand.chat(chat)
            guard let id=selected["id"] as? Int else { throw CLIFailure.appError("Invalid WhatsApp chat id.") }
            WhatsAppCommand.output(try WhatsAppCommand.rows(MessagingStore.whatsappMessages(chatID:id,since:date,limit:limit)),json:json)
        }
    }
    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(abstract:"Search WhatsApp message text")
        @Argument var text: String
        @Option(name:.long) var limit: Int = 20
        @Flag(name:.long) var json = false
        func run() throws { WhatsAppCommand.output(try WhatsAppCommand.rows(MessagingStore.whatsappMessages(text:text,limit:limit)),json:json) }
    }
    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(abstract:"Check WhatsApp read and send permissions")
        @Flag(name:.long) var json = false
        func run() throws {
            let readable=(try? messagingRows(WhatsAppCommand.database,"SELECT Z_PK FROM ZWACHATSESSION LIMIT 1")) != nil
            let result: [String:Any] = ["installed":NSWorkspace.shared.urlForApplication(withBundleIdentifier:"net.whatsapp.WhatsApp") != nil,
                "reader_ready":readable,"accessibility":AXIsProcessTrusted(),
                "send_allowed":Auth.load()["whatsapp.send"] ?? false,
                "reader_hint":"Grant Full Disk Access to the terminal running macos.",
                "send_hint":"Grant Accessibility to the terminal; a person must enable whatsapp.send with macos auth grant whatsapp.send."]
            if json { printJSON(result) } else { for key in result.keys.sorted() { print("\(key): \(result[key]!)") } }
        }
    }
    struct Send: ParsableCommand {
        static let configuration = CommandConfiguration(abstract:"Send to an individual WhatsApp chat or phone number")
        @Argument(help:"Chat id, exact name, JID, or international phone number") var chat: String
        @Option(name:.long) var text: String?
        @Option(name:.long) var textFile: String?
        @Flag(name:.long) var json = false
        func validate() throws {
            guard (text == nil) != (textFile == nil) else { throw ValidationError("Use --text or --text-file, exactly one.") }
        }
        func run() throws {
            try Auth.check("whatsapp.send")
            guard AXIsProcessTrusted() else { throw CLIFailure.permission("WhatsApp send needs Accessibility.",hint:"Run macos whatsapp doctor.") }
            let body=try messageBody(text ?? "",file:textFile)
            guard !body.isEmpty else { throw ValidationError("Message text is empty.") }
            let number: String
            let recipient: String
            if chat.hasPrefix("+"), chat.dropFirst().allSatisfy({ $0.isNumber }), chat.count > 7 {
                number=String(chat.dropFirst());recipient=number
            } else {
                let selected=try WhatsAppCommand.chat(chat)
                guard let jid=selected["jid"] as? String, jid.hasSuffix("@s.whatsapp.net") else {
                    throw ValidationError("URL sending supports individual phone chats only; group sending is unavailable.")
                }
                number=String(jid.split(separator:"@")[0]);recipient=selected["name"] as? String ?? number
            }
            var components=URLComponents()
            components.scheme="whatsapp";components.host="send"
            components.queryItems=[URLQueryItem(name:"phone",value:number),URLQueryItem(name:"text",value:body)]
            guard let url=components.url, NSWorkspace.shared.open(url) else { throw CLIFailure.appError("WhatsApp could not open its send URL.") }
            // AX actions never move the pointer or synthesize keyboard input. Require
            // a matching composer and exactly one Send button; fail closed otherwise.
            let deadline=Date().addingTimeInterval(15)
            repeat {
                if try pressWhatsAppSend(expectedText:body,expectedRecipient:recipient) {
                    if json { printJSON(["send_requested":true,"chat":chat]) } else { print("WhatsApp send requested: \(chat)") }
                    return
                }
                RunLoop.current.run(until:Date().addingTimeInterval(0.1))
            } while Date()<deadline
            throw CLIFailure.timeout("WhatsApp did not expose a matching composer and Send button; nothing was clicked.",hint:"Open the conversation in WhatsApp and check Accessibility permission.")
        }
    }
}

private func pressWhatsAppSend(expectedText: String, expectedRecipient: String) throws -> Bool {
    guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:"net.whatsapp.WhatsApp").first else { return false }
    let root=AXUIElementCreateApplication(app.processIdentifier)
    func value(_ element: AXUIElement,_ key: CFString) -> AnyObject? {
        var output: CFTypeRef?
        return AXUIElementCopyAttributeValue(element,key,&output) == .success ? output : nil
    }
    var queue: [(AXUIElement, Bool)] = [(root,false)]
    var buttons=[AXUIElement](), composer=false, recipient=false, visited=0
    while !queue.isEmpty && visited<3000 {
        let (element,inToolbar)=queue.removeFirst();visited+=1
        let role=value(element,kAXRoleAttribute as CFString) as? String ?? ""
        let title=value(element,kAXTitleAttribute as CFString) as? String ?? ""
        let description=value(element,kAXDescriptionAttribute as CFString) as? String ?? ""
        if role=="AXHeading" || (inToolbar && role=="AXStaticText") {
            let strings=[title,description,value(element,kAXValueAttribute as CFString) as? String ?? ""]
            recipient = recipient || strings.contains { $0 == expectedRecipient || (!$0.isEmpty && $0.filter(\.isNumber) == expectedRecipient && expectedRecipient.allSatisfy(\.isNumber)) }
        }
        if ["AXTextArea","AXTextField"].contains(role), value(element,kAXValueAttribute as CFString) as? String == expectedText { composer=true }
        if role=="AXButton", [title,description].contains(where:{$0.lowercased()=="send"}), value(element,kAXEnabledAttribute as CFString) as? Bool == true { buttons.append(element) }
        queue.append(contentsOf:(value(element,kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []).map { ($0,inToolbar || role=="AXToolbar") })
    }
    guard composer,recipient,buttons.count==1 else { return false }
    guard AXUIElementPerformAction(buttons[0],kAXPressAction as CFString) == .success else { throw CLIFailure.appError("WhatsApp Send button refused the action.") }
    return true
}
