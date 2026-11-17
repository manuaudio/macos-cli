import ArgumentParser
import AppKit
import Foundation
import MacCLICore

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
            try Auth.check("apps.launch")
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
            // Try by name via JXA envelope
            let escapedApp = jxaEscape(app)
            let script = """
            try {
                Application('\(escapedApp)').activate();
                JSON.stringify({ok:true,result:'launched'});
            } catch(e) { JSON.stringify({ok:false,error:String(e&&e.message?e.message:e)}); }
            """
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 5, fallback: "")
            if let env = parseJXAEnvelope(raw) {
                if !env.ok {
                    throw CLIFailure.notFound("App '\(app)' not found or could not be launched: \(env.error)")
                }
            } else {
                // fallback: try open -a
                let code = Process.run(args: ["/usr/bin/open", "-a", app])
                guard code == 0 else {
                    throw CLIFailure.notFound("App '\(app)' not found")
                }
            }
            print("Launched: \(app)")
        }
    }

    struct QuitCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "quit", abstract: "Quit an application")
        @Argument(help: "App name or bundle ID") var app: String?
        @Option(name: .long, help: "Quit this one process, not the first app of that name") var pid: Int32?
        @Flag(name: .long, help: "Force quit (SIGKILL)") var force = false

        func validate() throws {
            guard (app == nil) != (pid == nil) else {
                throw ValidationError("Name the app, or give --pid; not both")
            }
        }

        func run() throws {
            let match: NSRunningApplication?
            if let pid {
                // A process the caller started itself (its sibling: both have the caller as parent) is the
                // caller's to end, as a signal would; quitting it needs no grant. Any other needs apps.quit.
                if parent(of: pid) != getppid() { try Auth.check("apps.quit") }
                match = NSRunningApplication(processIdentifier: pid)
            } else {
                try Auth.check("apps.quit")
                match = NSWorkspace.shared.runningApplications.first {
                    $0.localizedName?.lowercased() == app?.lowercased() ||
                    $0.bundleIdentifier?.lowercased() == app?.lowercased()
                }
            }
            guard let target = match else {
                throw CLIFailure.notFound(pid.map { "No app runs as pid \($0)" } ?? "App '\(app ?? "")' is not running")
            }
            if force {
                target.forceTerminate()
            } else {
                target.terminate()
            }
            print("Quit: \(target.localizedName ?? app ?? "pid \(target.processIdentifier)")")
        }

        private func parent(of pid: Int32) -> Int32? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return Int32(info.pbi_ppid)
        }
    }

    struct InfoCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "info", abstract: "Show frontmost app info")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let ws = NSWorkspace.shared
            guard let app = ws.frontmostApplication else {
                throw CLIFailure.notFound("No frontmost application")
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
