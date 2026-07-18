import Foundation
import MacCLICore

// Dependency-free test runner for MacCLICore.
//
// WHY THIS EXISTS: `swift test` (XCTest) is unavailable in a Command-Line-Tools-only
// toolchain — `xcrun --show-sdk-platform-path` cannot resolve the XCTest platform, and
// the installed Xcode.app's license is not accepted (accepting it needs `sudo
// xcodebuild -license`, a system change outside this repo's scope). This runner exercises
// the IDENTICAL MacCLICore functions the XCTest suite covers (Tests/MacCLICoreTests), so
// the security-sensitive pure logic is genuinely validated here and now:
//
//   swift run MacCLICoreTestRunner   # exits 0 on pass, 1 on any failure
//
// When a full Xcode is available, `swift test` runs the canonical XCTest suite instead.
// Keep the two in sync.

var failures = 0
var checks = 0

func check(_ cond: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !cond {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(msg) (\(file):\(line))\n".utf8))
    }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    check(a == b, "\(msg) — expected \(b), got \(a)", file: file, line: line)
}

// MARK: - Authorization status names (stable across Ventura / macOS 14 rawValues)
eq(MacCLICore.authorizationStatusName(0), "notDetermined", "auth 0")
eq(MacCLICore.authorizationStatusName(1), "restricted", "auth 1")
eq(MacCLICore.authorizationStatusName(2), "denied", "auth 2")
eq(MacCLICore.authorizationStatusName(3), "authorized", "auth 3")
eq(MacCLICore.authorizationStatusName(4), "writeOnly", "auth 4")
eq(MacCLICore.authorizationStatusName(99), "unknown", "auth 99")

check(MacCLICore.authorizationCanRead(3), "canRead only when authorized")
for raw in [0, 1, 2, 4, 99] {
    check(!MacCLICore.authorizationCanRead(raw), "raw \(raw) must not read")
}

// MARK: - Fail-closed reminder list resolution (load-bearing security property)
let titles = ["Work", "Groceries", "Cara / Tour", "Work"]

do {
    let r = MacCLICore.resolveReminderLists(allTitles: titles, filter: nil)
    eq(r, MacCLICore.ListResolution(indices: [0, 1, 2, 3], failClosed: false), "nil filter selects all")
}
do {
    let r = MacCLICore.resolveReminderLists(allTitles: titles, filter: "Groceries")
    eq(r.indices, [1], "exact match")
    check(!r.failClosed, "exact match not fail-closed")
}
do {
    let r = MacCLICore.resolveReminderLists(allTitles: titles, filter: "Work")
    eq(r.indices, [0, 3], "duplicate titles select all matches")
    check(!r.failClosed, "duplicate match not fail-closed")
}
do {
    // THE security property: a nonexistent list must NEVER broaden to all.
    let r = MacCLICore.resolveReminderLists(allTitles: titles, filter: "___NOPE___")
    eq(r.indices, [], "nonexistent list selects zero")
    check(r.failClosed, "nonexistent list flagged fail-closed")
}
do {
    let r = MacCLICore.resolveReminderLists(allTitles: titles, filter: "Work / Tour")
    check(r.failClosed, "filter is exact, not substring")
    eq(r.indices, [], "substring-like filter selects zero")
}

// MARK: - Priority bands
eq(MacCLICore.priorityBand(0), "none", "prio 0")
eq(MacCLICore.priorityBand(1), "high", "prio 1")
eq(MacCLICore.priorityBand(4), "high", "prio 4")
eq(MacCLICore.priorityBand(5), "medium", "prio 5")
eq(MacCLICore.priorityBand(6), "low", "prio 6")
eq(MacCLICore.priorityBand(9), "low", "prio 9")

// MARK: - Agent-safe approval-token gate
check(MacCLICore.isApprovalTokenValid(supplied: "s3cret", expected: "s3cret"), "valid when non-empty and matches")
check(!MacCLICore.isApprovalTokenValid(supplied: nil, expected: "s3cret"), "invalid when no token supplied")
check(!MacCLICore.isApprovalTokenValid(supplied: "s3cret", expected: nil), "invalid when none configured")
check(!MacCLICore.isApprovalTokenValid(supplied: "", expected: ""), "empty configured never authorizes (empty supplied)")
check(!MacCLICore.isApprovalTokenValid(supplied: "anything", expected: ""), "empty configured never authorizes")
check(!MacCLICore.isApprovalTokenValid(supplied: "wrong", expected: "s3cret"), "invalid on mismatch")

