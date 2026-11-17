import XCTest
@testable import MacCLICore

final class AuthorizationTests: XCTestCase {
    func testStatusNamesAreStableAcrossRawValues() {
        XCTAssertEqual(MacCLICore.authorizationStatusName(0), "notDetermined")
        XCTAssertEqual(MacCLICore.authorizationStatusName(1), "restricted")
        XCTAssertEqual(MacCLICore.authorizationStatusName(2), "denied")
        XCTAssertEqual(MacCLICore.authorizationStatusName(3), "authorized")
        XCTAssertEqual(MacCLICore.authorizationStatusName(4), "writeOnly")
        XCTAssertEqual(MacCLICore.authorizationStatusName(99), "unknown")
    }

    func testCanReadOnlyWhenAuthorized() {
        XCTAssertTrue(MacCLICore.authorizationCanRead(3))
        for raw in [0, 1, 2, 4, 99] {
            XCTAssertFalse(MacCLICore.authorizationCanRead(raw), "raw \(raw) must not read")
        }
    }
}

final class ListResolutionTests: XCTestCase {
    let titles = ["Work", "Groceries", "Cara / Tour", "Work"]

    func testNilFilterSelectsAll() {
        let r = MacCLICore.resolveReminderLists(allTitles: titles, filter: nil)
        XCTAssertEqual(r, MacCLICore.ListResolution(indices: [0, 1, 2, 3], failClosed: false))
    }

    func testExactMatchSelectsThatList() {
        let r = MacCLICore.resolveReminderLists(allTitles: titles, filter: "Groceries")
        XCTAssertEqual(r.indices, [1])
        XCTAssertFalse(r.failClosed)
    }

    func testDuplicateTitlesSelectAllMatches() {
        let r = MacCLICore.resolveReminderLists(allTitles: titles, filter: "Work")
        XCTAssertEqual(r.indices, [0, 3])
        XCTAssertFalse(r.failClosed)
    }

    // The load-bearing security property: a nonexistent list must NEVER broaden to all.
    func testNonexistentListFailsClosed() {
        let r = MacCLICore.resolveReminderLists(allTitles: titles, filter: "___NOPE___")
        XCTAssertEqual(r.indices, [], "nonexistent list must select zero lists")
        XCTAssertTrue(r.failClosed, "nonexistent list must be flagged fail-closed")
    }

    func testFilterIsExactNotSubstring() {
        let r = MacCLICore.resolveReminderLists(allTitles: titles, filter: "Work / Tour")
        XCTAssertTrue(r.failClosed)
        XCTAssertEqual(r.indices, [])
    }
}

final class PriorityBandTests: XCTestCase {
    func testBands() {
        XCTAssertEqual(MacCLICore.priorityBand(0), "none")
        XCTAssertEqual(MacCLICore.priorityBand(1), "high")
        XCTAssertEqual(MacCLICore.priorityBand(4), "high")
        XCTAssertEqual(MacCLICore.priorityBand(5), "medium")
        XCTAssertEqual(MacCLICore.priorityBand(6), "low")
        XCTAssertEqual(MacCLICore.priorityBand(9), "low")
    }
}

final class ApprovalTokenTests: XCTestCase {
    func testValidOnlyWhenExpectedIsNonEmptyAndMatches() {
        XCTAssertTrue(MacCLICore.isApprovalTokenValid(supplied: "s3cret", expected: "s3cret"))
    }

    func testInvalidWhenNoTokenSupplied() {
        XCTAssertFalse(MacCLICore.isApprovalTokenValid(supplied: nil, expected: "s3cret"))
    }

    func testInvalidWhenNoTokenConfigured() {
        XCTAssertFalse(MacCLICore.isApprovalTokenValid(supplied: "s3cret", expected: nil))
    }

    func testInvalidWhenConfiguredTokenIsEmpty() {
        // An unset/empty env token can NEVER authorize a write.
        XCTAssertFalse(MacCLICore.isApprovalTokenValid(supplied: "", expected: ""))
        XCTAssertFalse(MacCLICore.isApprovalTokenValid(supplied: "anything", expected: ""))
    }

    func testInvalidOnMismatch() {
        XCTAssertFalse(MacCLICore.isApprovalTokenValid(supplied: "wrong", expected: "s3cret"))
    }

    func testDenialReasonsNeverLeakTokenValue() {
        let secret = "TOP-SECRET-TOKEN-123"
        let r1 = MacCLICore.approvalDenialReason(supplied: nil, expected: secret)
        XCTAssertTrue(r1.lowercased().contains("dry-run") || r1.lowercased().contains("no --approve"))
        XCTAssertFalse(r1.contains(secret))

        let r2 = MacCLICore.approvalDenialReason(supplied: "x", expected: nil)
        XCTAssertTrue(r2.lowercased().contains("configured") || r2.lowercased().contains("cannot be verified"))
        XCTAssertFalse(r2.contains(secret))

        let r3 = MacCLICore.approvalDenialReason(supplied: "x", expected: secret)
        XCTAssertTrue(r3.lowercased().contains("does not match") || r3.lowercased().contains("mismatch"))
        XCTAssertFalse(r3.contains(secret))
        XCTAssertFalse(r3.contains("x"), "reason must not echo the supplied token either")
    }

    // P1-1: reminder completion has exactly ONE write decision — `isApprovalTokenValid`.
    // The retired `done` command never reaches it (it constructs no EventKit store),
    // and `complete`/`complete-safe` route their only mutation through it. This matrix
    // proves the gate authorizes a write ONLY for an exact, non-empty token match —
    // every no-token, empty-token, and mismatch case fails closed.
    func testCompletionGateAuthorizesOnlyExactNonEmptyMatch() {
        let secret = "s3cret"
        let suppliedCases: [String?] = [nil, "", "wrong", " s3cret", "s3cret ", secret]
        let expectedCases: [String?] = [nil, "", secret]
        for supplied in suppliedCases {
            for expected in expectedCases {
                let shouldWrite = (supplied == secret && expected == secret)
                XCTAssertEqual(
                    MacCLICore.isApprovalTokenValid(supplied: supplied, expected: expected),
                    shouldWrite,
                    "supplied=\(String(describing: supplied)) expected=\(String(describing: expected)) "
                        + "must \(shouldWrite ? "authorize" : "refuse") the write")
            }
        }
    }
}

final class FetchTimeoutEnvelopeTests: XCTestCase {
    func testEnvelopeSignalsHardErrorNotEmptyResult() {
        let env = MacCLICore.fetchTimeoutErrorJSON(timeoutSeconds: 0.001)
        XCTAssertEqual(env["ok"] as? Bool, false)
        XCTAssertEqual(env["status"] as? String, "error")
        XCTAssertEqual(env["error"] as? String, "fetch_timeout")
        XCTAssertEqual(env["entity"] as? String, "reminder")
        XCTAssertEqual(env["timeout_seconds"] as? Double, 0.001)
        // A timeout envelope must NEVER look like an empty successful export.
        XCTAssertNil(env["reminders"], "timeout envelope must not carry a rows array")
        XCTAssertNil(env["count"], "timeout envelope must not carry a count")
    }

    func testEnvelopeIsJSONSerializable() {
        let env = MacCLICore.fetchTimeoutErrorJSON(timeoutSeconds: 25)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(env))
        let data = try? JSONSerialization.data(withJSONObject: env)
        XCTAssertNotNil(data)
    }
}

