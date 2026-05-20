import ArgumentParser
import Foundation

/// System info — CPU, RAM, uptime, OS version, network interfaces
struct InfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "System hardware and OS information",
        subcommands: [SystemInfoCmd.self, NetworkInfoCmd.self, PowerCmd.self]
    )

    // MARK: - System Info
    struct SystemInfoCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "system", abstract: "CPU, RAM, uptime, OS")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("info.read")
            let os = ProcessInfo.processInfo
            let cpuCount = os.processorCount
            let memGB = Double(os.physicalMemory) / 1_073_741_824
            let uptime = os.systemUptime
            let uptimeH = Int(uptime / 3600)
            let uptimeM = Int((uptime.truncatingRemainder(dividingBy: 3600)) / 60)
            let osVer = os.operatingSystemVersionString
            let host = os.hostName

            // CPU model via sysctl
            let cpuModel = Process.capture(args: ["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], timeout: 5, fallback: "")
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
            try Auth.check("info.read")
            let result = Process.capture(args: ["/sbin/ifconfig", "-a"], timeout: 5, fallback: "")
            if json {
                // Parse ifconfig output — consistent shape: name always present, ipv4/mac null when absent
                var interfaces: [[String: Any?]] = []
                var current: (name: String, ipv4: String?, mac: String?)? = nil
                for line in result.components(separatedBy: "\n") {
                    if let m = line.range(of: #"^(\w+\d*): "#, options: .regularExpression) {
                        if let c = current, c.ipv4 != nil || c.mac != nil {
                            interfaces.append(["name": c.name, "ipv4": c.ipv4, "mac": c.mac])
                        }
                        let name = String(line[m]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ": ", with: "")
                        current = (name, nil, nil)
                    } else if line.contains("inet ") && !line.contains("inet6") {
                        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                        if parts.count > 1, var c = current { c.ipv4 = parts[1]; current = c }
                    } else if line.contains("ether ") {
                        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                        if parts.count > 1, var c = current { c.mac = parts[1]; current = c }
                    }
                }
                if let c = current, c.ipv4 != nil || c.mac != nil {
                    interfaces.append(["name": c.name, "ipv4": c.ipv4, "mac": c.mac])
                }
                // Serialize with explicit nulls for consistent shape
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let cleaned = interfaces.map { iface -> [String: String?] in
                    ["name": iface["name"] as? String, "ipv4": iface["ipv4"] as? String ?? nil, "mac": iface["mac"] as? String ?? nil]
                }
                if let data = try? encoder.encode(cleaned), let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
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
                try Auth.check("system.sleep")
                Process.run(args: ["/usr/bin/pmset", "sleepnow"])
                print("Sleeping...")
            }
        }

        struct CaffeinateCmd: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "caffeinate", abstract: "Prevent sleep for N seconds")
            @Argument(help: "Duration in seconds (0 = indefinite, Ctrl-C to stop)") var seconds: Int = 0

            func run() throws {
                try Auth.check("system.sleep")
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
                try Auth.check("info.read")
                let result = Process.capture(args: ["/usr/bin/pmset", "-g"], timeout: 5, fallback: "")
                if json {
                    // Parse pmset -g key-value output into structured JSON
                    var parsed: [String: Any] = [:]
                    for line in result.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, !trimmed.hasPrefix("Active Profiles"), !trimmed.hasPrefix("Currently") else { continue }
                        let parts = trimmed.components(separatedBy: " ").filter { !$0.isEmpty }
                        guard parts.count >= 2 else { continue }
                        let key = parts[0]
                        let val = parts[1]
                        if let intVal = Int(val) {
                            parsed[key] = intVal
                        } else if val == "1" || val == "0" {
                            parsed[key] = val == "1"
                        } else {
                            parsed[key] = val
                        }
                    }
                    printJSON(parsed)
                } else {
                    print(result)
                }
            }
        }
    }

}
