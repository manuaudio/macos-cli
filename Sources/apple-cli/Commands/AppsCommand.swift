import ArgumentParser
import AppKit
import Foundation

struct AppsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "Manage running applications",
        subcommands: [ListCmd.self, LaunchCmd.self, QuitCmd.self, InfoCmd.self]
    )

    struct ListCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List running applications")
        @Flag(name: .long, help: "Include background apps") var all = false
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let ws = NSWorkspace.shared
            let apps = ws.runningApplications
            let filtered = all ? apps : apps.filter { $0.activationPolicy == .regular }
            let sorted = filtered.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

            if json {
                printJSON(sorted.map { app -> [String: Any] in
                    var d: [String: Any] = [
                        "pid": app.processIdentifier,
                        "name": app.localizedName ?? "",
                        "bundle_id": app.bundleIdentifier ?? "",
                        "active": app.isActive,
                        "hidden": app.isHidden,
                    ]
                    if let url = app.bundleURL { d["path"] = url.path }
                    return d
                })
            } else {
                for app in sorted {
                    let active = app.isActive ? " [active]" : ""
                    print("\(app.localizedName ?? "?")\(active) (pid: \(app.processIdentifier))")
                }
                print("\(sorted.count) apps")
            }
        }
    }

    struct LaunchCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "launch", abstract: "Launch an application")
        @Argument(help: "App name or bundle ID (e.g. 'Safari', 'com.apple.Safari')") var app: String

        func run() throws {
            let ws = NSWorkspace.shared
            // Try bundle ID first
            if app.contains(".") {
                if let url = ws.urlForApplication(withBundleIdentifier: app) {
                    let config = NSWorkspace.OpenConfiguration()
                    ws.openApplication(at: url, configuration: config)
                    print("Launched: \(app)")
                    return
                }
            }
            // Try by name
            let result = Process.capture(args: ["/usr/bin/open", "-a", app])
            if result.contains("error") || result.contains("Error") {
                throw ValidationError("App '\(app)' not found")
            }
            print("Launched: \(app)")
        }
    }

    struct QuitCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "quit", abstract: "Quit an application")
        @Argument(help: "App name or bundle ID") var app: String
        @Flag(name: .long, help: "Force quit (SIGKILL)") var force = false

        func run() throws {
            let ws = NSWorkspace.shared
            let running = ws.runningApplications
            let match = running.first {
                $0.localizedName?.lowercased() == app.lowercased() ||
                $0.bundleIdentifier?.lowercased() == app.lowercased()
            }
            guard let target = match else {
                throw ValidationError("App '\(app)' is not running")
            }
            if force {
                target.forceTerminate()
            } else {
                target.terminate()
            }
            print("Quit: \(target.localizedName ?? app)")
        }
    }

    struct InfoCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "info", abstract: "Show frontmost app info")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let ws = NSWorkspace.shared
            guard let app = ws.frontmostApplication else {
                throw ValidationError("No frontmost application")
            }
            if json {
                printJSON([
                    "name": app.localizedName ?? "",
                    "bundle_id": app.bundleIdentifier ?? "",
                    "pid": app.processIdentifier,
                    "path": app.bundleURL?.path ?? "",
                ])
            } else {
                print("Frontmost: \(app.localizedName ?? "?") (pid: \(app.processIdentifier))")
            }
        }
    }
}
