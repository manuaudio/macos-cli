import EventKit
import Foundation
import MacCLICore
import XCTest

/// Runs the built `macos-cli` binary the way an agent does and checks what it promises:
/// the exit code, a single JSON error envelope on stdout under `--json`, and an empty
/// stderr. Every case either fails before it reads anything, or reads with a policy
/// file that denies the read, so no calendar, contact, note or reminder is touched.
final class CLITests: XCTestCase {

    struct Run {
        let status: Int32
        let stdout: String
        let stderr: String

        var json: [String: Any]? {
            guard let data = stdout.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    /// A HOME of the test's own, so `~/.config/macos-cli/auth.json` is ours.
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("macos-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    static var binary: URL {
        // The test bundle sits next to the products SwiftPM built.
        Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("macos-cli")
    }

    func writePolicy(_ capabilities: [String: Bool]) throws {
        let dir = home.appendingPathComponent(".config/macos-cli")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body: [String: Any] = ["version": 1, "capabilities": capabilities]
        try JSONSerialization.data(withJSONObject: body).write(to: dir.appendingPathComponent("auth.json"))
    }

    func run(_ arguments: [String], input: String? = nil) throws -> Run {
        let binary = Self.binary
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("no built binary at \(binary.path); run `swift build` first")
            throw CocoaError(.fileNoSuchFile)
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input = input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus,
                   stdout: String(decoding: outData, as: UTF8.self),
                   stderr: String(decoding: errData, as: UTF8.self))
    }

