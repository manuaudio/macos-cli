import ArgumentParser
import Foundation
import MacCLICore

/// `macos commands`: every command, its flags, one line of help and whether it writes.
struct CommandsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "commands",
        abstract: "List every command with its flags, one line of help, and whether it writes"
    )

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() throws {
        let entries: [MacCLICore.CatalogueEntry]
        do {
            entries = try MacCLICore.commandCatalogue(dumpHelp: Data(MacOSCLI._dumpHelp().utf8))
        } catch {
            throw CLIFailure.appError("Could not read the command tree: \(error.localizedDescription)")
        }
        if json {
            printJSON(entries.map { $0.json })
        } else {
            print(MacCLICore.catalogueTable(entries))
        }
    }
}
