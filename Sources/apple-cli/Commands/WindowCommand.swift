import ArgumentParser
import Foundation
import CoreGraphics
import AppKit

struct WindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window",
        abstract: "List and control application windows",
        subcommands: [List.self, Move.self, Resize.self, Focus.self, Minimize.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all visible windows with their positions and sizes"
        )
        @Option(name: .long, help: "Filter by app name") var app: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
                fputs("Error: Could not get window list\n", stderr)
                throw ExitCode.failure
            }

            var windows: [[String: Any]] = []
            for w in list {
                let owner = w[kCGWindowOwnerName as String] as? String ?? ""
                let name  = w[kCGWindowName as String] as? String ?? ""
                let layer = w[kCGWindowLayer as String] as? Int ?? 0
                guard layer == 0 else { continue }
                if let filter = app, !owner.localizedCaseInsensitiveContains(filter) { continue }
                guard let bounds = w[kCGWindowBounds as String] as? [String: Any],
                      let x = bounds["X"] as? CGFloat,
                      let y = bounds["Y"] as? CGFloat,
                      let width = bounds["Width"] as? CGFloat,
                      let height = bounds["Height"] as? CGFloat else { continue }
                let entry: [String: Any] = [
                    "app": owner,
                    "title": name,
                    "x": Int(x), "y": Int(y),
                    "width": Int(width), "height": Int(height),
                    "id": w[kCGWindowNumber as String] as? Int ?? 0
                ]
                windows.append(entry)
            }

            if json {
                let data = try JSONSerialization.data(withJSONObject: windows, options: .prettyPrinted)
                print(String(data: data, encoding: .utf8) ?? "[]")
            } else {
                if windows.isEmpty { print("No windows found"); return }
                for w in windows {
                    let app   = w["app"] as! String
                    let title = w["title"] as! String
                    let x = w["x"] as! Int; let y = w["y"] as! Int
                    let width = w["width"] as! Int; let height = w["height"] as! Int
                    let label = title.isEmpty ? app : "\(app) — \(title)"
                    print("\(label): \(x),\(y) \(width)×\(height)")
                }
            }
        }
    }

    struct Move: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "move",
            abstract: "Move a window to a new position"
        )
        @Argument(help: "App name") var app: String
        @Option(name: .long, help: "X position") var x: Int
        @Option(name: .long, help: "Y position") var y: Int
        @Option(name: .long, help: "Window title (if multiple windows)") var title: String?

        func run() throws {
            try axWindow(app: app, title: title) { win in
                var point = CGPoint(x: x, y: y)
                let pos = AXValueCreate(.cgPoint, &point)!
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pos)
                print("Moved \(app) window to (\(x), \(y))")
            }
        }
    }

    struct Resize: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resize",
            abstract: "Resize a window"
        )
        @Argument(help: "App name") var app: String
        @Option(name: .long, help: "Width") var width: Int
        @Option(name: .long, help: "Height") var height: Int
        @Option(name: .long, help: "Window title (if multiple windows)") var title: String?

        func run() throws {
            try axWindow(app: app, title: title) { win in
                var size = CGSize(width: width, height: height)
                let sz = AXValueCreate(.cgSize, &size)!
                AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sz)
                print("Resized \(app) window to \(width)×\(height)")
            }
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "focus",
            abstract: "Bring a window to the front"
        )
        @Argument(help: "App name") var app: String
        @Option(name: .long, help: "Window title (if multiple windows)") var title: String?

        func run() throws {
            // Activate via NSRunningApplication first
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "")
            let _ = runningApps  // unused — use osascript activate instead
            guard let raw = Process.capture(
                args: ["/usr/bin/osascript", "-l", "JavaScript", "-e",
                       "Application('\(app)').activate()"],
                timeout: 5
            ) else {
                fputs("Error: Could not activate \(app)\n", stderr)
                throw ExitCode.failure
            }
            let _ = raw
            // Also raise via AX
            try axWindow(app: app, title: title) { win in
                AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, true as CFTypeRef)
                AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, true as CFTypeRef)
            }
            print("Focused: \(app)")
        }
    }

    struct Minimize: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "minimize",
            abstract: "Minimize a window"
        )
        @Argument(help: "App name") var app: String
        @Option(name: .long, help: "Window title (if multiple windows)") var title: String?

        func run() throws {
            try axWindow(app: app, title: title) { win in
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                print("Minimized \(app)")
            }
        }
    }
}

// MARK: - AX window helper

private func axWindow(app: String, title: String?, action: (AXUIElement) throws -> Void) throws {
    let axApp = AXUIElementCreateApplication(pid(for: app))
    var windowsRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
    guard err == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
        fputs("Error: Could not access \(app) windows — check Accessibility permission\n", stderr)
        throw ExitCode.failure
    }
    let target: AXUIElement
    if let t = title {
        let match = windows.first { win -> Bool in
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            return (titleRef as? String ?? "").localizedCaseInsensitiveContains(t)
        }
        guard let m = match else {
            fputs("Error: No window with title '\(t)' in \(app)\n", stderr)
            throw ExitCode.failure
        }
        target = m
    } else {
        target = windows[0]
    }
    try action(target)
}

private func pid(for appName: String) -> pid_t {
    let apps = NSWorkspace.shared.runningApplications
    if let app = apps.first(where: { ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName) }) {
        return app.processIdentifier
    }
    return 0
}
