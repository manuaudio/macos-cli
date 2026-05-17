import ArgumentParser
import Foundation

@main
struct AppleCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple",
        abstract: "macOS native data access CLI — Reminders, Calendar, Contacts, Notes, System, Apps, Screen, Storage, Info",
        version: "0.6.0",
        subcommands: [
            // Personal data (EventKit + Contacts.framework + Notes via SQLite)
            RemindersCommand.self,
            CalendarCommand.self,
            ContactsCommand.self,
            NotesCommand.self,
            // System controls
            SystemCommand.self,
            AppsCommand.self,
            ScreenCommand.self,
            StorageCommand.self,
            NotifyCommand.self,
            SpeechCommand.self,
            InfoCommand.self,
            // UI automation (Accessibility permission required for mouse/keyboard/ax)
            MouseCommand.self,
            KeyboardCommand.self,
            AxCommand.self,
            ScreenshotCommand.self,
            // App integrations (Automation permission required)
            SafariCommand.self,
            MailCommand.self,
            MessagesCommand.self,
            PhotosCommand.self,
            SetupCommand.self,
        ]
    )
}
