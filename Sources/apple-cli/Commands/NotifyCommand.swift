import ArgumentParser
import Foundation

struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Send a macOS system notification",
        subcommands: [SendCmd.self]
    )

    struct SendCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "send", abstract: "Send a notification")

        @Option(name: .long, help: "Notification title") var title: String
        @Option(name: .long, help: "Notification body") var body: String = ""
        @Option(name: .long, help: "Subtitle") var subtitle: String?
        @Option(name: .long, help: "Sound name (default, Hero, Ping, Purr, Sosumi, etc.)") var sound: String = "default"
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            // Use osascript — most reliable for CLI notifications
            var script = "display notification \"\(body.escaped)\""
            script += " with title \"\(title.escaped)\""
            if let sub = subtitle { script += " subtitle \"\(sub.escaped)\"" }
            if sound != "none" { script += " sound name \"\(sound.escaped)\"" }

            let result = Process.run(args: ["/usr/bin/osascript", "-e", script])
            if result != 0 {
                throw ValidationError("Notification failed — check Notifications permission in System Preferences")
            }
            if json {
                var out: [String: Any] = ["sent": true, "title": title, "body": body]
                if let sub = subtitle { out["subtitle"] = sub }
                printJSON(out)
            } else {
                print("Notification sent: \(title)")
            }
        }
    }
}

private extension String {
    var escaped: String { replacingOccurrences(of: "\"", with: "\\\"") }
}
