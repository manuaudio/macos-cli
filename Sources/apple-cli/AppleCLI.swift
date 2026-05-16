import ArgumentParser
import Foundation

@main
struct AppleCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple",
        abstract: "macOS native data access CLI — Reminders, Calendar, Contacts",
        version: "0.1.0",
        subcommands: [
            RemindersCommand.self,
            CalendarCommand.self,
            ContactsCommand.self,
        ]
    )
}