final class CalendarFilterTests: XCTestCase {
    let calTitles = ["Home", "Work", "Familia", "Work"]

    func testNilFilterSelectsAllLinkedCalendars() {
        let r = MacCLICore.resolveCalendarFilter(allTitles: calTitles, filter: nil)
        XCTAssertEqual(r, MacCLICore.ListResolution(indices: [0, 1, 2, 3], failClosed: false))
    }

    func testExactCalendarMatch() {
        let r = MacCLICore.resolveCalendarFilter(allTitles: calTitles, filter: "Familia")
        XCTAssertEqual(r.indices, [2])
        XCTAssertFalse(r.failClosed)
    }

    func testDuplicateCalendarTitlesSelectAllMatches() {
        let r = MacCLICore.resolveCalendarFilter(allTitles: calTitles, filter: "Work")
        XCTAssertEqual(r.indices, [1, 3])
    }

    // Ingestion security property: an unknown calendar must select zero, never all.
    func testUnknownCalendarFailsClosed() {
        let r = MacCLICore.resolveCalendarFilter(allTitles: calTitles, filter: "___NOPE___")
        XCTAssertEqual(r.indices, [], "unknown calendar must select zero calendars")
        XCTAssertTrue(r.failClosed, "unknown calendar must be flagged fail-closed")
    }
}

final class CalendarDateRangeTests: XCTestCase {
    func testInclusiveRangeIsValid() {
        XCTAssertTrue(MacCLICore.validateDateRange(startEpoch: 1000, endEpoch: 2000).valid)
        XCTAssertNil(MacCLICore.validateDateRange(startEpoch: 1000, endEpoch: 2000).reason)
        XCTAssertTrue(MacCLICore.validateDateRange(startEpoch: 2000, endEpoch: 2000).valid, "from == to is inclusive")
    }

    func testMisorderedRangeIsInvalid() {
        let v = MacCLICore.validateDateRange(startEpoch: 3000, endEpoch: 2000)
        XCTAssertFalse(v.valid)
        XCTAssertNotNil(v.reason)
    }

    func testRangeErrorEnvelope() {
        let env = MacCLICore.dateRangeErrorJSON(from: "2026-07-10", to: "2026-07-01")
        XCTAssertEqual(env["ok"] as? Bool, false)
        XCTAssertEqual(env["status"] as? String, "error")
        XCTAssertEqual(env["error"] as? String, "invalid_date_range")
        XCTAssertEqual(env["from"] as? String, "2026-07-10")
        XCTAssertEqual(env["to"] as? String, "2026-07-01")
        XCTAssertNil(env["events"], "range error must not carry an events array")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(env))
    }

    func testDateParseErrorEnvelope() {
        let env = MacCLICore.dateParseErrorJSON(field: "from", value: "not-a-date")
        XCTAssertEqual(env["error"] as? String, "invalid_date")
        XCTAssertEqual(env["field"] as? String, "from")
        XCTAssertEqual(env["value"] as? String, "not-a-date")
        XCTAssertEqual(env["ok"] as? Bool, false)
    }

    // Access failures on `calendar export`/`events --json` become a stable, redacted
    // machine error — no calendar content, no raw localized system strings, and no
    // rows/count keys that could be mistaken for an empty successful result.
    func testAccessErrorEnvelopeIsRedactedAndStructured() {
        let env = MacCLICore.accessErrorJSON(entity: "calendar")
        XCTAssertEqual(env["ok"] as? Bool, false)
        XCTAssertEqual(env["status"] as? String, "error")
        XCTAssertEqual(env["error"] as? String, "access_denied")
        XCTAssertEqual(env["entity"] as? String, "calendar")
        XCTAssertNil(env["events"], "access error must not carry an events array")
        XCTAssertNil(env["calendars"], "access error must not carry a calendars array")
        XCTAssertNil(env["count"], "access error must not carry a count")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(env))
    }
}

final class CalendarDeleteModeTests: XCTestCase {
    func testIdOnlyIsById() {
        XCTAssertEqual(MacCLICore.resolveDeleteMode(id: "EV-123", title: nil, date: nil), .byId("EV-123"))
    }

    func testTitleAndDateIsByTitleDate() {
        XCTAssertEqual(
            MacCLICore.resolveDeleteMode(id: nil, title: "Dentist", date: "2026-07-10"),
            .byTitleDate(title: "Dentist", date: "2026-07-10"))
    }

    func testMutuallyExclusiveAndIncompleteModesAreInvalid() {
        func isInvalid(_ m: MacCLICore.CalendarDeleteMode) -> Bool { if case .invalid = m { return true }; return false }
        XCTAssertTrue(isInvalid(MacCLICore.resolveDeleteMode(id: "EV-1", title: "X", date: nil)))
        XCTAssertTrue(isInvalid(MacCLICore.resolveDeleteMode(id: "EV-1", title: nil, date: "2026-07-10")))
        XCTAssertTrue(isInvalid(MacCLICore.resolveDeleteMode(id: "EV-1", title: "X", date: "2026-07-10")))
        XCTAssertTrue(isInvalid(MacCLICore.resolveDeleteMode(id: nil, title: "X", date: nil)))
        XCTAssertTrue(isInvalid(MacCLICore.resolveDeleteMode(id: nil, title: nil, date: "2026-07-10")))
        XCTAssertTrue(isInvalid(MacCLICore.resolveDeleteMode(id: nil, title: nil, date: nil)))
    }

    func testNotFoundEnvelope() {
        let env = MacCLICore.calendarDeleteNotFoundJSON(id: "EV-404")
        XCTAssertEqual(env["ok"] as? Bool, false)
        XCTAssertEqual(env["error"] as? String, "event_not_found")
        XCTAssertEqual(env["id"] as? String, "EV-404")
        XCTAssertEqual(env["deleted"] as? Bool, false)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(env))
    }

    func testDeleteResultCarriesNoPrivateContent() {
        let env = MacCLICore.calendarDeleteResultJSON(id: "EV-9", deleted: true)
        XCTAssertEqual(env["ok"] as? Bool, true)
        XCTAssertEqual(env["id"] as? String, "EV-9")
        XCTAssertEqual(env["deleted"] as? Bool, true)
        XCTAssertNil(env["title"], "id-mode delete result must not carry a title")
        XCTAssertNil(env["notes"], "id-mode delete result must not carry notes")
    }
}

final class CalendarAlarmTests: XCTestCase {
    func testOffsetConversion() {
        XCTAssertEqual(MacCLICore.alarmOffsetSeconds(minutesBefore: 60), -3600)
        XCTAssertEqual(MacCLICore.alarmOffsetSeconds(minutesBefore: 1), -60)
        XCTAssertEqual(MacCLICore.alarmOffsetSeconds(minutesBefore: 1440), -86400)
    }

    func testNonPositiveMinutesAreInvalid() {
        XCTAssertNil(MacCLICore.alarmOffsetSeconds(minutesBefore: 0))
        XCTAssertNil(MacCLICore.alarmOffsetSeconds(minutesBefore: -5))
    }

    func testInvalidMinutesDetection() {
        XCTAssertEqual(MacCLICore.invalidAlarmMinutes([15, 60, 1440]), [])
        XCTAssertEqual(MacCLICore.invalidAlarmMinutes([15, 0, -3, 60]), [0, -3])
    }

    func testOffsetsPreserveOrder() {
        XCTAssertEqual(MacCLICore.alarmOffsets([1440, 60]), [-86400, -3600])
    }

