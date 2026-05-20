import ArgumentParser
import Foundation
import CoreGraphics
import AppKit

struct WindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window",
        abstract: "List and control application windows",
        subcommands: [List.self, Move.self, Resize.self, Focus.self, Minimize.self, Fullscreen.self, Maximize.self, Snap.self]
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

    struct Fullscreen: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "fullscreen", abstract: "Toggle fullscreen for an app window")
        @Argument(help: "App name") var app: String
        @Option(name: .long, help: "Window title (if multiple windows)") var title: String?

        func run() throws {
            try axWindow(app: app, title: title) { win in
                var currentRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &currentRef)
                let current = (currentRef as? NSNumber)?.boolValue ?? false
                AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, (!current) as CFTypeRef)
                print("\(self.app) \(!current ? "entered" : "exited") fullscreen")
            }
        }
    }

    struct Maximize: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "maximize", abstract: "Expand a window to fill the visible screen area")
        @Argument(help: "App name") var app: String
        @Option(name: .long, help: "Window title (if multiple windows)") var title: String?

        func run() throws {
            guard let screen = NSScreen.main else {
                throw ValidationError("Could not determine main screen.")
            }
            let vf = screen.visibleFrame
            let sf = screen.frame
            // AX position uses top-left origin; NSScreen uses bottom-left. Convert.
            let axY = sf.height - vf.origin.y - vf.height
            try axWindow(app: app, title: title) { win in
                var origin = CGPoint(x: vf.origin.x, y: axY)
                let pos = AXValueCreate(.cgPoint, &origin)!
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pos)
                var size = CGSize(width: vf.width, height: vf.height)
                let sz = AXValueCreate(.cgSize, &size)!
                AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sz)
                print("Maximized \(self.app): \(Int(vf.width))×\(Int(vf.height))")
            }
        }
    }

    struct Snap: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "snap", abstract: "Snap a window to a screen region")
        @Argument(help: "App name") var app: String
        @Argument(help: "Position: left|right|top|bottom|top-left|top-right|bottom-left|bottom-right|left-third|center-third|right-third") var position: String
        @Option(name: .long, help: "Window title (if multiple windows)") var title: String?

        func run() throws {
            guard let screen = NSScreen.main else {
                throw ValidationError("Could not determine main screen.")
            }
            let vf = screen.visibleFrame
            let sf = screen.frame
            let W = vf.width, H = vf.height
            let ox = vf.origin.x
            let baseY = sf.height - vf.origin.y - vf.height

            let (rx, ry, rw, rh): (CGFloat, CGFloat, CGFloat, CGFloat)
            switch position {
            case "left":          (rx, ry, rw, rh) = (ox,         baseY,       W/2, H)
            case "right":         (rx, ry, rw, rh) = (ox + W/2,   baseY,       W/2, H)
            case "top":           (rx, ry, rw, rh) = (ox,         baseY,       W,   H/2)
            case "bottom":        (rx, ry, rw, rh) = (ox,         baseY + H/2, W,   H/2)
            case "top-left":      (rx, ry, rw, rh) = (ox,         baseY,       W/2, H/2)
            case "top-right":     (rx, ry, rw, rh) = (ox + W/2,   baseY,       W/2, H/2)
            case "bottom-left":   (rx, ry, rw, rh) = (ox,         baseY + H/2, W/2, H/2)
            case "bottom-right":  (rx, ry, rw, rh) = (ox + W/2,   baseY + H/2, W/2, H/2)
            case "left-third":    (rx, ry, rw, rh) = (ox,         baseY,       W/3, H)
            case "center-third":  (rx, ry, rw, rh) = (ox + W/3,   baseY,       W/3, H)
            case "right-third":   (rx, ry, rw, rh) = (ox + 2*W/3, baseY,       W/3, H)
            default:
                throw ValidationError(
                    "Unknown position '\(position)'. Valid: left, right, top, bottom, top-left, top-right, bottom-left, bottom-right, left-third, center-third, right-third"
                )
            }

            try axWindow(app: app, title: title) { win in
                var origin = CGPoint(x: rx, y: ry)
                let pos = AXValueCreate(.cgPoint, &origin)!
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pos)
                var size = CGSize(width: rw, height: rh)
                let sz = AXValueCreate(.cgSize, &size)!
                AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sz)
                print("Snapped \(self.app) to \(self.position): \(Int(rw))×\(Int(rh)) at (\(Int(rx)),\(Int(ry)))")
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
