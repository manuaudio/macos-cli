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

    func testDecodeNoteBodyPicksLongestCoherentText() {
        let short = "hi"                       // below minLen
        let long = "The quick brown fox — café 日本語 jumps over the lazy dog"
        var proto = Data()
        proto.append(protoField(3, Data(short.utf8)))
        proto.append(protoField(2, Data(long.utf8)))
        // A binary sub-message the walker must recurse into without crashing.
        proto.append(protoField(5, Data([0x00, 0x01, 0x02, 0xFF, 0xFE])))
        XCTAssertEqual(MacCLICore.decodeNoteBody(proto), long)
    }

    func testDecodeNoteBodyReturnsNilOnGarbage() {
        XCTAssertNil(MacCLICore.decodeNoteBody(Data([0x00, 0x01, 0x02])))
    }
}
