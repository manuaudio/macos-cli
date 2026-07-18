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

// MARK: - Calendar: fail-closed calendar filter (an unknown filter must NEVER broaden to all)
let calTitles = ["Home", "Work", "Familia", "Work"]
do {
    let r = MacCLICore.resolveCalendarFilter(allTitles: calTitles, filter: nil)
    eq(r, MacCLICore.ListResolution(indices: [0, 1, 2, 3], failClosed: false), "nil calendar filter selects all linked calendars")
}
do {
    let r = MacCLICore.resolveCalendarFilter(allTitles: calTitles, filter: "Familia")
    eq(r.indices, [2], "exact calendar match")
    check(!r.failClosed, "known calendar not fail-closed")
}
do {
    let r = MacCLICore.resolveCalendarFilter(allTitles: calTitles, filter: "Work")
    eq(r.indices, [1, 3], "duplicate calendar titles select all matches")
}
do {
    // THE ingestion security property: an unknown calendar must select zero, never all.
    let r = MacCLICore.resolveCalendarFilter(allTitles: calTitles, filter: "___NOPE___")
    eq(r.indices, [], "unknown calendar selects zero, never all")
    check(r.failClosed, "unknown calendar flagged fail-closed")
}

// MARK: - Calendar: date-range validation (from <= to, inclusive)
do {
    let v = MacCLICore.validateDateRange(startEpoch: 1000, endEpoch: 2000)
    check(v.valid, "from < to is valid")
    check(v.reason == nil, "valid range carries no reason")
}
do {
    let v = MacCLICore.validateDateRange(startEpoch: 2000, endEpoch: 2000)
    check(v.valid, "from == to is valid (inclusive)")
}
do {
    let v = MacCLICore.validateDateRange(startEpoch: 3000, endEpoch: 2000)
    check(!v.valid, "from > to is invalid")
    check(v.reason != nil, "invalid range carries a reason")
}
do {
    let env = MacCLICore.dateRangeErrorJSON(from: "2026-07-10", to: "2026-07-01")
    check(env["ok"] as? Bool == false, "range error ok=false")
    eq(env["status"] as? String, "error", "range error status")
    eq(env["error"] as? String, "invalid_date_range", "range error code")
    eq(env["from"] as? String, "2026-07-10", "range error echoes from")
    eq(env["to"] as? String, "2026-07-01", "range error echoes to")
    check(env["events"] == nil, "range error carries no events array")
    check(JSONSerialization.isValidJSONObject(env), "range error is JSON-serializable")
}
do {
    let env = MacCLICore.dateParseErrorJSON(field: "from", value: "not-a-date")
    eq(env["error"] as? String, "invalid_date", "parse error code")
    eq(env["field"] as? String, "from", "parse error echoes field")
    eq(env["value"] as? String, "not-a-date", "parse error echoes value")
    check(env["ok"] as? Bool == false, "parse error ok=false")
}

// MARK: - Calendar: redacted access-denied envelope (structured, leaks no content)
do {
    let env = MacCLICore.accessErrorJSON(entity: "calendar")
    check(env["ok"] as? Bool == false, "access error ok=false")
    eq(env["status"] as? String, "error", "access error status")
    eq(env["error"] as? String, "access_denied", "access error code")
    eq(env["entity"] as? String, "calendar", "access error echoes entity")
    // Redaction: never a rows/count/calendars array — cannot be mistaken for a result.
    check(env["events"] == nil, "access error carries no events array")
    check(env["calendars"] == nil, "access error carries no calendars array")
    check(env["count"] == nil, "access error carries no count")
    check(JSONSerialization.isValidJSONObject(env), "access error JSON-serializable")
}

// MARK: - Calendar: delete mode resolution (exactly one of --id | --title+--date)
eq(MacCLICore.resolveDeleteMode(id: "EV-123", title: nil, date: nil), .byId("EV-123"), "id-only => byId")
eq(MacCLICore.resolveDeleteMode(id: nil, title: "Dentist", date: "2026-07-10"),
   .byTitleDate(title: "Dentist", date: "2026-07-10"), "title+date => byTitleDate")
