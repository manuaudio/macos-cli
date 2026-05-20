import ArgumentParser
import Foundation

struct FocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Read and set macOS Focus / Do Not Disturb state",
        subcommands: [Status.self, Modes.self, On.self, Off.self]
    )

    // MARK: - Status
    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show current Focus mode and DND state")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let state = FocusDB.currentState()
            if json {
                var out: [String: Any] = [
                    "dnd_active": state.dndActive,
                    "assertion_count": state.assertionCount,
                ]
                if !state.activeModes.isEmpty { out["modes"] = state.activeModes }
                printJSON(out)
            } else {
                if state.dndActive {
                    let label = state.activeModes.isEmpty ? "Focus: ON" : "Focus: " + state.activeModes.joined(separator: ", ")
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
            let modes = FocusDB.availableModes()
            if json {
                printJSON(modes.map { ["name": $0.name, "identifier": $0.identifier] })
            } else {
                if modes.isEmpty {
                    print("No Focus modes found")
                } else {
                    modes.forEach { print("\($0.name)  \($0.identifier)") }
                }
            }
        }
    }

    // MARK: - On
    struct On: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Enable Do Not Disturb")

        @Option(name: .long, help: "Focus mode identifier (default: com.apple.donotdisturb.mode.default)")
        var mode: String = "com.apple.donotdisturb.mode.default"

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("focus.write")
            let ok = FocusDB.setAssertion(modeIdentifier: mode, enable: true)
            let status = FocusDB.currentState()
            if json {
                printJSON(["dnd_active": status.dndActive, "modes": status.activeModes, "write_ok": ok])
            } else {
                if status.dndActive {
                    print("Focus ON: \(status.activeModes.joined(separator: ", "))")
                } else {
                    print("Focus ON requested\(ok ? "" : " (write may need a moment to take effect)")")
                }
            }
        }
    }

    // MARK: - Off
    struct Off: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Disable Do Not Disturb")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("focus.write")
            let ok = FocusDB.setAssertion(modeIdentifier: nil, enable: false)
            let status = FocusDB.currentState()
            if json {
                printJSON(["dnd_active": status.dndActive, "modes": status.activeModes, "write_ok": ok])
            } else {
                if !status.dndActive {
                    print("Focus OFF")
                } else {
                    print("Focus OFF requested\(ok ? "" : " (write may need a moment to take effect)")")
                }
            }
        }
    }
}

// MARK: - DoNotDisturb DB reader/writer

struct FocusState {
    let dndActive: Bool
    let activeModes: [String]
    let assertionCount: Int
}

struct FocusMode {
    let name: String
    let identifier: String
}

enum FocusDB {
    // MARK: Read

    static func currentState() -> FocusState {
        guard let (_, records) = loadAssertions() else {
            return FocusState(dndActive: false, activeModes: [], assertionCount: 0)
        }

        let modeIds = records.compactMap { r -> String? in
            guard let details = r["assertionDetails"] as? [String: Any],
                  let modeId = details["assertionDetailsModeIdentifier"] as? String else { return nil }
            // Sleep mode is always there; only count explicitly user-interactive modes as "active"
            if modeId == "com.apple.sleep.sleep-mode" { return nil }
            return modeId
        }
        return FocusState(
            dndActive: !modeIds.isEmpty,
            activeModes: modeIds,
            assertionCount: modeIds.count
        )
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

    // MARK: Write

    /// Adds or removes a DND assertion from Assertions.json, then signals donotdisturbd.
    @discardableResult
    static func setAssertion(modeIdentifier: String?, enable: Bool) -> Bool {
        let dbPath = NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json"
        let url = URL(fileURLWithPath: dbPath)

        guard var (obj, records) = loadAssertions(),
              var dataArr = obj["data"] as? [[String: Any]], !dataArr.isEmpty else { return false }

        let now = Date().timeIntervalSinceReferenceDate
        let deviceId = deviceIdentifier(from: records)

        if enable {
            let mode = modeIdentifier ?? "com.apple.donotdisturb.mode.default"
            let assertion: [String: Any] = [
                "assertionUUID": UUID().uuidString.uppercased(),
                "assertionSource": [
                    "assertionClientIdentifier": "com.apple.controlcenter.dnd",
                    "assertionSourceDeviceIdentifier": deviceId,
                ],
                "assertionStartDateTimestamp": now,
                "assertionDetails": [
                    "assertionDetailsIdentifier": "com.apple.controlcenter.dnd",
                    "assertionDetailsModeIdentifier": mode,
                    "assertionDetailsReason": "user-action",
                ],
            ]
            records.append(assertion)
        } else {
            // Remove all non-sleep assertions (including schedule-based DND)
            records = records.filter { r in
                guard let details = r["assertionDetails"] as? [String: Any],
                      let modeId = details["assertionDetailsModeIdentifier"] as? String else { return true }
                return modeId == "com.apple.sleep.sleep-mode"
            }

            // Add a "user-changed-state" invalidation request so donotdisturbd registers the override
            var invalidationReqs = (dataArr[0]["storeInvalidationRequestRecords"] as? [[String: Any]]) ?? []
            invalidationReqs.append([
                "invalidationRequestPredicate": ["invalidationPredicateType": "any"],
                "invalidationRequestReason": "user-changed-state",
                "invalidationRequestUUID": UUID().uuidString.uppercased(),
                "invalidationRequestSource": [
                    "assertionClientIdentifier": "com.apple.controlcenter.dnd",
                    "assertionSourceDeviceIdentifier": deviceId,
                ],
                "invalidationRequestDateTimestamp": now,
            ])
            dataArr[0]["storeInvalidationRequestRecords"] = invalidationReqs
        }

        dataArr[0]["storeAssertionRecords"] = records
        var header = (obj["header"] as? [String: Any]) ?? [:]
        header["timestamp"] = now
        obj["data"] = dataArr
        obj["header"] = header

        guard let newData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return false }

        do {
            try newData.write(to: url, options: .atomic)
        } catch {
            fputs("error writing Assertions.json: \(error)\n", stderr)
            return false
        }

        // Signal donotdisturbd — SIGHUP causes it to reload state
        signalDoNotDisturbD()
        Thread.sleep(forTimeInterval: 0.4)
        return true
    }

    // MARK: Helpers

    private static func loadAssertions() -> ([String: Any], [[String: Any]])? {
        let dbPath = NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dbPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = obj["data"] as? [[String: Any]],
              let storeData = dataArr.first,
              let records = storeData["storeAssertionRecords"] as? [[String: Any]] else {
            return nil
        }
        return (obj, records)
    }

    private static func deviceIdentifier(from records: [[String: Any]]) -> String {
        for r in records {
            if let src = r["assertionSource"] as? [String: Any],
               let id = src["assertionSourceDeviceIdentifier"] as? String {
                return id
            }
        }
        return UUID().uuidString.uppercased()
    }

    private static func signalDoNotDisturbD() {
        let raw = Process.capture(args: ["/bin/ps", "-axo", "pid=,comm="], timeout: 5, fallback: "")
        for line in raw.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2, parts[1].contains("donotdisturbd"),
                  let pid = Int32(parts[0]) else { continue }
            kill(pid, SIGHUP)
            return
        }
    }
}
