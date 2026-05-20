// Sources/macos-cli/Auth.swift
import Foundation
import ArgumentParser

struct Auth {
    private static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/macos-cli/auth.json")

    // Call at top of any destructive run(). Throws ValidationError if denied.
    //
    // Capability resolution order (H6 — partial-config safety):
    //   1. caps[capability]                — explicit user choice from auth.json
    //   2. defaultCapabilities[capability] — code-declared default for known capabilities
    //   3. !isWriteCapability(capability)  — heuristic fallback for truly unknown caps
    //
    // Step 2 is the load-bearing one for upgrades: when a user has an old auth.json that
    // pre-dates a new capability, we must fall through to the *declared* default — never
    // to the heuristic, because the heuristic doesn't know that e.g. `keychain.list`
    // should be denied by default. New capabilities MUST be added to allCapabilities so
    // step 2 has a value to return.
    static func check(_ capability: String) throws {
        let caps = load()
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
        // Calendar
        ("calendar.read",      true,  "Read calendar events"),
        ("calendar.write",     true,  "Create and modify calendar events"),
        ("calendar.delete",    false, "Delete calendar events"),
        // Mail
        ("mail.read",          true,  "Read emails"),
        ("mail.send",          false, "Send emails"),
        ("mail.delete",        false, "Delete emails"),
        // Contacts
        ("contacts.read",      true,  "Read contacts"),
        ("contacts.write",     false, "Create and modify contacts"),
        ("contacts.delete",    false, "Delete contacts"),
        // Keychain
        ("keychain.get",       false, "Read keychain entries"),
        ("keychain.set",       false, "Write keychain entries"),
        ("keychain.delete",    false, "Delete keychain entries"),
        ("keychain.list",      false, "List keychain service/account metadata"),
        // Reminders
        ("reminders.read",     true,  "Read reminders"),
        ("reminders.write",    true,  "Create and modify reminders"),
        ("reminders.delete",   false, "Delete reminders"),
        // Notes
        ("notes.read",         true,  "Read notes"),
        ("notes.write",        false, "Create and modify notes"),
        ("notes.delete",       false, "Delete notes"),
        // Screen / screenshots
        ("screen.capture",     true,  "Take screenshots"),
        ("screen.lock",        true,  "Lock the screen"),
        // Spaces / Mission Control
        ("spaces.read",        true,  "List spaces"),
        ("spaces.write",       false, "Switch and manage spaces"),
        // Audio
        ("audio.read",         true,  "List audio devices"),
        ("audio.write",        false, "Change audio input/output or volume/mute"),
        // Script (JXA / AppleScript passthrough)
        ("script.run",         false, "Run arbitrary JXA or AppleScript"),
        // Menu bar
        ("menu.read",          true,  "List menu bar items"),
        ("menu.click",         false, "Click menu bar items"),
        // Time Machine
        ("timemachine.read",   true,  "Read Time Machine status"),
        ("timemachine.write",  false, "Start or stop Time Machine backups"),
        // System power / lock
        ("system.lock",        true,  "Lock the Mac immediately"),
        ("system.sleep",       false, "Put the Mac to sleep"),
        // Messages
        ("messages.send",      false, "Send iMessages"),
        ("messages.delete",    false, "Delete iMessage conversations"),
        // Mouse / Keyboard
        ("mouse.write",        false, "Synthesize mouse events"),
        ("keyboard.write",     false, "Synthesize keyboard events"),
        // Accessibility tree writes
        ("ax.write",           false, "Click or set values on Accessibility elements"),
        // File system
        ("file.read",          true,  "List, stat, and read files"),
        ("file.write",         false, "Copy, move, create files"),
        ("file.delete",        false, "Delete files permanently"),
        // Trash
        ("trash.empty",        false, "Empty the Trash"),
        // Apps
        ("apps.quit",          false, "Quit running applications"),
        // Defaults
        ("defaults.read",      true,  "Read defaults domains/keys"),
        ("defaults.write",     false, "Write defaults values"),
        ("defaults.delete",    false, "Delete defaults keys"),
        // Dock
        ("dock.write",         false, "Add/remove/restart the Dock"),
        // Login items
        ("login-items.write",  false, "Add or remove login items"),
        // Safari
        ("safari.read",        true,  "List tabs, history, bookmarks"),
        ("safari.execute",     false, "Open URLs, execute JS, close/reload tabs"),
        // Photos
        ("photos.read",        true,  "List/search/export photos"),
        ("photos.write",       false, "Add photos to albums or modify library"),
        ("photos.delete",      false, "Delete photos from the library"),
        // Finder
        ("finder.read",        true,  "Read Finder selection / cwd / hidden state"),
        ("finder.write",       false, "Reveal/open/new folder/rename/tag/go-to/show-hidden"),
        // Bluetooth
        ("bluetooth.read",     true,  "List paired Bluetooth devices"),
        ("bluetooth.write",    false, "Connect or disconnect Bluetooth devices"),
        // Disk
        ("disk.read",          true,  "List disks and read disk info"),
        ("disk.write",         false, "Eject / unmount / mount volumes"),
        // OCR
        ("ocr.capture",        true,  "OCR screen regions or image files"),
        // Process
        ("process.kill",       false, "Send signals to processes"),
        // Window
        ("window.write",       false, "Move/resize/snap/close/minimize/maximize/fullscreen windows"),
        // Music
        ("music.write",        false, "Control Music app playback / queue / volume"),
        // Notify
        ("notify.send",        true,  "Send a user notification"),
        // Speech
        ("speech.speak",       true,  "Speak text aloud"),
        // Shortcuts
        ("shortcuts.run",      false, "Run a Shortcut"),
        // Spotlight
        ("spotlight.search",   true,  "Search files via Spotlight"),
        // Focus
        ("focus.write",        false, "Toggle Focus modes"),
        // PDF
        ("pdf.read",           true,  "Extract text/metadata from PDFs"),
        // Storage
        ("storage.read",       true,  "List volumes / disk usage"),
        // Location
        ("location.read",      false, "Read the Mac's location"),
        // Wi-Fi
        ("wifi.write",         false, "Join or leave Wi-Fi networks"),
        // Display
        ("display.write",      false, "Set brightness, dark mode, wallpaper"),
        // VPN
        ("vpn.write",          false, "Connect to or disconnect VPN"),
        // Network
        ("network.read",       true,  "Ping, DNS, port check, traceroute, interfaces"),
        // Info
        ("info.read",          true,  "Read system, network, power info"),
        // Clipboard
        ("clipboard.write",    true,  "Write to the system clipboard"),
        // Apps (launch)
        ("apps.launch",        true,  "Launch applications"),
    ]

    static var defaultCapabilities: [String: Bool] {
        Dictionary(uniqueKeysWithValues: allCapabilities.map { ($0.id, $0.defaultAllow) })
    }
}