    // P1 #1: `calendar create` inserts ZERO default alarms. An empty --alarm yields an
    // empty minute list AND empty offsets — never a silent [1440, 60] default.
    func testCreationAlarmsAreExplicitOnlyNoDefault() {
        XCTAssertEqual(MacCLICore.creationAlarmMinutes([]), [], "no --alarm must add zero alarm minutes")
        XCTAssertEqual(MacCLICore.alarmOffsets(MacCLICore.creationAlarmMinutes([])), [],
                       "no --alarm must produce zero alarm offsets (no default insertion)")
    }

    func testCreationAlarmsPassExplicitValuesThrough() {
        XCTAssertEqual(MacCLICore.creationAlarmMinutes([1440, 60]), [1440, 60])
        XCTAssertEqual(MacCLICore.alarmOffsets(MacCLICore.creationAlarmMinutes([1440, 60])), [-86400, -3600])
        // Nonpositive validation still applies to explicit values.
        XCTAssertEqual(MacCLICore.invalidAlarmMinutes(MacCLICore.creationAlarmMinutes([0, -3, 60])), [0, -3])
    }

    func testAlarmValidationEnvelope() {
        let env = MacCLICore.alarmValidationErrorJSON(invalid: [0, -3])
        XCTAssertEqual(env["ok"] as? Bool, false)
        XCTAssertEqual(env["error"] as? String, "invalid_alarm")
        XCTAssertEqual(env["invalid"] as? [Int], [0, -3])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(env))
    }
}

