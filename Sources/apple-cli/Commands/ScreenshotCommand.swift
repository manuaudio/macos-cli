import ArgumentParser
import Foundation

// Screenshot via macOS screencapture CLI — full screen requires no TCC permission.
// Window capture (--window) needs Screen Recording in System Settings → Privacy.

struct ScreenshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture screen or window to file",
        subcommands: [Full.self, Window.self, Region.self]
    )

    // MARK: - Full

    struct Full: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Capture the full screen")

        @Option(name: .long, help: "Output path (default: /tmp/screenshot.png)")
        var output: String = "/tmp/screenshot.png"

        @Flag(name: .long, help: "No shutter sound") var silent = true

        func run() throws {
            var args = ["/usr/sbin/screencapture", "-x"]  // -x = no sound
            args.append(output)
            let code = Process.run(args: args)
            guard code == 0 else {
                throw ValidationError("screencapture failed (exit \(code))")
            }
            print("Screenshot saved to \(output)")
        }
    }

    // MARK: - Window

    struct Window: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Capture a specific app window (needs Screen Recording permission)")

        @Option(name: .long, help: "App name (e.g. 'Notes', 'Safari')")
        var app: String

        @Option(name: .long, help: "Output path (default: /tmp/screenshot.png)")
        var output: String = "/tmp/screenshot.png"

        func run() throws {
            // Get the window ID via CGWindowList
            let py = """
import subprocess, json, sys
result = subprocess.run(
    ['python3', '-c', '''
import Quartz
windows = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements, 0)
app = sys.argv[1]
match = next((w for w in windows if app.lower() in (w.get("kCGWindowOwnerName") or "").lower()), None)
if match:
    print(match["kCGWindowNumber"])
else:
    print("")
''', '\(app.replacingOccurrences(of: "'", with: "\\'"))'],
    capture_output=True, text=True
)
print(result.stdout.strip())
"""
            // Simpler: use screencapture -l with window list from osascript
            let windowScript = """
            const se = Application('System Events');
            const procs = se.applicationProcesses.whose({name: '\(app.replacingOccurrences(of: "'", with: "\\'"))'})(  );
            procs.length > 0 ? 'found' : 'not found';
            """
            // Use screencapture interactive window selection for the named app
            // Focus the app first, then capture its frontmost window
            let focusScript = "Application('\(app.replacingOccurrences(of: "'", with: "\\'"))').activate()"
            _ = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", focusScript], timeout: 10, fallback: "")
            usleep(300_000)  // wait for focus

            // screencapture -l requires window ID; use -w (interactive) or fall back to full
            // Use Python + Quartz if available, otherwise fall back to full screen
            let quartz = Process.capture(args: ["/usr/bin/python3", "-c", """
import sys
try:
    import Quartz
    import objc
    windows = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
    app = '\(app.replacingOccurrences(of: "'", with: "\\'"))'
    match = None
    for w in windows:
        name = w.get('kCGWindowOwnerName', '')
        if app.lower() in name.lower() and w.get('kCGWindowLayer', 99) == 0:
            match = w
            break
    if match:
        wid = match['kCGWindowNumber']
        print(str(wid))
    else:
        print('')
except Exception as e:
    print('')
"""], timeout: 10, fallback: "")

            let wid = quartz.trimmingCharacters(in: .whitespacesAndNewlines)
            var args = ["/usr/sbin/screencapture", "-x"]
            if !wid.isEmpty, let _ = Int(wid) {
                args += ["-l", wid]
            } else {
                // Fall back to full screen
                print("Note: Could not get window ID for '\(app)' — capturing full screen instead")
            }
            args.append(output)
            let code = Process.run(args: args)
            guard code == 0 else {
                throw ValidationError("screencapture failed (exit \(code)). May need Screen Recording permission.")
            }
            print("Screenshot saved to \(output)")
        }
    }

    // MARK: - Region

    struct Region: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Capture a rectangular region")

        @Option(help: "Left X coordinate") var x: Int
        @Option(help: "Top Y coordinate") var y: Int
        @Option(help: "Width") var width: Int
        @Option(help: "Height") var height: Int
        @Option(name: .long, help: "Output path (default: /tmp/screenshot.png)")
        var output: String = "/tmp/screenshot.png"

        func run() throws {
            // screencapture -R x,y,w,h
            let args = ["/usr/sbin/screencapture", "-x", "-R", "\(x),\(y),\(width),\(height)", output]
            let code = Process.run(args: args)
            guard code == 0 else {
                throw ValidationError("screencapture failed (exit \(code))")
            }
            print("Region (\(x),\(y)) \(width)×\(height) saved to \(output)")
        }
    }
}
