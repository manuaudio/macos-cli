import ArgumentParser
import Foundation

struct ProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "List and manage running processes",
        subcommands: [List.self, Find.self, Kill.self]
    )

    // MARK: - List
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List running processes")

        enum SortKey: String, ExpressibleByArgument {
            case cpu, mem, name, pid
        }

        @Option(name: .long, help: "Sort by: cpu, mem, name, pid (default: cpu)")
        var sort: SortKey = .cpu

        @Option(name: .long, help: "Limit output to N processes (default: 30)")
        var limit: Int = 30

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let procs = try readProcesses()
            let sorted: [ProcInfo]
            switch sort {
            case .cpu:  sorted = procs.sorted { $0.cpu  > $1.cpu }
            case .mem:  sorted = procs.sorted { $0.mem  > $1.mem }
            case .name: sorted = procs.sorted { $0.name < $1.name }
            case .pid:  sorted = procs.sorted { $0.pid  < $1.pid }
            }
            let top = Array(sorted.prefix(limit))

            if json {
                printJSON(top.map { $0.dict })
            } else {
                print(String(format: "%-8@ %-6@ %-6@ %@", "PID", "CPU%", "MEM%", "NAME"))
                for p in top {
                    print(String(format: "%-8d %-6.1f %-6.1f %@", p.pid, p.cpu, p.mem, p.name))
                }
                print("\(top.count) processes shown")
            }
        }
    }

    // MARK: - Find
    struct Find: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Find processes by name")

        @Argument(help: "Process name (substring match)")
        var name: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let procs = try readProcesses()
            let matches = procs.filter { $0.name.localizedCaseInsensitiveContains(name) }

            if json {
                printJSON(matches.map { $0.dict })
            } else {
                if matches.isEmpty {
                    print("No processes matching '\(name)'")
                    return
                }
                print(String(format: "%-8@ %-6@ %-6@ %@", "PID", "CPU%", "MEM%", "NAME"))
                for p in matches {
                    print(String(format: "%-8d %-6.1f %-6.1f %@", p.pid, p.cpu, p.mem, p.name))
                }
            }
        }
    }

    // MARK: - Kill
    struct Kill: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Kill a process by PID or name")

        @Option(name: .long, help: "Process ID to kill")
        var pid: Int?

        @Option(name: .long, help: "Process name to kill (kills first match)")
        var name: String?

        @Option(name: .long, help: "Signal to send (default: TERM)")
        var signal: String = "TERM"

        @Flag(name: .long, help: "Kill all matching processes (when using --name)")
        var all = false

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            guard pid != nil || name != nil else {
                throw ValidationError("Provide --pid or --name")
            }

            let sigNum = signalNumber(signal)
            var killed: [Int32] = []

            if let targetPid = pid {
                let code = kill(pid_t(targetPid), sigNum)
                if code == 0 {
                    killed.append(Int32(targetPid))
                } else {
                    throw ValidationError("kill(\(targetPid)) failed: \(String(cString: strerror(errno)))")
                }
            } else if let nameFilter = name {
                let procs = try readProcesses()
                let matches = procs.filter { $0.name.localizedCaseInsensitiveContains(nameFilter) }
                if matches.isEmpty {
                    throw ValidationError("No processes matching '\(nameFilter)'")
                }
                let targets = all ? matches : [matches[0]]
                for p in targets {
                    let code = kill(pid_t(p.pid), sigNum)
                    if code == 0 { killed.append(Int32(p.pid)) }
                    else { fputs("error: kill(\(p.pid) \(p.name)): \(String(cString: strerror(errno)))\n", stderr) }
                }
            }

            if json {
                printJSON(["killed": killed, "signal": signal])
            } else {
                print("Sent \(signal) to \(killed.count) process(es): \(killed.map { String($0) }.joined(separator: ", "))")
            }
        }
    }
}

// MARK: - Process model

private struct ProcInfo {
    let pid: Int
    let cpu: Double
    let mem: Double
    let name: String

    var dict: [String: Any] { ["pid": pid, "cpu": cpu, "mem": mem, "name": name] }
}

private func readProcesses() throws -> [ProcInfo] {
    let output = Process.capture(args: ["/bin/ps", "-axo", "pid=,pcpu=,pmem=,comm="])
    let lines = output.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return lines.compactMap { line -> ProcInfo? in
        let parts = line.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard parts.count >= 4,
              let pid = Int(parts[0]),
              let cpu = Double(parts[1]),
              let mem = Double(parts[2]) else { return nil }
        let name = parts[3...].joined(separator: " ")
        return ProcInfo(pid: pid, cpu: cpu, mem: mem, name: name)
    }
}

private func signalNumber(_ name: String) -> Int32 {
    switch name.uppercased() {
    case "TERM", "15": return SIGTERM
    case "KILL", "9":  return SIGKILL
    case "HUP",  "1":  return SIGHUP
    case "INT",  "2":  return SIGINT
    case "QUIT", "3":  return SIGQUIT
    case "USR1", "10": return SIGUSR1
    case "USR2", "12": return SIGUSR2
    default:
        if let n = Int32(name), n > 0 { return n }
        return SIGTERM
    }
}
