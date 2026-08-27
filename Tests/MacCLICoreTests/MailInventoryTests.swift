import XCTest
@testable import MacCLICore

// Deterministic tests for the `mail inventory` / `mail mutate` machine contract.
//
// Every fixture here is synthetic: no Mail.app, no JXA, no accounts. What is under
// test is the pure decision layer that decides whether a bulk-triage caller is
// allowed to act — argument validation, exact-identity uniqueness, and the read-back
// verification that turns an *attempted* setter into a *verified* one.

// MARK: - Argument validation

final class MailInventoryArgsTests: XCTestCase {
    func testFullyScopedRequestIsValid() {
        let v = MacCLICore.validateMailInventoryArgs(account: "Work", mailbox: "INBOX", limit: 50, offset: 0)
        XCTAssertTrue(v.valid)
        XCTAssertNil(v.error)
    }

    func testBlankScopeSelectorsAreRejected() {
        for bad in ["", "   ", "\n", "\t "] {
            XCTAssertEqual(
                MacCLICore.validateMailInventoryArgs(account: bad, mailbox: "INBOX", limit: 10, offset: 0).error,
                "invalid_account", "account \(bad.debugDescription) must be rejected")
            XCTAssertEqual(
                MacCLICore.validateMailInventoryArgs(account: "Work", mailbox: bad, limit: 10, offset: 0).error,
                "invalid_mailbox", "mailbox \(bad.debugDescription) must be rejected")
        }
    }

    func testControlCharactersInAScopeSelectorAreRejected() {
        // A NUL or DEL can only be an injection attempt; it is refused before the value
        // is ever spliced into a JXA literal.
        XCTAssertEqual(
            MacCLICore.validateMailInventoryArgs(account: "Wo\u{0000}rk", mailbox: "INBOX", limit: 10, offset: 0).error,
            "invalid_account")
        XCTAssertEqual(
            MacCLICore.validateMailInventoryArgs(account: "Work", mailbox: "IN\u{007F}BOX", limit: 10, offset: 0).error,
            "invalid_mailbox")
    }

    func testInteriorWhitespaceInAMailboxNameIsAllowed() {
        XCTAssertTrue(MacCLICore.validateMailInventoryArgs(
            account: "iCloud", mailbox: "Deleted Messages", limit: 1, offset: 0).valid)
    }

    func testLimitMustBePositiveAndBounded() {
        for bad in [0, -1, -500, MacCLICore.mailInventoryMaxLimit + 1, 10_000] {
            let v = MacCLICore.validateMailInventoryArgs(account: "Work", mailbox: "INBOX", limit: bad, offset: 0)
            XCTAssertFalse(v.valid, "limit \(bad) must be rejected")
            XCTAssertEqual(v.error, "invalid_limit")
            XCTAssertEqual(v.field, "limit")
        }
    }

    func testLimitBoundariesAreAccepted() {
        XCTAssertTrue(MacCLICore.validateMailInventoryArgs(account: "W", mailbox: "I", limit: 1, offset: 0).valid)
        XCTAssertTrue(MacCLICore.validateMailInventoryArgs(
            account: "W", mailbox: "I", limit: MacCLICore.mailInventoryMaxLimit, offset: 0).valid)
    }

    func testNegativeOffsetIsRejected() {
        let v = MacCLICore.validateMailInventoryArgs(account: "Work", mailbox: "INBOX", limit: 10, offset: -1)
        XCTAssertEqual(v.error, "invalid_offset")
        XCTAssertEqual(v.field, "offset")
    }

    func testThereIsNoUnboundedMode() {
        // The ceiling is a constant, not a suggestion: no argument can exceed it.
        XCTAssertEqual(MacCLICore.mailInventoryMaxLimit, 500)
        XCTAssertFalse(MacCLICore.validateMailInventoryArgs(
            account: "W", mailbox: "I", limit: Int.max, offset: 0).valid)
    }
}

final class MailMutateArgsTests: XCTestCase {
    private func validate(
        account: String = "Work", mailbox: String = "INBOX",
        id: String? = "4711", rfc: String? = nil,
        read: Bool = true, unread: Bool = false, moveTo: String? = nil
    ) -> MacCLICore.MailValidation {
        return MacCLICore.validateMailMutateArgs(
            account: account, mailbox: mailbox, id: id, rfcMessageID: rfc,
            read: read, unread: unread, moveTo: moveTo)
    }

    func testScopeIsMandatoryEvenWithAPerfectIdentity() {
        XCTAssertEqual(validate(account: "  ").error, "invalid_account")
        XCTAssertEqual(validate(mailbox: "  ").error, "invalid_mailbox")
    }

    func testIdentityIsMandatory() {
        let v = validate(id: nil, rfc: nil)
        XCTAssertFalse(v.valid)
        XCTAssertEqual(v.error, "missing_identity")
    }

    func testBlankIdentityDoesNotCountAsAnIdentity() {
        XCTAssertEqual(validate(id: "   ", rfc: nil).error, "missing_identity")
        XCTAssertEqual(validate(id: nil, rfc: "\t").error, "missing_identity")
    }

    func testEitherIdentityAloneIsEnough() {
        XCTAssertTrue(validate(id: "4711", rfc: nil).valid)
        XCTAssertTrue(validate(id: nil, rfc: "<a@b.example>").valid)
        XCTAssertTrue(validate(id: "4711", rfc: "<a@b.example>").valid)
    }

    func testReadAndUnreadConflict() {
        let v = validate(read: true, unread: true)
        XCTAssertFalse(v.valid)
        XCTAssertEqual(v.error, "conflicting_read_flags")
    }

    func testAtLeastOneMutationIsRequired() {
        let v = validate(read: false, unread: false, moveTo: nil)
        XCTAssertFalse(v.valid)
        XCTAssertEqual(v.error, "no_mutation_requested")
    }

    func testBlankDestinationIsReportedAsMalformedNotAsNoOp() {
        // A blank --move-to must not be silently downgraded to "you asked for nothing".
        let v = validate(read: false, unread: false, moveTo: "   ")
        XCTAssertEqual(v.error, "invalid_destination")
        XCTAssertEqual(v.field, "move-to")
    }

    func testMovingToTheSourceMailboxIsRefused() {
        let v = validate(mailbox: "Archive", read: false, unread: false, moveTo: " Archive ")
        XCTAssertEqual(v.error, "destination_equals_source")
    }

    func testIDMustBeMailsNumericID() {
        // --id is interpolated as a NUMERIC literal into `messages.whose({id: ...})`;
        // anything but digits is refused before a script is ever built.
        for bad in ["47a", "-1", "4.7", "4711 OR 1", "0x10", String(repeating: "9", count: 19)] {
            XCTAssertEqual(validate(id: bad).error, "invalid_id", "should reject --id \(bad)")
        }
        XCTAssertTrue(validate(id: "0").valid)
        XCTAssertTrue(validate(id: " 4711 ").valid)
    }

