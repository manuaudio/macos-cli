import ArgumentParser
import Foundation
import MacCLICore

// MARK: - Master Tour (Eventric's REST API v5, read only)

struct MasterTourCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mastertour",
        abstract: "Read tours, days, schedules, hotels and crew from Master Tour (JSON)",
        discussion: """
        Uses the Master Tour API key: copy the key and secret from my.eventric.com/portal/apikey, \
        then `macos mastertour login --key KEY` (the secret on stdin), or set MASTERTOUR_KEY and \
        MASTERTOUR_SECRET. Every answer is the API's `data` object as JSON.
        """,
        subcommands: [Login.self, Tours.self, Tour.self, Day.self, Summary.self,
                      Events.self, Hotels.self, Crew.self, Guestlist.self]
    )

    static let service = "macos-cli.mastertour"

    struct Credentials {
        let key: String
        let secret: String
    }

    static func credentials() throws -> Credentials {
        let key = TourAccess.environment("MASTERTOUR_KEY")
        let secret = TourAccess.environment("MASTERTOUR_SECRET")
        if let key = key, let secret = secret { return Credentials(key: key, secret: secret) }
        if key == nil, secret == nil, let stored = TourAccess.read(service: service), !stored.account.isEmpty {
            return Credentials(key: stored.account, secret: stored.secret)
        }
        let missing = key == nil && secret == nil ? "MASTERTOUR_KEY and MASTERTOUR_SECRET"
            : key == nil ? "MASTERTOUR_KEY" : "MASTERTOUR_SECRET"
        throw CLIFailure(
            code: "credentials_missing",
            message: "No Master Tour API key: \(missing) \(missing.contains(" and ") ? "are" : "is") not set"
                + (TourAccess.keychainEnabled ? " and the keychain holds none." : "."),
            hint: "Copy the key and secret from my.eventric.com/portal/apikey, then run "
                + "`macos mastertour login --key KEY` with the secret on stdin, or set MASTERTOUR_KEY and MASTERTOUR_SECRET.",
            extra: ["service": "mastertour"])
    }

    /// Signs and sends one GET, prints the answer's `data`.
    static func read(_ path: String, query: [(String, String)] = []) throws {
        try Auth.check("mastertour.read")
        let creds = try credentials()
        let url = MacCLICore.masterTourURL(path: path, query: query)
        var request = URLRequest(url: MacCLICore.oauthSignedURL(
            method: "GET", url: url, consumerKey: creds.key, consumerSecret: creds.secret,
            nonce: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            timestamp: Int(Date().timeIntervalSince1970)))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (status, body) = try TourAccess.get(request)
        let json = try? JSONSerialization.jsonObject(with: body)
        let apiMessage = ((json as? [String: Any])?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch status {
        case 200..<300:
            guard let json = json else { throw CLIFailure.appError("Master Tour answered with something that is not JSON.") }
            printJSON((json as? [String: Any])?["data"] ?? json)
        case 401, 403:
            throw CLIFailure(code: "credentials_refused",
                             message: "Master Tour refused the API key" + (apiMessage.map { ": \($0)" } ?? "."),
                             hint: "Check the key and secret at my.eventric.com/portal/apikey and run `macos mastertour login` again.",
                             extra: ["http_status": status])
        case 404:
            throw CLIFailure(code: "not_found", message: "Master Tour has no \(path)" + (apiMessage.map { ": \($0)" } ?? "."),
                             hint: "Run `macos mastertour tours` for the tour ids, then `tour <id>` for the day ids.",
                             extra: ["http_status": status])
        default:
            throw CLIFailure(code: "app_error",
                             message: "Master Tour answered \(status)" + (apiMessage.map { ": \($0)" } ?? "."),
                             extra: ["http_status": status])
        }
    }

    /// Ids go into the path; refuse anything that would change it.
    static func id(_ value: String, _ name: String) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw CLIFailure(code: "invalid_argument", message: "'\(value)' is not a Master Tour \(name) id.",
                             extra: ["field": name])
        }
        return value
    }

    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "login",
            abstract: "Save the Master Tour API key and secret (secret on stdin) in the login keychain")

        @Option(name: .long, help: "The API key from my.eventric.com/portal/apikey") var key: String
        @Flag(name: .long, help: "Output JSON (always on)") var json = false

        func run() throws {
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw ValidationError("--key is empty.") }
            let secret = try TourAccess.readSecret(prompt: "Master Tour secret: ")
            try TourAccess.save(service: MasterTourCommand.service, account: key, secret: secret)
            printJSON(["ok": true, "saved": "mastertour", "keychain_service": MasterTourCommand.service])
        }
    }

    struct Tours: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "tours", abstract: "The tours this key can read")
        @Flag(name: .long, help: "Output JSON (always on)") var json = false
        func run() throws { try MasterTourCommand.read("tours") }
    }

    struct Tour: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "tour", abstract: "One tour with all its days")
        @Argument(help: "Tour id") var id: String
        @Flag(name: .long, help: "Output JSON (always on)") var json = false
        func run() throws {
            try MasterTourCommand.read("tour/\(MasterTourCommand.id(id, "tour"))", query: [("numPastDays", "0")])
        }
    }

    struct Day: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "day", abstract: "One day: venue, schedule, notes")
        @Argument(help: "Day id") var id: String
        @Flag(name: .long, help: "Output JSON (always on)") var json = false
        func run() throws { try MasterTourCommand.read("day/\(MasterTourCommand.id(id, "day"))") }
    }

    struct Summary: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "summary", abstract: "A tour's summary for one date")
        @Argument(help: "Tour id") var tourId: String
        @Argument(help: "Date, YYYY-MM-DD") var date: String
        @Flag(name: .long, help: "Output JSON (always on)") var json = false
        func run() throws {
            guard MacCLICore.isDay(date) else {
                throw CLIFailure(envelope: MacCLICore.errorEnvelope(
                    code: "invalid_date", message: "'\(date)' is not a date; use YYYY-MM-DD.",
                    extra: ["field": "date", "value": date]))
            }
            try MasterTourCommand.read("tour/\(MasterTourCommand.id(tourId, "tour"))/summary/\(date)")
        }
    }

    struct Events: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "events", abstract: "A day's events (shows)")
        @Argument(help: "Day id") var dayId: String
        @Flag(name: .long, help: "Output JSON (always on)") var json = false
        func run() throws { try MasterTourCommand.read("day/\(MasterTourCommand.id(dayId, "day"))/events") }
    }

    struct Hotels: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "hotels", abstract: "A day's hotels")
        @Argument(help: "Day id") var dayId: String
        @Flag(name: .long, help: "Output JSON (always on)") var json = false
        func run() throws { try MasterTourCommand.read("day/\(MasterTourCommand.id(dayId, "day"))/hotels") }
    }

    struct Crew: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "crew", abstract: "A tour's crew")
        @Argument(help: "Tour id") var tourId: String
        @Flag(name: .long, help: "Output JSON (always on)") var json = false
        func run() throws { try MasterTourCommand.read("tour/\(MasterTourCommand.id(tourId, "tour"))/crew") }
    }

    struct Guestlist: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "guestlist", abstract: "An event's guest list")
        @Argument(help: "Event id") var eventId: String
        @Flag(name: .long, help: "Output JSON (always on)") var json = false
        func run() throws { try MasterTourCommand.read("event/\(MasterTourCommand.id(eventId, "event"))/guestlist") }
    }
}
