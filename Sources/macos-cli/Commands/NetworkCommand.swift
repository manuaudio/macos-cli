import ArgumentParser
import Foundation

// MARK: - Top-level network command

struct NetworkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Network diagnostics — ping, DNS, port check, traceroute",
        subcommands: [Ping.self, Dns.self, Port.self, Traceroute.self, Interfaces.self]
    )

    // MARK: - Ping

    struct Ping: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ping", abstract: "Ping a host")

        @Option(name: .long, help: "Hostname or IP to ping") var host: String
        @Option(name: .long, help: "Number of pings (default: 4)") var count: Int = 4
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            guard count > 0 && count <= 100 else { throw ValidationError("--count must be 1–100") }
            let output = Process.capture(args: ["/sbin/ping", "-c", "\(count)", host], timeout: 30, fallback: "")
            if json {
                // Parse summary line: "round-trip min/avg/max/stddev = 1.2/3.4/5.6/7.8 ms"
                var result: [String: Any] = ["host": host, "count": count, "output": output]
                if let rtLine = output.components(separatedBy: "\n")
                    .first(where: { $0.contains("round-trip") || $0.contains("rtt") }) {
                    // Extract min/avg/max from "min/avg/max/stddev = X/Y/Z/W ms"
                    if let eqRange = rtLine.range(of: "="),
                       let msRange = rtLine.range(of: " ms") {
                        let values = String(rtLine[eqRange.upperBound..<msRange.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
                            .components(separatedBy: "/")
                        if values.count >= 3 {
                            result["rtt_min_ms"] = Double(values[0].trimmingCharacters(in: .whitespaces))
                            result["rtt_avg_ms"] = Double(values[1].trimmingCharacters(in: .whitespaces))
                            result["rtt_max_ms"] = Double(values[2].trimmingCharacters(in: .whitespaces))
                        }
                    }
                }
                // Parse packet loss: "N packets transmitted, M received, X% packet loss"
                if let lossLine = output.components(separatedBy: "\n")
                    .first(where: { $0.contains("packet loss") }),
                   let pctRange = lossLine.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression) {
                    let pctStr = String(lossLine[pctRange]).dropLast() // drop "%"
                    result["packet_loss_pct"] = Double(pctStr)
                }
                printJSON(result)
            } else {
                print(output)
            }
        }
    }

    // MARK: - Dns

    struct Dns: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "dns", abstract: "Resolve a hostname to IP addresses")

        @Option(name: .long, help: "Hostname to resolve") var host: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            // Try dig first; fall back to host command
            var output: String
            let digPath = "/usr/bin/dig"
            let hostPath = "/usr/bin/host"
            if FileManager.default.fileExists(atPath: digPath) {
                output = Process.capture(args: [digPath, "+short", host], timeout: 10, fallback: "")
            } else if FileManager.default.fileExists(atPath: hostPath) {
                let raw = Process.capture(args: [hostPath, host], timeout: 10, fallback: "")
                // "example.com has address 1.2.3.4" — extract IPs
                output = raw.components(separatedBy: "\n")
                    .filter { $0.contains("has address") || $0.contains("has IPv6") }
                    .compactMap { line -> String? in
                        guard let lastSpace = line.lastIndex(of: " ") else { return nil }
                        return String(line[line.index(after: lastSpace)...])
                    }
                    .joined(separator: "\n")
            } else {
                throw ValidationError("Neither /usr/bin/dig nor /usr/bin/host found")
            }
            let addresses = output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if json {
                printJSON(["host": host, "addresses": addresses] as [String: Any])
            } else {
                if addresses.isEmpty {
                    print("No addresses found for \(host)")
                } else {
                    for addr in addresses { print(addr) }
                }
            }
        }
    }

    // MARK: - Port

    struct Port: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "port", abstract: "Check if a TCP port is open")

        @Option(name: .long, help: "Hostname or IP") var host: String
        @Option(name: .long, help: "Port number") var port: Int
        @Option(name: .long, help: "Seconds to wait (default: 5)") var timeout: Int = 5
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            guard port > 0 && port <= 65535 else { throw ValidationError("--port must be 1–65535") }
            guard timeout > 0 && timeout <= 60 else { throw ValidationError("--timeout must be 1–60") }
            // nc -zv -w <timeout> <host> <port>: exits 0 if open, non-zero if closed/refused
            let args = ["/usr/bin/nc", "-zv", "-w", "\(timeout)", host, "\(port)"]
            let code = Process.run(args: args)
            let isOpen = (code == 0)
            if json {
                printJSON(["host": host, "port": port, "open": isOpen] as [String: Any])
            } else {
                print("Port \(port) on \(host): \(isOpen ? "open" : "closed")")
            }
        }
    }

    // MARK: - Traceroute

    struct Traceroute: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "traceroute", abstract: "Trace the route to a host")

        @Option(name: .long, help: "Hostname or IP") var host: String
        @Option(name: [.customLong("max-hops")], help: "Maximum hops / TTL (default: 30)") var maxHops: Int = 30
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            guard maxHops > 0 && maxHops <= 64 else { throw ValidationError("--max-hops must be 1–64") }
            let output = Process.capture(
                args: ["/usr/sbin/traceroute", "-m", "\(maxHops)", host],
                timeout: 60,
                fallback: ""
            )
            if json {
                // Best-effort hop parsing; always include raw output as fallback
                var hops: [[String: Any]] = []
                for line in output.components(separatedBy: "\n").dropFirst() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    guard let hopNum = parts.first.flatMap({ Int($0) }) else { continue }
                    var hop: [String: Any] = ["hop": hopNum]
                    // Second token is usually the hostname or "*"
                    if parts.count > 1 { hop["host"] = parts[1] }
                    // Third token may be an IP in parens
                    if parts.count > 2 {
                        let ip = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                        if ip != parts[1] { hop["ip"] = ip }
                    }
                    hops.append(hop)
                }
                printJSON(["host": host, "max_hops": maxHops, "hops": hops, "output": output] as [String: Any])
            } else {
                print(output)
            }
        }
    }

    // MARK: - Interfaces

    struct Interfaces: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "interfaces", abstract: "List network interfaces and their IP addresses")

        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let output = Process.capture(args: ["/sbin/ifconfig"], timeout: 5, fallback: "")
            var interfaces: [[String: Any]] = []
            var currentName = ""
            var currentAddresses: [String] = []
            var currentStatus = "inactive"

            func flush() {
                guard !currentName.isEmpty else { return }
                interfaces.append([
                    "name": currentName,
                    "addresses": currentAddresses,
                    "status": currentStatus,
                ])
            }

            for line in output.components(separatedBy: "\n") {
                // Interface header: "en0: flags=..." — starts at column 0, ends with ":"
                if !line.hasPrefix("\t") && !line.hasPrefix(" ") && line.contains(": flags=") {
                    flush()
                    currentName = String(line.prefix(while: { $0 != ":" }))
                    currentAddresses = []
                    currentStatus = line.contains("<UP,") || line.contains(",UP,") || line.contains(",UP>") ? "active" : "inactive"
                } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("inet ") {
                    // inet 192.168.1.5 netmask ... or inet6 ...
                    let parts = line.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                    if parts.count >= 2 { currentAddresses.append(parts[1]) }
                } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("inet6 ") {
                    let parts = line.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                    if parts.count >= 2 {
                        // Drop link-local scope suffix (%en0) for cleanliness
                        let addr = parts[1].components(separatedBy: "%").first ?? parts[1]
                        currentAddresses.append(addr)
                    }
                }
            }
            flush()

            if json {
                printJSON(interfaces)
            } else {
                for iface in interfaces {
                    let name = iface["name"] as? String ?? ""
                    let status = iface["status"] as? String ?? "inactive"
                    let addrs = iface["addresses"] as? [String] ?? []
                    if addrs.isEmpty {
                        print("\(name): (no address) (\(status))")
                    } else {
                        for addr in addrs {
                            print("\(name): \(addr) (\(status))")
                        }
                    }
                }
            }
        }
    }
}
