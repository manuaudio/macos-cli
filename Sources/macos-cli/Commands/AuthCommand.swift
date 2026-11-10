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
        static let configuration = CommandConfiguration(
            abstract: "Grant a capability (a person confirms it at the terminal)")
        @Argument(help: "Capability ID — run `macos auth list` to see all") var capability: String

        func run() throws {
            guard Auth.allCapabilities.contains(where: { $0.id == capability }) else {
                throw ValidationError("Unknown capability '\(capability)'. Run `macos auth list` to see valid IDs.")
            }
            try Auth.confirmByPerson("Grant '\(capability)' to every program that runs macos?", answer: capability)
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
        static let configuration = CommandConfiguration(
            abstract: "Reset all capabilities to default policy (a person confirms it at the terminal)")

        func run() throws {
            try Auth.confirmByPerson("Reset every capability to the default policy?", answer: "reset")
            try Auth.save(Auth.defaultCapabilities)
            print("Permissions reset to default policy (reads allowed, destructive operations denied).")
        }
    }

    // MARK: - Setup

    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Interactive onboarding wizard — configure all capabilities (needs a person at the terminal)")
        @Flag(name: .long, help: "Grant every capability (a person confirms it at the terminal)") var all = false

        func run() throws {
            if all {
                let granting = Auth.allCapabilities.map { "  \($0.id)" }.joined(separator: "\n")
                try Auth.confirmByPerson("This grants every capability:\n\(granting)\nContinue?", answer: "all")
                var caps = Auth.defaultCapabilities
                for entry in Auth.allCapabilities { caps[entry.id] = true }
                try Auth.save(caps)
                print("All capabilities granted. Run `macos auth list` to review, `macos auth deny <cap>` to restrict.")
                return
            }

            guard personAtTerminal else { throw Auth.personRequired() }
            print("macos-cli permission setup")
            print("Press Y to grant, N to deny, Enter to keep the default shown in brackets.\n")
            var caps = Auth.load()
            if caps.isEmpty { caps = Auth.defaultCapabilities }

            for entry in Auth.allCapabilities {
                let current = caps[entry.id] ?? entry.defaultAllow
                print("\(entry.id) [\(current ? "Y" : "N")] — \(entry.description): ", terminator: "")
                fflush(stdout)
                let input = askPerson("")?.lowercased() ?? ""
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
