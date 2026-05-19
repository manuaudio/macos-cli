import ArgumentParser
import Foundation
import CoreGraphics

struct ScreenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "Screen and display information",
        subcommands: [InfoCmd.self, ScreenshotCmd.self, LockCmd.self]
    )

    struct InfoCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "info", abstract: "Display screen dimensions and scaling")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let displays = CGGetActiveDisplayList(10, nil, nil)
            var ids = [CGDirectDisplayID](repeating: 0, count: 10)
            var count: UInt32 = 0
            CGGetActiveDisplayList(10, &ids, &count)

            var screens: [[String: Any]] = []
            for i in 0..<Int(count) {
                let dId = ids[i]
                let bounds = CGDisplayBounds(dId)
                let isMain = CGDisplayIsMain(dId) == 1
                let rotation = CGDisplayRotation(dId)
                screens.append([
                    "id": dId,
                    "main": isMain,
                    "width": Int(bounds.size.width),
                    "height": Int(bounds.size.height),
                    "origin_x": Int(bounds.origin.x),
                    "origin_y": Int(bounds.origin.y),
                    "rotation": Int(rotation),
                    "retina": CGDisplayUsesOpenGLAcceleration(dId) == 1,
                ])
            }

            if json {
                printJSON(screens)
            } else {
                for s in screens {
                    let main = (s["main"] as? Bool == true) ? " [main]" : ""
                    print("Display \(s["id"] ?? 0)\(main): \(s["width"] ?? 0)×\(s["height"] ?? 0)")
                }
            }
        }
    }

    struct ScreenshotCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "capture", abstract: "Take a screenshot")

        @Option(name: .long, help: "Output file path (default: /tmp/screenshot.png)") var output: String = "/tmp/screenshot.png"
        @Flag(name: .long, help: "Capture window selection interactively") var window = false

        func run() throws {
            var args = ["/usr/sbin/screencapture", "-x"]  // -x = no sound
            if window { args.append("-w") }
            args.append(output)
            let result = Process.run(args: args)
            if result != 0 { throw ValidationError("Screenshot failed — grant Screen Recording in Privacy & Security") }
            print("Screenshot saved: \(output)")
        }
    }

    struct LockCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "lock", abstract: "Lock the screen")

        func run() throws {
            Process.run(args: ["/usr/bin/pmset", "displaysleepnow"])
            // Also trigger screensaver lock
            let script = "tell application \"System Events\" to start screensaver"
            Process.run(args: ["/usr/bin/osascript", "-e", script])
            print("Screen locked")
        }
    }
}
