import ArgumentParser
import Foundation
import MacCLICore

// MARK: - Daysheets (a tour's calendar feed, read only)

struct DaysheetsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daysheets",
        abstract: "Read a Daysheets tour's days from its calendar feed (JSON)",
        discussion: """
        Daysheets has no public API; each tour has a calendar feed (Tour Settings → Add a calendar \
        feed). `macos daysheets login` saves that URL in the login keychain (read from stdin), or set \
        DAYSHEETS_FEED_URL. The URL is the key to the tour, so it is never printed.
        """,
        subcommands: [Login.self, Days.self, Day.self]
    )

    static let service = "macos-cli.daysheets"

    static func feedURL() throws -> URL {
        let value = TourAccess.environment("DAYSHEETS_FEED_URL") ?? TourAccess.read(service: service)?.secret
        guard let value = value else {
            throw CLIFailure(
                code: "credentials_missing",
                message: "No Daysheets feed: DAYSHEETS_FEED_URL is not set"
                    + (TourAccess.keychainEnabled ? " and the keychain holds none." : "."),
                hint: "Copy the tour's calendar feed URL (Tour Settings → Add a calendar feed), then run "
                    + "`macos daysheets login` with it on stdin, or set DAYSHEETS_FEED_URL.",
                extra: ["service": "daysheets"])
        }
        return try parseFeed(value)
    }

    /// `webcal://` is the feed's https address; a `file://` URL reads a saved .ics.
    static func parseFeed(_ value: String) throws -> URL {
        var text = value
        if text.lowercased().hasPrefix("webcal://") { text = "https://" + text.dropFirst("webcal://".count) }
        guard let url = URL(string: text), ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") else {
            throw CLIFailure(code: "invalid_argument",
                             message: "The Daysheets feed is not an https, webcal or file URL.",
                             hint: "Copy the feed URL again from Tour Settings → Add a calendar feed.")
        }
        return url
    }

    static func events() throws -> [MacCLICore.TourEvent] {
        try Auth.check("daysheets.read")
        let (status, body) = try TourAccess.get(URLRequest(url: try feedURL()))
        switch status {
        case 200..<300: break
        case 401, 403, 404, 410:
            throw CLIFailure(code: "credentials_refused",
                             message: "Daysheets refused the feed URL (\(status)); the feed may have been removed.",
                             hint: "Add a calendar feed again in Tour Settings and run `macos daysheets login` with the new URL.",
                             extra: ["http_status": status])
        default:
            throw CLIFailure(code: "app_error", message: "Daysheets answered \(status).", extra: ["http_status": status])
        }
        guard let text = String(data: body, encoding: .utf8), text.contains("BEGIN:VCALENDAR") else {
            throw CLIFailure.appError("The feed is not an iCalendar file.",
                                      hint: "Copy the feed URL again from Tour Settings → Add a calendar feed.")
        }
        return MacCLICore.parseICS(text, timeZone: .current)
    }

    static func day(_ value: String, _ field: String) throws -> String {
        guard MacCLICore.isDay(value) else {
            throw CLIFailure(envelope: MacCLICore.errorEnvelope(
                code: "invalid_date", message: "'\(value)' is not a date; use YYYY-MM-DD.",
                extra: ["field": field, "value": value]))
        }
        return value
    }

    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "login",
            abstract: "Save the tour's calendar feed URL (on stdin) in the login keychain")

        @Flag(name: .long, help: "Output JSON (always on)") var json = false

        func run() throws {
            let value = try TourAccess.readSecret(prompt: "Daysheets feed URL: ")
            _ = try DaysheetsCommand.parseFeed(value)
            try TourAccess.save(service: DaysheetsCommand.service, account: "feed", secret: value)
            printJSON(["ok": true, "saved": "daysheets", "keychain_service": DaysheetsCommand.service])
        }
    }

    struct Days: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "days", abstract: "The tour's days with their events, oldest first")

        @Option(name: .long, help: "First day, YYYY-MM-DD") var from: String?
        @Option(name: .long, help: "Last day, YYYY-MM-DD") var to: String?
        @Flag(name: .long, help: "Output JSON (always on)") var json = false

        func run() throws {
            let from = try from.map { try DaysheetsCommand.day($0, "from") }
            let to = try to.map { try DaysheetsCommand.day($0, "to") }
            printJSON(MacCLICore.tourDays(try DaysheetsCommand.events(), from: from, to: to))
        }
    }

    struct Day: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "day", abstract: "One day's events; an empty list on a day with none")

        @Argument(help: "The day, YYYY-MM-DD") var date: String
        @Flag(name: .long, help: "Output JSON (always on)") var json = false

        func run() throws {
            let date = try DaysheetsCommand.day(date, "date")
            let days = MacCLICore.tourDays(try DaysheetsCommand.events(), from: date, to: date)
            printJSON(days.first ?? ["date": date, "events": [Any]()])
        }
    }
}
