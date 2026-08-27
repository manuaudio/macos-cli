import Foundation

// Pure decision layer for the `mail inventory` / `mail mutate` machine API.
//
// These two commands exist so an external classifier can triage a real inbox
// safely. That safety is entirely a property of the code in this file: nothing
// here touches Mail.app or JXA, so every rule below — argument validation,
// exact-identity uniqueness, affected-count enforcement, and post-mutation
// read-back verification — is covered by deterministic tests with synthetic
// fixtures.
//
// The legacy `mail search/mark/delete` commands take a substring, sweep every
// account and mailbox, and slice at 500. None of that is reachable from here:
// inventory and mutate require an explicit account AND mailbox, and mutate
// additionally requires a stable per-message identity. There is no substring
// selector on `mail mutate` at all, and no delete/expunge path.
extension MacCLICore {

    // MARK: - Bounds

    /// Hard ceiling on one inventory page. Callers page with `--offset`; there is no
    /// "give me everything" mode, so a typo can never become a full-mailbox sweep.
    public static let mailInventoryMaxLimit = 500

    // NOTE: `mail mutate` deliberately has NO scan limit and no mailbox-size ceiling.
    // It used to enumerate every id in the source mailbox to prove uniqueness, which is
    // O(mailbox) — unusable against the real inboxes this exists for (24k and 34k
    // messages). Uniqueness is now proven by an exact Mail-side filtered specifier
    // (`messages.whose(...)`), whose cost is O(matches). See `mailMutateScript`.

    // MARK: - Validation

    /// Outcome of validating caller-supplied arguments. `error` is a stable machine
    /// code (never a localized string); `field` names the offending flag when known.
    public struct MailValidation: Equatable {
        public let valid: Bool
        public let error: String?
        public let field: String?
        public let message: String?
        public init(valid: Bool, error: String?, field: String?, message: String?) {
            self.valid = valid
            self.error = error
            self.field = field
            self.message = message
        }
        public static let ok = MailValidation(valid: true, error: nil, field: nil, message: nil)
        static func fail(_ error: String, _ field: String?, _ message: String) -> MailValidation {
            return MailValidation(valid: false, error: error, field: field, message: message)
        }
    }

