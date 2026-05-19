import ArgumentParser
import Foundation

@main
struct MacOSCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macos",
        abstract: "macOS CLI — full agentic control of macOS via the terminal",
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
            // UI automation (Accessibility + Screen Recording required)
            MouseCommand.self,
            KeyboardCommand.self,
            AxCommand.self,
            ScreenshotCommand.self,
            OcrCommand.self,
            WindowCommand.self,
            // App integrations (Automation permission required)
            SafariCommand.self,
            MailCommand.self,
            MessagesCommand.self,
            PhotosCommand.self,
            MusicCommand.self,
            FinderCommand.self,
            SetupCommand.self,
            // 0.6 additions
            ShortcutsCommand.self,
            PdfCommand.self,
            FocusCommand.self,
            ProcessCommand.self,
            DiskCommand.self,
            LocationCommand.self,
            // 0.5.5
            VoiceMemosCommand.self,
            // 0.6.0 — new agentic commands
            BluetoothCommand.self,
            TrashCommand.self,
            SpotlightCommand.self,
            FileCommand.self,
            LoginItemsCommand.self,
            DockCommand.self,
        ]
    )
}
