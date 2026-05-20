import ArgumentParser
import Foundation
import ApplicationServices
import CoreGraphics
import EventKit
import Contacts

struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Interactive setup — check permissions and verify every capability works"
    )

    func run() throws {
        print("")
        print("macOS CLI setup")
        print("===============")
        print("Checking capabilities...\n")

        var failures: [String] = []

        // ── 1. No-permission capabilities ─────────────────────────────────────
        header("Core (no permission required)")
        check("Battery / system info",     &failures) { batteryOK() }
        check("Apple Notes (SQLite read)", &failures) { notesOK() }
        check("Text-to-speech",            &failures) { speechOK() }
        check("Storage / disk info",       &failures) { true }
        print("")

        // ── 2. Screen Recording ───────────────────────────────────────────────
        header("Screen Recording — screenshot with app window content")
        let screenRecordingGranted = CGPreflightScreenCaptureAccess()
        check("Screenshot captures app windows", &failures) { screenRecordingGranted }
        if !screenRecordingGranted {
            print("  ⚠️   Grant Screen Recording access:")
            print("       System Settings → Privacy & Security → Screen Recording")
            print("       Add Terminal (or tmux/iTerm) and toggle ON")
            offerOpen("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
        print("")

        // ── 3. Accessibility ──────────────────────────────────────────────────
        header("Accessibility — mouse, keyboard, AX element control")
        let axGranted = AXIsProcessTrusted()
        check("Mouse move / click / drag",   &failures) { axGranted }
        check("Keyboard shortcuts",           &failures) { axGranted }
        check("AX tree (find/click by name)", &failures) { axGranted }
        if !axGranted {
            print("  ⚠️   Grant Accessibility access:")
            print("       System Settings → Privacy & Security → Accessibility")
            print("       Add Terminal (or tmux/iTerm) and toggle ON")
            offerOpen("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
        print("")

        // ── 4. Automation — each app ──────────────────────────────────────────
        header("Automation — app control via JXA (10s timeout per app)")
        print("  (First run may show a permission dialog — click Allow)")
        print("  Checking takes up to 10s per app...\n")

        let safariOK = jxaOK("Application('Safari').windows().length")
        check("Safari (tabs, open URL, read page, run JS)", &failures) { safariOK }

        let mailOK = jxaOK("Application('Mail').accounts().length")
        check("Mail (draft, search)",               &failures) { mailOK }

        let photosOK = jxaOK("Application('Photos').albums().length")
        check("Photos (albums, search, recent)",    &failures) { photosOK }

        let msgOK = jxaOK("Application('Messages').chats().length")
        check("Messages (conversations, send)",     &failures) { msgOK }

        let musicOK = jxaOK("Application('Music').playerState().toString()")
        check("Music (status, play, pause, skip)",  &failures) { musicOK }

        let notesAutoOK = jxaOK("Application('Notes').folders().length.toString()")
        check("Notes (read, create, delete, update, folders)", &failures) { notesAutoOK }

        let finderOK = jxaOK("Application('Finder').selection().length.toString()")
        check("Finder (selected, reveal, new-folder, rename, go-to)", &failures) { finderOK }

        let contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        let contactsOK = contactsStatus == .authorized
        check("Contacts (search, create, update, delete)", &failures) { contactsOK }

        let calStatus = EKEventStore.authorizationStatus(for: .event)
        let calOK: Bool
        if #available(macOS 14.0, *) {
            calOK = calStatus == .fullAccess
        } else {
            calOK = calStatus == .authorized
        }
        check("Calendar (events, create, update, delete)", &failures) { calOK }

        let remStatus = EKEventStore.authorizationStatus(for: .reminder)
        let remOK: Bool
        if #available(macOS 14.0, *) {
            remOK = remStatus == .fullAccess
        } else {
            remOK = remStatus == .authorized
        }
        check("Reminders (list, create, update, delete, complete)", &failures) { remOK }

        let hasAutoFailures = [safariOK, mailOK, photosOK, msgOK, musicOK, finderOK, notesAutoOK, contactsOK, calOK, remOK].contains(false)
        if hasAutoFailures {
            print("")
            print("  ⚠️   For any ❌ above:")
            print("       System Settings → Privacy & Security → Automation")
            print("       Find Terminal (or tmux/iTerm) → enable the app checkboxes")
            offerOpen("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        }
        print("")

        // ── 5. No-auth system commands ────────────────────────────────────────
        header("System commands (no special permission)")
        check("Network ping/dns/port/traceroute", &failures) { cliOK(["network", "dns", "--host", "8.8.8.8"]) }
        check("Defaults read/write",              &failures) { cliOK(["defaults", "list-domains"]) }
        check("Safari history (SQLite read)",     &failures) { cliOK(["safari", "history", "--limit", "1"]) }
        check("Safari bookmarks (plist read)",    &failures) { cliOK(["safari", "bookmarks"]) }
        print("")

        // ── Summary ───────────────────────────────────────────────────────────
        print("════════════════════════════════════════")
        if failures.isEmpty {
            print("✅  All capabilities working. You're fully set up.")
        } else {
            print("⚠️   Still needed: \(failures.joined(separator: ", "))")
            print("    Re-run `macos setup` after granting permissions.")
        }
        print("")
    }

    // MARK: - Helpers

    private func header(_ title: String) {
        print("── \(title)")
    }

    private func check(_ label: String, _ failures: inout [String], test: () -> Bool) {
        let ok = test()
        print("  \(ok ? "✅" : "❌")  \(label)")
        if !ok { failures.append(label) }
    }

    // Test actual macOS CLI subcommand (self-call) — check exit code, not stdout content
    private func cliOK(_ args: [String]) -> Bool {
        let selfPath = CommandLine.arguments[0]
        return Process.run(args: [selfPath] + args) == 0
    }

    private func jxaOK(_ expr: String) -> Bool {
        guard let raw = Process.capture(
            args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", expr],
            timeout: 10
        ) else { return false }
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !r.isEmpty && !r.lowercased().contains("not allowed") && !r.lowercased().contains("error")
    }

    private func offerOpen(_ url: String) {
        print("  Open settings now? (y/n): ", terminator: "")
        fflush(stdout)
        if let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           line == "y" || line == "yes" {
            _ = Process.run(args: ["/usr/bin/open", url])
            print("  Press Enter after granting access...")
            _ = readLine()
        }
    }

    private func batteryOK() -> Bool {
        (Process.capture(args: ["/usr/bin/pmset", "-g", "batt"], timeout: 5) ?? "").contains("%")
    }

    private func notesOK() -> Bool {
        let db = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
        let r = (Process.capture(args: ["/usr/bin/sqlite3", db,
            "SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZTITLE1 IS NOT NULL;"],
            timeout: 5) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(r) != nil
    }

    private func speechOK() -> Bool {
        Process.run(args: ["/usr/bin/say", "-v", "?"]) == 0
    }
}