    func testMalformedIDIsRefusedEvenWhenAMessageIDIsAlsoSupplied() {
        // Falling back to the Message-ID would silently honour half the request.
        XCTAssertEqual(validate(id: "4a", rfc: "<a@b.example>").error, "invalid_id")
    }

    func testValidMutationCombinations() {
        XCTAssertTrue(validate(read: true, unread: false, moveTo: nil).valid)
        XCTAssertTrue(validate(read: false, unread: true, moveTo: nil).valid)
        XCTAssertTrue(validate(read: false, unread: false, moveTo: "Archive").valid)
        XCTAssertTrue(validate(read: true, unread: false, moveTo: "Archive").valid)
    }
}

final class MailMutationRequestTests: XCTestCase {
    func testReadStateIsAppliedBeforeTheMove() {
        // The read flag must be set while the message is still at a known address.
        let m = MacCLICore.mailMutationsRequested(read: true, unread: false, moveTo: "Archive")
        XCTAssertEqual(m, [.markRead, .move("Archive")])
    }

    func testUnreadAndMoveOrdering() {
        XCTAssertEqual(MacCLICore.mailMutationsRequested(read: false, unread: true, moveTo: "Junk"),
                       [.markUnread, .move("Junk")])
    }

    func testDestinationIsTrimmed() {
        XCTAssertEqual(MacCLICore.mailMutationsRequested(read: false, unread: false, moveTo: "  Archive  "),
                       [.move("Archive")])
    }

    func testUnusableDestinationProducesNoMove() {
        XCTAssertTrue(MacCLICore.mailMutationsRequested(read: false, unread: false, moveTo: "   ").isEmpty)
        XCTAssertTrue(MacCLICore.mailMutationsRequested(read: false, unread: false, moveTo: nil).isEmpty)
    }

    func testEveryReachableMutationIsReversible() {
        // Exhaustive over the enum: a delete case would fail to compile here.
        let all = MacCLICore.mailMutationsRequested(read: true, unread: false, moveTo: "Archive")
            + MacCLICore.mailMutationsRequested(read: false, unread: true, moveTo: nil)
        for m in all {
            switch m {
            case .markRead, .markUnread, .move: break
            }
        }
        XCTAssertEqual(all.count, 3)
    }
}

// MARK: - Numeric message id

final class MailNumericIDTests: XCTestCase {
    func testAcceptsPlainDecimalIDs() {
        for good in ["0", "1", "4711", " 4711 ", "999999999999999999"] {
            XCTAssertTrue(MacCLICore.mailNumericIDIsValid(good), "should accept \(good)")
        }
    }

    func testRejectsAnythingThatIsNotPurelyDigits() {
        for bad in ["", "   ", "-1", "+1", "4.7", "1e3", "0x10", "47 11", "4711;", "47\u{0301}11"] {
            XCTAssertFalse(MacCLICore.mailNumericIDIsValid(bad), "should reject \(bad)")
        }
        XCTAssertFalse(MacCLICore.mailNumericIDIsValid(nil))
    }

    func testRejectsIDsBeyondExactJSIntegerRange() {
        // 19 digits can exceed 2^53 and would round to a DIFFERENT message's id inside JXA.
        XCTAssertFalse(MacCLICore.mailNumericIDIsValid(String(repeating: "9", count: 19)))
    }
}

// MARK: - JXA string escaping (user-controlled selectors reach a script literal)

final class JXAEscapeTests: XCTestCase {
    /// Every apostrophe in the escaped output must be preceded by an ODD run of
    /// backslashes. This is the real invariant — "the output does not contain `');`" is
    /// not, because the correctly escaped form `\');` still contains that substring.
    private func everyQuoteIsEscaped(_ escaped: String) -> Bool {
        let scalars = Array(escaped.unicodeScalars)
        for (i, scalar) in scalars.enumerated() where scalar == "'" {
            guard i > 0 else { return false }
            var backslashes = 0
            var j = i - 1
            while j >= 0, scalars[j] == "\\" {
                backslashes += 1
                j -= 1
            }
            // An even run means the backslashes escaped each other and the quote is live.
            if backslashes % 2 == 0 { return false }
        }
        return true
    }

    /// Minimal unescaper for exactly the sequences `jxaStringEscape` can emit. Used to
    /// prove the escape is lossless as well as safe.
    private func unescapeJSLiteral(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "\\" else {
                out.append(s[i])
                i = s.index(after: i)
                continue
            }
            let next = s.index(after: i)
            guard next < s.endIndex else { out.append(s[i]); break }
            switch s[next] {
            case "n": out.append("\n"); i = s.index(after: next)
            case "r": out.append("\r"); i = s.index(after: next)
            case "u":
                let start = s.index(after: next)
                guard let end = s.index(start, offsetBy: 4, limitedBy: s.endIndex),
                      let code = UInt32(s[start..<end], radix: 16),
                      let scalar = Unicode.Scalar(code) else {
                    out.append(s[next]); i = s.index(after: next); continue
                }
                out.unicodeScalars.append(scalar)
                i = end
            default: out.append(s[next]); i = s.index(after: next)
            }
        }
        return out
    }

    func testSingleQuoteIsEscaped() {
        XCTAssertEqual(MacCLICore.jxaStringEscape("O'Brien"), "O\\'Brien")
    }

    func testBackslashIsEscapedBeforeQuotes() {
        // Backslash first, else the escape introduced for the quote gets re-escaped into
        // a literal backslash and the quote breaks out.
        XCTAssertEqual(MacCLICore.jxaStringEscape("a\\'b"), "a\\\\\\'b")
        XCTAssertTrue(everyQuoteIsEscaped(MacCLICore.jxaStringEscape("a\\'b")))
    }

    func testInjectionAttemptStaysInsideTheLiteral() {
        let payload = "'); Application('Finder').delete(); ('"
        let escaped = MacCLICore.jxaStringEscape(payload)
        XCTAssertTrue(everyQuoteIsEscaped(escaped), "a live quote survived: \(escaped)")
        XCTAssertTrue(escaped.contains("\\'"))
        // Round-tripping the escaped text as a JS literal reproduces the payload exactly:
        // nothing added, nothing lost, nothing that could execute.
        XCTAssertEqual(unescapeJSLiteral(escaped), payload)
    }

    func testTerminatorHeavyPayloadsStayInsideTheLiteral() {
        for payload in ["''''", "\\", "\\\\'", "a'\\'b", "'\n');alert(1);('", "\u{2028}');x('"] {
            let escaped = MacCLICore.jxaStringEscape(payload)
            XCTAssertTrue(everyQuoteIsEscaped(escaped), "live quote in \(payload.debugDescription)")
            XCTAssertFalse(escaped.contains("\n"), "raw newline in \(payload.debugDescription)")
            XCTAssertFalse(escaped.contains("\r"), "raw CR in \(payload.debugDescription)")
            XCTAssertFalse(escaped.unicodeScalars.contains("\u{2028}"))
            XCTAssertFalse(escaped.unicodeScalars.contains("\u{2029}"))
            XCTAssertEqual(unescapeJSLiteral(escaped), payload, "escape must be lossless")
        }
    }

    func testNewlinesAreEscaped() {
        XCTAssertEqual(MacCLICore.jxaStringEscape("a\nb\rc"), "a\\nb\\rc")
    }

    func testLineSeparatorsAreEscaped() {
        // U+2028/U+2029 terminate a JS line and would end the string literal.
        XCTAssertEqual(MacCLICore.jxaStringEscape("a\u{2028}b\u{2029}c"), "a\\u2028b\\u2029c")
    }

    func testUnicodeIsOtherwisePreserved() {
        XCTAssertEqual(MacCLICore.jxaStringEscape("Señor 日本語 🎛️"), "Señor 日本語 🎛️")
    }
}

