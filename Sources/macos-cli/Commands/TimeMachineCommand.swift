// Sources/macos-cli/Commands/TimeMachineCommand.swift
import ArgumentParser
import Foundation

struct TimeMachineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "timemachine",
        abstract: "Time Machine — backup status, control, and snapshot management",
        subcommands: [Status.self, Start.self, Stop.self, ListSnapshots.self, ListDestinations.self]
    )

    // MARK: - Status

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show backup status and last backup time")
        @Flag(name: .long, help: "Output JSON") var json = false

        // Parse a value from tmutil's old-style plist text output.
        // Lines look like: `    Running = 0;` or `    BackupPhase = "ThinningPreBackup";`
        private func parseStatusField(_ raw: String, key: String) -> String? {
            for line in raw.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let prefix = "\(key) = "
                if trimmed.hasPrefix(prefix) {
                    var value = String(trimmed.dropFirst(prefix.count))
                    if value.hasSuffix(";") { value = String(value.dropLast()) }
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    return value
                }
            }
            return nil
        }

        func run() throws {
            try Auth.check("timemachine.read")
            let raw = Process.capture(args: ["/usr/bin/tmutil", "status"], timeout: 15, fallback: "")

            let running  = parseStatusField(raw, key: "Running") == "1"
            let phase    = parseStatusField(raw, key: "BackupPhase") ?? "Idle"
            let percentStr = parseStatusField(raw, key: "Percent") ?? "0"
            let percent  = Double(percentStr) ?? 0.0

            let lastBackup = Process.capture(args: ["/usr/bin/tmutil", "latestbackup"], timeout: 10, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // latestbackup returns an error message when no backup exists — filter it
            let cleanLastBackup = lastBackup.contains("Error") || lastBackup.contains("Failed") ? "" : lastBackup

            if json {
                printJSON([
                    "running": running,
                    "phase": phase,
                    "percent": percent,
                    "last_backup": cleanLastBackup
                ])
            } else {
                if running {
                    print("Status: Backup in progress — \(phase) (\(Int(percent * 100))%)")
                } else {
                    print("Status: Idle")
                }
                if !cleanLastBackup.isEmpty { print("Last backup: \(cleanLastBackup)") }
            }
        }
    }

    // MARK: - Start

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start a backup immediately")

        func run() throws {
            try Auth.check("timemachine.write")
            let code = Process.run(args: ["/usr/bin/tmutil", "startbackup"])
            guard code == 0 else {
                throw ValidationError(
                    "Could not start backup (tmutil exit \(code)). Check that a destination is configured in System Settings → Time Machine."
                )
            }
            print("Backup started.")
        }
    }

    // MARK: - Stop

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Cancel a running backup")

        func run() throws {
            try Auth.check("timemachine.write")
            let code = Process.run(args: ["/usr/bin/tmutil", "stopbackup"])
            guard code == 0 else {
                throw ValidationError("Could not stop backup — no backup may be running (tmutil exit \(code)).")
            }
            print("Backup stopped.")
        }
    }

    // MARK: - ListSnapshots

    struct ListSnapshots: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list-snapshots", abstract: "List local Time Machine snapshots")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("timemachine.read")
            let raw = Process.capture(args: ["/usr/bin/tmutil", "listlocalsnapshots", "/"], timeout: 15, fallback: "")
            let snapshots = raw.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("com.apple.TimeMachine") }
            if json {
                printJSON(snapshots)
            } else if snapshots.isEmpty {
                print("No local snapshots.")
            } else {
                snapshots.forEach { print($0) }
            }
        }
    }

    // MARK: - ListDestinations

    struct ListDestinations: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list-destinations", abstract: "List configured backup destinations")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("timemachine.read")
            let raw = Process.capture(args: ["/usr/bin/tmutil", "destinationinfo", "-X"], timeout: 10, fallback: "")
            guard let data = raw.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let dests = plist["Destinations"] as? [[String: Any]]
            else {
                if json { printJSON([String]()) }
                else { print("No Time Machine destinations configured.") }
                return
            }
            let result: [[String: Any]] = dests.map { [
                "name": $0["Name"] as? String ?? "",
                "kind": $0["Kind"] as? String ?? "",
                "id":   $0["ID"]   as? String ?? ""
            ] }
            if json {
                printJSON(result)
            } else {
                for d in result {
                    print("\(d["name"] ?? "") (\(d["kind"] ?? ""))")
                }
            }
        }
    }
}