final class CalendarEventSerializationTests: XCTestCase {
    func testMinimalEventKeepsCompatKeysOnly() {
        let d = MacCLICore.calendarEventJSON(
            id: "EV-1", title: "Standup", calendar: "Work", source: nil,
            start: "2026-07-18T17:00:00Z", end: "2026-07-18T17:30:00Z", allDay: false,
            location: nil, notes: nil, url: nil, timeZone: nil,
            created: nil, lastModified: nil, status: nil, availability: nil,
            hasRecurrence: false, organizer: nil, attendees: [], alarmsMinutes: [])
        XCTAssertEqual(d["id"] as? String, "EV-1")
        XCTAssertEqual(d["title"] as? String, "Standup")
        XCTAssertEqual(d["calendar"] as? String, "Work")
        XCTAssertEqual(d["start"] as? String, "2026-07-18T17:00:00Z")
        XCTAssertEqual(d["end"] as? String, "2026-07-18T17:30:00Z")
        XCTAssertEqual(d["all_day"] as? Bool, false)
        for absent in ["location", "notes", "source", "url", "attendees", "alarms"] {
            XCTAssertNil(d[absent], "\(absent) must be absent when not provided")
        }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(d))
    }

    func testRichEventFlowsThroughVerbatim() {
        let d = MacCLICore.calendarEventJSON(
            id: "EV-2", title: "Show", calendar: "Gigs", source: "iCloud",
            start: "2026-07-20T02:00:00Z", end: "2026-07-20T05:00:00Z", allDay: false,
            location: "The Fonda", notes: "load-in 3pm", url: "https://x.example/e",
            timeZone: "America/Los_Angeles", created: "2026-07-01T00:00:00Z",
            lastModified: "2026-07-10T00:00:00Z", status: "confirmed", availability: "busy",
            hasRecurrence: true, organizer: "promoter@example.com",
            attendees: ["a@example.com", "b@example.com"], alarmsMinutes: [1440, 60])
        XCTAssertEqual(d["source"] as? String, "iCloud")
        XCTAssertEqual(d["location"] as? String, "The Fonda")
        XCTAssertEqual(d["notes"] as? String, "load-in 3pm")
        XCTAssertEqual(d["url"] as? String, "https://x.example/e")
        XCTAssertEqual(d["timezone"] as? String, "America/Los_Angeles")
        XCTAssertEqual(d["created"] as? String, "2026-07-01T00:00:00Z")
        XCTAssertEqual(d["last_modified"] as? String, "2026-07-10T00:00:00Z")
        XCTAssertEqual(d["status"] as? String, "confirmed")
        XCTAssertEqual(d["availability"] as? String, "busy")
        XCTAssertEqual(d["recurring"] as? Bool, true)
        XCTAssertEqual(d["organizer"] as? String, "promoter@example.com")
        XCTAssertEqual(d["attendees"] as? [String], ["a@example.com", "b@example.com"])
        XCTAssertEqual(d["alarms"] as? [Int], [1440, 60])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(d))
    }

    func testExportEnvelopeShape() {
        let e1 = MacCLICore.calendarEventJSON(
            id: "EV-1", title: "A", calendar: "Work", source: nil,
            start: "2026-07-18T17:00:00Z", end: "2026-07-18T18:00:00Z", allDay: false,
            location: nil, notes: nil, url: nil, timeZone: nil, created: nil,
            lastModified: nil, status: nil, availability: nil, hasRecurrence: false,
            organizer: nil, attendees: [], alarmsMinutes: [])
        let env = MacCLICore.calendarExportEnvelope(events: [e1], calendars: ["Work", "Home"], filter: nil)
        XCTAssertEqual(env["ok"] as? Bool, true)
        XCTAssertEqual(env["status"] as? String, "ok")
        XCTAssertEqual(env["count"] as? Int, 1)
        XCTAssertEqual(env["calendars"] as? [String], ["Work", "Home"])
        XCTAssertTrue(env["filter"] is NSNull, "nil filter must serialize as JSON null")
        XCTAssertEqual((env["events"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(env))
    }

    // Fail-closed ingestion: an unknown filter yields zero events AND zero calendars.
    func testExportEnvelopeUnknownFilterIsZeroNeverAll() {
        let env = MacCLICore.calendarExportEnvelope(events: [], calendars: [], filter: "___NOPE___")
        XCTAssertEqual(env["count"] as? Int, 0)
        XCTAssertEqual(env["calendars"] as? [String], [])
        XCTAssertEqual(env["filter"] as? String, "___NOPE___")
        XCTAssertTrue((env["events"] as? [[String: Any]])?.isEmpty == true)
    }
}

final class NotesDecodeTests: XCTestCase {
    /// Encode one length-delimited protobuf field (wire type 2).
    private func protoField(_ fieldNumber: Int, _ payload: Data) -> Data {
        var out = Data()
        let tag = UInt64(fieldNumber << 3 | 2)
        out.append(varint(tag))
        out.append(varint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    private func varint(_ v: UInt64) -> Data {
        var value = v
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    func testGunzipPassthroughWhenNotGzip() {
        let plain = Data("not gzipped".utf8)
        XCTAssertEqual(MacCLICore.gunzipIfNeeded(plain), plain)
    }

    func testExtractPreservesUnicodeBody() {
        // Apple Notes bodies wrap the plain text in protobuf field 2.
        let body = "Café ☕ déjà vu — 日本語 — Ñoño"
        let proto = protoField(2, Data(body.utf8))
        let extracted = MacCLICore.extractProtobufText(proto, minAlphaRatio: 0.3, minLen: 4)
        XCTAssertTrue(extracted.contains(body), "Unicode body must survive extraction verbatim")
    }

    func testStructuralBodiesPreserveContent() {
        for body in ["12345 / 67890", "12-34.56!", "?!", "a", "", "  \n", "Café ☕ 日本語"] {
            let note = protoField(2, Data(body.utf8)) + protoField(3, Data("Metadata longer than body".utf8))
            let proto = protoField(2, protoField(3, note))
            XCTAssertEqual(MacCLICore.decodeNoteBody(proto), body)
            XCTAssertNil(MacCLICore.decodeNoteBody(proto, isProtected: true))
        }
    }

    func testStructuralDecodeFailsClosed() {
        let valid = protoField(2, protoField(3, protoField(2, Data("ok".utf8))))
        let invalid: [Data] = [
            protoField(2, Data("unsupported direct text".utf8)),
            protoField(2, protoField(3, protoField(2, Data([0xff])))),
            valid + Data([0]), valid + Data([0x80]),
            protoField(2, protoField(3, Data([0x12, 0x7f, 0x61]))),
            protoField(2, protoField(3, protoField(2, Data()) + protoField(2, Data()))),
            valid + Data([0x1d, 0x00]),
            valid + Data([0x20] + Array(repeating: 0xff, count: 10)),
            Data([0x1f, 0x8b, 0x08])
        ]
        for fixture in invalid { XCTAssertNil(MacCLICore.decodeNoteBody(fixture)) }
    }

    func testGzipBodyAndIntegrity() {
        let gzip = Data([31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 19, 18, 148, 226, 23, 226, 53, 52, 50, 54, 49, 85, 208, 87, 48, 51, 183, 176, 52, 0, 0, 16, 221, 218, 156, 19, 0, 0, 0])
        XCTAssertEqual(MacCLICore.decodeNoteBody(gzip), "12345 / 67890")
        var badCRC = gzip; badCRC[badCRC.count - 8] ^= 1
        var badSize = gzip; badSize[badSize.count - 4] ^= 1
        var badPayload = gzip; badPayload[10] ^= 0xff
        for fixture in [badCRC, badSize, badPayload, Data(gzip.dropLast())] {
            XCTAssertNil(MacCLICore.decodeNoteBody(fixture))
        }
    }

    func testDecodeNoteBodyReturnsNilOnGarbage() {
        XCTAssertNil(MacCLICore.decodeNoteBody(Data([0x00, 0x01, 0x02])))
    }
}

// MARK: - Contacts serialization (job_title parity for add-only verified enrichment)

final class ContactGetSerializationTests: XCTestCase {
    func testJobTitleFlowsThroughWithPreExistingKeys() {
        let d = MacCLICore.contactGetJSON(
            id: "C-1", name: "Ada Lovelace", organization: "Analytical Engines",
            jobTitle: "Chief Mathematician",
            phones: [["label": "mobile", "number": "+13105550100"]],
            emails: [["label": "work", "email": "ada@example.com"]],
            birthday: "1815-12-10")
        XCTAssertEqual(d["id"] as? String, "C-1")
        XCTAssertEqual(d["name"] as? String, "Ada Lovelace")
        XCTAssertEqual(d["organization"] as? String, "Analytical Engines")
        XCTAssertEqual(d["job_title"] as? String, "Chief Mathematician")
        XCTAssertEqual(d["birthday"] as? String, "1815-12-10")
        XCTAssertNotNil(d["phones"])
        XCTAssertNotNil(d["emails"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(d))
    }

    func testEmptyJobTitleIsEmptyStringAndBirthdayOmittedWhenNil() {
        let d = MacCLICore.contactGetJSON(
            id: "C-2", name: "No Title", organization: "",
            jobTitle: "", phones: [], emails: [], birthday: nil)
        // Matches export's convention: empty string, never null.
        XCTAssertEqual(d["job_title"] as? String, "")
        XCTAssertNil(d["birthday"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(d))
    }

    func testSpecialCharactersSurviveJSONRoundTrip() {
        let tricky = "V.P. \"Ops\" — Café ☕ 日本語"
        let d = MacCLICore.contactGetJSON(
            id: "C-3", name: "Tricky", organization: "O", jobTitle: tricky,
            phones: [], emails: [], birthday: nil)
        XCTAssertEqual(d["job_title"] as? String, tricky)
        let data = try! JSONSerialization.data(withJSONObject: d)
        let round = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(round["job_title"] as? String, tricky)
    }
}

final class ContactExportSerializationTests: XCTestCase {
    private let exportKeys = ["id", "given_name", "middle_name", "family_name", "nickname",
                              "organization", "department", "job_title", "contact_type",
                              "phones", "emails", "urls", "instant_messages", "social_profiles",
                              "relations", "postal_addresses", "dates", "birthday", "display_name"]

    func testRichExportPreservesFullKeySetIncludingJobTitle() {
        let d = MacCLICore.contactExportJSON(
            id: "C-9", givenName: "Ada", middleName: "", familyName: "Lovelace",
            nickname: "", organization: "Analytical Engines", department: "R&D",
            jobTitle: "Chief Mathematician", contactType: "person",
            phones: [], emails: [], urls: [], instantMessages: [], socialProfiles: [],
            relations: [], postalAddresses: [], dates: [],
            birthday: "1815-12-10", displayName: "Ada Lovelace")
        XCTAssertEqual(d["id"] as? String, "C-9")
        XCTAssertEqual(d["given_name"] as? String, "Ada")
        XCTAssertEqual(d["job_title"] as? String, "Chief Mathematician")
        XCTAssertEqual(d["contact_type"] as? String, "person")
        XCTAssertEqual(d["birthday"] as? String, "1815-12-10")
        XCTAssertEqual(d["display_name"] as? String, "Ada Lovelace")
        for k in exportKeys { XCTAssertNotNil(d[k], "export must preserve key \(k)") }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(d))
    }

    func testAbsentScalarsKeepPreExistingConventions() {
        let d = MacCLICore.contactExportJSON(
            id: "C-10", givenName: "", middleName: "", familyName: "", nickname: "",
            organization: "", department: "", jobTitle: "", contactType: "person",
            phones: [], emails: [], urls: [], instantMessages: [], socialProfiles: [],
            relations: [], postalAddresses: [], dates: [],
            birthday: NSNull(), displayName: NSNull())
        XCTAssertEqual(d["job_title"] as? String, "")
        XCTAssertTrue(d["birthday"] is NSNull)
        XCTAssertTrue(d["display_name"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(d))
    }

    func testJobTitleSpecialCharactersSurviveJSONRoundTrip() {
        let tricky = "Señor \"Boss\" 🎛️ — 日本語"
        let d = MacCLICore.contactExportJSON(
            id: "C-11", givenName: "T", middleName: "", familyName: "", nickname: "",
            organization: "", department: "", jobTitle: tricky, contactType: "person",
            phones: [], emails: [], urls: [], instantMessages: [], socialProfiles: [],
            relations: [], postalAddresses: [], dates: [],
            birthday: NSNull(), displayName: "T")
        XCTAssertEqual(d["job_title"] as? String, tricky)
        let data = try! JSONSerialization.data(withJSONObject: d)
        let round = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(round["job_title"] as? String, tricky)
    }
}

final class ErrorContractTests: XCTestCase {
    func testExitCodesFollowTheTable() {
        for code in ["usage", "invalid_argument", "invalid_date", "invalid_date_range", "invalid_alarm"] {
            XCTAssertEqual(MacCLICore.exitCode(forErrorCode: code), 64, code)
        }
        for code in ["not_found", "calendar_not_found", "event_not_found"] {
            XCTAssertEqual(MacCLICore.exitCode(forErrorCode: code), 3, code)
        }
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode: "capability_denied"), 4)
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode: "access_denied"), 4)
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode: "timeout"), 5)
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode: "fetch_timeout"), 5)
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode: "app_error"), 6)
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode: "something_new"), 6)
    }

    func testEnvelopeKeepsContractKeysOverExtras() {
        let env = MacCLICore.errorEnvelope(code: "not_found", message: "gone", hint: "look elsewhere",
                                           extra: ["ok": true, "error": "spoofed", "id": "x"])
        XCTAssertEqual(env["ok"] as? Bool, false)
        XCTAssertEqual(env["status"] as? String, "error")
        XCTAssertEqual(env["error"] as? String, "not_found")
        XCTAssertEqual(env["message"] as? String, "gone")
        XCTAssertEqual(env["hint"] as? String, "look elsewhere")
        XCTAssertEqual(env["exit_code"] as? Int, 3)
        XCTAssertEqual(env["id"] as? String, "x")
        XCTAssertNil(MacCLICore.errorEnvelope(code: "timeout", message: "slow")["hint"])
    }

    func testMachineErrorsForJSONFlagAndExports() {
        XCTAssertTrue(MacCLICore.wantsMachineErrors(arguments: ["calendar", "events", "--json"]))
        XCTAssertTrue(MacCLICore.wantsMachineErrors(arguments: ["notes", "export"]))
        XCTAssertTrue(MacCLICore.wantsMachineErrors(arguments: ["reminders", "export", "--list", "x"]))
        XCTAssertFalse(MacCLICore.wantsMachineErrors(arguments: ["calendar", "events"]))
        XCTAssertFalse(MacCLICore.wantsMachineErrors(arguments: ["file", "read", "export"]))
        XCTAssertFalse(MacCLICore.wantsMachineErrors(arguments: ["script", "run", "--", "--json"]))
    }
}

