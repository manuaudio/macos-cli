// Sources/macos-cli/Auth.swift
import Foundation
import ArgumentParser

struct Auth {
    private static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/macos-cli/auth.json")

    // Call at top of any destructive run(). Throws ValidationError if denied.
    static func check(_ capability: String) throws {
        let caps = load()
        // Use defaultCapabilities as the fallback when no config file exists
        let allowed = caps[capability] ?? defaultCapabilities[capability] ?? !isWriteCapability(capability)
        if !allowed {
            if caps.isEmpty {
                throw ValidationError(
                    "'\(capability)' is denied by default. Run `macos auth setup` to configure permissions, " +
                    "or `macos auth grant \(capability)` to enable this capability."
                )
            } else {
                throw ValidationError(
                    "'\(capability)' is denied. Run `macos auth grant \(capability)` to enable it."
                )
            }
        }
    }

    static func load() -> [String: Bool] {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let caps = json["capabilities"] as? [String: Bool]
        else { return [:] }
        return caps
    }

    static func save(_ capabilities: [String: Bool]) throws {
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = ["version": 1, "capabilities": capabilities]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
    }

    // Conservative default: anything with a "write" suffix or known destructive verb is a write capability
    static func isWriteCapability(_ capability: String) -> Bool {
        let writeSuffixes = ["write", "send", "delete", "set", "run", "click", "shutdown", "reboot"]
        return writeSuffixes.contains { capability.hasSuffix($0) }
    }

    static let allCapabilities: [(id: String, defaultAllow: Bool, description: String)] = [
        ("calendar.read",      true,  "Read calendar events"),
        ("calendar.write",     true,  "Create and modify calendar events"),
        ("calendar.delete",    false, "Delete calendar events"),
        ("mail.read",          true,  "Read emails"),
        ("mail.send",          false, "Send emails"),
        ("mail.delete",        false, "Delete emails"),
        ("contacts.read",      true,  "Read contacts"),
        ("contacts.write",     false, "Create and modify contacts"),
        ("contacts.delete",    false, "Delete contacts"),
        ("keychain.get",       false, "Read keychain entries"),
        ("keychain.set",       false, "Write keychain entries"),
        ("keychain.delete",    false, "Delete keychain entries"),
        ("reminders.read",     true,  "Read reminders"),
        ("reminders.write",    true,  "Create and modify reminders"),
        ("reminders.delete",   false, "Delete reminders"),
        ("notes.read",         true,  "Read notes"),
        ("notes.write",        false, "Create and modify notes"),
        ("notes.delete",       false, "Delete notes"),
        ("screen.capture",     true,  "Take screenshots"),
        ("screen.lock",        true,  "Lock the screen"),
        ("spaces.read",        true,  "List spaces"),
        ("spaces.write",       false, "Switch and manage spaces"),
        ("audio.read",         true,  "List audio devices"),
        ("audio.write",        false, "Change audio input/output"),
        ("script.run",         false, "Run arbitrary JXA or AppleScript"),
        ("menu.read",          true,  "List menu bar items"),
        ("menu.click",         false, "Click menu bar items"),
        ("timemachine.read",   true,  "Read Time Machine status"),
        ("timemachine.write",  false, "Start or stop Time Machine backups"),
        ("system.shutdown",    false, "Shut down the Mac"),
        ("system.reboot",      false, "Restart the Mac"),
    ]

    static var defaultCapabilities: [String: Bool] {
        Dictionary(uniqueKeysWithValues: allCapabilities.map { ($0.id, $0.defaultAllow) })
    }
}
