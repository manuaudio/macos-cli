import CryptoKit
import Foundation

// The tour connectors: Master Tour's REST API, signed with OAuth 1.0 (consumer key and
// secret only, no token), and a Daysheets tour's calendar feed, read as iCalendar and
// grouped into days. Pure: no network, no keychain; the commands do those.
extension MacCLICore {

    // MARK: - OAuth 1.0, HMAC-SHA1 (RFC 5849)

    /// RFC 3986 percent-encoding: everything but ALPHA, DIGIT, `-`, `.`, `_`, `~`.
    public static func oauthPercentEncode(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// The signature base string: method, the URL without its query, and every parameter
    /// (query and `oauth_*`) encoded, sorted by name then value, joined with `&`.
    public static func oauthBaseString(method: String, url: URL, parameters: [(String, String)]) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        parts.query = nil
        parts.fragment = nil
        let base = parts.string ?? url.absoluteString
        let pairs: [(name: String, value: String)] = parameters.map { (oauthPercentEncode($0.0), oauthPercentEncode($0.1)) }
        let sorted = pairs.sorted { (a, b) -> Bool in a.name == b.name ? a.value < b.value : a.name < b.name }
        let encoded = sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
        return [method.uppercased(), base, encoded].map(oauthPercentEncode).joined(separator: "&")
    }

    /// Base64 HMAC-SHA1 of the base string, keyed by `consumerSecret&tokenSecret`.
    public static func oauthSignature(baseString: String, consumerSecret: String, tokenSecret: String = "") -> String {
        let key = SymmetricKey(data: Data((oauthPercentEncode(consumerSecret) + "&" + oauthPercentEncode(tokenSecret)).utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(baseString.utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    /// The `Authorization: OAuth …` header for a consumer-only (two-legged) request.
    /// `url` carries the request's query; its parameters are signed with the `oauth_*` ones.
    public static func oauthAuthorizationHeader(method: String, url: URL, consumerKey: String, consumerSecret: String,
                                                nonce: String, timestamp: Int) -> String {
        var oauth: [(String, String)] = [
            ("oauth_consumer_key", consumerKey),
            ("oauth_nonce", nonce),
            ("oauth_signature_method", "HMAC-SHA1"),
            ("oauth_timestamp", String(timestamp)),
            ("oauth_version", "1.0"),
        ]
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }
        let base = oauthBaseString(method: method, url: url, parameters: oauth + query)
        oauth.append(("oauth_signature", oauthSignature(baseString: base, consumerSecret: consumerSecret)))
        return "OAuth " + oauth.sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\"\(oauthPercentEncode($0.1))\"" }
            .joined(separator: ", ")
    }

    // MARK: - Master Tour

    public static let masterTourBase = URL(string: "https://my.eventric.com/portal/api/v5/")!

    /// A Master Tour read: the path under api/v5 plus `version=7`, which the API requires
    /// on every request (without it the answer is 426).
    public static func masterTourURL(path: String, query: [(String, String)] = []) -> URL {
        var parts = URLComponents(url: masterTourBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = ([("version", "7")] + query).map { URLQueryItem(name: $0.0, value: $0.1) }
        return parts.url!
    }

    // MARK: - Daysheets (iCalendar feed)

    /// One VEVENT of the feed.
    public struct TourEvent: Equatable {
        public var uid = ""
        public var title = ""
        public var location = ""
        public var notes = ""
        public var allDay = false
        public var start: Date?
        public var end: Date?
        /// The zone the event's times are in: its TZID, else the zone the feed was read in.
        public var timeZone = TimeZone(identifier: "UTC")!
        /// YYYY-MM-DD of the first day, in `timeZone`.
        public var firstDay = ""
        /// YYYY-MM-DD of the last day it covers (an all-day DTEND is exclusive).
        public var lastDay = ""
        public init() {}
    }

    /// The content lines of an iCalendar text, unfolded (RFC 5545 3.1: a line that starts
    /// with a space or a tab continues the one before).
    public static func icsUnfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(raw)
            }
        }
        return lines
    }

