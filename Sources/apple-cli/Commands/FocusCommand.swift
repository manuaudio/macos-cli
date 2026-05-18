import ArgumentParser
import Foundation

struct FocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Read macOS Focus / Do Not Disturb state",
        subcommands: [Status.self, Modes.self, On.self, Off.self]
    )

    // MARK: - Status
    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show current Focus mode and DND state")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let state = FocusReader.currentState()
            if json {
                var out: [String: Any] = ["dnd_active": state.dndActive]
                if let mode = state.modeName { out["mode"] = mode }
                out["assertion_count"] = state.assertionCount
                printJSON(out)
            } else {
                if state.dndActive {
                    let label = state.modeName.map { "Focus: \($0)" } ?? "Do Not Disturb: ON"
                    print(label)
                } else {
                    print("Focus: OFF")
                }
            }
        }
    }

    // MARK: - Modes
    struct Modes: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all configured Focus modes")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let modes = FocusReader.availableModes()
            if json {
                printJSON(modes.map { ["name": $0.name, "identifier": $0.identifier] })
            } else {
                if modes.isEmpty {
                    print("No Focus modes found")
                } else {
                    modes.forEach { print("\($0.name) (\($0.identifier))") }
                }
            }
        }
    }

    // MARK: - On
    struct On: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Enable Do Not Disturb")

        func run() throws {
            let result = enableDND()
            if result {
                print("Focus/DND enabled")
            } else {
                fputs("warning: Could not enable DND — try manually via Control Center\n", stderr)
                print("Focus/DND enable attempted (may require Shortcut or manual action)")
            }
        }
    }

    // MARK: - Off
    struct Off: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Disable Do Not Disturb")

        func run() throws {
            let result = disableDND()
            if result {
                print("Focus/DND disabled")
            } else {
                fputs("warning: Could not disable DND — try manually via Control Center\n", stderr)
                print("Focus/DND disable attempted (may require Shortcut or manual action)")
            }
        }
    }
}

// MARK: - DoNotDisturb reader

private struct FocusState {
    let dndActive: Bool
    let modeName: String?
    let assertionCount: Int
}

private struct FocusMode {
    let name: String
    let identifier: String
}

private enum FocusReader {
    static func currentState() -> FocusState {
        let dbPath = NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dbPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let storeAssertions = obj["storeAssertions"] as? [[String: Any]] else {
            return FocusState(dndActive: false, modeName: nil, assertionCount: 0)
        }
        let active = storeAssertions.filter { ($0["assertionType"] as? Int) != nil }
        let modeName = active.compactMap { $0["focusModeIdentifier"] as? String }.first
        return FocusState(dndActive: !active.isEmpty, modeName: modeName, assertionCount: active.count)
    }

    static func availableModes() -> [FocusMode] {
        let configPath = NSHomeDirectory() + "/Library/DoNotDisturb/DB/ModeConfigurations.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = obj["data"] as? [[String: Any]],
              let first = dataArr.first,
              let modeConfigs = first["modeConfigurations"] as? [String: Any] else {
            return []
        }
        var modes: [FocusMode] = []
        for (_, config) in modeConfigs {
            guard let c = config as? [String: Any],
                  let mode = c["mode"] as? [String: Any],
                  let identifier = mode["modeIdentifier"] as? String else { continue }
            let name = (mode["name"] as? String) ?? identifier
            modes.append(FocusMode(name: name, identifier: identifier))
        }
        return modes.sorted { $0.name < $1.name }
    }
}

// MARK: - DND toggle helpers

private func enableDND() -> Bool {
    let result1 = Process.run(args: [
        "/usr/bin/defaults", "-currentHost", "write",
        "com.apple.notificationcenterui", "doNotDisturb", "-boolean", "true"
    ])
    let result2 = Process.run(args: [
        "/usr/bin/defaults", "-currentHost", "write",
        "com.apple.notificationcenterui", "doNotDisturbDate",
        "-date", isoNow()
    ])
    Process.run(args: ["/usr/bin/killall", "NotificationCenter"])
    return result1 == 0 && result2 == 0
}

private func disableDND() -> Bool {
    let result = Process.run(args: [
        "/usr/bin/defaults", "-currentHost", "write",
        "com.apple.notificationcenterui", "doNotDisturb", "-boolean", "false"
    ])
    Process.run(args: ["/usr/bin/killall", "NotificationCenter"])
    return result == 0
}

private func isoNow() -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss +0000"
    df.timeZone = TimeZone(abbreviation: "UTC")
    return df.string(from: Date())
}