    /// True when a selector is usable: present, non-blank, and free of control
    /// characters. Control characters cannot occur in a real account name, mailbox
    /// name, or Message-ID, and rejecting them before the value is ever spliced into a
    /// JXA literal keeps the escaping surface small and auditable.
    static func mailSelectorIsUsable(_ value: String?) -> Bool {
        guard let value = value else { return false }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// True when `--id` is a plain non-negative decimal integer, which is what Mail's
    /// message `id` property actually is.
    ///
    /// This matters beyond tidiness: the id is interpolated into the JXA filter as a
    /// NUMERIC literal (`messages.whose({id: 12345})`), because Mail will not match an
    /// integer property against a string. Restricting the value to digits means nothing
    /// but digits can ever reach that position. The 18-digit ceiling keeps it inside the
    /// range a JS number represents exactly, so a huge value cannot round to a different
    /// message's id.
    public static func mailNumericIDIsValid(_ raw: String?) -> Bool {
        guard let raw = raw else { return false }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 18 else { return false }
        return s.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    /// Validate `mail inventory` arguments before any Apple Event is sent.
    ///
    /// Both scope selectors are mandatory and explicit — there is deliberately no
    /// "all accounts" or "all mailboxes" mode — and the retrieval window must be
    /// positive and bounded.
    public static func validateMailInventoryArgs(
        account: String, mailbox: String, limit: Int, offset: Int
    ) -> MailValidation {
        guard mailSelectorIsUsable(account) else {
            return .fail("invalid_account", "account",
                         "--account must be a non-empty account name or address.")
        }
        guard mailSelectorIsUsable(mailbox) else {
            return .fail("invalid_mailbox", "mailbox",
                         "--mailbox must be a non-empty mailbox name.")
        }
        guard limit > 0, limit <= mailInventoryMaxLimit else {
            return .fail("invalid_limit", "limit",
                         "--limit must be between 1 and \(mailInventoryMaxLimit); page with --offset.")
        }
        guard offset >= 0 else {
            return .fail("invalid_offset", "offset", "--offset must be zero or greater.")
        }
        return .ok
    }

    /// Validate `mail mutate` arguments before any Apple Event is sent.
    ///
    /// Ordering matters and is load-bearing: scope, then identity, then the requested
    /// mutations. A malformed destination is reported as such rather than being
    /// silently downgraded to "you asked for nothing".
    public static func validateMailMutateArgs(
        account: String, mailbox: String,
        id: String?, rfcMessageID: String?,
        read: Bool, unread: Bool, moveTo: String?
    ) -> MailValidation {
        guard mailSelectorIsUsable(account) else {
            return .fail("invalid_account", "account",
                         "--account must be a non-empty account name or address.")
        }
        guard mailSelectorIsUsable(mailbox) else {
            return .fail("invalid_mailbox", "mailbox",
                         "--mailbox must be a non-empty source mailbox name.")
        }
        guard mailSelectorIsUsable(id) || mailSelectorIsUsable(rfcMessageID) else {
            return .fail("missing_identity", nil,
                         "Supply --id and/or --message-id. mutate never matches on subject or sender.")
        }
        if mailSelectorIsUsable(id), !mailNumericIDIsValid(id) {
            return .fail("invalid_id", "id",
                         "--id must be Mail's numeric message id exactly as `mail inventory` reports it.")
        }
        if read && unread {
            return .fail("conflicting_read_flags", nil, "--read and --unread are mutually exclusive.")
        }
        if let dest = moveTo {
            guard mailSelectorIsUsable(dest) else {
                return .fail("invalid_destination", "move-to",
                             "--move-to must be a non-empty destination mailbox name.")
            }
            let from = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = dest.trimmingCharacters(in: .whitespacesAndNewlines)
            if from == to {
                return .fail("destination_equals_source", "move-to",
                             "--move-to names the source mailbox; that is a no-op, not a move.")
            }
        }
        if !read && !unread && moveTo == nil {
            return .fail("no_mutation_requested", nil,
                         "Specify at least one of --read, --unread, --move-to.")
        }
        return .ok
    }

    /// A single reversible mutation. There is no delete case, by design.
    public enum MailMutation: Equatable {
        case markRead
        case markUnread
        case move(String)
    }

    /// The mutations a caller asked for, in application order: read-state first, then
    /// the move — so the read flag is set while the message is still at a known address.
    public static func mailMutationsRequested(read: Bool, unread: Bool, moveTo: String?) -> [MailMutation] {
        var out: [MailMutation] = []
        if read { out.append(.markRead) }
        if unread { out.append(.markUnread) }
        if let dest = moveTo, mailSelectorIsUsable(dest) {
            out.append(.move(dest.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return out
    }

    // MARK: - JXA string escaping

    /// Escape a string for safe interpolation into a single-quoted JXA string literal.
    ///
    /// The backslash MUST be handled first, else the escape character introduced for a
    /// quote gets re-escaped into a literal backslash and the quote breaks out.
    /// U+2028/U+2029 are JavaScript line terminators: left raw they end the literal.
    public static func jxaStringEscape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // MARK: - Bounded, redacted error surfacing

    /// Turn a raw JXA/Apple Event error into a single-line, length-bounded string with
    /// e-mail addresses removed. Errors are surfaced, never swallowed — but they must
    /// not smuggle correspondent addresses or multi-kilobyte script dumps into logs.
    public static func redactBoundedError(_ raw: String, limit: Int = 200) -> String {
        let oneLine = collapseMailWhitespace(raw)
        guard !oneLine.isEmpty else { return "unknown_error" }
        var redacted = oneLine
        if let re = try? NSRegularExpression(
            pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", options: []) {
            redacted = re.stringByReplacingMatches(
                in: redacted, options: [],
                range: NSRange(redacted.startIndex..., in: redacted),
                withTemplate: "[redacted-address]")
        }
        if redacted.count > limit { return String(redacted.prefix(limit)) + "…" }
        return redacted
    }

    /// `"\r\n"` must be listed explicitly: it is a single Swift Character, so testing only
    /// for `"\r"` and `"\n"` leaves a CRLF pair intact and a "single-line" error would
    /// still span two log lines.
    private static func collapseMailWhitespace(_ s: String) -> String {
        return s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r\n" || $0 == "\r" || $0 == "\n" })
            .joined(separator: " ")
    }

    // MARK: - Exact-identity selection (fail closed)

    /// One candidate message reduced to just its addressable identity.
    public struct MailCandidate: Equatable {
        public let id: String?
        public let rfcMessageID: String?
        public init(id: String?, rfcMessageID: String?) {
            self.id = id
            self.rfcMessageID = rfcMessageID
        }
    }

    public enum MailSelectionVerdict: Equatable {
        case unique
        case notFound
        case notUnique
        case missingIdentity
    }

    public struct MailSelection: Equatable {
        public let indices: [Int]
        public let verdict: MailSelectionVerdict
        public init(indices: [Int], verdict: MailSelectionVerdict) {
            self.indices = indices
            self.verdict = verdict
        }
    }

    /// Normalize an RFC Message-ID for comparison: trim surrounding whitespace and the
    /// optional angle brackets. Case is PRESERVED — the local part of a Message-ID is
    /// case-sensitive, and folding it would let two distinct messages collide.
    static func normalizeRFCMessageID(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") { s.removeFirst() }
        if s.hasSuffix(">") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Select the messages matching the supplied identity, fail closed.
    ///
    /// Matching is EXACT on both selectors — never substring, never prefix, never
    /// case-folded. When both are supplied a candidate must satisfy BOTH, so a caller
    /// that pairs a stale numeric id with a Message-ID gets a refusal rather than
    /// having one half of its request silently honoured. Anything other than
    /// `.unique` must stop the mutation.
    public static func mailSelectUnique(
        candidates: [MailCandidate], id: String?, rfcMessageID: String?
    ) -> MailSelection {
        let wantID: String? = mailSelectorIsUsable(id)
            ? id!.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let wantRFC: String? = mailSelectorIsUsable(rfcMessageID)
            ? normalizeRFCMessageID(rfcMessageID!) : nil

        guard wantID != nil || wantRFC != nil else {
            return MailSelection(indices: [], verdict: .missingIdentity)
        }

        let indices = candidates.indices.filter { i in
            let c = candidates[i]
            if let wantID = wantID {
                guard let have = c.id, have == wantID else { return false }
            }
            if let wantRFC = wantRFC {
                guard let have = c.rfcMessageID, normalizeRFCMessageID(have) == wantRFC else { return false }
            }
            return true
        }
        switch indices.count {
        case 0: return MailSelection(indices: indices, verdict: .notFound)
        case 1: return MailSelection(indices: indices, verdict: .unique)
        default: return MailSelection(indices: indices, verdict: .notUnique)
        }
    }

    // MARK: - RFC header extraction

    /// The classification-relevant headers a pertinent-mail filter needs. Everything
    /// else Mail exposes (the Received chain, Return-Path, X-* noise, and above all the
    /// body) is dropped and never reaches the caller.
    public static let mailClassificationHeaderNames: [String] = [
        "message-id",
        "in-reply-to",
        "references",
        "list-id",
        "list-unsubscribe",
        "list-unsubscribe-post",
        "precedence",
        "auto-submitted",
    ]

    /// Parse a raw RFC 5322 header block into the allowlisted subset.
    ///
    /// Folded continuation lines are unfolded onto one line, names are matched
    /// case-insensitively and normalized to lowercase, and the FIRST occurrence of a
    /// duplicated field wins (a forged trailing `Precedence:` must not override the real
    /// one). Parsing stops at the first blank line, so body text can never be parsed as
    /// a header even if more than the header block is handed over.
    public static func mailClassificationHeaders(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        var currentName: String?
        var currentValue = ""

        func flush() {
            defer { currentName = nil; currentValue = "" }
            guard let name = currentName else { return }
            guard mailClassificationHeaderNames.contains(name), out[name] == nil else { return }
            let collapsed = collapseMailWhitespace(currentValue)
            if !collapsed.isEmpty { out[name] = collapsed }
        }

        // Split on any line ending. `"\r\n"` is ONE Swift Character (an extended grapheme
        // cluster), so `split(separator: "\n")` silently fails to break CRLF header text
        // apart — and Mail hands back exactly that, which would have collapsed a whole
        // header block, blank line and body included, into a single "value".
        for lineSlice in raw.split(omittingEmptySubsequences: false,
                                   whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }) {
            let line = String(lineSlice)
            if line.isEmpty { break }  // end of the header block
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if currentName != nil {
                    currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            guard isValidMailHeaderName(name) else { continue }
            currentName = name
            currentValue = String(line[line.index(after: colon)...])
        }
        flush()
        return out
    }

    /// RFC 5322 field name: one or more printable US-ASCII characters except colon.
    /// This is what stops a Unix `From ` envelope line (which contains a colon inside
    /// its timestamp) from being mistaken for a header field.
    private static func isValidMailHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 && $0 != ":" }
    }

    // MARK: - Inventory serialization

    private static func jsonValue(_ s: String?) -> Any {
        guard let s = s else { return NSNull() }
        return s
    }

    /// One inventory row: enough stable identity to address exactly one message later,
    /// plus the metadata a classifier needs — and never a body.
    ///
    /// Every field Mail might fail to produce is emitted as either a value or an
    /// explicit JSON `null`, so a consumer can tell "Mail did not expose this" from "the
    /// key moved". `errors` names each field that could not be read, and `addressable`
    /// states plainly whether this row can be the target of a later `mail mutate`.
    public static func mailInventoryItemJSON(
        account: String,
        mailbox: String,
        index: Int,
        id: String?,
        rfcMessageID: String?,
        subject: String?,
        sender: String?,
        toRecipients: [String],
        ccRecipients: [String],
        dateSent: String?,
        dateReceived: String?,
        read: Bool?,
        flagged: Bool?,
        headers: [String: String],
        headersStatus: String,
        errors: [String]
    ) -> [String: Any] {
        let usableID = mailSelectorIsUsable(id) ? id : nil
        let usableRFC = mailSelectorIsUsable(rfcMessageID) ? rfcMessageID : nil
        return [
            "account": account,
            "mailbox": mailbox,
            "index": index,
            "id": jsonValue(usableID),
            "rfc_message_id": jsonValue(usableRFC),
            "addressable": usableID != nil || usableRFC != nil,
            "subject": jsonValue(subject),
            "sender": jsonValue(sender),
            "to": toRecipients,
            "cc": ccRecipients,
            "date_sent": jsonValue(dateSent),
            "date_received": jsonValue(dateReceived),
            "read": read as Any? ?? NSNull(),
            "flagged": flagged as Any? ?? NSNull(),
            "headers": headers,
            "headers_status": headersStatus,
            "errors": errors,
        ]
    }

    /// Wrap inventory rows in the paginated envelope.
    ///
    /// The load-bearing rule: `ok` is true ONLY when nothing degraded. A partial result
    /// is reported as `ok: false` / `status: "degraded"` — with the rows it did manage to
    /// retrieve — so a swallowed per-message or per-mailbox failure can never be mistaken
    /// for a complete inventory. `has_more` is false whenever the page came back empty,
    /// so a paging caller can never be sent round a loop forever.
    ///
    /// `order` is `mailbox_native`: rows come back in Mail's own mailbox order, and
    /// `offset` indexes into that order.
    public static func mailInventoryEnvelope(
        messages: [[String: Any]],
        account: String,
        mailbox: String,
        unreadOnly: Bool,
        limit: Int,
        offset: Int,
        totalMatching: Int,
        totalInMailbox: Int,
        degraded: [String]
    ) -> [String: Any] {
        let ok = degraded.isEmpty
        let consumed = offset + messages.count
        let hasMore = !messages.isEmpty && consumed < totalMatching
        var d: [String: Any] = [
            "ok": ok,
            "status": ok ? "ok" : "degraded",
            "command": "mail.inventory",
            "account": account,
            "mailbox": mailbox,
            "unread_only": unreadOnly,
            "limit": limit,
            "offset": offset,
            "count": messages.count,
            "total_matching": totalMatching,
            "total_in_mailbox": totalInMailbox,
            "has_more": hasMore,
            "next_offset": hasMore ? consumed : NSNull(),
            "order": "mailbox_native",
            "degraded": degraded,
            "messages": messages,
        ]
        if !ok {
            d["message"] = "Part of this inventory could not be read; it is incomplete. "
                + "Do not treat a degraded page as a complete view of the mailbox."
        }
        return d
    }

    /// A structured refusal for either command. Carries no `messages`/`count` keys, so it
    /// is structurally impossible to mistake for an empty successful inventory. Values in
    /// `extra` are merged in for context but can never override the status keys.
    public static func mailErrorJSON(
        command: String, error: String, message: String, extra: [String: Any] = [:]
    ) -> [String: Any] {
        var d: [String: Any] = extra
        d["ok"] = false
        d["status"] = "error"
        d["command"] = command
        d["error"] = error
        d["message"] = message
        return d
    }

    // MARK: - Mutation contract

    /// The identity a mutation was asked to act on.
    public struct MailMessageRef: Equatable {
        public let account: String
        public let mailbox: String
        public let id: String?
        public let rfcMessageID: String?
        public init(account: String, mailbox: String, id: String?, rfcMessageID: String?) {
            self.account = account
            self.mailbox = mailbox
            self.id = id
            self.rfcMessageID = rfcMessageID
        }
        public var jsonObject: [String: Any] {
            return [
                "account": account,
                "mailbox": mailbox,
                "id": id as Any? ?? NSNull(),
                "rfc_message_id": rfcMessageID as Any? ?? NSNull(),
            ]
        }
    }

    /// What was observed AFTER the setters ran. `readAfter` / `moveVerified` come from a
    /// fresh read-back, never from the fact that a setter did not throw.
    public struct MailMutationOutcome: Equatable {
        /// nil when no read-state change was requested.
        public let readRequested: Bool?
        /// The read flag observed after mutating; nil when it could not be read back.
        public let readAfter: Bool?
        /// True when a read-back actually happened and produced a usable value.
        public let readVerified: Bool
        /// nil when no move was requested.
        public let moveRequestedTo: String?
        /// True when the message was found in the destination after the move.
        public let moveVerified: Bool
        /// Stable machine code explaining why verification could not be completed.
        public let unverifiedReason: String?
        public init(readRequested: Bool?, readAfter: Bool?, readVerified: Bool,
                    moveRequestedTo: String?, moveVerified: Bool, unverifiedReason: String?) {
            self.readRequested = readRequested
            self.readAfter = readAfter
            self.readVerified = readVerified
            self.moveRequestedTo = moveRequestedTo
            self.moveVerified = moveVerified
            self.unverifiedReason = unverifiedReason
        }
    }

    /// Did the requested mutation demonstrably take effect?
    ///
    /// An attempted setter is not evidence. Apple Mail will accept a property assignment
    /// on a specifier it cannot honour and report nothing, so success is asserted only
    /// from state observed after the fact: the read flag must have been read back AND
    /// equal what was asked for, and a moved message must have been found in the
    /// destination. Checks for mutations that were never requested are skipped, not failed.
    public static func mailMutationVerified(_ o: MailMutationOutcome) -> Bool {
        if o.unverifiedReason != nil { return false }
        if let want = o.readRequested {
            guard o.readVerified, let after = o.readAfter, after == want else { return false }
        }
        if o.moveRequestedTo != nil {
            guard o.moveVerified else { return false }
        }
        return true
    }

    /// A mutation succeeded only when it affected exactly one message AND that effect was
    /// verified. Any other affected count — zero, two, negative — is a failure.
    public static func mailMutationOK(affectedCount: Int, outcome: MailMutationOutcome) -> Bool {
        return affectedCount == 1 && mailMutationVerified(outcome)
    }

    /// The result envelope for an attempted mutation.
    ///
    /// It lets a caller verify, without re-querying: the identity it asked for, the
    /// account/mailbox the message started in, its final mailbox, the read state before
    /// and after, which checks were verified, and the affected count.
    ///
    /// `status: "unverified"` is deliberately distinct from `"error"`: the mutation may
    /// well have landed, so the correct caller response is to re-run `mail inventory`,
    /// not to blindly retry the mutation.
    public static func mailMutationResultJSON(
        requested: MailMessageRef,
        matchedCount: Int,
        affectedCount: Int,
        resultID: String?,
        resultRFCMessageID: String?,
        finalMailbox: String,
        readBefore: Bool?,
        outcome: MailMutationOutcome
    ) -> [String: Any] {
        let verified = mailMutationVerified(outcome)
        let ok = matchedCount == 1 && affectedCount == 1 && verified
        let status: String = ok ? "ok" : (verified ? "error" : "unverified")
        return [
            "ok": ok,
            "status": status,
            "command": "mail.mutate",
            "requested": requested.jsonObject,
            "matched_count": matchedCount,
            "affected_count": affectedCount,
            "verified": verified,
            "unverified_reason": outcome.unverifiedReason as Any? ?? NSNull(),
            "message": [
                "account": requested.account,
                "mailbox": finalMailbox,
                "id": resultID as Any? ?? NSNull(),
                "rfc_message_id": resultRFCMessageID as Any? ?? NSNull(),
            ],
            "read": [
                "requested": outcome.readRequested != nil,
                "before": readBefore as Any? ?? NSNull(),
                "after": outcome.readAfter as Any? ?? NSNull(),
                "verified": outcome.readVerified,
            ],
            "move": [
                "requested": outcome.moveRequestedTo != nil,
                "from": requested.mailbox,
                "to": outcome.moveRequestedTo as Any? ?? NSNull(),
                "verified": outcome.moveVerified,
            ],
        ]
    }

    // NOTE: `encodeJXAResult` now lives in MacCLICore.swift — it is not specific to the
    // mail inventory/mutate surface, and the `mail refresh` crash it fixes is on the
    // legacy path. Call `MacCLICore.encodeJXAResult` from here.

    /// The refusal emitted when an identity did not select exactly one message in exactly
    /// the specified account and mailbox. Nothing was mutated, so `affected_count` is 0.
    public static func mailMatchRefusalJSON(requested: MailMessageRef, matchedCount: Int) -> [String: Any] {
        let notFound = matchedCount == 0
        return [
            "ok": false,
            "status": "error",
            "command": "mail.mutate",
            "error": notFound ? "message_not_found" : "not_unique",
            "requested": requested.jsonObject,
            "matched_count": matchedCount,
            "affected_count": 0,
            "message": notFound
                ? "No message with that identity exists in the specified account and mailbox."
                : "That identity matched \(matchedCount) messages; exactly one is required. Nothing was changed.",
        ]
    }

    // MARK: - JXA source (pure string construction, so the contract is testable)

    /// A JS string literal, or the JS `null` literal when there is no value.
    public static func jsLiteral(_ value: String?) -> String {
        guard let v = value else { return "null" }
        return "'" + jxaStringEscape(v) + "'"
    }

    /// A JS *numeric* literal, or `null`. Only digit strings survive `mailNumericIDIsValid`,
    /// so this can never emit an expression.
    public static func jsNumericLiteral(_ value: String?) -> String {
        guard let v = value, mailNumericIDIsValid(v) else { return "null" }
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shared scope resolver and exact-locator helpers for the scoped machine API.
    ///
    /// `inventory` and `mutate` share this so both agree, to the character, on what "this
    /// account" and "this mailbox" mean. Resolution is EXACT and fail-closed: an account
    /// matches on its exact name or one of its exact addresses, a mailbox on its exact
    /// name, and anything resolving to zero or more than one target is refused rather than
    /// guessed. Nested mailboxes sharing a leaf name are therefore reported ambiguous.
    ///
    /// The locator helpers below build Mail-side FILTERED OBJECT SPECIFIERS. Mail evaluates
    /// the predicate itself and hands back only the matches, so the cost is O(matches), not
    /// O(mailbox). Nothing here ever materializes `messages.id()` or `messages.messageId()`
    /// as an array — against a 34,000-message inbox that is the difference between a
    /// sub-second call and one that never returns.
    ///
    /// Written in ES5-flavoured JavaScript with no regular expressions and no backslash
    /// escapes, so the source survives Swift string interpolation unaltered.
    public static let jxaMailPrelude = """
    function fail(code, detail, extra) {
      var o = extra || {};
      o.ok = false;
      o.error = code;
      if (detail !== null && detail !== undefined) { o.detail = String(detail).slice(0, 300); }
      return JSON.stringify(o);
    }
    function isoDate(d) {
      try { return d ? d.toISOString() : null; } catch (e) { return null; }
    }
    function normId(s) {
      if (s === null || s === undefined) return null;
      var t = String(s).trim();
      if (t.charAt(0) === '<') { t = t.slice(1); }
      if (t.length > 0 && t.charAt(t.length - 1) === '>') { t = t.slice(0, -1); }
      return t.trim();
    }
    function resolveAccount(Mail, want) {
      var accounts;
      try { accounts = Mail.accounts(); } catch (e) { return {err: 'account_enumeration_failed', detail: e}; }
      var found = [], names = [];
      for (var i = 0; i < accounts.length; i++) {
        var a = accounts[i], nm = null, ems = [];
        try { nm = a.name(); } catch (e) { nm = null; }
        if (nm === null || nm === undefined) continue;
        names.push(String(nm));
        try { ems = a.emailAddresses() || []; } catch (e) { ems = []; }
        var hit = (String(nm) === want);
        if (!hit) {
          for (var j = 0; j < ems.length; j++) { if (String(ems[j]) === want) { hit = true; break; } }
        }
        if (hit) { found.push({obj: a, name: String(nm), email: ems.length ? String(ems[0]) : null}); }
      }
      if (found.length === 1) return {acct: found[0]};
      return {err: found.length === 0 ? 'account_not_found' : 'account_ambiguous',
              matched: found.length, available: names.slice(0, 50)};
    }
    function resolveMailbox(acctObj, want) {
      var boxes;
      try { boxes = acctObj.mailboxes(); } catch (e) { return {err: 'mailbox_enumeration_failed', detail: e}; }
      var found = [], names = [];
      for (var i = 0; i < boxes.length; i++) {
        var b = boxes[i], nm = null;
        try { nm = b.name(); } catch (e) { nm = null; }
        if (nm === null || nm === undefined) continue;
        names.push(String(nm));
        if (String(nm) === want) { found.push(b); }
      }
      if (found.length === 1) return {mbox: found[0]};
      return {err: found.length === 0 ? 'mailbox_not_found' : 'mailbox_ambiguous',
              matched: found.length, available: names.slice(0, 100)};
    }
    // Mail stores the RFC Message-ID with or without angle brackets depending on how the
    // message arrived, and an exact predicate cannot normalize. Both spellings are probed
    // as separate exact filters; a message's messageId equals at most one of them, so the
    // counts sum without any risk of double-counting one message.
    function rfcForms(bare) { return [bare, '<' + bare + '>']; }
    function countSel(sel) {
      try { var n = sel.length; return (typeof n === 'number' && n >= 0) ? n : -1; }
      catch (e) { return -1; }
    }
    // Exact Mail-side filter on the numeric message id.
    function selById(mbox, idNum) { return mbox.messages.whose({id: idNum}); }
    // Exact Mail-side filter on one exact spelling of the RFC Message-ID.
    function selByRfcForm(mbox, form) { return mbox.messages.whose({messageId: form}); }
    // Total exact matches for a bare Message-ID across both spellings; -1 if Mail refused.
    function countByRfc(mbox, bare) {
      var forms = rfcForms(bare), total = 0;
      for (var i = 0; i < forms.length; i++) {
        var c = countSel(selByRfcForm(mbox, forms[i]));
        if (c < 0) return -1;
        total += c;
      }
      return total;
    }
    // The single message matching a bare Message-ID, or null when it is not unique.
    function firstByRfc(mbox, bare) {
      var forms = rfcForms(bare), hit = null, total = 0;
      for (var i = 0; i < forms.length; i++) {
        var sel = selByRfcForm(mbox, forms[i]);
        var c = countSel(sel);
        if (c < 0) return null;
        total += c;
        if (c === 1 && hit === null) { try { hit = sel[0]; } catch (e) { return null; } }
      }
      return total === 1 ? hit : null;
    }
    """

    /// Build the single-window `mail mutate` script.
    ///
    /// Everything happens in ONE osascript invocation — resolve scope, resolve the
    /// destination, locate the message, mutate it, and capture the post-state — because
    /// every boundary between scripts is a window in which the mailbox can change under
    /// us. The previous two-script design located a message by array INDEX and then
    /// re-opened Mail to act on `messages[index]`, which is precisely the race this
    /// avoids: here the message is never addressed by position, only by an exact filter.
    ///
    /// Cost is O(matches). `id` is passed as a numeric literal (Mail will not match its
    /// integer `id` against a string) and both are gated by `validateMailMutateArgs`.
    ///
    /// The script refuses — `refused: true`, `affected: 0` — whenever the identity does
    /// not select exactly one message, and mutates nothing in that case.
    public static func mailMutateScript(
        account: String, mailbox: String, destination: String?,
        id: String?, rfcMessageID: String?, read: Bool, unread: Bool
    ) -> String {
        let wantRFC: String? = mailSelectorIsUsable(rfcMessageID)
            ? normalizeRFCMessageID(rfcMessageID!) : nil
        let setRead: String = read ? "true" : (unread ? "false" : "null")
        return """
        (function () {
        \(jxaMailPrelude)
        var WANT_ACCOUNT = \(jsLiteral(account));
        var WANT_MAILBOX = \(jsLiteral(mailbox));
        var MOVE_TO = \(jsLiteral(destination));
        var WANT_ID = \(jsNumericLiteral(id));
        var WANT_RFC = \(jsLiteral(wantRFC));
        var SET_READ = \(setRead);

        var Mail;
        try { Mail = Application('Mail'); } catch (e) { return fail('mail_unavailable', e); }
        var ar = resolveAccount(Mail, WANT_ACCOUNT);
        if (ar.err) return fail(ar.err, ar.detail, {matched: ar.matched, available: ar.available});
        var mr = resolveMailbox(ar.acct.obj, WANT_MAILBOX);
        if (mr.err) return fail(mr.err, mr.detail, {matched: mr.matched, available: mr.available});

        // The destination is resolved BEFORE anything is mutated: a typo in --move-to must
        // not leave a message marked read with nowhere to go.
        var dest = null;
        if (MOVE_TO !== null) {
          var dr = resolveMailbox(ar.acct.obj, MOVE_TO);
          if (dr.err) {
            var code = dr.err === 'mailbox_not_found' ? 'destination_not_found'
                     : (dr.err === 'mailbox_ambiguous' ? 'destination_ambiguous' : dr.err);
            return fail(code, dr.detail, {matched: dr.matched});
          }
          dest = dr.mbox;
        }

        // ---- Exact Mail-side lookup. Never enumerates the mailbox.
        var m = null, matched = 0;
        if (WANT_ID !== null) {
          var sel = selById(mr.mbox, WANT_ID);
          matched = countSel(sel);
          if (matched < 0) return fail('id_filter_unavailable', null);
          if (matched === 1) { try { m = sel[0]; } catch (e) { return fail('id_filter_unavailable', e); } }
        } else {
          matched = countByRfc(mr.mbox, WANT_RFC);
          if (matched < 0) return fail('message_id_filter_unavailable', null);
          if (matched === 1) { m = firstByRfc(mr.mbox, WANT_RFC); }
        }
        if (matched !== 1 || m === null) {
          return JSON.stringify({ok: true, refused: true, matched_count: matched < 0 ? 0 : matched,
                                 affected: 0});
        }

        // Capture identity from the located message and re-check it against everything the
        // caller asserted. When both --id and --message-id are supplied the message found
        // by id must ALSO carry the requested Message-ID, so a stale pairing is refused
        // rather than half-honoured.
        var curId = null, curRfc = null;
        try { curId = String(m.id()); } catch (e) { curId = null; }
        try { var t = m.messageId(); curRfc = t ? String(t) : null; } catch (e) { curRfc = null; }
        if (WANT_ID !== null && curId !== String(WANT_ID)) {
          return fail('identity_mismatch', null, {matched_count: 1, affected_count: 0});
        }
        if (WANT_RFC !== null && normId(curRfc) !== normId(WANT_RFC)) {
          return fail('identity_mismatch', null, {matched_count: 1, affected_count: 0});
        }

        var res = {ok: true, refused: false, matched_count: 1, read_before: null, read_after: null,
                   read_verified: false, move_verified: false, final_mailbox: WANT_MAILBOX,
                   unverified_reason: null, result_id: curId, result_rfc: curRfc, affected: 0};
        function unverified(reason) { if (!res.unverified_reason) { res.unverified_reason = reason; } }
        try { res.read_before = m.readStatus(); } catch (e) { res.read_before = null; }

        // Read state first, while the message is still at a known address.
        if (SET_READ !== null) {
          try { m.readStatus = SET_READ; } catch (e) { return fail('read_setter_failed', e); }
          res.affected = 1;
          try { res.read_after = m.readStatus(); res.read_verified = true; }
          catch (e) { res.read_verified = false; unverified('read_state_not_readable'); }
        }

        if (dest !== null) {
          try { Mail.move(m, {to: dest}); } catch (e) { return fail('move_failed', e, {affected_count: res.affected}); }
          res.affected = 1;
          res.final_mailbox = MOVE_TO;
          if (curRfc === null) {
            // Mail's numeric id is not guaranteed stable across a move, so without an RFC
            // Message-ID there is nothing durable left to verify against.
            unverified('no_rfc_message_id_for_move_verification');
          } else {
            // Read back through exact filters on BOTH mailboxes. A setter that did not
            // throw proves nothing; exactly one in the destination and zero in the source
            // does. Both counts are O(matches).
            var bare = normId(curRfc);
            var dc = countByRfc(dest, bare), sc = countByRfc(mr.mbox, bare);
            if (dc < 0 || sc < 0) { unverified('move_verification_failed'); }
            else if (sc > 0) { unverified('source_still_contains_message'); }
            else if (dc === 1) { res.move_verified = true; }
            else if (dc === 0) { unverified('move_not_applied'); }
            else { unverified('destination_contains_duplicates'); }
          }
          // Re-read the read flag at the message's NEW location; the pre-move handle is
          // stale once Mail has relocated it.
          if (SET_READ !== null && res.move_verified) {
            res.read_verified = false;
            try {
              var moved = firstByRfc(dest, normId(curRfc));
              if (moved !== null) { res.read_after = moved.readStatus(); res.read_verified = true; }
            } catch (e) { res.read_verified = false; }
            if (!res.read_verified) { unverified('read_state_not_readable_after_move'); }
          }
        }
        return JSON.stringify(res);
        })()
        """
    }
}
