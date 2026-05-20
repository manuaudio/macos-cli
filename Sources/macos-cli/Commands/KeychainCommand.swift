import ArgumentParser
import Foundation

// MARK: - Top-level keychain command

struct KeychainCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keychain",
        abstract: "Read and write Keychain secrets",
        subcommands: [Get.self, Set.self, Delete.self, List.self]
    )

    // MARK: - Get

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "get", abstract: "Retrieve a Keychain password")

        @Option(name: .long, help: "Keychain service name") var service: String
        @Option(name: .long, help: "Account name (optional)") var account: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("keychain.get")
            var args = ["/usr/bin/security", "find-generic-password", "-s", service]
            if let a = account { args += ["-a", a] }
            args.append("-w")
            guard let output = Process.capture(args: args, timeout: 5) else {
                throw ValidationError("Keychain query timed out for service '\(service)'")
            }
            let password = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if password.isEmpty {
                throw ValidationError("Item not found in Keychain for service '\(service)'")
            }
            if json {
                printJSON([
                    "service": service,
                    "account": account ?? "",
                    "password": password,
                ] as [String: Any])
            } else {
                print(password)
            }
        }
    }

    // MARK: - Set

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Save or update a Keychain password")

        @Option(name: .long, help: "Keychain service name") var service: String
        @Option(name: .long, help: "Account name") var account: String
        @Option(name: .long, help: "Password or secret to store") var password: String
        @Flag(name: .long, help: "Update if item already exists") var update = false
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("keychain.set")
            var args = ["/usr/bin/security", "add-generic-password", "-s", service, "-a", account, "-w", password]
            if update { args.append("-U") }
            let code = Process.run(args: args)
            guard code == 0 else {
                throw ValidationError("Keychain write failed (exit \(code)) — item may already exist; try --update")
            }
            if json {
                printJSON(["saved": true, "service": service, "account": account] as [String: Any])
            } else {
                print("Saved: \(service) / \(account)")
            }
        }
    }

    // MARK: - Delete

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a Keychain item")

        @Option(name: .long, help: "Keychain service name") var service: String
        @Option(name: .long, help: "Account name (optional)") var account: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            var args = ["/usr/bin/security", "delete-generic-password", "-s", service]
            if let a = account { args += ["-a", a] }
            let code = Process.run(args: args)
            guard code == 0 else {
                throw ValidationError("Keychain delete failed (exit \(code)) — item may not exist")
            }
            if json {
                printJSON(["deleted": true, "service": service, "account": account ?? ""] as [String: Any])
            } else {
                print("Deleted: \(service)\(account != nil ? " / \(account!)" : "")")
            }
        }
    }

    // MARK: - List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List Keychain service/account metadata (no passwords)")

        @Option(name: .long, help: "Filter by service name substring") var query: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            // dump-keychain outputs metadata only; grep for service (svce) and account (acct) attributes
            let output = Process.capture(args: ["/usr/bin/security", "dump-keychain"], timeout: 15, fallback: "")
            var items: [[String: String]] = []
            var currentService = ""
            var currentAccount = ""

            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Lines look like:    "svce"<blob>="com.example.app"
                if trimmed.contains("\"svce\"") {
                    currentService = extractKeychainValue(from: trimmed)
                } else if trimmed.contains("\"acct\"") {
                    currentAccount = extractKeychainValue(from: trimmed)
                } else if trimmed.hasPrefix("keychain:") && !currentService.isEmpty {
                    // boundary between items — flush previous
                    let svc = currentService
                    let acct = currentAccount
                    if let q = query, !svc.lowercased().contains(q.lowercased()) {
                        currentService = ""; currentAccount = ""
                        continue
                    }
                    items.append(["service": svc, "account": acct])
                    currentService = ""; currentAccount = ""
                }
            }
            // Flush last item
            if !currentService.isEmpty {
                if query == nil || currentService.lowercased().contains(query!.lowercased()) {
                    items.append(["service": currentService, "account": currentAccount])
                }
            }

            if json {
                printJSON(items)
            } else {
                if items.isEmpty {
                    print("No items found\(query != nil ? " matching '\(query!)'" : "")")
                } else {
                    for item in items {
                        print("\(item["service"] ?? "") — \(item["account"] ?? "")")
                    }
                }
            }
        }

        private func extractKeychainValue(from line: String) -> String {
            // Handles: "svce"<blob>="value" and "svce"<blob>=<NULL> and hex forms
            if let eqRange = line.range(of: "=") {
                let rhs = String(line[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if rhs.hasPrefix("\"") && rhs.hasSuffix("\"") && rhs.count >= 2 {
                    return String(rhs.dropFirst().dropLast())
                }
                // hex-encoded: 0x... /* "value" */
                if let commentStart = rhs.range(of: "/* \""),
                   let commentEnd = rhs.range(of: "\" */", range: commentStart.upperBound..<rhs.endIndex) {
                    return String(rhs[commentStart.upperBound..<commentEnd.lowerBound])
                }
            }
            return ""
        }
    }
}
