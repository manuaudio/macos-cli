import ArgumentParser
import Foundation

@main
struct AppleCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple",
        abstract: "macOS native data access CLI — Reminders, Calendar, Contacts, System, Apps, Screen, Storage, Info",
        version: "0.3.0",
        subcommands: [
            // Personal data (EventKit + Contacts.framework)
            RemindersCommand.self,
            CalendarCommand.self,
            ContactsCommand.self,
            // System controls
            SystemCommand.self,
            AppsCommand.self,
            ScreenCommand.self,
            StorageCommand.self,
            NotifyCommand.self,
            SpeechCommand.self,
            InfoCommand.self,
        ]
    )
}