// MARK: - RFC header extraction

final class MailHeaderParsingTests: XCTestCase {
    private let raw = """
    Received: from mx.example.com by inbox.example.net; Tue, 5 Aug 2025 10:00:00 +0000
    Subject: Quarterly numbers
    Message-ID: <abc123@example.com>
    In-Reply-To: <parent@example.com>
    References: <a@example.com>
     <b@example.com>
    \t<c@example.com>
    List-ID: Marketing Blasts <blast.list.example.com>
    List-Unsubscribe: <https://example.com/u/1>, <mailto:u@example.com>
    List-Unsubscribe-Post: List-Unsubscribe=One-Click
    Precedence: bulk
    Auto-Submitted: auto-generated
    X-Spam-Score: 0.1
    """

    func testAllowlistedHeadersAreExtracted() {
        let h = MacCLICore.mailClassificationHeaders(raw)
        XCTAssertEqual(h["message-id"], "<abc123@example.com>")
        XCTAssertEqual(h["in-reply-to"], "<parent@example.com>")
        XCTAssertEqual(h["list-id"], "Marketing Blasts <blast.list.example.com>")
        XCTAssertEqual(h["list-unsubscribe"], "<https://example.com/u/1>, <mailto:u@example.com>")
        XCTAssertEqual(h["list-unsubscribe-post"], "List-Unsubscribe=One-Click")
        XCTAssertEqual(h["precedence"], "bulk")
        XCTAssertEqual(h["auto-submitted"], "auto-generated")
    }

    func testFoldedHeaderIsUnfoldedOntoOneLine() {
        let h = MacCLICore.mailClassificationHeaders(raw)
        XCTAssertEqual(h["references"], "<a@example.com> <b@example.com> <c@example.com>")
    }

    func testNonAllowlistedHeadersAreDropped() {
        let h = MacCLICore.mailClassificationHeaders(raw)
        XCTAssertNil(h["received"])
        XCTAssertNil(h["subject"])
        XCTAssertNil(h["x-spam-score"])
        XCTAssertEqual(Set(h.keys).subtracting(MacCLICore.mailClassificationHeaderNames), [])
    }

    func testHeaderNamesAreCaseInsensitiveAndKeysNormalized() {
        // Mail hands back CRLF-delimited header text; the CR must not survive anywhere.
        let h = MacCLICore.mailClassificationHeaders("MESSAGE-id: <x@y.example>\r\nPRECEDENCE: List\r\n")
        XCTAssertEqual(h["message-id"], "<x@y.example>")
        XCTAssertEqual(h["precedence"], "List")
        XCTAssertEqual(h.count, 2)
        for (name, value) in h {
            XCTAssertFalse(name.contains("\r"), "CR leaked into key \(name.debugDescription)")
            XCTAssertFalse(value.contains("\r"), "CR leaked into value \(value.debugDescription)")
        }
    }

    func testCRLFFoldedContinuationIsUnfolded() {
        let h = MacCLICore.mailClassificationHeaders(
            "References: <a@x.example>\r\n <b@x.example>\r\nPrecedence: bulk\r\n")
        XCTAssertEqual(h["references"], "<a@x.example> <b@x.example>")
        XCTAssertEqual(h["precedence"], "bulk")
    }

    func testFirstOccurrenceOfADuplicatedFieldWins() {
        // A forged trailing `Precedence:` must not override the real one.
        XCTAssertEqual(MacCLICore.mailClassificationHeaders("Precedence: bulk\r\nPrecedence: list\r\n")["precedence"],
                       "bulk")
        XCTAssertEqual(MacCLICore.mailClassificationHeaders("Precedence: bulk\nPrecedence: list\n")["precedence"],
                       "bulk")
    }

    func testParsingStopsAtTheBlankLineSoNoBodyLeaks() {
        let withBody = "Precedence: bulk\r\n\r\nList-ID: not-a-header <evil.example>\r\nbody text\r\n"
        let h = MacCLICore.mailClassificationHeaders(withBody)
        XCTAssertEqual(h["precedence"], "bulk")
        XCTAssertNil(h["list-id"], "content after the blank line is body, never headers")
        XCTAssertEqual(h.count, 1)
    }

    func testEmptyAndMalformedInputYieldsNoHeaders() {
        XCTAssertTrue(MacCLICore.mailClassificationHeaders("").isEmpty)
        XCTAssertTrue(MacCLICore.mailClassificationHeaders("no colon here\njust text").isEmpty)
    }

    func testUnixMboxFromLineIsIgnored() {
        let h = MacCLICore.mailClassificationHeaders(
            "From bounce@example.com Tue Aug  5 10:00:00 2025\nPrecedence: bulk\n")
        XCTAssertEqual(h["precedence"], "bulk")
        XCTAssertEqual(h.count, 1)
    }
}

// MARK: - Exact-identity selection (fail closed)

final class MailSelectUniqueTests: XCTestCase {
    private let candidates = [
        MacCLICore.MailCandidate(id: "1", rfcMessageID: "<a@example.com>"),
        MacCLICore.MailCandidate(id: "2", rfcMessageID: "<b@example.com>"),
        MacCLICore.MailCandidate(id: "3", rfcMessageID: "<b@example.com>"),  // duplicated RFC id
        MacCLICore.MailCandidate(id: "4", rfcMessageID: nil),
    ]

    func testExactIDSelectsExactlyOne() {
        let s = MacCLICore.mailSelectUnique(candidates: candidates, id: "2", rfcMessageID: nil)
        XCTAssertEqual(s.verdict, .unique)
        XCTAssertEqual(s.indices, [1])
    }

    func testDuplicateRFCMessageIDIsNotUnique() {
        let s = MacCLICore.mailSelectUnique(candidates: candidates, id: nil, rfcMessageID: "<b@example.com>")
        XCTAssertEqual(s.verdict, .notUnique)
        XCTAssertEqual(s.indices, [1, 2])
    }