    /// The envelope every failure under `--json` must be.
    func assertEnvelope(_ run: Run, code: String, status: Int32,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.status, status, "exit status; stdout: \(run.stdout)", file: file, line: line)
        guard let body = run.json else {
            return XCTFail("stdout is not one JSON object: \(run.stdout)", file: file, line: line)
        }
        XCTAssertEqual(body["ok"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(body["status"] as? String, "error", file: file, line: line)
        XCTAssertEqual(body["error"] as? String, code, file: file, line: line)
        XCTAssertEqual(body["exit_code"] as? Int, Int(status), file: file, line: line)
        XCTAssertFalse((body["message"] as? String ?? "").isEmpty, "message", file: file, line: line)
        XCTAssertEqual(run.stderr, "", "stderr stays empty under --json", file: file, line: line)
    }

    // MARK: - The README's table is the code's table

    /// Every row of the README's exit-code table, read from the file, against
    /// `MacCLICore.exitCode(forErrorCode:)`: each code it lists exits with its row's status.
    func testReadmeExitCodeTableMatchesTheCode() throws {
        let readme = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        guard let section = text.components(separatedBy: "### Errors and exit codes").dropFirst().first else {
            return XCTFail("README has no 'Errors and exit codes' section")
        }
        var checked = 0
        for line in (section.components(separatedBy: "\n### ").first ?? "").components(separatedBy: "\n") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4, let status = Int32(cells[1]), status != 0 else { continue }
            let codes = cells[3].components(separatedBy: "`").enumerated()
                .filter { $0.offset % 2 == 1 }.map(\.element)
                .filter { $0.allSatisfy { $0 == "_" || ($0.isLetter && $0.isLowercase) } }
            XCTAssertFalse(codes.isEmpty, "row \(status) names no code")
            for code in codes {
                XCTAssertEqual(MacCLICore.exitCode(forErrorCode: code), status, "README row for `\(code)`")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 10, "the table was read")
    }

    func testMissingDirectoryIsNotFound() throws {
        let missing = home.appendingPathComponent("no-such-directory").path
        assertEnvelope(try run(["file", "list", missing, "--json"]), code: "not_found", status: 3)
    }

    // MARK: - Success

    func testInfoSystemJSONExitsZero() throws {
        let result = try run(["info", "system", "--json"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertNotNil(result.json?["os"], "info system --json returns its object")
    }

    func testVersionComesFromVersionSwiftAndMatchesInfoPlist() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/macos-cli-Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
        let expected = (info as? [String: Any])?["CFBundleShortVersionString"] as? String
        let result = try run(["--version"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), expected)
    }

    // MARK: - --json on the four exports

    /// The exports always printed JSON but refused the flag ("Unknown option '--json'",
    /// exit 64). With every read denied by policy, each one must get past the parser and
    /// stop at the policy check: `capability_denied`, exit 4, and nothing read.
    func testEveryExportAcceptsJSONFlag() throws {
        try writePolicy(["calendar.read": false, "contacts.read": false,
                         "notes.read": false, "reminders.read": false])
        for (area, capability) in [("calendar", "calendar.read"), ("contacts", "contacts.read"),
                                   ("notes", "notes.read"), ("reminders", "reminders.read")] {
            let result = try run([area, "export", "--json"])
            assertEnvelope(result, code: "capability_denied", status: 4)
            XCTAssertEqual(result.json?["capability"] as? String, capability, area)
        }
    }

    func testExportWithBadDateIsJSONError() throws {
        let result = try run(["calendar", "export", "--json", "--from", "bad"])
        assertEnvelope(result, code: "invalid_date", status: 64)
        XCTAssertEqual(result.json?["field"] as? String, "from")
    }

    func testExportFailuresAreJSONEvenWithoutTheFlag() throws {
        let result = try run(["calendar", "export", "--from", "2026-02-30"])
        assertEnvelope(result, code: "invalid_date", status: 64)
    }

    // MARK: - Usage

    func testUnknownOptionUnderJSONIsUsageEnvelope() throws {
        let result = try run(["calendar", "events", "--json", "--no-such-option"])
        assertEnvelope(result, code: "usage", status: 64)
    }

    func testCommandWithoutJSONOutputSaysSoInJSON() throws {
        let result = try run(["auth", "list", "--json"])
        assertEnvelope(result, code: "usage", status: 64)
        XCTAssertEqual(result.json?["message"] as? String, "This command has no --json output.")
    }

    func testUsageWithoutJSONStaysPlainText() throws {
        let result = try run(["calendar", "events", "--no-such-option"])
        XCTAssertEqual(result.status, 64)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("Unknown option '--no-such-option'"), result.stderr)
    }

    // MARK: - Permission

    func testDeniedCapabilityIsJSONUnderFlag() throws {
        try writePolicy(["calendar.read": false])
        let result = try run(["calendar", "events", "--json"])
        assertEnvelope(result, code: "capability_denied", status: 4)
        XCTAssertNotNil(result.json?["hint"], "a denial says how to allow it")
    }

    func testDeniedCapabilityIsOneLineWithoutFlag() throws {
        try writePolicy(["calendar.read": false])
        let result = try run(["calendar", "events"])
        XCTAssertEqual(result.status, 4)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.hasPrefix("Error: 'calendar.read' is denied"), result.stderr)
        XCTAssertFalse(result.stderr.contains("USAGE:"), "a denial is not a usage mistake")
    }

    // MARK: - Not found

    /// An unknown calendar used to print the root usage text and exit 64. When this
    /// process may read calendars it is `calendar_not_found` (exit 3); where macOS has
    /// not granted calendars to it, the access failure must still be the envelope.
    func testUnknownCalendarIsNotFound() throws {
        let name = "no-such-calendar-\(UUID().uuidString)"
        let result = try run(["calendar", "events", "--json", "--calendar", name])
        switch result.json?["error"] as? String {
        case "access_denied":
            assertEnvelope(result, code: "access_denied", status: 4)
            throw XCTSkip("macOS has not granted calendars to this process; not-found path not reached")
        case "timeout":
            assertEnvelope(result, code: "timeout", status: 5)
            throw XCTSkip("the calendar permission request was not answered; not-found path not reached")
        default:
            assertEnvelope(result, code: "calendar_not_found", status: 3)
            XCTAssertEqual(result.json?["calendar"] as? String, name)
        }
    }

    // MARK: - Timeout

    func testScriptTimeoutIsTimeoutEnvelope() throws {
        try writePolicy(["script.run": true])
        let result = try run(["script", "run", "--json", "--timeout", "1", "--jxa", "delay(10)"])
        assertEnvelope(result, code: "timeout", status: 5)
    }