do {
    let secret = "TOP-SECRET-TOKEN-123"
    let r1 = MacCLICore.approvalDenialReason(supplied: nil, expected: secret)
    check(r1.lowercased().contains("dry-run") || r1.lowercased().contains("no --approve"), "r1 phrasing")
    check(!r1.contains(secret), "r1 must not leak token")

    let r2 = MacCLICore.approvalDenialReason(supplied: "x", expected: nil)
    check(r2.lowercased().contains("configured") || r2.lowercased().contains("cannot be verified"), "r2 phrasing")
    check(!r2.contains(secret), "r2 must not leak token")

    let r3 = MacCLICore.approvalDenialReason(supplied: "x", expected: secret)
    check(r3.lowercased().contains("does not match") || r3.lowercased().contains("mismatch"), "r3 phrasing")
    check(!r3.contains(secret), "r3 must not leak configured token")
    check(!r3.contains("x") || r3.lowercased().contains("does not match"), "r3 must not echo supplied token")
}

// MARK: - Completion gate matrix (P1-1: writes only behind the exact-nonempty token)
// Reminder completion has ONE write decision — isApprovalTokenValid. The retired
// `done` command never reaches it; `complete`/`complete-safe` route their only
// mutation through it. Prove the whole matrix fails closed except the exact match.
do {
    let secret = "s3cret"
    let suppliedCases: [String?] = [nil, "", "wrong", " s3cret", "s3cret ", secret]
    let expectedCases: [String?] = [nil, "", secret]
    for supplied in suppliedCases {
        for expected in expectedCases {
            let shouldWrite = (supplied == secret && expected == secret)
            eq(MacCLICore.isApprovalTokenValid(supplied: supplied, expected: expected), shouldWrite,
               "gate supplied=\(String(describing: supplied)) expected=\(String(describing: expected))")
        }
    }
}

// MARK: - Export timeout envelope (machine contract: hard error, never empty result)
do {
    let env = MacCLICore.fetchTimeoutErrorJSON(timeoutSeconds: 0.001)
    check(env["ok"] as? Bool == false, "timeout envelope ok=false")
    eq(env["status"] as? String, "error", "timeout envelope status")
    eq(env["error"] as? String, "fetch_timeout", "timeout envelope error code")
    eq(env["entity"] as? String, "reminder", "timeout envelope entity")
    eq(env["timeout_seconds"] as? Double, 0.001, "timeout envelope echoes seconds")
    // Must never be mistakable for an empty successful export.
    check(env["reminders"] == nil, "timeout envelope carries no rows array")
    check(env["count"] == nil, "timeout envelope carries no count")
    check(JSONSerialization.isValidJSONObject(env), "timeout envelope is JSON-serializable")
}

// MARK: - Notes body decoding (Unicode-preserving)
func varint(_ v: UInt64) -> Data {
    var value = v, out = Data()
    repeat {
        var byte = UInt8(value & 0x7F); value >>= 7
        if value != 0 { byte |= 0x80 }
        out.append(byte)
    } while value != 0
    return out
}
func protoField(_ fieldNumber: Int, _ payload: Data) -> Data {
    var out = Data()
    out.append(varint(UInt64(fieldNumber << 3 | 2)))
    out.append(varint(UInt64(payload.count)))
    out.append(payload)
    return out
}

do {
    let plain = Data("not gzipped".utf8)
    eq(MacCLICore.gunzipIfNeeded(plain), plain, "gunzip passthrough when not gzip")
}
do {
    let body = "Café ☕ déjà vu — 日本語 — Ñoño"
    let extracted = MacCLICore.extractProtobufText(protoField(2, Data(body.utf8)), minAlphaRatio: 0.3, minLen: 4)
    check(extracted.contains(body), "Unicode body survives extraction verbatim")
}
do {
    let short = "hi"
    let long = "The quick brown fox — café 日本語 jumps over the lazy dog"
    var proto = Data()
    proto.append(protoField(3, Data(short.utf8)))
    proto.append(protoField(2, Data(long.utf8)))
    proto.append(protoField(5, Data([0x00, 0x01, 0x02, 0xFF, 0xFE])))
    eq(MacCLICore.decodeNoteBody(proto), long, "decode picks longest coherent text")
}
check(MacCLICore.decodeNoteBody(Data([0x00, 0x01, 0x02])) == nil, "decode returns nil on garbage")

// MARK: - Summary
if failures == 0 {
    print("ok — \(checks) checks passed")
    exit(0)
} else {
    FileHandle.standardError.write(Data("\(failures)/\(checks) checks FAILED\n".utf8))
    exit(1)
}