    func testAngleBracketsAndSurroundingSpaceAreNormalized() {
        for form in ["<a@example.com>", "a@example.com", "  <a@example.com>  "] {
            XCTAssertEqual(MacCLICore.mailSelectUnique(candidates: candidates, id: nil, rfcMessageID: form).verdict,
                           .unique, "form \(form.debugDescription) must resolve")
        }
    }

    func testMessageIDCaseIsNotFolded() {
        // The local part of a Message-ID is case-sensitive; folding it would let two
        // distinct messages collide.
        XCTAssertEqual(MacCLICore.mailSelectUnique(candidates: candidates, id: nil, rfcMessageID: "<A@example.com>").verdict,
                       .notFound)
    }

    func testMatchingIsNeverSubstringOrPrefix() {
        for near in ["<b@example.co>", "@example.com", "b@example.com.evil"] {
            XCTAssertEqual(MacCLICore.mailSelectUnique(candidates: candidates, id: nil, rfcMessageID: near).verdict,
                           .notFound, "\(near) must not match by substring or prefix")
        }
        XCTAssertEqual(MacCLICore.mailSelectUnique(candidates: candidates, id: "1x", rfcMessageID: nil).verdict,
                       .notFound)
    }

    func testBothSelectorsMustAgree() {
        // A stale numeric id paired with a good Message-ID is a refusal, not a
        // half-honoured request.
        XCTAssertEqual(MacCLICore.mailSelectUnique(candidates: candidates, id: "1", rfcMessageID: "<b@example.com>").verdict,
                       .notFound)
        XCTAssertEqual(MacCLICore.mailSelectUnique(candidates: candidates, id: "2", rfcMessageID: "<b@example.com>").verdict,
                       .unique)
    }

    func testCandidateWithoutTheRequestedIdentityNeverMatches() {
        XCTAssertEqual(MacCLICore.mailSelectUnique(
            candidates: [MacCLICore.MailCandidate(id: nil, rfcMessageID: nil)],
            id: "4", rfcMessageID: nil).verdict, .notFound)
        XCTAssertEqual(MacCLICore.mailSelectUnique(
            candidates: candidates, id: nil, rfcMessageID: "<d@example.com>").verdict, .notFound)
    }

    func testNoIdentityIsRefusedRatherThanMatchingEverything() {
        for (id, rfc) in [(nil, nil), ("   ", nil), (nil, "\t"), ("", "")] as [(String?, String?)] {
            let s = MacCLICore.mailSelectUnique(candidates: candidates, id: id, rfcMessageID: rfc)
            XCTAssertEqual(s.verdict, .missingIdentity)
            XCTAssertTrue(s.indices.isEmpty, "an absent identity must never select rows")
        }
    }

    func testEmptyMailboxYieldsNotFound() {
        XCTAssertEqual(MacCLICore.mailSelectUnique(candidates: [], id: "1", rfcMessageID: nil).verdict, .notFound)
    }
}

// MARK: - Inventory row contract

final class MailInventoryItemTests: XCTestCase {
    private func row(id: String? = "4711", rfc: String? = "<abc123@example.com>",
                     errors: [String] = [], headersStatus: String = "ok") -> [String: Any] {
        return MacCLICore.mailInventoryItemJSON(
            account: "Work", mailbox: "INBOX", index: 3,
            id: id, rfcMessageID: rfc,
            subject: "Quarterly numbers", sender: "Ada <ada@example.com>",
            toRecipients: ["me@example.com"], ccRecipients: ["cc@example.com"],
            dateSent: "2025-08-05T10:00:00Z", dateReceived: "2025-08-05T10:00:03Z",
            read: false, flagged: true,
            headers: ["message-id": "<abc123@example.com>", "precedence": "bulk"],
            headersStatus: headersStatus, errors: errors)
    }

    func testRowCarriesEnoughIdentityToAddressExactlyOneMessage() {
        let r = row()
        XCTAssertEqual(r["account"] as? String, "Work")
        XCTAssertEqual(r["mailbox"] as? String, "INBOX")
        XCTAssertEqual(r["index"] as? Int, 3)
        XCTAssertEqual(r["id"] as? String, "4711")
        XCTAssertEqual(r["rfc_message_id"] as? String, "<abc123@example.com>")
        XCTAssertEqual(r["addressable"] as? Bool, true)
    }

    func testRowCarriesClassificationFields() {
        let r = row()
        XCTAssertEqual(r["subject"] as? String, "Quarterly numbers")
        XCTAssertEqual(r["sender"] as? String, "Ada <ada@example.com>")
        XCTAssertEqual(r["to"] as? [String] ?? [], ["me@example.com"])
        XCTAssertEqual(r["cc"] as? [String] ?? [], ["cc@example.com"])
        XCTAssertEqual(r["date_sent"] as? String, "2025-08-05T10:00:00Z")
        XCTAssertEqual(r["date_received"] as? String, "2025-08-05T10:00:03Z")
        XCTAssertEqual(r["read"] as? Bool, false)
        XCTAssertEqual(r["flagged"] as? Bool, true)
        XCTAssertEqual((r["headers"] as? [String: String])?["precedence"], "bulk")
        XCTAssertEqual(r["headers_status"] as? String, "ok")
    }

    func testRowNeverCarriesAMessageBody() {
        let r = row()
        for forbidden in ["content", "body", "text", "source", "raw", "all_headers"] {
            XCTAssertNil(r[forbidden], "inventory must never emit \(forbidden)")
        }
    }

    func testUnreadableFieldsBecomeExplicitNullNotOmitted() {
        let r = MacCLICore.mailInventoryItemJSON(
            account: "Work", mailbox: "INBOX", index: 0, id: nil, rfcMessageID: nil,
            subject: nil, sender: nil, toRecipients: [], ccRecipients: [],
            dateSent: nil, dateReceived: nil, read: nil, flagged: nil,
            headers: [:], headersStatus: "unavailable", errors: ["subject", "headers"])
        for key in ["id", "rfc_message_id", "subject", "sender", "date_sent", "date_received", "read", "flagged"] {
            XCTAssertTrue(r[key] is NSNull, "\(key) must be an explicit null")
        }
        XCTAssertEqual(r["addressable"] as? Bool, false, "a row with no identity is not addressable")
        XCTAssertEqual(r["errors"] as? [String] ?? [], ["subject", "headers"])
        XCTAssertEqual(r["headers_status"] as? String, "unavailable")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(r))
    }

    func testBlankIdentityIsTreatedAsAbsent() {
        // Mail sometimes returns an empty string rather than failing. That is not an
        // identity, and a row must not claim to be addressable on the strength of it.
        let r = row(id: "   ", rfc: "")
        XCTAssertTrue(r["id"] is NSNull)
        XCTAssertTrue(r["rfc_message_id"] is NSNull)
        XCTAssertEqual(r["addressable"] as? Bool, false)
    }

    func testOneUsableIdentityIsEnoughToBeAddressable() {
        XCTAssertEqual(row(id: nil)["addressable"] as? Bool, true)
        XCTAssertEqual(row(rfc: nil)["addressable"] as? Bool, true)
    }
}