    /// TEXT value escapes: `\n`, `\,`, `\;`, `\\`.
    static func icsUnescape(_ value: String) -> String {
        var out = ""
        var escaped = false
        for c in value {
            if escaped {
                out.append(c == "n" || c == "N" ? "\n" : c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Every VEVENT in the text. A date-time with `Z` is UTC, one with `TZID` is in that
    /// zone, a floating one is in `timeZone`; times are reported in the event's zone
    /// (`Z` and floating ones in `timeZone`).
    public static func parseICS(_ text: String, timeZone: TimeZone) -> [TourEvent] {
        var events: [TourEvent] = []
        var current: TourEvent?
        var nested = 0
        var endDay: (value: String, params: [String: String])?
        var startValue: (value: String, params: [String: String])?

        for line in icsUnfold(text) {
            guard let (name, params, value) = icsProperty(line) else { continue }
            switch (name, value.uppercased()) {
            case ("BEGIN", "VEVENT"):
                current = TourEvent(); nested = 0; endDay = nil; startValue = nil
                continue
            case ("END", "VEVENT"):
                if var event = current, let start = startValue {
                    resolve(&event, start: start, end: endDay, timeZone: timeZone)
                    events.append(event)
                }
                current = nil
                continue
            case ("BEGIN", _) where current != nil: nested += 1; continue
            case ("END", _) where current != nil: nested -= 1; continue
            default: break
            }
            guard current != nil, nested == 0 else { continue }
            switch name {
            case "UID": current?.uid = value
            case "SUMMARY": current?.title = icsUnescape(value)
            case "LOCATION": current?.location = icsUnescape(value)
            case "DESCRIPTION": current?.notes = icsUnescape(value)
            case "DTSTART": startValue = (value, params)
            case "DTEND": endDay = (value, params)
            default: break
            }
        }
        return events.sorted { ($0.firstDay, $0.start ?? .distantPast) < ($1.firstDay, $1.start ?? .distantPast) }
    }

    /// `NAME;PARAM=V;…:value`, the name and parameter names upper-cased. A colon inside a
    /// quoted parameter value does not end the parameters.
    static func icsProperty(_ line: String) -> (String, [String: String], String)? {
        var quoted = false
        guard let colon = line.firstIndex(where: { c in
            if c == "\"" { quoted.toggle() }
            return c == ":" && !quoted
        }) else { return nil }
        let head = line[..<colon].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var params: [String: String] = [:]
        for param in head.dropFirst() {
            let pair = param.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return (head[0].uppercased(), params, String(line[line.index(after: colon)...]))
    }

    private static func resolve(_ event: inout TourEvent, start: (value: String, params: [String: String]),
                                end: (value: String, params: [String: String])?, timeZone: TimeZone) {
        let zone = start.params["TZID"].flatMap(TimeZone.init(identifier:)) ?? timeZone
        event.timeZone = zone
        event.allDay = start.params["VALUE"]?.uppercased() == "DATE" || start.value.count == 8
        event.start = icsDate(start.value, params: start.params, fallback: zone)
        if let end = end {
            event.end = icsDate(end.value, params: end.params,
                                fallback: end.params["TZID"].flatMap(TimeZone.init(identifier:)) ?? zone)
        }
        guard let first = event.start else { return }
        event.firstDay = dayString(first, in: zone)
        event.lastDay = event.firstDay
        if event.allDay, let end = event.end, end > first {
            // DTEND of an all-day event is the day after its last.
            event.lastDay = dayString(end.addingTimeInterval(-1), in: zone)
        }
    }

    static func icsDate(_ value: String, params: [String: String], fallback: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        if value.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = fallback
            return formatter.date(from: value)
        }
        if value.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
        } else {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = params["TZID"].flatMap(TimeZone.init(identifier:)) ?? fallback
        }
        return formatter.date(from: value)
    }

    static func dayString(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The events grouped into tour days, oldest first; `from` and `to` (YYYY-MM-DD,
    /// inclusive) bound the days. An all-day event appears on every day it covers.
    /// Within a day: all-day events first, then by start time.
    public static func tourDays(_ events: [TourEvent], from: String? = nil, to: String? = nil) -> [[String: Any]] {
        var byDay: [String: [TourEvent]] = [:]
        for event in events where !event.firstDay.isEmpty {
            for day in daysBetween(event.firstDay, event.lastDay) {
                if let from = from, day < from { continue }
                if let to = to, day > to { continue }
                byDay[day, default: []].append(event)
            }
        }
        return byDay.keys.sorted().map { day in
            let sorted = byDay[day]!.sorted {
                $0.allDay != $1.allDay ? $0.allDay : ($0.start ?? .distantPast) < ($1.start ?? .distantPast)
            }
            return ["date": day, "events": sorted.map(tourEventJSON)]
        }
    }

    private static func daysBetween(_ first: String, _ last: String) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard var day = formatter.date(from: first), let end = formatter.date(from: last), end >= day else {
            return [first]
        }
        var days: [String] = []
        while day <= end, days.count < 366 {
            days.append(formatter.string(from: day))
            day = day.addingTimeInterval(86_400)
        }
        return days
    }

    /// One event as JSON. `venue` and `city` split LOCATION at its first comma
    /// ("Venue, City, State" → venue "Venue", city "City, State"); one part is the venue.
    public static func tourEventJSON(_ event: TourEvent) -> [String: Any] {
        var body: [String: Any] = [
            "uid": event.uid,
            "title": event.title,
            "all_day": event.allDay,
            "location": event.location,
            "notes": event.notes,
            "time_zone": event.timeZone.identifier,
        ]
        let parts = event.location.split(separator: ",", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        body["venue"] = parts.first.map { $0 as Any } ?? NSNull()
        body["city"] = parts.count > 1 ? parts[1] : NSNull()
        if event.allDay {
            body["start"] = event.firstDay
            body["end"] = event.lastDay
        } else {
            let iso = ISO8601DateFormatter()
            iso.timeZone = event.timeZone
            let time = DateFormatter()
            time.locale = Locale(identifier: "en_US_POSIX")
            time.timeZone = event.timeZone
            time.dateFormat = "HH:mm"
            body["start"] = event.start.map { iso.string(from: $0) as Any } ?? NSNull()
            body["end"] = event.end.map { iso.string(from: $0) as Any } ?? NSNull()
            body["start_time"] = event.start.map { time.string(from: $0) as Any } ?? NSNull()
            body["end_time"] = event.end.map { time.string(from: $0) as Any } ?? NSNull()
        }
        return body
    }

    /// True for YYYY-MM-DD.
    public static func isDay(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd"
        return value.count == 10 && formatter.date(from: value) != nil
    }
}
