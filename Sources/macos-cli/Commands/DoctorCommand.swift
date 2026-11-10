import ApplicationServices
import ArgumentParser
import CoreGraphics
import CoreLocation
import EventKit
import Foundation
import MacCLICore

/// The apps macos-cli drives through Apple events, and the commands that need each.
private let automationTargets: [(id: String, bundleID: String, app: String, commands: [String])] = [
    ("mail", "com.apple.mail", "Mail", ["mail"]),
    ("messages", "com.apple.MobileSMS", "Messages", ["messages"]),
    ("notes", "com.apple.Notes", "Notes", ["notes create", "notes update", "notes delete", "notes folders"]),
    ("safari", "com.apple.Safari", "Safari", ["safari tabs", "safari open", "safari read", "safari js"]),
    ("music", "com.apple.Music", "Music", ["music"]),
    ("photos", "com.apple.Photos", "Photos", ["photos"]),
    ("finder", "com.apple.finder", "Finder", ["finder"]),
    ("system_events", "com.apple.systemevents", "System Events", ["menu", "window", "dock", "spaces"]),
]

private let settingsPane = "x-apple.systempreferences:com.apple.preference.security?"

/// Every privacy area, read without showing a single prompt.
private func privacyAreas() -> [MacCLICore.PrivacyArea] {
    var areas: [MacCLICore.PrivacyArea] = [
        .init(id: "calendars", state: PrivacyAccess.state(.event), neededBy: ["calendar"],
              hint: "A person runs `macos authorize calendars`, or turns it on in System Settings › Privacy & Security › Calendars.",
              authorize: "macos authorize calendars"),
        .init(id: "reminders", state: PrivacyAccess.state(.reminder), neededBy: ["reminders"],
              hint: "A person runs `macos authorize reminders`, or turns it on in System Settings › Privacy & Security › Reminders.",
              authorize: "macos authorize reminders"),
        .init(id: "contacts", state: PrivacyAccess.contactsState, neededBy: ["contacts"],
              hint: "A person runs `macos authorize contacts`, or turns it on in System Settings › Privacy & Security › Contacts.",
              authorize: "macos authorize contacts"),
    ]

    let notes = DiskAccess.probe(DiskAccess.notesStore)
    let safari = DiskAccess.probe(userHome().appendingPathComponent("Library/Safari/History.db"))
    let fullDisk = [notes, safari].contains("granted") ? "granted"
        : [notes, safari].contains("denied") ? "denied" : "unknown"
    areas.append(.init(id: "full_disk_access", state: fullDisk,
                       neededBy: ["notes list", "notes search", "notes read", "notes export", "safari history"],
                       hint: "Add the macos binary in System Settings › Privacy & Security › Full Disk Access; macOS has no prompt for it.",
                       authorize: "macos authorize full-disk-access",
                       detail: fullDisk == "unknown" ? "neither the Notes nor the Safari database exists to test" : nil))

    areas.append(.init(id: "accessibility", state: AXIsProcessTrusted() ? "granted" : "denied",
                       neededBy: ["mouse", "keyboard", "ax", "menu", "window"],
                       hint: "A person runs `macos authorize accessibility` and turns the binary on in the pane it opens.",
                       authorize: "macos authorize accessibility"))
    areas.append(.init(id: "screen_recording", state: CGPreflightScreenCaptureAccess() ? "granted" : "denied",
                       neededBy: ["screenshot", "screen capture", "ocr"],
                       hint: "A person runs `macos authorize screen-recording` and turns the binary on in the pane it opens.",
                       authorize: "macos authorize screen-recording"))

    let location = locationState()
    areas.append(.init(id: "location", state: location, neededBy: ["location"],
                       hint: "A person runs `macos authorize location` and clicks Allow.",
                       authorize: "macos authorize location"))

    for target in automationTargets {
        let (state, detail) = AutomationAccess.state(bundleID: target.bundleID)
        areas.append(.init(id: "automation.\(target.id)", state: state, neededBy: target.commands,
                           hint: "With \(target.app) open, a person runs `macos authorize automation.\(target.id)` and clicks OK.",
                           authorize: "macos authorize automation.\(target.id)", detail: detail))
    }
    return areas
}