do {
    func isInvalid(_ m: MacCLICore.CalendarDeleteMode) -> Bool { if case .invalid = m { return true }; return false }
    check(isInvalid(MacCLICore.resolveDeleteMode(id: "EV-1", title: "X", date: nil)), "id + title is invalid")
    check(isInvalid(MacCLICore.resolveDeleteMode(id: "EV-1", title: nil, date: "2026-07-10")), "id + date is invalid")
    check(isInvalid(MacCLICore.resolveDeleteMode(id: "EV-1", title: "X", date: "2026-07-10")), "id + title + date is invalid")
    check(isInvalid(MacCLICore.resolveDeleteMode(id: nil, title: "X", date: nil)), "title without date is invalid")
    check(isInvalid(MacCLICore.resolveDeleteMode(id: nil, title: nil, date: "2026-07-10")), "date without title is invalid")
    check(isInvalid(MacCLICore.resolveDeleteMode(id: nil, title: nil, date: nil)), "no mode is invalid")
}
do {
    let env = MacCLICore.calendarDeleteNotFoundJSON(id: "EV-404")
    check(env["ok"] as? Bool == false, "not-found ok=false")
    eq(env["error"] as? String, "event_not_found", "not-found error code")
    eq(env["id"] as? String, "EV-404", "not-found echoes id")
    check(env["deleted"] as? Bool == false, "not-found deleted=false")
    check(JSONSerialization.isValidJSONObject(env), "not-found envelope JSON-serializable")
}
do {
    let env = MacCLICore.calendarDeleteResultJSON(id: "EV-9", deleted: true)
    check(env["ok"] as? Bool == true, "delete result ok=true")
    eq(env["id"] as? String, "EV-9", "delete result echoes id")
    check(env["deleted"] as? Bool == true, "delete result deleted=true")
    // An id-mode delete result must carry NO private event content.
    check(env["title"] == nil, "delete result carries no title")
    check(env["notes"] == nil, "delete result carries no notes")
}

// MARK: - Calendar: alarm validation + offset conversion (minutes-before => negative seconds)
eq(MacCLICore.alarmOffsetSeconds(minutesBefore: 60), -3600 as Double?, "60 min => -3600s")
eq(MacCLICore.alarmOffsetSeconds(minutesBefore: 1), -60 as Double?, "1 min => -60s")
eq(MacCLICore.alarmOffsetSeconds(minutesBefore: 1440), -86400 as Double?, "1440 min => -86400s (1 day)")
check(MacCLICore.alarmOffsetSeconds(minutesBefore: 0) == nil, "0 min is invalid")
check(MacCLICore.alarmOffsetSeconds(minutesBefore: -5) == nil, "negative min is invalid")
eq(MacCLICore.invalidAlarmMinutes([15, 60, 1440]), [], "all-positive alarms have no invalids")
eq(MacCLICore.invalidAlarmMinutes([15, 0, -3, 60]), [0, -3], "non-positive alarms flagged")
eq(MacCLICore.alarmOffsets([1440, 60]), [-86400, -3600] as [Double], "offsets map to negative seconds in order")

// P1 #1: create alarm default preservation — explicit-only, ZERO default insertion.
// With no --alarm, create must add NO alarms (pre-0.8 behavior); [] => [] the whole way.
eq(MacCLICore.creationAlarmMinutes([]), [], "no --alarm => zero alarm minutes (no default insertion)")
eq(MacCLICore.alarmOffsets(MacCLICore.creationAlarmMinutes([])), [] as [Double], "no --alarm => zero alarm offsets")
eq(MacCLICore.creationAlarmMinutes([1440, 60]), [1440, 60], "explicit --alarm values pass through in given order")
eq(MacCLICore.alarmOffsets(MacCLICore.creationAlarmMinutes([1440, 60])), [-86400, -3600] as [Double],
   "explicit --alarm values map to offsets")
// Nonpositive validation is unchanged and still applies to explicit values.
eq(MacCLICore.invalidAlarmMinutes(MacCLICore.creationAlarmMinutes([0, -3, 60])), [0, -3],
   "explicit nonpositive alarms still flagged after creation pass-through")

do {
    let env = MacCLICore.alarmValidationErrorJSON(invalid: [0, -3])
    check(env["ok"] as? Bool == false, "alarm error ok=false")
    eq(env["error"] as? String, "invalid_alarm", "alarm error code")
    eq(env["invalid"] as? [Int] ?? [], [0, -3], "alarm error echoes offending minutes")
    check(JSONSerialization.isValidJSONObject(env), "alarm error JSON-serializable")
}

