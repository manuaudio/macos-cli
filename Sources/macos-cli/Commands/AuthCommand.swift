// Sources/macos-cli/Commands/AuthCommand.swift
import ArgumentParser
import Foundation

struct AuthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage macos-cli capability permissions",
        subcommands: [Setup.self, List.self, Grant.self, Deny.self, Reset.self]
    )

    // MARK: - List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show all capabilities and their current state")

        func run() throws {
            let caps = Auth.load()
            for entry in Auth.allCapabilities {
                let allowed = caps[entry.id] ?? entry.defaultAllow
                let marker = allowed ? "✓" : "✗"
                print("\(marker) \(entry.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(entry.description)")
            }
        }
    }

    // MARK: - Grant

    struct Grant: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Grant a capability")
        @Argument(help: "Capability ID — run `macos auth list` to see all") var capability: String

        func run() throws {
            guard Auth.allCapabilities.contains(where: { $0.id == capability }) else {
                throw ValidationError("Unknown capability '\(capability)'. Run `macos auth list` to see valid IDs.")
            }
            var caps = Auth.load()
            if caps.isEmpty { caps = Auth.defaultCapabilities }
            caps[capability] = true
            try Auth.save(caps)
            print("Granted: \(capability)")
        }
    }

    // MARK: - Deny

    struct Deny: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Deny a capability")
        @Argument(help: "Capability ID — run `macos auth list` to see all") var capability: String

        func run() throws {
            guard Auth.allCapabilities.contains(where: { $0.id == capability }) else {
                throw ValidationError("Unknown capability '\(capability)'. Run `macos auth list` to see valid IDs.")
            }
            var caps = Auth.load()
            if caps.isEmpty { caps = Auth.defaultCapabilities }
            caps[capability] = false
            try Auth.save(caps)
            print("Denied: \(capability)")
        }
    }

    // MARK: - Reset

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reset all capabilities to default policy")

        func run() throws {
            try Auth.save(Auth.defaultCapabilities)
            print("Permissions reset to default policy (reads allowed, destructive operations denied).")
        }
    }

    // MARK: - Setup

    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Interactive onboarding wizard — configure all capabilities")
        @Flag(name: .long, help: "Grant all capabilities without prompting (agent use; requires --yes to skip confirmation)") var all = false
        @Flag(name: .long, help: "Skip confirmation prompt when using --all") var yes = false

        func run() throws {
            if all {
                if !yes {
                    let granting = Auth.allCapabilities.map { "  \($0.id)" }.joined(separator: "\n")
                    print("This will GRANT every capability:\n\(granting)\n")
                    print("Continue? (y/N): ", terminator: "")
                    let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                    guard input == "y" || input == "yes" else {
                        print("Cancelled.")
                        return
                    }
                }
                var caps = Auth.defaultCapabilities
                for entry in Auth.allCapabilities { caps[entry.id] = true }
                try Auth.save(caps)
                print("All capabilities granted. Run `macos auth list` to review, `macos auth deny <cap>` to restrict.")
                return
            }

            print("macos-cli permission setup")
            print("Press Y to grant, N to deny, Enter to keep the default shown in brackets.\n")
            var caps = Auth.load()
            if caps.isEmpty { caps = Auth.defaultCapabilities }

            for entry in Auth.allCapabilities {
                let current = caps[entry.id] ?? entry.defaultAllow
                print("\(entry.id) [\(current ? "Y" : "N")] — \(entry.description): ", terminator: "")
                let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                if input == "y" { caps[entry.id] = true }
                else if input == "n" { caps[entry.id] = false }
                // empty → keep current
            }
            try Auth.save(caps)
            print("\nPermissions saved to ~/.config/macos-cli/auth.json")
            print("Run `macos auth list` to review. Use `macos auth grant/deny <cap>` to adjust anytime.")
        }
    }
}
