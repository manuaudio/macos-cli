import ApplicationServices
import Contacts
import CoreGraphics
import CoreLocation
import EventKit
import Foundation
import MacCLICore

/// The home folder. `HOME` wins over the account's, so a test can point every
/// per-user path (the policy file, the Notes store) at a folder of its own.
func userHome() -> URL {
    ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
}

/// True when a person can answer: stdin and stderr are both a terminal. An agent's
/// shell, a pipe, cron and launchd have no terminal, and a macOS permission request
/// from them is never answered (the old 15 s timeout), so commands do not ask there.
var personAtTerminal: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDERR_FILENO) == 1 }

/// Ask a person a question on the controlling terminal and return the answer.
/// Reads `/dev/tty`, not stdin, so text piped into the command cannot answer it.
/// Nil when the process has no terminal.
func askPerson(_ question: String) -> String? {
    guard personAtTerminal, let tty = fopen("/dev/tty", "r+") else { return nil }
    defer { fclose(tty) }
    fputs(question, tty)
    fflush(tty)
    var buffer = [CChar](repeating: 0, count: 512)
    guard fgets(&buffer, Int32(buffer.count), tty) != nil else { return nil }
    return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Calendars, Reminders, Contacts

enum PrivacyAccess {
    static func state(_ type: EKEntityType) -> String {
        MacCLICore.privacyState(eventKitOrContactsRaw: EKEventStore.authorizationStatus(for: type).rawValue)
    }

    static var contactsState: String {
        MacCLICore.privacyState(eventKitOrContactsRaw: CNContactStore.authorizationStatus(for: .contacts).rawValue)
    }

    /// Ask macOS for Contacts, waiting at most `timeout` seconds for the answer.
    static func requestContacts(_ store: CNContactStore, timeout: Double) throws {
        let sema = DispatchSemaphore(value: 0)
        var granted = false
        store.requestAccess(for: .contacts) { ok, _ in granted = ok; sema.signal() }
        if sema.wait(timeout: .now() + timeout) == .timedOut {
            throw CLIFailure.permissionTimeout("Contacts", seconds: timeout)
        }
        guard granted else { throw CLIFailure.notGranted("Contacts", state: "denied") }
    }

    /// The Contacts store, once access is granted. A command asks macOS only when a
    /// person is at the terminal; elsewhere an undecided permission fails at once.
    static func contactsStore() throws -> CNContactStore {
        let store = CNContactStore()
        switch contactsState {
        case "granted":
            return store
        case "not_determined" where personAtTerminal:
            try requestContacts(store, timeout: 60)
            return store
        case let state:
            throw CLIFailure.notGranted("Contacts", state: state)
        }
    }
}

extension CLIFailure {
    /// macOS has not given an area to this binary. `state` says whether it was
    /// refused or never decided; the hint names the command or pane that fixes it.
    static func notGranted(_ area: String, state: String) -> CLIFailure {
        let pane = "System Settings › Privacy & Security › \(area)"
        let message: String
        let hint: String
        switch state {
        case "not_determined":
            message = "macOS has not been asked for \(area) access for this binary yet."
            hint = "A person runs `macos authorize \(area.lowercased())` in a Terminal window and clicks Allow."
        case "restricted":
            message = "\(area) access is restricted on this Mac (a profile or parental control)."
            hint = "Only the Mac's administrator can lift it."
        case "write_only":
            message = "This binary may add to \(area) but not read it."
            hint = "Turn on full access in \(pane)."
        default:
            message = "\(area) access is turned off for this binary."
            hint = "Turn it on in \(pane), then retry."
        }
        return CLIFailure(code: "access_denied", message: message, hint: hint,
                          extra: ["area": area.lowercased(), "state": state])
    }

    static func permissionTimeout(_ area: String, seconds: Double) -> CLIFailure {
        CLIFailure(code: "timeout",
                   message: "The \(area) permission request was not answered within \(Int(seconds)) s.",
                   hint: "Run `macos authorize \(area.lowercased())` in a Terminal window on the Mac's screen and click Allow.",
                   extra: ["area": area.lowercased()])
    }
}

// MARK: - Full Disk Access

enum DiskAccess {
    static var notesStore: URL {
        userHome().appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }

    /// granted | denied | missing — whether this process can open the file. Without
    /// Full Disk Access macOS refuses the open (EPERM) even though the file exists.
    static func probe(_ url: URL) -> String {
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 { close(fd); return "granted" }
        return errno == ENOENT || errno == ENOTDIR ? "missing" : "denied"
    }

    /// The Notes database path, or the reason it cannot be read. Notes used to answer
    /// `count: 0` here, as if there were no notes.
    static func readableNotesStore() throws -> String {
        let url = notesStore
        switch probe(url) {
        case "granted":
            return url.path
        case "missing":
            throw CLIFailure.notFound("No Notes database at \(url.path).",
                                      hint: "Open Notes once on this Mac so it creates its store.")
        default:
            throw CLIFailure(code: "access_denied",
                             message: "Reading Notes needs Full Disk Access, and this binary does not have it.",
                             hint: "Add the macos binary in System Settings › Privacy & Security › Full Disk Access.",
                             extra: ["area": "full_disk_access", "state": "denied"])
        }
    }
}

// MARK: - Automation (Apple events)

enum AutomationAccess {
    /// granted | denied | not_determined | unknown, without showing a prompt unless
    /// `ask` is true. macOS can only answer for an app that is running.
    static func state(bundleID: String, ask: Bool = false) -> (state: String, detail: String?) {
        var target = AEAddressDesc()
        let created = bundleID.withCString { ptr in
            AECreateDesc(DescType(typeApplicationBundleID), ptr, bundleID.utf8.count, &target)
        }
        guard created == noErr else { return ("unknown", "could not address \(bundleID)") }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard),
                                                           AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return ("granted", nil)
        case OSStatus(errAEEventNotPermitted): return ("denied", nil)
        case OSStatus(errAEEventWouldRequireUserConsent): return ("not_determined", nil)
        case OSStatus(procNotFound): return ("unknown", "the app is not running; macOS answers only for a running app")
        default: return ("unknown", "macOS returned \(status)")
        }
    }
}