// MARK: - Calendar: rich event serialization (compat keys preserved + additive rich fields)
do {
    // Minimal event: only the six backward-compatible keys, no optional-null noise.
    let d = MacCLICore.calendarEventJSON(
        id: "EV-1", title: "Standup", calendar: "Work", source: nil,
        start: "2026-07-18T17:00:00Z", end: "2026-07-18T17:30:00Z", allDay: false,
        location: nil, notes: nil, url: nil, timeZone: nil,
        created: nil, lastModified: nil, status: nil, availability: nil,
        hasRecurrence: false, organizer: nil, attendees: [], alarmsMinutes: [])
    eq(d["id"] as? String, "EV-1", "compat id")
    eq(d["title"] as? String, "Standup", "compat title")
    eq(d["calendar"] as? String, "Work", "compat calendar")
    eq(d["start"] as? String, "2026-07-18T17:00:00Z", "compat start")
    eq(d["end"] as? String, "2026-07-18T17:30:00Z", "compat end")
    check(d["all_day"] as? Bool == false, "compat all_day")
    check(d["location"] == nil, "no location key when nil")
    check(d["notes"] == nil, "no notes key when nil")
    check(d["source"] == nil, "no source key when nil")
    check(d["url"] == nil, "no url key when nil")
    check(d["attendees"] == nil, "no attendees key when empty")
    check(d["alarms"] == nil, "no alarms key when empty")
    check(JSONSerialization.isValidJSONObject(d), "minimal event dict JSON-serializable")
}
do {
    // Rich event: every optional field present flows through verbatim.
    let d = MacCLICore.calendarEventJSON(
        id: "EV-2", title: "Show", calendar: "Gigs", source: "iCloud",
        start: "2026-07-20T02:00:00Z", end: "2026-07-20T05:00:00Z", allDay: false,
        location: "The Fonda", notes: "load-in 3pm", url: "https://x.example/e",
        timeZone: "America/Los_Angeles", created: "2026-07-01T00:00:00Z",
        lastModified: "2026-07-10T00:00:00Z", status: "confirmed", availability: "busy",
        hasRecurrence: true, organizer: "promoter@example.com",
        attendees: ["a@example.com", "b@example.com"], alarmsMinutes: [1440, 60])
    eq(d["source"] as? String, "iCloud", "rich source")
    eq(d["location"] as? String, "The Fonda", "rich location")
    eq(d["notes"] as? String, "load-in 3pm", "rich notes")
    eq(d["url"] as? String, "https://x.example/e", "rich url")
    eq(d["timezone"] as? String, "America/Los_Angeles", "rich timezone")
    eq(d["created"] as? String, "2026-07-01T00:00:00Z", "rich created")
    eq(d["last_modified"] as? String, "2026-07-10T00:00:00Z", "rich last_modified")
    eq(d["status"] as? String, "confirmed", "rich status")
    eq(d["availability"] as? String, "busy", "rich availability")
    check(d["recurring"] as? Bool == true, "rich recurring flag")
    eq(d["organizer"] as? String, "promoter@example.com", "rich organizer")
    eq(d["attendees"] as? [String] ?? [], ["a@example.com", "b@example.com"], "rich attendees")
    eq(d["alarms"] as? [Int] ?? [], [1440, 60], "rich alarms minutes")
    check(JSONSerialization.isValidJSONObject(d), "rich event dict JSON-serializable")
}

// MARK: - Calendar: export envelope (events / count / calendars / filter)
do {
    let e1 = MacCLICore.calendarEventJSON(
        id: "EV-1", title: "A", calendar: "Work", source: nil,
        start: "2026-07-18T17:00:00Z", end: "2026-07-18T18:00:00Z", allDay: false,
        location: nil, notes: nil, url: nil, timeZone: nil, created: nil,
        lastModified: nil, status: nil, availability: nil, hasRecurrence: false,
        organizer: nil, attendees: [], alarmsMinutes: [])
    let env = MacCLICore.calendarExportEnvelope(events: [e1], calendars: ["Work", "Home"], filter: nil)
    check(env["ok"] as? Bool == true, "export envelope ok=true")
    eq(env["status"] as? String, "ok", "export envelope status")
    eq(env["count"] as? Int, 1, "export envelope count matches events")
    eq(env["calendars"] as? [String] ?? [], ["Work", "Home"], "export envelope lists calendars")
    check(env["filter"] is NSNull, "nil filter serializes as JSON null")
    check((env["events"] as? [[String: Any]])?.count == 1, "export envelope carries events array")
    check(JSONSerialization.isValidJSONObject(env), "export envelope JSON-serializable")
}
do {
    // Fail-closed ingestion: an unknown filter yields zero events AND zero calendars, never all.
    let env = MacCLICore.calendarExportEnvelope(events: [], calendars: [], filter: "___NOPE___")
    eq(env["count"] as? Int, 0, "unknown filter => zero count")
    eq(env["calendars"] as? [String] ?? [], [], "unknown filter => zero calendars, never all")
    eq(env["filter"] as? String, "___NOPE___", "export envelope echoes requested filter")
    check((env["events"] as? [[String: Any]])?.isEmpty == true, "unknown filter => empty events")
}

// MARK: - Summary
if failures == 0 {
    print("ok — \(checks) checks passed")
    exit(0)
} else {
    FileHandle.standardError.write(Data("\(failures)/\(checks) checks FAILED\n".utf8))
    exit(1)
}
