import XCTest
@testable import MacCLICore

/// Regression coverage for scalar JXA envelope results such as `mail refresh`.
final class JXAEnvelopeResultEncodingTests: XCTestCase {
    func testRefreshEnvelopeScalarResultDoesNotAbort() {
        let raw = #"{"ok": true, "result": "refreshed", "error": ""}"#
        let obj = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        XCTAssertFalse(JSONSerialization.isValidJSONObject(obj["result"]!))
        XCTAssertEqual(MacCLICore.encodeJXAResult(obj["result"]), "\"refreshed\"")
    }

    func testEveryScalarKindEncodesAsAFragment() {
        XCTAssertEqual(MacCLICore.encodeJXAResult("refreshed"), "\"refreshed\"")
        XCTAssertEqual(MacCLICore.encodeJXAResult(42), "42")
        XCTAssertEqual(MacCLICore.encodeJXAResult(true), "true")
        XCTAssertEqual(MacCLICore.encodeJXAResult(NSNull()), "null")
    }

    func testAbsentResultEncodesToEmptyString() {
        XCTAssertEqual(MacCLICore.encodeJXAResult(nil), "")
    }

    func testContainerResultsAreUnchanged() {
        XCTAssertEqual(MacCLICore.encodeJXAResult(["sent": true]), #"{"sent":true}"#)
        XCTAssertEqual(MacCLICore.encodeJXAResult([1, 2, 3]), "[1,2,3]")
        XCTAssertEqual(MacCLICore.encodeJXAResult([String]()), "[]")
        XCTAssertEqual(MacCLICore.encodeJXAResult([String: String]()), "{}")
    }

    func testScalarFragmentsAreEscapedAndReparseable() {
        let hostile = "refre\"shed\\\n\t 🎛️ 日本語"
        let encoded = MacCLICore.encodeJXAResult(hostile)
        let round = try! JSONSerialization.jsonObject(with: Data(encoded.utf8), options: [.fragmentsAllowed])
        XCTAssertEqual(round as? String, hostile)
    }

    func testUnencodableValuesDegradeToEmptyString() {
        XCTAssertEqual(MacCLICore.encodeJXAResult(Double.nan), "")
        XCTAssertEqual(MacCLICore.encodeJXAResult(Double.infinity), "")
        XCTAssertEqual(MacCLICore.encodeJXAResult(Data([0x00])), "")
    }
}
