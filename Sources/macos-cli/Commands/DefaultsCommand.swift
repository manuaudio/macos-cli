import ArgumentParser
import Foundation

// MARK: - Top-level defaults command

struct DefaultsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "defaults",
        abstract: "Read and write macOS user defaults (app preferences)",
        subcommands: [Read.self, Write.self, Delete.self, ListDomains.self]
    )

    // MARK: - Read

    struct Read: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "read", abstract: "Read a defaults domain or key")

        @Option(name: .long, help: "Defaults domain e.g. com.apple.finder") var domain: String
        @Option(name: .long, help: "Specific key to read (omit for all keys)") var key: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            var args = ["/usr/bin/defaults", "read", domain]
            if let k = key { args.append(k) }
            guard let output = Process.capture(args: args, timeout: 5) else {
                throw ValidationError("defaults read timed out for domain '\(domain)'")
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("does not exist") {
                throw ValidationError("Domain '\(domain)' not found or key '\(key ?? "")' does not exist")
            }
            if json {
                printJSON([
                    "domain": domain,
                    "key": key ?? "",
                    "value": trimmed,
                ] as [String: Any])
            } else {
                print(trimmed)
            }
        }
    }

    // MARK: - Write

    struct Write: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "write", abstract: "Write a value to a defaults key")

        @Option(name: .long, help: "Defaults domain") var domain: String
        @Option(name: .long, help: "Key to set") var key: String
        @Option(name: .long, help: "Value to write") var value: String
        @Option(name: .long, help: "Value type: string, bool, int, float (default: string)") var type: String = "string"
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("defaults.write")
            let allowedTypes = ["string", "bool", "int", "float"]
            guard allowedTypes.contains(type) else {
                throw ValidationError("--type must be one of: string, bool, int, float")
            }
            let args = ["/usr/bin/defaults", "write", domain, key, "-\(type)", value]
            let code = Process.run(args: args)
            guard code == 0 else {
                throw ValidationError("defaults write failed (exit \(code))")
            }
            if json {
                printJSON(["written": true, "domain": domain, "key": key, "value": value, "type": type] as [String: Any])
            } else {
                print("Written: \(domain) \(key) = \(value) (\(type))")
            }
        }
    }

    // MARK: - Delete

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a defaults key")

        @Option(name: .long, help: "Defaults domain") var domain: String
        @Option(name: .long, help: "Key to delete") var key: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("defaults.delete")
            let args = ["/usr/bin/defaults", "delete", domain, key]
            let code = Process.run(args: args)
            guard code == 0 else {
                throw ValidationError("defaults delete failed (exit \(code)) — key may not exist")
            }
            if json {
                printJSON(["deleted": true, "domain": domain, "key": key] as [String: Any])
            } else {
                print("Deleted: \(domain) \(key)")
            }
        }
    }

    // MARK: - ListDomains

    struct ListDomains: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list-domains", abstract: "List all defaults domains")

        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let output = Process.capture(args: ["/usr/bin/defaults", "domains"], timeout: 10, fallback: "")
            // Output is comma-separated on a single line
            let domains = output
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if json {
                printJSON(domains)
            } else {
                for d in domains { print(d) }
            }
        }
    }
}