// MARK: - Inventory envelope contract

final class MailInventoryEnvelopeTests: XCTestCase {
    private var sampleRow: [String: Any] {
        return MacCLICore.mailInventoryItemJSON(
            account: "Work", mailbox: "INBOX", index: 0, id: "1", rfcMessageID: "<a@example.com>",
            subject: "s", sender: "f", toRecipients: [], ccRecipients: [],
            dateSent: nil, dateReceived: nil, read: false, flagged: false,
            headers: [:], headersStatus: "ok", errors: [])
    }

    func testCleanEnvelopeIsOkAndPaginates() {
        let e = MacCLICore.mailInventoryEnvelope(
            messages: [sampleRow, sampleRow], account: "Work", mailbox: "INBOX",
            unreadOnly: true, limit: 2, offset: 0,
            totalMatching: 5, totalInMailbox: 900, degraded: [])
        XCTAssertEqual(e["ok"] as? Bool, true)
        XCTAssertEqual(e["status"] as? String, "ok")
        XCTAssertEqual(e["command"] as? String, "mail.inventory")
        XCTAssertEqual(e["account"] as? String, "Work")
        XCTAssertEqual(e["mailbox"] as? String, "INBOX")
        XCTAssertEqual(e["unread_only"] as? Bool, true)
        XCTAssertEqual(e["limit"] as? Int, 2)
        XCTAssertEqual(e["offset"] as? Int, 0)
        XCTAssertEqual(e["count"] as? Int, 2)
        XCTAssertEqual(e["total_matching"] as? Int, 5)
        XCTAssertEqual(e["total_in_mailbox"] as? Int, 900)
        XCTAssertEqual(e["has_more"] as? Bool, true)
        XCTAssertEqual(e["next_offset"] as? Int, 2)
        XCTAssertEqual(e["order"] as? String, "mailbox_native")
        XCTAssertNil(e["message"], "a clean page needs no caveat")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(e))
    }

    func testLastPageReportsNoMore() {
        let e = MacCLICore.mailInventoryEnvelope(
            messages: [sampleRow], account: "Work", mailbox: "INBOX",
            unreadOnly: false, limit: 2, offset: 4,
            totalMatching: 5, totalInMailbox: 5, degraded: [])
        XCTAssertEqual(e["has_more"] as? Bool, false)
        XCTAssertTrue(e["next_offset"] is NSNull)
    }

    func testEmptyPageCanNeverSendAPagingCallerRoundALoop() {
        let e = MacCLICore.mailInventoryEnvelope(
            messages: [], account: "Work", mailbox: "INBOX",
            unreadOnly: false, limit: 10, offset: 99,
            totalMatching: 5, totalInMailbox: 5, degraded: [])
        XCTAssertEqual(e["count"] as? Int, 0)
        XCTAssertEqual(e["has_more"] as? Bool, false, "an empty page must never advertise more")
        XCTAssertTrue(e["next_offset"] is NSNull)
        XCTAssertEqual(e["ok"] as? Bool, true, "an honest empty page is still a success")
    }

    // The load-bearing property: a swallowed failure must never read as success.
    func testAnyDegradationDowngradesTheEnvelope() {
        let e = MacCLICore.mailInventoryEnvelope(
            messages: [sampleRow], account: "Work", mailbox: "INBOX",
            unreadOnly: false, limit: 10, offset: 0,
            totalMatching: 5, totalInMailbox: 5,
            degraded: ["message[3]: subject unreadable"])
        XCTAssertEqual(e["ok"] as? Bool, false)
        XCTAssertEqual(e["status"] as? String, "degraded")
        XCTAssertEqual(e["degraded"] as? [String] ?? [], ["message[3]: subject unreadable"])
        XCTAssertNotNil(e["message"], "a degraded page must say so in words as well as flags")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(e))
    }

    func testDegradedPageStillReturnsTheRowsItGot() {
        let e = MacCLICore.mailInventoryEnvelope(
            messages: [sampleRow], account: "Work", mailbox: "INBOX",
            unreadOnly: false, limit: 10, offset: 0,
            totalMatching: 5, totalInMailbox: 5, degraded: ["headers unavailable"])
        XCTAssertEqual((e["messages"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(e["ok"] as? Bool, false)
    }
}

// MARK: - Structured refusals

final class MailErrorEnvelopeTests: XCTestCase {
    func testRefusalCannotBeMistakenForAnEmptyInventory() {
        let e = MacCLICore.mailErrorJSON(
            command: "mail.inventory", error: "mailbox_not_found",
            message: "No mailbox named 'Archiv' in account 'Work'.")
        XCTAssertEqual(e["ok"] as? Bool, false)
        XCTAssertEqual(e["status"] as? String, "error")
        XCTAssertEqual(e["command"] as? String, "mail.inventory")
        XCTAssertEqual(e["error"] as? String, "mailbox_not_found")
        XCTAssertNil(e["messages"], "an error body must never look like an empty inventory")
        XCTAssertNil(e["count"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(e))
    }

    func testExtraContextIsMergedButCannotOverrideStatusKeys() {
        let e = MacCLICore.mailErrorJSON(
            command: "mail.mutate", error: "invalid_limit", message: "bad",
            extra: ["ok": true, "status": "ok", "error": "spoofed", "field": "limit"])
        XCTAssertEqual(e["ok"] as? Bool, false)
        XCTAssertEqual(e["status"] as? String, "error")
        XCTAssertEqual(e["error"] as? String, "invalid_limit")
        XCTAssertEqual(e["field"] as? String, "limit")
    }
}

// MARK: - Read-back verification (never trust an attempted setter)

final class MailMutationVerificationTests: XCTestCase {
    private func outcome(
        readRequested: Bool? = nil, readAfter: Bool? = nil, readVerified: Bool = false,
        moveRequestedTo: String? = nil, moveVerified: Bool = false, unverifiedReason: String? = nil
    ) -> MacCLICore.MailMutationOutcome {
        return MacCLICore.MailMutationOutcome(
            readRequested: readRequested, readAfter: readAfter, readVerified: readVerified,
            moveRequestedTo: moveRequestedTo, moveVerified: moveVerified,
            unverifiedReason: unverifiedReason)
    }

    func testReadStateVerifiedFromObservedState() {
        XCTAssertTrue(MacCLICore.mailMutationVerified(
            outcome(readRequested: true, readAfter: true, readVerified: true)))
    }

    func testSetterThatDidNotStickIsNotSuccess() {
        XCTAssertFalse(MacCLICore.mailMutationVerified(
            outcome(readRequested: true, readAfter: false, readVerified: true)))
    }

    func testUnreadableStateIsNotSuccess() {
        // Mail accepted the assignment and said nothing; that is not evidence.
        XCTAssertFalse(MacCLICore.mailMutationVerified(
            outcome(readRequested: true, readAfter: nil, readVerified: false)))
        XCTAssertFalse(MacCLICore.mailMutationVerified(
            outcome(readRequested: true, readAfter: true, readVerified: false)))
    }

    func testMarkingUnreadIsVerifiedAgainstFalseNotTruthiness() {
        XCTAssertTrue(MacCLICore.mailMutationVerified(
            outcome(readRequested: false, readAfter: false, readVerified: true)))
        XCTAssertFalse(MacCLICore.mailMutationVerified(
            outcome(readRequested: false, readAfter: true, readVerified: true)))
    }

    func testUnverifiedMoveIsNotSuccess() {
        XCTAssertFalse(MacCLICore.mailMutationVerified(
            outcome(moveRequestedTo: "Archive", moveVerified: false)))
        XCTAssertTrue(MacCLICore.mailMutationVerified(
            outcome(moveRequestedTo: "Archive", moveVerified: true)))
    }

    func testAnyUnverifiedReasonVetoesEverything() {
        // Even a fully observed read and move cannot be called verified once the
        // read-back itself reported a problem.
        XCTAssertFalse(MacCLICore.mailMutationVerified(
            outcome(readRequested: true, readAfter: true, readVerified: true,
                    moveRequestedTo: "Archive", moveVerified: true,
                    unverifiedReason: "readback_failed")))
    }

    func testChecksForUnrequestedMutationsAreSkippedNotFailed() {
        XCTAssertTrue(MacCLICore.mailMutationVerified(
            outcome(readRequested: nil, readAfter: nil, readVerified: false,
                    moveRequestedTo: nil, moveVerified: false)))
        XCTAssertTrue(MacCLICore.mailMutationVerified(
            outcome(readRequested: true, readAfter: true, readVerified: true,
                    moveRequestedTo: nil, moveVerified: false)))
    }

    func testMutationOKRequiresExactlyOneAffectedMessage() {
        let good = outcome(readRequested: true, readAfter: true, readVerified: true)
        XCTAssertTrue(MacCLICore.mailMutationOK(affectedCount: 1, outcome: good))
        for bad in [-1, 0, 2, 500] {
            XCTAssertFalse(MacCLICore.mailMutationOK(affectedCount: bad, outcome: good),
                           "affected_count \(bad) must be a failure")
        }
    }

    func testOneAffectedButUnverifiedIsStillAFailure() {
        XCTAssertFalse(MacCLICore.mailMutationOK(
            affectedCount: 1,
            outcome: outcome(readRequested: true, readAfter: false, readVerified: true)))
    }
}

// MARK: - Mutation result envelope

final class MailMutationResultTests: XCTestCase {
    private let ref = MacCLICore.MailMessageRef(
        account: "Work", mailbox: "INBOX", id: "4711", rfcMessageID: "<abc123@example.com>")

    private func result(
        matched: Int = 1, affected: Int = 1, outcome: MacCLICore.MailMutationOutcome,
        finalMailbox: String = "Archive", readBefore: Bool? = false
    ) -> [String: Any] {
        return MacCLICore.mailMutationResultJSON(
            requested: ref, matchedCount: matched, affectedCount: affected,
            resultID: "9001", resultRFCMessageID: "<abc123@example.com>",
            finalMailbox: finalMailbox, readBefore: readBefore, outcome: outcome)
    }

    private var verifiedOutcome: MacCLICore.MailMutationOutcome {
        return MacCLICore.MailMutationOutcome(
            readRequested: true, readAfter: true, readVerified: true,
            moveRequestedTo: "Archive", moveVerified: true, unverifiedReason: nil)
    }

    func testHappyPathIsSelfDescribingAndVerifiable() {
        let r = result(outcome: verifiedOutcome)
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["status"] as? String, "ok")
        XCTAssertEqual(r["command"] as? String, "mail.mutate")
        XCTAssertEqual(r["matched_count"] as? Int, 1)
        XCTAssertEqual(r["affected_count"] as? Int, 1)
        XCTAssertEqual(r["verified"] as? Bool, true)
        XCTAssertTrue(r["unverified_reason"] is NSNull)
        XCTAssertEqual((r["requested"] as? [String: Any])?["rfc_message_id"] as? String, "<abc123@example.com>")
        XCTAssertEqual((r["message"] as? [String: Any])?["mailbox"] as? String, "Archive")
        XCTAssertEqual((r["read"] as? [String: Any])?["requested"] as? Bool, true)
        XCTAssertEqual((r["read"] as? [String: Any])?["before"] as? Bool, false)
        XCTAssertEqual((r["read"] as? [String: Any])?["after"] as? Bool, true)
        XCTAssertEqual((r["move"] as? [String: Any])?["from"] as? String, "INBOX")
        XCTAssertEqual((r["move"] as? [String: Any])?["to"] as? String, "Archive")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(r))
    }

    func testAffectedCountOtherThanOneIsAFailure() {
        for bad in [0, 2] {
            let r = result(affected: bad, outcome: verifiedOutcome)
            XCTAssertEqual(r["ok"] as? Bool, false, "affected \(bad)")
            XCTAssertEqual(r["affected_count"] as? Int, bad)
        }
    }

    func testNonUniqueMatchIsAFailure() {
        let r = result(matched: 3, outcome: verifiedOutcome)
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertEqual(r["matched_count"] as? Int, 3)
    }

    // "The setter ran" is not success — and "we could not tell" is not a flat error either.
    func testUnverifiableOutcomeIsReportedAsUnverifiedNotError() {
        let unverifiable = MacCLICore.MailMutationOutcome(
            readRequested: true, readAfter: nil, readVerified: false,
            moveRequestedTo: nil, moveVerified: false, unverifiedReason: "readback_failed")
        let r = result(outcome: unverifiable, finalMailbox: "INBOX")
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertEqual(r["status"] as? String, "unverified",
                       "the caller should re-run inventory, not blindly retry the mutation")
        XCTAssertEqual(r["verified"] as? Bool, false)
        XCTAssertEqual(r["unverified_reason"] as? String, "readback_failed")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(r))
    }

    func testAppliedButUnverifiableIsNotReportedAsAPlainError() {
        // A move whose read-back could not run may well have landed; conflating it with
        // a refusal would invite a destructive retry.
        let r = result(outcome: MacCLICore.MailMutationOutcome(
            readRequested: nil, readAfter: nil, readVerified: false,
            moveRequestedTo: "Archive", moveVerified: false,
            unverifiedReason: "destination_readback_failed"))
        XCTAssertEqual(r["status"] as? String, "unverified")
        XCTAssertEqual((r["move"] as? [String: Any])?["verified"] as? Bool, false)
    }

    func testMissingResultIdentityIsExplicitNull() {
        let r = MacCLICore.mailMutationResultJSON(
            requested: ref, matchedCount: 1, affectedCount: 1,
            resultID: nil, resultRFCMessageID: nil, finalMailbox: "INBOX",
            readBefore: nil, outcome: verifiedOutcome)
        let msg = r["message"] as? [String: Any]
        XCTAssertTrue(msg?["id"] is NSNull)
        XCTAssertTrue(msg?["rfc_message_id"] is NSNull)
        XCTAssertTrue((r["read"] as? [String: Any])?["before"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(r))
    }

    func testRefusalReportsZeroAffectedAndDistinguishesAbsenceFromAmbiguity() {
        let notFound = MacCLICore.mailMatchRefusalJSON(requested: ref, matchedCount: 0)
        XCTAssertEqual(notFound["ok"] as? Bool, false)
        XCTAssertEqual(notFound["status"] as? String, "error")
        XCTAssertEqual(notFound["error"] as? String, "message_not_found")
        XCTAssertEqual(notFound["affected_count"] as? Int, 0)

        for n in [2, 17] {
            let ambiguous = MacCLICore.mailMatchRefusalJSON(requested: ref, matchedCount: n)
            XCTAssertEqual(ambiguous["error"] as? String, "not_unique", "matched \(n)")
            XCTAssertEqual(ambiguous["affected_count"] as? Int, 0, "a refusal never mutates")
            XCTAssertEqual(ambiguous["matched_count"] as? Int, n)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(ambiguous))
        }
    }
}

