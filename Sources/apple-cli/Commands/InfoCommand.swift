import ArgumentParser
import Foundation

/// System info — CPU, RAM, uptime, OS version, network interfaces
struct InfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "System hardware and OS information",
        subcommands: [SystemInfoCmd.self, NetworkInfoCmd.self, PowerCmd.self, SpotlightCmd.self, KeychainCmd.self]
    )

    // MARK: - System Info
    struct SystemInfoCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "system", abstract: "CPU, RAM, uptime, OS")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let os = ProcessInfo.processInfo
            let cpuCount = os.processorCount
            let memGB = Double(os.physicalMemory) / 1_073_741_824
            let uptime = os.systemUptime
            let uptimeH = Int(uptime / 3600)
            let uptimeM = Int((uptime.truncatingRemainder(dividingBy: 3600)) / 60)
            let osVer = os.operatingSystemVersionString
            let host = os.hostName

            // CPU model via sysctl
            let cpuModel = Process.capture(args: ["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if json {
                printJSON([
                    "hostname": host,
                    "os": osVer,
                    "cpu": cpuModel,
                    "cpu_count": cpuCount,
                    "ram_gb": memGB,
                    "uptime_seconds": Int(uptime),
                    "uptime_human": "\(uptimeH)h \(uptimeM)m",
                ])
            } else {
                print("Host: \(host)")
                print("OS: \(osVer)")
                print("CPU: \(cpuModel) (\(cpuCount) cores)")
                print(String(format: "RAM: %.1f GB", memGB))
                print("Uptime: \(uptimeH)h \(uptimeM)m")
            }
        }
    }

    // MARK: - Network Info
    struct NetworkInfoCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "network", abstract: "Network interfaces and IP addresses")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let result = Process.capture(args: ["/sbin/ifconfig", "-a"])
            if json {
                // Parse ifconfig output into structured JSON
                var interfaces: [[String: String]] = []
                var current: [String: String] = [:]
                for line in result.components(separatedBy: "\n") {
                    if let m = line.range(of: #"^(\w+\d*): "#, options: .regularExpression) {
                        if !current.isEmpty { interfaces.append(current) }
                        current = ["name": String(line[m]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ": ", with: "")]
                    } else if line.contains("inet ") && !line.contains("inet6") {
                        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                        if parts.count > 1 { current["ipv4"] = parts[1] }
                    } else if line.contains("ether ") {
                        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                        if parts.count > 1 { current["mac"] = parts[1] }
                    }
                }
                if !current.isEmpty { interfaces.append(current) }
                printJSON(interfaces.filter { $0["ipv4"] != nil || $0["mac"] != nil })
            } else {
                print(result)
            }
        }
    }

    // MARK: - Power
    struct PowerCmd: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "power",
            abstract: "Power management — sleep, caffeinate, settings",
            subcommands: [SleepCmd.self, CaffeinateCmd.self, SettingsCmd.self]
        )

        struct SleepCmd: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "sleep", abstract: "Put Mac to sleep")
            func run() throws {
                Process.run(args: ["/usr/bin/pmset", "sleepnow"])
                print("Sleeping...")
            }
        }

        struct CaffeinateCmd: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "caffeinate", abstract: "Prevent sleep for N seconds")
            @Argument(help: "Duration in seconds (0 = indefinite, Ctrl-C to stop)") var seconds: Int = 0

            func run() throws {
                var args = ["/usr/bin/caffeinate", "-d"]  // -d = prevent display sleep
                if seconds > 0 { args += ["-t", String(seconds)] }
                print(seconds > 0 ? "Caffeinating for \(seconds)s..." : "Caffeinating indefinitely (Ctrl-C to stop)...")
                Process.run(args: args)
            }
        }

        struct SettingsCmd: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "settings", abstract: "Show power management settings")
            @Flag(name: .long, help: "Output JSON") var json = false

            func run() throws {
                let result = Process.capture(args: ["/usr/bin/pmset", "-g"])
                if json { printJSON(["raw": result]) } else { print(result) }
            }
        }
    }

    // MARK: - Spotlight
    struct SpotlightCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "spotlight", abstract: "Search files via Spotlight (mdfind)")

        @Argument(help: "Search query") var query: String
        @Option(name: .long, help: "Limit to directory") var onlyin: String?
        @Option(name: .long, help: "Max results (default: 20)") var limit: Int = 20
        @Option(name: .long, help: "Spotlight attribute filter, e.g. 'kMDItemKind == PDF'") var attr: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            var args = ["/usr/bin/mdfind"]
            if let dir = onlyin { args += ["-onlyin", dir] }
            if let a = attr { args += [a] } else { args += [query] }

            let result = Process.capture(args: args)
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
            let limited = Array(lines.prefix(limit))

            if json {
                printJSON(limited.map { ["path": $0] })
            } else {
                limited.forEach { print($0) }
                print("\(limited.count) results (of \(lines.count) total)")
            }
        }
    }

    // MARK: - Keychain
    struct KeychainCmd: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "keychain",
            abstract: "Store and retrieve secrets from macOS Keychain",
            subcommands: [SetCmd.self, GetCmd.self, DeleteCmd.self]
        )

        struct SetCmd: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "set", abstract: "Store a secret in Keychain")
            @Argument(help: "Service name (key)") var service: String
            @Argument(help: "Account name") var account: String
            @Argument(help: "Secret value") var value: String

            func run() throws {
                // Delete existing first (security add-generic-password fails if exists)
                _ = Process.capture(args: ["/usr/bin/security", "delete-generic-password",
                    "-s", service, "-a", account, "/Users/you/Library/Keychains/login.keychain-db"])
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                proc.arguments = ["add-generic-password", "-s", service, "-a", account,
                    "-w", value, "/Users/you/Library/Keychains/login.keychain-db"]
                proc.standardOutput = FileHandle.nullDevice
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    throw ValidationError("Failed to store secret in Keychain")
                }
                print("Stored: \(service)/\(account)")
            }
        }

        struct GetCmd: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "get", abstract: "Retrieve a secret from Keychain")
            @Argument(help: "Service name") var service: String
            @Argument(help: "Account name") var account: String

            func run() throws {
                let result = Process.capture(args: ["/usr/bin/security", "find-generic-password",
                    "-s", service, "-a", account, "-w",
                    "/Users/you/Library/Keychains/login.keychain-db"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if result.isEmpty { throw ValidationError("Secret not found: \(service)/\(account)") }
                print(result)
            }
        }

        struct DeleteCmd: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a secret from Keychain")
            @Argument(help: "Service name") var service: String
            @Argument(help: "Account name") var account: String

            func run() throws {
                let result = Process.run(args: ["/usr/bin/security", "delete-generic-password",
                    "-s", service, "-a", account,
                    "/Users/you/Library/Keychains/login.keychain-db"])
                if result != 0 { throw ValidationError("Secret not found: \(service)/\(account)") }
                print("Deleted: \(service)/\(account)")
            }
        }
    }
}