    func testScriptRunJSONReturnsOutput() throws {
        try writePolicy(["script.run": true])
        let result = try run(["script", "run", "--json", "--jxa", "6 * 7"])
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.json?["output"] as? String, "42")
    }

    // MARK: - doctor

    func testDoctorForAgentNamesEveryArea() throws {
        let result = try run(["doctor", "--for-agent"])
        XCTAssertEqual(result.status, 0, result.stderr)
        let body = try XCTUnwrap(result.json, result.stdout)
        let areas = try XCTUnwrap(body["areas"] as? [[String: Any]])
        let ids = Set(areas.compactMap { $0["area"] as? String })
        let expected: Set<String> = [
            "calendars", "reminders", "contacts", "full_disk_access", "accessibility", "screen_recording",
            "location", "automation.mail", "automation.messages", "automation.notes", "automation.safari",
            "automation.music", "automation.photos", "automation.finder", "automation.system_events",
        ]
        XCTAssertEqual(ids, expected)
        for area in areas {
            let state = area["state"] as? String ?? ""
            XCTAssertTrue(["granted", "denied", "not_determined", "restricted", "write_only", "unknown"].contains(state),
                          "\(area)")
            if state != "granted" { XCTAssertNotNil(area["hint"] as? String, "\(area)") }
        }
        XCTAssertEqual((body["binary"] as? [String: Any])?["bundle_id"] as? String, "com.manuaudio.macos-cli")
        XCTAssertEqual((body["session"] as? [String: Any])?["terminal"] as? Bool, false)
        XCTAssertEqual((body["capabilities"] as? [String: Bool])?["mail.send"], false, "the default policy")
        XCTAssertEqual(body["ready"] as? Bool, (body["missing"] as? [String])?.isEmpty)
    }

    // MARK: - Only a person widens the policy

    func policy() throws -> [String: Bool] {
        let url = home.appendingPathComponent(".config/macos-cli/auth.json")
        let body = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return body?["capabilities"] as? [String: Bool] ?? [:]
    }

    /// An agent granted itself capabilities with `auth grant`. Without a terminal it is
    /// refused, the answer piped to stdin does not count, and the policy is unchanged.
    func testAuthGrantWithoutTerminalRefuses() throws {
        try writePolicy(["mail.send": false])
        let result = try run(["auth", "grant", "mail.send"], input: "mail.send\ny\n")
        XCTAssertEqual(result.status, 4)
        XCTAssertTrue(result.stderr.hasPrefix("Error: Widening macos-cli's permissions needs a person"), result.stderr)
        XCTAssertEqual(try policy()["mail.send"], false)
    }

    func testAuthSetupAllAndResetWithoutTerminalRefuse() throws {
        try writePolicy(["calendar.read": false])
        for arguments in [["auth", "setup", "--all"], ["auth", "setup"], ["auth", "reset"]] {
            let result = try run(arguments, input: "all\nreset\ny\n")
            XCTAssertEqual(result.status, 4, "\(arguments): \(result.stderr)")
        }
        XCTAssertEqual(try policy(), ["calendar.read": false])
        XCTAssertEqual(try run(["auth", "setup", "--all", "--yes"]).status, 64, "--yes no longer skips the person")
    }