// MARK: - Bounded, redacted error surfacing

final class MailErrorRedactionTests: XCTestCase {
    func testErrorIsBoundedInLength() {
        let red = MacCLICore.redactBoundedError(String(repeating: "x", count: 5000), limit: 200)
        XCTAssertEqual(red.count, 201)  // 200 characters plus the ellipsis
        XCTAssertTrue(red.hasSuffix("…"))
    }

    func testShortErrorIsNotTruncatedOrDecorated() {
        XCTAssertEqual(MacCLICore.redactBoundedError("Mail got an error: no such mailbox"),
                       "Mail got an error: no such mailbox")
    }

    func testAddressesAreRedacted() {
        let red = MacCLICore.redactBoundedError("Error: can't get message of ada@example.com in mailbox")
        XCTAssertFalse(red.contains("ada@example.com"))
        XCTAssertTrue(red.contains("[redacted-address]"))
    }

    func testEveryAddressInAMultiAddressErrorIsRedacted() {
        let red = MacCLICore.redactBoundedError("failed for a.b+tag@sub.example.co.uk and c@d.example")
        XCTAssertFalse(red.contains("@sub.example.co.uk"))
        XCTAssertFalse(red.contains("c@d.example"))
        XCTAssertEqual(red, "failed for [redacted-address] and [redacted-address]")
    }

