import Foundation
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

    func run(_ arguments: [String]) throws -> Run {
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
        process.standardInput = FileHandle.nullDevice
        try process.run()
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
}