private func locationState() -> String {
    switch CLLocationManager().authorizationStatus {
    case .notDetermined: return "not_determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorizedAlways: return "granted"
    @unknown default: return "unknown"
    }
}

/// Who macOS sees: the grants above belong to this identity.
private func binaryIdentity() -> [String: Any] {
    let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    let signature = Process.captureWithStderr(args: ["/usr/bin/codesign", "-dv", "--verbose=2", path], timeout: 5)
    // codesign -dv writes its report to stderr.
    let lines = signature.stderr.split(separator: "\n").map(String.init)
    func value(_ key: String) -> String? {
        lines.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }
    let signing: String
    if signature.exitCode != 0 { signing = "unsigned" }
    else if value("Signature") == "adhoc" { signing = "adhoc" }
    else { signing = value("Authority") ?? "signed" }
    return [
        "path": path,
        "bundle_id": Bundle.main.bundleIdentifier ?? NSNull(),
        "version": macosCLIVersion,
        "signature": signing,
        "team_id": value("TeamIdentifier").flatMap { $0 == "not set" ? nil : $0 as Any } ?? NSNull(),
    ]
}

private func sessionFacts() -> [String: Any] {
    let manager = (Process.capture(args: ["/bin/launchctl", "managername"], timeout: 3) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return [
        "terminal": personAtTerminal,
        "gui_session": manager == "Aqua",
        "note": "macOS may record a grant against the app that started this process (Terminal, an IDE, an agent host) "
            + "rather than against the macos binary; run doctor from the same place the agent runs.",
    ]
}

private func resolvedCapabilities() -> [String: Bool] {
    let caps = Auth.load()
    var out: [String: Bool] = [:]
    for entry in Auth.allCapabilities { out[entry.id] = caps[entry.id] ?? entry.defaultAllow }
    return out
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report every macOS permission this binary has, and how to get the rest (never prompts)")

    @Flag(name: .customLong("for-agent"), help: "The full report as JSON: areas, binary identity, session, capabilities")
    var forAgent = false

    @Flag(name: .long, help: "Output JSON (same as --for-agent)")
    var json = false

    func run() throws {
        let areas = privacyAreas()
        if json || forAgent {
            printJSON(MacCLICore.doctorReport(areas: areas, binary: binaryIdentity(), session: sessionFacts(),
                                              capabilities: resolvedCapabilities()))
            return
        }
        for area in areas {
            let mark = area.state == "granted" ? "✓" : area.state == "unknown" ? "?" : "✗"
            print("\(mark) \(area.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(area.state)")
            if let hint = area.hint { print("    \(hint)") }
            if let detail = area.detail { print("    (\(detail))") }
        }
        let missing = areas.filter { $0.state != "granted" }.count
        print(missing == 0 ? "\nAll areas granted." : "\n\(missing) of \(areas.count) areas not granted.")
    }
}

struct AuthorizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "authorize",
        abstract: "Ask macOS for one permission: shows its prompt, or opens its settings pane",
        discussion: """
        Areas: calendars, reminders, contacts, location, accessibility, screen-recording,
        full-disk-access, automation.<app> (\(automationTargets.map { $0.id }.joined(separator: ", "))).
        The prompt appears on the Mac's screen; a person clicks Allow. From a shell with no
        one at the screen the request times out after --timeout seconds.
        """)

    @Argument(help: "The area, as `macos doctor` names it")
    var area: String

    @Option(name: .long, help: "Seconds to wait for the answer (default: 60)")
    var timeout: Double = 60

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() throws {
        let key = area.lowercased().replacingOccurrences(of: "-", with: "_")
        let state: String
        switch key {
        case "calendars", "calendar":
            state = try requestEventKit(.event)
        case "reminders":
            state = try requestEventKit(.reminder)
        case "contacts":
            if PrivacyAccess.contactsState == "not_determined" {
                try PrivacyAccess.requestContacts(.init(), timeout: timeout)
            }
            state = try settled(PrivacyAccess.contactsState, area: "Contacts", pane: "Privacy_Contacts")
        case "accessibility":
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(options) else { throw paneOpened("Accessibility", "Privacy_Accessibility") }
            state = "granted"
        case "screen_recording":
            guard CGRequestScreenCaptureAccess() else { throw paneOpened("Screen Recording", "Privacy_ScreenCapture") }
            state = "granted"
        case "full_disk_access":
            guard DiskAccess.probe(DiskAccess.notesStore) == "granted" else {
                throw paneOpened("Full Disk Access", "Privacy_AllFiles")
            }
            state = "granted"
        case "location":
            state = try requestLocation()
        case _ where key.hasPrefix("automation."):
            let id = String(key.dropFirst("automation.".count))
            guard let target = automationTargets.first(where: { $0.id == id }) else {
                throw ValidationError("Unknown app '\(id)'. Known: \(automationTargets.map { $0.id }.joined(separator: ", ")).")
            }
            let (answer, detail) = AutomationAccess.state(bundleID: target.bundleID, ask: true)
            if answer == "unknown" {
                throw CLIFailure.appError("macOS could not answer for \(target.app): \(detail ?? "no reason given").",
                                          hint: "Open \(target.app), then run this again.")
            }
            state = answer
        default:
            throw ValidationError("Unknown area '\(area)'. Run `macos doctor` to see the areas.")
        }

        if json {
            printJSON(["ok": true, "area": key, "state": state, "granted": state == "granted"])
        } else {
            print("\(key): \(state)")
        }
    }

    private func requestEventKit(_ type: EKEntityType) throws -> String {
        if PrivacyAccess.state(type) == "not_determined" {
            try EventKitStore.request(type, store: EKEventStore(), timeout: timeout)
        }
        return try settled(PrivacyAccess.state(type), area: EventKitStore.areaName(type),
                           pane: type == .event ? "Privacy_Calendars" : "Privacy_Reminders")
    }

    /// macOS asks only once. After a refusal the pane is the only way, so it opens.
    private func settled(_ state: String, area: String, pane: String) throws -> String {
        if state == "granted" { return state }
        if state == "denied" || state == "write_only" { throw paneOpened(area, pane) }
        throw CLIFailure.notGranted(area, state: state)
    }

    /// The areas macOS will not prompt for again (or never prompts for) are turned on
    /// in System Settings; open the pane on the Mac's screen and say so.
    private func paneOpened(_ area: String, _ anchor: String) -> CLIFailure {
        _ = Process.run(args: ["/usr/bin/open", settingsPane + anchor])
        return CLIFailure(code: "access_denied",
                          message: "\(area) is not granted to this binary. Its settings pane is open on the Mac's screen.",
                          hint: "A person turns the macos binary on there (adding it with + if it is not listed).",
                          extra: ["area": area.lowercased(), "state": "settings_opened"])
    }

    private func requestLocation() throws -> String {
        final class Waiter: NSObject, CLLocationManagerDelegate {
            var changed = false
            func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
                if manager.authorizationStatus != .notDetermined { changed = true }
            }
        }
        let manager = CLLocationManager()
        let waiter = Waiter()
        manager.delegate = waiter
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            let deadline = CFAbsoluteTimeGetCurrent() + timeout
            while !waiter.changed && CFAbsoluteTimeGetCurrent() < deadline {
                CFRunLoopRunInMode(.defaultMode, 0.1, false)
            }
            if !waiter.changed { throw CLIFailure.permissionTimeout("Location", seconds: timeout) }
        }
        let state = locationState()
        if state == "granted" { return state }
        throw CLIFailure.notGranted("Location", state: state)
    }
}