    func testCRLFAndRunsOfWhitespaceCollapseToASingleLine() {
        // A multi-line Apple Event error must never become multiple log lines.
        let red = MacCLICore.redactBoundedError("line one\r\n\r\nline   two\n\tthree")
        XCTAssertEqual(red, "line one line two three")
        XCTAssertFalse(red.contains("\n"))
        XCTAssertFalse(red.contains("\r"))
    }

    func testEmptyOrBlankErrorBecomesStableUnknown() {
        XCTAssertEqual(MacCLICore.redactBoundedError(""), "unknown_error")
        XCTAssertEqual(MacCLICore.redactBoundedError("   "), "unknown_error")
        XCTAssertEqual(MacCLICore.redactBoundedError("\r\n\t"), "unknown_error")
    }
}

// MARK: - JXA envelope result encoding (regression: `mail refresh --json` crash)

final class JXAResultEncodingTests: XCTestCase {
    // `mail refresh` returned {"ok": true, "result": "refreshed"}. Handing that bare
    // string to JSONSerialization.data(withJSONObject:) raises an Objective-C exception
    // that `try?` cannot catch, and the CLI died on it.
    func testTopLevelStringScalarEncodesInsteadOfTrapping() {
        XCTAssertEqual(MacCLICore.encodeJXAResult("refreshed"), "\"refreshed\"")
    }

    func testOtherScalarsEncodeAsJSONFragments() {
        XCTAssertEqual(MacCLICore.encodeJXAResult(42), "42")
        XCTAssertEqual(MacCLICore.encodeJXAResult(true), "true")
        XCTAssertEqual(MacCLICore.encodeJXAResult(NSNull()), "null")
    }

    func testScalarWithJSONMetacharactersIsEscaped() {
        XCTAssertEqual(MacCLICore.encodeJXAResult("say \"hi\"\n"), "\"say \\\"hi\\\"\\n\"")
    }

    func testContainersEncodeUnchanged() {
        XCTAssertEqual(MacCLICore.encodeJXAResult(["refreshed": true]), "{\"refreshed\":true}")
        XCTAssertEqual(MacCLICore.encodeJXAResult([1, 2, 3]), "[1,2,3]")
        XCTAssertEqual(MacCLICore.encodeJXAResult([String]()), "[]")
    }

    func testAbsentResultIsAnEmptyStringNotACrash() {
        XCTAssertEqual(MacCLICore.encodeJXAResult(nil), "")
    }

    func testUnencodableValueDegradesToEmptyRatherThanTrapping() {
        XCTAssertEqual(MacCLICore.encodeJXAResult(Double.nan), "")
        XCTAssertEqual(MacCLICore.encodeJXAResult(Date()), "")
    }

    func testEveryEncodedFragmentParsesBack() {
        for value in ["refreshed", 42, true, ["a": 1], [1, 2]] as [Any] {
            let s = MacCLICore.encodeJXAResult(value)
            guard let data = s.data(using: .utf8) else { return XCTFail("no data for \(s)") }
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                             "\(s) must round-trip")
        }
    }
}

// MARK: - Mutate JXA script contract
//
// `mail mutate` used to prove uniqueness by materializing every id in the source mailbox
// (`mbox.messages.id()` / `mbox.messages.messageId()`) and refusing above a --scan-limit.
// Against the inboxes this command exists for — 24,291 and 34,263 messages — that is
// unusable: the scan either takes minutes or the scan limit refuses outright. These tests
// fail if that architecture comes back.

final class MailMutateScriptContractTests: XCTestCase {
    private func script(
        account: String = "Work", mailbox: String = "INBOX", destination: String? = "Archive",
        id: String? = "4711", rfc: String? = "<a@b.example>",
        read: Bool = true, unread: Bool = false
    ) -> String {
        return MacCLICore.mailMutateScript(
            account: account, mailbox: mailbox, destination: destination,
            id: id, rfcMessageID: rfc, read: read, unread: unread)
    }