final class AgentTrustTests: XCTestCase {
    let calendars = [
        MacCLICore.CalendarRef(id: "A", title: "Work", source: "iCloud"),
        MacCLICore.CalendarRef(id: "B", title: "Home", source: "iCloud"),
        MacCLICore.CalendarRef(id: "C", title: "Work", source: "Exchange"),
    ]

    func testCalendarIdNamesExactlyOne() {
        XCTAssertEqual(MacCLICore.selectCalendar(calendars, name: nil, id: "C", forWrite: true), .calendar(2))
        guard case .failure(let env) = MacCLICore.selectCalendar(calendars, name: nil, id: "Z", forWrite: false) else {
            return XCTFail("unknown id is an error")
        }
        XCTAssertEqual(env["error"] as? String, "calendar_not_found")
        XCTAssertEqual(env["exit_code"] as? Int, 3)
        XCTAssertEqual(env["calendar_id"] as? String, "Z")
    }

    func testWriteToSharedNameIsRefusedWithBothIds() {
        guard case .failure(let env) = MacCLICore.selectCalendar(calendars, name: "Work", id: nil, forWrite: true) else {
            return XCTFail("a write to a shared name must be refused")
        }
        XCTAssertEqual(env["error"] as? String, "ambiguous_calendar")
        XCTAssertEqual(env["exit_code"] as? Int, 64)
        let ids = (env["candidates"] as? [[String: String]])?.compactMap { $0["id"] }
        XCTAssertEqual(ids, ["A", "C"])
        XCTAssertTrue((env["hint"] as? String ?? "").contains("--calendar-id"))
    }

    func testReadBySharedNameTakesEveryMatch() {
        XCTAssertEqual(MacCLICore.selectCalendar(calendars, name: "Work", id: nil, forWrite: false), .calendars([0, 2]))
        XCTAssertEqual(MacCLICore.selectCalendar(calendars, name: "Home", id: nil, forWrite: true), .calendar(1))
        XCTAssertEqual(MacCLICore.selectCalendar(calendars, name: nil, id: nil, forWrite: true), .none)
    }

    func testNameAndIdTogetherIsUsage() {
        guard case .failure(let env) = MacCLICore.selectCalendar(calendars, name: "Home", id: "B", forWrite: true) else {
            return XCTFail("both is an error")
        }
        XCTAssertEqual(env["exit_code"] as? Int, 64)
    }

    func testPrivacyStateVocabulary() {
        XCTAssertEqual((0...4).map { MacCLICore.privacyState(eventKitOrContactsRaw: $0) },
                       ["not_determined", "restricted", "denied", "granted", "write_only"])
        XCTAssertEqual(MacCLICore.privacyState(eventKitOrContactsRaw: 9), "unknown")
    }

    func testDoctorReportIsReadyOnlyWhenEveryAreaIsGranted() {
        let granted = MacCLICore.PrivacyArea(id: "calendars", state: "granted", neededBy: ["calendar"],
                                             hint: "grant it", authorize: "macos authorize calendars")
        let missing = MacCLICore.PrivacyArea(id: "contacts", state: "not_determined", neededBy: ["contacts"],
                                             hint: "grant it", authorize: "macos authorize contacts")
        XCTAssertNil(granted.hint, "a granted area carries no hint")
        let report = MacCLICore.doctorReport(areas: [granted, missing], binary: [:], session: [:], capabilities: [:])
        XCTAssertEqual(report["ready"] as? Bool, false)
        XCTAssertEqual(report["missing"] as? [String], ["contacts"])
        let areas = report["areas"] as? [[String: Any]]
        XCTAssertEqual(areas?.last?["granted"] as? Bool, false)
        XCTAssertEqual(areas?.last?["hint"] as? String, "grant it")
        XCTAssertEqual(MacCLICore.doctorReport(areas: [granted], binary: [:], session: [:], capabilities: [:])["ready"]
                       as? Bool, true)
    }

    func testSinceTakesISODateTimeOrDay() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(MacCLICore.parseSince("2026-11-10T09:00:00-08:00", timeZone: utc)?.timeIntervalSince1970,
                       1_794_330_000)
        XCTAssertEqual(MacCLICore.parseSince("2026-11-10", timeZone: utc)?.timeIntervalSince1970, 1_794_268_800)
        XCTAssertNil(MacCLICore.parseSince("yesterday"))
        XCTAssertNil(MacCLICore.parseSince("2026-02-30"))
    }

    func testNewRefusalsHaveTheirExitCodes() {
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode: "person_required"), 4)
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode: "ambiguous_calendar"), 64)
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode: "invalid_timezone"), 64)
    }
}