    func testAuthDenyNeedsNoPerson() throws {
        try writePolicy([:])
        let result = try run(["auth", "deny", "calendar.read"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try policy()["calendar.read"], false)
    }

    // MARK: - Notes behind Full Disk Access

    func notesStore() -> URL {
        home.appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }

    /// Without Full Disk Access Notes answered `count: 0`, exit 0. A store this process
    /// cannot open is now a permission error naming the grant.
    func testNotesWithoutFullDiskAccessIsPermissionError() throws {
        let store = notesStore()
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: store.path, contents: Data(), attributes: [.posixPermissions: 0])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path) }
        for arguments in [["notes", "list", "--json"], ["notes", "search", "x", "--json"], ["notes", "export"]] {
            let result = try run(arguments)
            assertEnvelope(result, code: "access_denied", status: 4)
            XCTAssertEqual(result.json?["area"] as? String, "full_disk_access", "\(arguments)")
        }
    }

    func testNotesWithoutStoreIsNotFound() throws {
        assertEnvelope(try run(["notes", "list", "--json"]), code: "not_found", status: 3)
    }

    // MARK: - Calendar flags

    func testStartIsAcceptedAsFrom() throws {
        let result = try run(["calendar", "export", "--start", "bad"])
        assertEnvelope(result, code: "invalid_date", status: 64)
        XCTAssertEqual(result.json?["field"] as? String, "from")
    }

    func testBadSinceAndTimezoneAreRefusedBeforeAnyRead() throws {
        let since = try run(["calendar", "export", "--since", "yesterday"])
        assertEnvelope(since, code: "invalid_date", status: 64)
        XCTAssertEqual(since.json?["field"] as? String, "since")
        assertEnvelope(try run(["calendar", "events", "--json", "--timezone", "Mars/Base"]),
                       code: "invalid_timezone", status: 64)
    }

    func testUpdateRefusesAlarmAndClearTogether() throws {
        assertEnvelope(try run(["calendar", "update", "--json", "--id", "x", "--alarm", "10", "--clear-alarms"]),
                       code: "usage", status: 64)
    }

    /// Writes only to calendars named by MACOS_CLI_TEST_CALENDAR on the Local source,
    /// made here and removed at the end. Two of them share the name, so a write by name
    /// is refused with both ids, and `--calendar-id` reaches the one it names.
    func testSharedCalendarNameAndCalendarId() throws {
        guard let name = ProcessInfo.processInfo.environment["MACOS_CLI_TEST_CALENDAR"], !name.isEmpty else {
            throw XCTSkip("set MACOS_CLI_TEST_CALENDAR to run the calendar write test")
        }
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .event).rawValue == 3,
              let local = store.sources.first(where: { $0.sourceType == .local }) else {
            throw XCTSkip("this test process has no full calendar access, or the Mac has no Local source")
        }
        var made: [EKCalendar] = []
        defer { for cal in made { try? store.removeCalendar(cal, commit: true) } }
        for _ in 0..<2 {
            let cal = EKCalendar(for: .event, eventStore: store)
            cal.title = name
            cal.source = local
            try store.saveCalendar(cal, commit: true)
            made.append(cal)
        }
        try writePolicy(["calendar.read": true, "calendar.write": true, "calendar.delete": true])

        let byName = try run(["calendar", "create", "--json", "--title", "t", "--start", "2030-01-01 10:00",
                              "--calendar", name])
        assertEnvelope(byName, code: "ambiguous_calendar", status: 64)
        let ids = (byName.json?["candidates"] as? [[String: String]])?.compactMap { $0["id"] } ?? []
        XCTAssertEqual(Set(ids), Set(made.map { $0.calendarIdentifier }))

        let target = made[1].calendarIdentifier
        let created = try run(["calendar", "create", "--json", "--title", "t", "--start", "2030-01-01 10:00",
                               "--calendar-id", target, "--timezone", "UTC"])
        XCTAssertEqual(created.status, 0, created.stdout)
        XCTAssertEqual(created.json?["calendar_id"] as? String, target)
        let id = try XCTUnwrap(created.json?["id"] as? String)

        let updated = try run(["calendar", "update", "--json", "--id", id, "--alarm", "15", "--alarm", "60"])
        XCTAssertEqual(updated.status, 0, updated.stdout)
        XCTAssertEqual(updated.json?["alarms"] as? [Int], [15, 60])
        let cleared = try run(["calendar", "update", "--json", "--id", id, "--clear-alarms"])
        XCTAssertEqual(cleared.json?["alarms"] as? [Int], [])

        let export = try run(["calendar", "export", "--calendar-id", target, "--from", "2030-01-01", "--to", "2030-01-02"])
        XCTAssertEqual(export.json?["count"] as? Int, 1, export.stdout)
        XCTAssertEqual(try run(["calendar", "delete", "--json", "--id", id]).status, 0)
    }
}