    /// Every shape the command can be invoked in, so a banned construct cannot hide in a
    /// branch that only one flag combination emits.
    private var allShapes: [String] {
        return [
            script(destination: nil, rfc: nil),
            script(destination: nil, id: nil),
            script(destination: nil),
            script(id: nil, read: false, unread: true),
            script(rfc: nil, read: false, unread: false),
            script(read: false, unread: false),
            script(),
        ]
    }

    func testNeverEnumeratesWholeMailboxIdentityArrays() {
        for s in allShapes {
            XCTAssertFalse(s.contains("messages.id()"),
                           "mutate must not materialize every id in the mailbox")
            XCTAssertFalse(s.contains("messages.messageId()"),
                           "mutate must not materialize every Message-ID in the mailbox")
            XCTAssertFalse(s.contains("messages()"),
                           "mutate must not pull the mailbox's messages down as an array")
        }
    }

    func testNoScanLimitLogicRemains() {
        for s in allShapes {
            for banned in ["SCAN_LIMIT", "scan_limit", "scanLimit", "scan-limit",
                           "uniqueness_unverifiable"] {
                XCTAssertFalse(s.contains(banned), "mutate must not reintroduce \(banned)")
            }
        }
    }

    func testLocatesByExactMailSideFilters() {
        // The whole point: Mail evaluates the predicate, so the cost is O(matches).
        let s = script()
        XCTAssertTrue(s.contains("whose({id: idNum})"))
        XCTAssertTrue(s.contains("whose({messageId: form})"))
    }

    func testNeverAddressesAMessageByPosition() {
        // Indexing `messages[n]` is what made the old two-script design racy.
        for s in allShapes {
            XCTAssertFalse(s.contains("mr.mbox.messages[INDEX]"))
            XCTAssertFalse(s.contains("INDEX"))
        }
    }

    func testNoDestructiveOrFuzzySelectors() {
        for s in allShapes {
            // The predicate-operator spellings, not the words: `unverified_reason` values
            // like "destination_contains_duplicates" legitimately contain "_contains".
            for banned in ["delete(", "expunge", "permanentlyDelete", "_contains:",
                           "_beginsWith:", "_endsWith:", "whose({subject", "whose({sender"] {
                XCTAssertFalse(s.contains(banned), "mutate must never emit \(banned)")
            }
        }
    }

    func testDestinationIsResolvedBeforeAnythingIsMutated() {
        let s = script()
        guard let destResolve = s.range(of: "dest = dr.mbox"),
              let readSetter = s.range(of: "m.readStatus = SET_READ"),
              let move = s.range(of: "Mail.move(") else {
            return XCTFail("expected destination resolution, read setter and move in the script")
        }
        XCTAssertTrue(destResolve.lowerBound < readSetter.lowerBound)
        XCTAssertTrue(destResolve.lowerBound < move.lowerBound)
    }

    func testLookupMutationAndReadBackShareOneScriptWindow() {
        // One osascript invocation: any seam between them is a window for the mailbox to
        // change under us.
        let s = script()
        XCTAssertTrue(s.contains("selById("))          // lookup
        XCTAssertTrue(s.contains("m.readStatus = SET_READ"))  // mutation
        XCTAssertTrue(s.contains("Mail.move("))              // mutation
        XCTAssertTrue(s.contains("countByRfc(dest, bare)"))  // read-back
        XCTAssertTrue(s.contains("countByRfc(mr.mbox, bare)"))
    }

    func testMoveIsVerifiedByExactCountsInBothMailboxes() {
        // Exactly one in the destination AND zero in the source. A setter that did not
        // throw is not evidence.
        let s = script()
        XCTAssertTrue(s.contains("else if (sc > 0) { unverified('source_still_contains_message'); }"))
        XCTAssertTrue(s.contains("else if (dc === 1) { res.move_verified = true; }"))
        XCTAssertTrue(s.contains("else if (dc === 0) { unverified('move_not_applied'); }"))
    }

    func testMoveFailurePreservesAnyEarlierReadMutationCount() {
        let s = script()
        XCTAssertTrue(s.contains("fail('move_failed', e, {affected_count: res.affected})"),
                      "a failed move must not claim zero affected after mark-read already landed")
    }

    func testIdIsEmittedAsANumericLiteralAndMessageIDAsAStringLiteral() {
        let s = script(id: "4711", rfc: "<a@b.example>")
        XCTAssertTrue(s.contains("var WANT_ID = 4711;"))
        XCTAssertTrue(s.contains("var WANT_RFC = 'a@b.example';"))  // normalized, brackets dropped
    }

    func testBothIdentitiesMustDescribeTheSameMessage() {
        let s = script(id: "4711", rfc: "<a@b.example>")
        XCTAssertTrue(s.contains("if (WANT_ID !== null && curId !== String(WANT_ID))"))
        XCTAssertTrue(s.contains("if (WANT_RFC !== null && normId(curRfc) !== normId(WANT_RFC))"))
        XCTAssertTrue(s.contains("identity_mismatch"))
    }

    func testBothBracketSpellingsOfTheMessageIDAreProbedExactly() {
        let s = script()
        XCTAssertTrue(s.contains("function rfcForms(bare) { return [bare, '<' + bare + '>']; }"))
    }

    func testAbsentSelectorsBecomeJSNull() {
        let noMove = script(destination: nil)
        XCTAssertTrue(noMove.contains("var MOVE_TO = null;"))
        XCTAssertTrue(script(id: nil).contains("var WANT_ID = null;"))
        XCTAssertTrue(script(rfc: nil).contains("var WANT_RFC = null;"))
    }

    func testSetReadIsAJSBooleanOrNullNeverAnExpression() {
        XCTAssertTrue(script(read: true, unread: false).contains("var SET_READ = true;"))
        XCTAssertTrue(script(read: false, unread: true).contains("var SET_READ = false;"))
        XCTAssertTrue(script(read: false, unread: false).contains("var SET_READ = null;"))
    }

    func testHostileSelectorsCannotBreakOutOfTheirLiterals() {
        // A mailbox named with a quote must stay inside the literal it was placed in.
        // The payload text still appears — inside the literal, which is the point. What
        // matters is that it stays escaped and never becomes a statement.
        let s = script(account: "a'; Mail.quit(); //", mailbox: "In\\box", destination: "A'B")
        XCTAssertTrue(s.contains("var WANT_ACCOUNT = 'a\\'; Mail.quit(); //';"))
        XCTAssertTrue(s.contains("var WANT_MAILBOX = 'In\\\\box';"))
        XCTAssertTrue(s.contains("var MOVE_TO = 'A\\'B';"))
    }

    func testMalformedIdCanNeverReachTheNumericSlot() {
        // Defence in depth: validation refuses these, but the emitter must also not
        // splice a non-numeric value into a position where it would be evaluated as code.
        for bad in ["4711; Mail.quit()", "1 || 1", "-1", ""] {
            XCTAssertTrue(script(id: bad).contains("var WANT_ID = null;"),
                          "non-numeric --id must degrade to null, not reach the numeric slot")
        }
    }
}