final class ReleaseTests: XCTestCase {
    func testVersionsCompareNumericallyPartByPart() {
        XCTAssertTrue(Release.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertTrue(Release.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(Release.isNewer("0.9.1", than: "0.9"))
        XCTAssertFalse(Release.isNewer("0.9.0", than: "0.9.0"))
        XCTAssertFalse(Release.isNewer("0.8.1", than: "0.9.0"))
    }

    func testReleaseBodyGivesVersionAndAssets() throws {
        let body = #"{"tag_name":"v0.9.0","assets":[{"name":"macos-cli-0.9.0-arm64.zip","browser_download_url":"https://x/z"}]}"#
        let release = try XCTUnwrap(Release.parse(Data(body.utf8)))
        XCTAssertEqual(release.version, "0.9.0")
        XCTAssertEqual(release.assets[Release.zipName(version: "0.9.0")], "https://x/z")
        XCTAssertNil(Release.parse(Data(#"{"message":"Not Found"}"#.utf8)))
    }

    func testShaFileGivesItsHashOrNothing() {
        let hex = String(repeating: "aB", count: 32)
        XCTAssertEqual(Release.expectedSHA256("\(hex)  macos-cli-0.9.0-arm64.zip\n"), hex.lowercased())
        XCTAssertNil(Release.expectedSHA256("not a hash  file"))
        XCTAssertNil(Release.expectedSHA256(""))
    }
}

final class CatalogueTests: XCTestCase {
    /// A trimmed `--experimental-dump-help` document: a group with a nested group, a hidden
    /// command, ArgumentParser's own `help`, and a command the writes table does not name.
    let dump = #"""
    {"serializationVersion":0,"command":{"commandName":"macos","arguments":[
      {"kind":"flag","names":[{"kind":"long","name":"version"}],"shouldDisplay":true,"isOptional":true,"isRepeating":false},
      {"kind":"flag","names":[{"kind":"short","name":"h"},{"kind":"long","name":"help"}],"shouldDisplay":true,"isOptional":true,"isRepeating":false}],
     "subcommands":[
      {"commandName":"system","abstract":"System controls","subcommands":[
        {"commandName":"battery","abstract":"Battery status","arguments":[
          {"kind":"flag","names":[{"kind":"long","name":"json"}],"shouldDisplay":true,"isOptional":true,"isRepeating":false}]},
        {"commandName":"wifi","subcommands":[
          {"commandName":"join","abstract":"Join a Wi-Fi network","arguments":[
            {"kind":"positional","names":[{"kind":"long","name":"ssid"}],"shouldDisplay":true,"isOptional":false,"isRepeating":false},
            {"kind":"option","names":[{"kind":"long","name":"from"},{"kind":"long","name":"start"}],"shouldDisplay":true,"isOptional":true,"isRepeating":false},
            {"kind":"option","names":[{"kind":"short","name":"o"}],"shouldDisplay":true,"isOptional":true,"isRepeating":false},
            {"kind":"flag","names":[{"kind":"long","name":"secret"}],"shouldDisplay":false,"isOptional":true,"isRepeating":false}]}]}]},
      {"commandName":"ghost","abstract":"Hidden","shouldDisplay":false},
      {"commandName":"new-thing","abstract":"Not in the table"},
      {"commandName":"help","abstract":"Show subcommand help information."}]}}
    """#

    func testListsEveryRunnableCommandSortedWithItsFlagsAndWrites() throws {
        let writes = ["system battery": false, "system wifi join": true]
        let entries = try MacCLICore.commandCatalogue(dumpHelp: Data(dump.utf8), writes: writes)
        XCTAssertEqual(entries, [
            .init(path: "new-thing", flags: [], help: "Not in the table", writes: true),
            .init(path: "system battery", flags: ["--json"], help: "Battery status", writes: false),
            .init(path: "system wifi join", flags: ["--from", "-o"], help: "Join a Wi-Fi network", writes: true),
        ])
    }

    func testAnEntryIsFourKeysWithABoolWrites() throws {
        let entry = try XCTUnwrap(MacCLICore.commandCatalogue(dumpHelp: Data(dump.utf8), writes: [:]).first)
        XCTAssertEqual(Set(entry.json.keys), ["path", "flags", "help", "writes"])
        XCTAssertTrue(entry.json["writes"] is Bool)
    }

    func testTableMarksTheWrites() throws {
        let entries = try MacCLICore.commandCatalogue(dumpHelp: Data(dump.utf8), writes: ["system battery": false])
        let lines = MacCLICore.catalogueTable(entries).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("COMMAND"))
        XCTAssertTrue(lines[2].contains("system battery    no      Battery status"), lines[2])
    }

    func testNotADumpIsAnError() {
        XCTAssertThrowsError(try MacCLICore.commandCatalogue(dumpHelp: Data("[]".utf8)))
    }
}

final class TourConnectorTests: XCTestCase {

    // MARK: OAuth 1.0

    /// The worked example of the OAuth 1.0 specification (Appendix A.5): its base string
    /// and its signature, `tR3+Ty81lMeYAr/Fid0kMTYa/WM=`.
    func testSignatureMatchesTheSpecificationExample() {
        let base = MacCLICore.oauthBaseString(
            method: "GET", url: URL(string: "http://photos.example.net/photos")!,
            parameters: [("file", "vacation.jpg"), ("size", "original"),
                         ("oauth_consumer_key", "dpf43f3p2l4k3l03"), ("oauth_token", "nnch734d00sl2jdk"),  // gitleaks:allow (test vector)
                         ("oauth_signature_method", "HMAC-SHA1"), ("oauth_timestamp", "1191242096"),
                         ("oauth_nonce", "kllo9940pd9333jh"), ("oauth_version", "1.0")])
        XCTAssertEqual(base, "GET&http%3A%2F%2Fphotos.example.net%2Fphotos&file%3Dvacation.jpg%26oauth_consumer_key%3Ddpf43f3p2l4k3l03%26oauth_nonce%3Dkllo9940pd9333jh%26oauth_signature_method%3DHMAC-SHA1%26oauth_timestamp%3D1191242096%26oauth_token%3Dnnch734d00sl2jdk%26oauth_version%3D1.0%26size%3Doriginal")  // gitleaks:allow (test vector)
        XCTAssertEqual(MacCLICore.oauthSignature(baseString: base, consumerSecret: "kd94hf93k423kf44",
                                                 tokenSecret: "pfkkdhi9sl3r4s00"),  // gitleaks:allow (test vector)
                       "tR3+Ty81lMeYAr/Fid0kMTYa/WM=")
    }

    /// A consumer-only Master Tour request, signed by hand (Python's hmac) with a secret
    /// that needs encoding: the query, `version=7` and the oauth parameters are all signed.
    func testMasterTourHeaderIsSignedWithTheQuery() {
        let url = MacCLICore.masterTourURL(path: "tour/42", query: [("numPastDays", "0")])
        XCTAssertEqual(url.absoluteString, "https://my.eventric.com/portal/api/v5/tour/42?version=7&numPastDays=0")
        let header = MacCLICore.oauthAuthorizationHeader(method: "GET", url: url, consumerKey: "demo-key",
                                                         consumerSecret: "demo secret+/", nonce: "abc123",
                                                         timestamp: 1_700_000_000)
        XCTAssertEqual(header, #"OAuth oauth_consumer_key="demo-key", oauth_nonce="abc123", "#
            + #"oauth_signature="VTeQ0c6vTGm9ItD9Ll4XpAcOk9s%3D", oauth_signature_method="HMAC-SHA1", "#  // gitleaks:allow (test vector)
            + #"oauth_timestamp="1700000000", oauth_version="1.0""#)
    }

    /// Master Tour reads the oauth parameters from the query: the signed URL carries the same signature.
    func testMasterTourSignedURLCarriesTheOAuthParameters() {
        let url = MacCLICore.masterTourURL(path: "tour/42", query: [("numPastDays", "0")])
        let signed = MacCLICore.oauthSignedURL(method: "GET", url: url, consumerKey: "demo-key",
                                               consumerSecret: "demo secret+/", nonce: "abc123",
                                               timestamp: 1_700_000_000)
        XCTAssertEqual(signed.absoluteString, "https://my.eventric.com/portal/api/v5/tour/42?version=7&numPastDays=0"
            + "&oauth_consumer_key=demo-key&oauth_nonce=abc123&oauth_signature_method=HMAC-SHA1"
            + "&oauth_timestamp=1700000000&oauth_version=1.0&oauth_signature=VTeQ0c6vTGm9ItD9Ll4XpAcOk9s%3D")  // gitleaks:allow (test vector)
    }

    func testMissingAndRefusedCredentialsArePermissionErrors() {
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode: "credentials_missing"), 4)
        XCTAssertEqual(MacCLICore.exitCode(forErrorCode: "credentials_refused"), 4)
        XCTAssertTrue(MacCLICore.wantsMachineErrors(arguments: ["mastertour", "tours"]))
        XCTAssertTrue(MacCLICore.wantsMachineErrors(arguments: ["daysheets", "days"]))
    }

    // MARK: Daysheets feed

    static var fixture: String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tour.ics")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testFixtureParsesToDays() throws {
        let events = MacCLICore.parseICS(Self.fixture, timeZone: TimeZone(identifier: "America/Chicago")!)
        XCTAssertEqual(events.count, 4, "the VALARM is not an event")
        let days = MacCLICore.tourDays(events)
        XCTAssertEqual(days.map { $0["date"] as? String }, ["2026-12-04", "2026-12-05", "2026-12-06"])

        let first = try XCTUnwrap(days[0]["events"] as? [[String: Any]])
        XCTAssertEqual(first.map { $0["title"] as? String }, ["Austin", "Load in", "Show"])
        XCTAssertEqual(first[0]["all_day"] as? Bool, true)
        XCTAssertEqual(first[0]["start"] as? String, "2026-12-04")

        let load = first[1]
        XCTAssertEqual(load["start"] as? String, "2026-12-04T11:00:00-06:00", "17:00Z in the reading zone")
        XCTAssertEqual(load["start_time"] as? String, "11:00")
        XCTAssertEqual(load["notes"] as? String, "Dock on the east side of the building.", "folded lines")
        XCTAssertEqual(load["venue"] as? String, "The Example Hall")
        XCTAssertTrue(load["city"] is NSNull)

        let show = first[2]
        XCTAssertEqual(show["start"] as? String, "2026-12-04T20:00:00-06:00")
        XCTAssertEqual(show["end_time"] as? String, "22:00")
        XCTAssertEqual(show["time_zone"] as? String, "America/Chicago")
        XCTAssertEqual(show["location"] as? String, "The Example Hall, Austin, TX")
        XCTAssertEqual(show["venue"] as? String, "The Example Hall")
        XCTAssertEqual(show["city"] as? String, "Austin, TX")
        XCTAssertEqual(show["notes"] as? String, "Doors 19:00\nCurfew 23:00; no pyro", "escapes, not the alarm's text")

        XCTAssertEqual((days[1]["events"] as? [[String: Any]])?.first?["title"] as? String, "Travel days")
        XCTAssertEqual((days[2]["events"] as? [[String: Any]])?.first?["end"] as? String, "2026-12-06",
                       "an all-day DTEND is exclusive")
    }

    func testTimesStayInTheEventsOwnZone() throws {
        let events = MacCLICore.parseICS(Self.fixture, timeZone: TimeZone(identifier: "Europe/Madrid")!)
        let day = try XCTUnwrap(MacCLICore.tourDays(events, from: "2026-12-04", to: "2026-12-04").first)
        let titles = (day["events"] as? [[String: Any]] ?? []).map { "\($0["title"] ?? "") \($0["start"] ?? "")" }
        XCTAssertEqual(titles, ["Austin 2026-12-04", "Load in 2026-12-04T18:00:00+01:00",
                                "Show 2026-12-04T20:00:00-06:00"])
    }

    func testFromAndToBoundTheDays() {
        let events = MacCLICore.parseICS(Self.fixture, timeZone: TimeZone(identifier: "America/Chicago")!)
        XCTAssertEqual(MacCLICore.tourDays(events, from: "2026-12-05").map { $0["date"] as? String },
                       ["2026-12-05", "2026-12-06"])
        XCTAssertEqual(MacCLICore.tourDays(events, to: "2026-12-04").count, 1)
        XCTAssertTrue(MacCLICore.tourDays(events, from: "2027-01-01").isEmpty)
        XCTAssertTrue(MacCLICore.isDay("2026-12-04"))
        XCTAssertFalse(MacCLICore.isDay("2026-13-04"))
        XCTAssertFalse(MacCLICore.isDay("12/04/2026"))
    }
}

final class JXAEnvelopeTests: XCTestCase {
    // `apps launch Safari` (the name form) prints this envelope; a bare string result
    // used to raise NSInvalidArgumentException "Invalid top-level type in JSON write".
    func testBareStringResultFromAppsLaunchByName() {
        let env = parseJXAEnvelope("{\"ok\":true,\"result\":\"launched\"}\n")
        XCTAssertEqual(env, JXAEnvelope(ok: true, resultJSON: "\"launched\"", error: ""))
    }

    func testScalarAndObjectResults() {
        XCTAssertEqual(parseJXAEnvelope("{\"ok\":true,\"result\":3}")?.resultJSON, "3")
        XCTAssertEqual(parseJXAEnvelope("{\"ok\":true,\"result\":null}")?.resultJSON, "")
        XCTAssertEqual(parseJXAEnvelope("{\"ok\":true,\"result\":{\"a\":1}}")?.resultJSON, "{\"a\":1}")
    }

    func testFailureAndNonEnvelope() {
        XCTAssertEqual(parseJXAEnvelope("{\"ok\":false,\"error\":\"no such app\"}"),
                       JXAEnvelope(ok: false, resultJSON: "", error: "no such app"))
        XCTAssertEqual(parseJXAEnvelope("execution error: boom")?.ok, false)
        XCTAssertNil(parseJXAEnvelope(""))
        XCTAssertNil(parseJXAEnvelope("launched"))
    }
}

final class NetworkShareTests: XCTestCase {
    func testParsesTheNASURL() {
        XCTAssertEqual(NetworkShare.parse(url: "smb://manu@ManuStorage.local/Arimaka"),
                       NetworkShare(user: "manu", host: "ManuStorage.local", share: "Arimaka"))
        XCTAssertEqual(NetworkShare.parse(url: "smb://100.88.105.22/Arimaka/sub")?.share, "Arimaka")
    }

    func testRefusesAPasswordInTheURLAndHalfURLs() {
        XCTAssertNil(NetworkShare.parse(url: "smb://manu:secret@ManuStorage.local/Arimaka"))
        XCTAssertNil(NetworkShare.parse(url: "smb://ManuStorage.local/"))
        XCTAssertNil(NetworkShare.parse(url: "/dev/disk2s1"))
        XCTAssertNil(NetworkShare.parse(url: "https://host/share"))
    }

    func testFinderBonjourMountIsTheSameShare() {
        let asked = NetworkShare.parse(url: "smb://manu@ManuStorage.local/Arimaka")!
        let mounted = NetworkShare.parse(mountedFrom: "//manu@ManuStorage._smb._tcp.local/Arimaka")!
        XCTAssertTrue(asked.isSameShare(as: mounted))
        XCTAssertFalse(asked.isSameShare(as: NetworkShare.parse(mountedFrom: "//manu@ManuStorage.local/Other")!))
        XCTAssertFalse(asked.isSameShare(as: NetworkShare.parse(mountedFrom: "//guest@ManuStorage.local/Arimaka")!))
        XCTAssertFalse(asked.isSameShare(as: NetworkShare.parse(mountedFrom: "//manu@100.88.105.22/Arimaka")!))
    }
}

final class MessagesStoreTests: XCTestCase {
    func blob(_ text: String, lengthBytes: [UInt8]) -> [UInt8] {
        [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
            + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B] + lengthBytes + Array(text.utf8) + [0x86, 0x84]
    }

    func testShortBodyDecodes() {
        let text = "On my way 🚗"
        XCTAssertEqual(MacCLICore.attributedBodyText(blob(text, lengthBytes: [UInt8(text.utf8.count)])), text)
    }

    func testTwoByteLengthDecodes() {
        let text = String(repeating: "a", count: 300)
        XCTAssertEqual(MacCLICore.attributedBodyText(blob(text, lengthBytes: [0x81, 0x2C, 0x01])), text)
    }

    func testNoStringOrCutShortIsNil() {
        XCTAssertNil(MacCLICore.attributedBodyText([]))
        XCTAssertNil(MacCLICore.attributedBodyText(Array("streamtyped NSDictionary".utf8)))
        XCTAssertNil(MacCLICore.attributedBodyText(Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B, 0x81]))
    }

    func testDatesInNanosecondsAndSeconds() {
        XCTAssertEqual(MacCLICore.messagesDate(784_000_000_000_000_000).timeIntervalSinceReferenceDate, 784_000_000)
        XCTAssertEqual(MacCLICore.messagesDate(500_000_000).timeIntervalSinceReferenceDate, 500_000_000)
    }
}

final class LocationTriggerTests: XCTestCase {
    private func change(arriving: String? = nil, leaving: String? = nil, radius: Double? = nil,
                        clear: Bool = false) throws -> LocationTrigger.Change {
        try LocationTrigger.change(whenArriving: arriving, whenLeaving: leaving, radius: radius, clearLocation: clear)
    }

    private func usageMessage(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch let e as LocationTrigger.UsageError { return e.message } catch { return "\(error)" }
    }

    // MARK: Flag parsing

    func testArrivingHomeWithTheDefaultRadius() throws {
        XCTAssertEqual(try change(arriving: "home"), .set(.init(place: .home, proximity: .arriving, radius: 150)))
        XCTAssertEqual(try change(arriving: "Home"), .set(.init(place: .home, proximity: .arriving, radius: 150)))
    }

    func testLeavingWorkWithARadius() throws {
        XCTAssertEqual(try change(leaving: "work", radius: 300), .set(.init(place: .work, proximity: .leaving, radius: 300)))
    }

    func testAnythingElseIsAnAddress() throws {
        XCTAssertEqual(try change(arriving: " 1 Example Street, Springfield "),
                       .set(.init(place: .address("1 Example Street, Springfield"), proximity: .arriving)))
    }

    func testNoFlagsIsNoChangeAndClearIsClear() throws {
        XCTAssertEqual(try change(), LocationTrigger.Change.none)
        XCTAssertEqual(try change(clear: true), .clear)
    }

    func testRefusedCombinations() {
        XCTAssertEqual(usageMessage { try self.change(arriving: "home", leaving: "work") },
                       "Use one of --when-arriving and --when-leaving, not both.")
        XCTAssertNotNil(usageMessage { try self.change(arriving: "home", clear: true) })
        XCTAssertNotNil(usageMessage { try self.change(radius: 100) })
        XCTAssertNotNil(usageMessage { try self.change(radius: 100, clear: true) })
        XCTAssertNotNil(usageMessage { try self.change(arriving: "home", radius: 0) })
        XCTAssertNotNil(usageMessage { try self.change(arriving: "home", radius: -5) })
        XCTAssertNotNil(usageMessage { try self.change(arriving: "  ") })
    }

    // MARK: Home and work from the Me card

    func testHomeAndWorkPickTheirLabelledAddress() throws {
        let labels: [String?] = [nil, LocationTrigger.contactsWorkLabel, LocationTrigger.contactsHomeLabel]
        XCTAssertEqual(try LocationTrigger.meCardAddressIndex(for: .home, meCardAddressLabels: labels), 2)
        XCTAssertEqual(try LocationTrigger.meCardAddressIndex(for: .work, meCardAddressLabels: labels), 1)
    }

    func testNoMeCardNamesWhatIsMissing() {
        XCTAssertThrowsError(try LocationTrigger.meCardAddressIndex(for: .home, meCardAddressLabels: nil)) { error in
            XCTAssertEqual(error as? LocationTrigger.LookupError, .noMeCard)
            XCTAssertTrue("\(error)".contains("no Me card"), "\(error)")
        }
    }

    func testMeCardWithoutAHomeAddressNamesTheLabel() {
        XCTAssertThrowsError(try LocationTrigger.meCardAddressIndex(
            for: .home, meCardAddressLabels: [LocationTrigger.contactsWorkLabel])) { error in
            XCTAssertEqual(error as? LocationTrigger.LookupError, .noLabelledAddress("home"))
            XCTAssertEqual("\(error)", "The Me card in Contacts has no address labelled home.")
        }
        XCTAssertThrowsError(try LocationTrigger.meCardAddressIndex(for: .work, meCardAddressLabels: []))
    }

    func testLocationTitles() {
        XCTAssertEqual(LocationTrigger(place: .home, proximity: .arriving).locationTitle, "Home")
        XCTAssertEqual(LocationTrigger(place: .work, proximity: .leaving).locationTitle, "Work")
        XCTAssertEqual(LocationTrigger(place: .address("Main St"), proximity: .arriving).locationTitle, "Main St")
    }

    // MARK: Replace, never stack

    private struct Alarm: Equatable { let name: String; let isLocation: Bool }

    func testANewTriggerReplacesTheOldOneAndKeepsTimeAlarms() {
        let existing = [Alarm(name: "9am", isLocation: false), Alarm(name: "old home", isLocation: true)]
        let next = LocationTrigger.alarms(existing, isLocation: { $0.isLocation },
                                          adding: Alarm(name: "new home", isLocation: true))
        XCTAssertEqual(next, [Alarm(name: "9am", isLocation: false), Alarm(name: "new home", isLocation: true)])
        XCTAssertEqual(next.filter(\.isLocation).count, 1)
    }

    func testSettingTwiceStillLeavesOne() {
        var alarms: [Alarm] = []
        for _ in 0..<3 {
            alarms = LocationTrigger.alarms(alarms, isLocation: { $0.isLocation }, adding: Alarm(name: "home", isLocation: true))
        }
        XCTAssertEqual(alarms.count, 1)
    }

    func testClearRemovesOnlyTheLocation() {
        let existing = [Alarm(name: "home", isLocation: true), Alarm(name: "9am", isLocation: false)]
        XCTAssertEqual(LocationTrigger.alarms(existing, isLocation: { $0.isLocation }, adding: nil),
                       [Alarm(name: "9am", isLocation: false)])
    }

    // MARK: Output

    func testLocationJSONHasNoCoordinates() throws {
        let json = try XCTUnwrap(LocationTrigger.locationJSON(title: "Home", proximityRaw: 1, radius: 150))
        XCTAssertEqual(Set(json.keys), ["title", "proximity", "radius"])
        XCTAssertEqual(json["proximity"] as? String, "arriving")
        XCTAssertEqual(LocationTrigger.locationJSON(title: "Work", proximityRaw: 2, radius: 80)?["proximity"] as? String,
                       "leaving")
        XCTAssertNil(LocationTrigger.locationJSON(title: "Home", proximityRaw: 0, radius: 150))
    }
}
