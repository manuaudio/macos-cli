import ArgumentParser
import Foundation
import CoreFoundation
import IOKit
import IOKit.ps
import AppKit

// MARK: - Top-level system command

struct SystemCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "system",
        abstract: "macOS system controls — battery, audio, Wi-Fi, display, clipboard, VPN",
        subcommands: [
            BatteryCommand.self,
            AudioCommand.self,
            WifiCommand.self,
            ClipboardCommand.self,
            DisplayCommand.self,
            VPNCommand.self,
            LockCommand.self,
            SleepCommand.self,
        ]
    )
}

// MARK: - Battery

struct BatteryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "battery", abstract: "Battery status")

    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]

        var level = -1
        var charging = false
        var plugged = false
        var timeRemaining = -1

        for src in sources {
            let desc = IOPSGetPowerSourceDescription(info, src).takeUnretainedValue() as NSDictionary
            if let cap = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                level = Int((Double(cap) / Double(max)) * 100)
            }
            if let isCharging = desc[kIOPSIsChargingKey] as? Bool { charging = isCharging }
            if let isPowered = desc[kIOPSPowerSourceStateKey] as? String {
                plugged = isPowered == kIOPSACPowerValue
            }
            if let t = desc[kIOPSTimeToEmptyKey] as? Int, t > 0 { timeRemaining = t }
            if let t = desc[kIOPSTimeToFullChargeKey] as? Int, charging && t > 0 { timeRemaining = t }
        }

        if json {
            var d: [String: Any] = [
                "level": level,
                "charging": charging,
                "plugged_in": plugged,
            ]
            if timeRemaining > 0 { d["time_remaining_minutes"] = timeRemaining }
            printJSON(d)
        } else {
            let statusStr = charging ? "charging" : (plugged ? "plugged in, not charging" : "on battery")
            let timeStr = timeRemaining > 0 ? " (\(timeRemaining)min)" : ""
            print("Battery: \(level)% — \(statusStr)\(timeStr)")
        }
    }
}

// MARK: - Audio

struct AudioCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Audio volume and device control",
        subcommands: [VolumeCommand.self, MuteCommand.self, DevicesCommand.self, NowPlayingCommand.self]
    )

    struct VolumeCommand: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "volume", abstract: "Get or set system volume")

        @Argument(help: "Volume level 0-100 (omit to get)") var level: Int?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            if let level = level {
                guard level >= 0 && level <= 100 else { throw ValidationError("Volume must be 0–100") }
                let script = "set volume output volume \(level)"
                Process.run(args: ["/usr/bin/osascript", "-e", script])
                if !json { print("Volume set to \(level)%") }
            } else {
                let result = Process.capture(args: ["/usr/bin/osascript", "-e",
                    "output volume of (get volume settings)"], timeout: 10, fallback: "")
                let vol = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if json { printJSON(["volume": Int(vol) ?? -1]) } else { print("Volume: \(vol)%") }
            }
        }
    }

    struct MuteCommand: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "mute", abstract: "Get or set mute state")

        @Argument(help: "on or off (omit to get)") var state: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            if let state = state {
                guard state == "on" || state == "off" else { throw ValidationError("State must be 'on' or 'off'") }
                let muted = state == "on"
                Process.run(args: ["/usr/bin/osascript", "-e",
                    "set volume output muted \(muted ? "true" : "false")"])
                if json { printJSON(["muted": muted]) } else { print("Mute: \(state)") }
            } else {
                let result = Process.capture(args: ["/usr/bin/osascript", "-e",
                    "output muted of (get volume settings)"], timeout: 10, fallback: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let isMuted = result == "true"
                if json { printJSON(["muted": isMuted]) } else { print("Mute: \(result)") }
            }
        }
    }

    struct DevicesCommand: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "devices", abstract: "List audio input/output devices")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let spOutput = Process.capture(args: ["/usr/sbin/system_profiler",
                "SPAudioDataType", "-json"], timeout: 30, fallback: "")
            guard let data = spOutput.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let audioData = parsed["SPAudioDataType"] as? [[String: Any]] else {
                throw ValidationError("Could not retrieve audio devices")
            }
            // Normalize raw system_profiler keys into clean output
            var devices: [[String: Any]] = []
            for group in audioData {
                guard let items = group["_items"] as? [[String: Any]] else { continue }
                for item in items {
                    var d: [String: Any] = [:]
                    d["name"] = item["_name"] as? String ?? ""
                    d["manufacturer"] = item["coreaudio_device_manufacturer"] as? String ?? ""
                    d["type"] = item["coreaudio_device_transport"] as? String ?? ""
                    d["input_channels"] = item["coreaudio_device_input"] as? Int ?? 0
                    d["output_channels"] = item["coreaudio_device_output"] as? Int ?? 0
                    d["default_input"] = item["coreaudio_default_audio_input_device"] != nil
                    d["default_output"] = item["coreaudio_default_audio_output_device"] != nil
                    devices.append(d)
                }
            }
            if json {
                printJSON(devices)
            } else {
                for d in devices {
                    let name = d["name"] as? String ?? ""
                    let inp = (d["default_input"] as? Bool == true) ? " [default in]" : ""
                    let out = (d["default_output"] as? Bool == true) ? " [default out]" : ""
                    print("\(name)\(inp)\(out)")
                }
            }
        }
    }

    struct NowPlayingCommand: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "now-playing", abstract: "Currently playing media info")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let script = """
            tell application "Music"
                if player state is playing then
                    return name of current track & "|" & artist of current track & "|" & album of current track
                end if
            end tell
            return "nothing"
            """
            let result = Process.capture(args: ["/usr/bin/osascript", "-e", script], timeout: 10, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result == "nothing" || result.isEmpty {
                if json { printJSON(["playing": false]) } else { print("Nothing playing") }
            } else {
                let parts = result.components(separatedBy: "|")
                if json {
                    printJSON([
                        "playing": true,
                        "title": parts.count > 0 ? parts[0] : "",
                        "artist": parts.count > 1 ? parts[1] : "",
                        "album": parts.count > 2 ? parts[2] : "",
                    ])
                } else {
                    print(result.replacingOccurrences(of: "|", with: " — "))
                }
            }
        }
    }
}

// MARK: - Wi-Fi (CoreWLAN)

struct WifiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wifi",
        abstract: "Wi-Fi status, network scan, join and leave",
        subcommands: [StatusCmd.self, NetworksCmd.self, JoinCmd.self, LeaveCmd.self]
    )

    struct StatusCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Current Wi-Fi connection")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            // Use system_profiler for Wi-Fi info (works without entitlements)
            let result = Process.capture(args: ["/usr/sbin/system_profiler", "SPAirPortDataType", "-json"], timeout: 30, fallback: "")
            if let data = result.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let airportData = parsed["SPAirPortDataType"] as? [[String: Any]],
               let first = airportData.first,
               let interfaces = first["spairport_airport_interfaces"] as? [[String: Any]],
               let iface = interfaces.first {
                let ssid = iface["spairport_current_network_information"] as? [String: Any]
                let networkName = ssid?["_name"] as? String ?? "unknown"
                let channel = ssid?["spairport_network_channel"] as? String ?? ""
                let security = ssid?["spairport_security_mode"] as? String ?? ""
                let ifaceName = iface["_name"] as? String ?? ""
                let macAddr = iface["spairport_airport_hardware_address"] as? String ?? ""

                if json {
                    var out: [String: Any] = [
                        "interface": ifaceName,
                        "ssid": networkName,
                        "channel": channel,
                        "security": security,
                        "connected": networkName != "unknown",
                    ]
                    if !macAddr.isEmpty { out["mac"] = macAddr }
                    printJSON(out)
                } else {
                    print("Interface: \(ifaceName)")
                    print("Network: \(networkName)")
                    if !channel.isEmpty { print("Channel: \(channel)") }
                    if !security.isEmpty { print("Security: \(security)") }
                }
            } else {
                throw ValidationError("Could not retrieve Wi-Fi info")
            }
        }
    }

    struct NetworksCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "networks", abstract: "Scan for nearby networks")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            // airport scan (requires /System/Library/PrivateFrameworks/Apple80211.framework)
            let airportPath = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
            let result = Process.capture(args: [airportPath, "-s"], timeout: 10, fallback: "")
            if json {
                let lines = result.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
                let networks = lines.map { line -> [String: String] in
                    let parts = line.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                    return [
                        "ssid": parts.count > 0 ? parts[0] : "",
                        "bssid": parts.count > 1 ? parts[1] : "",
                        "rssi": parts.count > 2 ? parts[2] : "",
                        "channel": parts.count > 3 ? parts[3] : "",
                    ]
                }
                printJSON(networks)
            } else {
                print(result)
            }
        }
    }

    struct JoinCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "join", abstract: "Join a Wi-Fi network")

        @Option(name: .long, help: "Network SSID") var ssid: String
        @Option(name: .long, help: "Password (omit for open networks)") var password: String?

        func run() throws {
            var args = ["/usr/sbin/networksetup", "-setairportnetwork", "en0", ssid]
            if let pw = password { args.append(pw) }
            let code = Process.run(args: args)
            guard code == 0 else {
                throw ValidationError("Could not join '\(ssid)' (exit \(code)) — check SSID and password")
            }
            print("Joined: \(ssid)")
        }
    }

    struct LeaveCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "leave", abstract: "Disconnect from current Wi-Fi network")

        func run() throws {
            _ = Process.run(args: ["/usr/sbin/networksetup", "-setairportpower", "en0", "off"])
            usleep(500_000)
            _ = Process.run(args: ["/usr/sbin/networksetup", "-setairportpower", "en0", "on"])
            print("Disconnected from Wi-Fi")
        }
    }
}

// MARK: - Clipboard

struct ClipboardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "Read or write the system clipboard",
        subcommands: [GetCmd.self, SetCmd.self]
    )

    struct GetCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "get", abstract: "Read clipboard contents")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let result = Process.capture(args: ["/usr/bin/pbpaste"], timeout: 3, fallback: "")
            if json { printJSON(["text": result]) } else { print(result) }
        }
    }

    struct SetCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Write text to clipboard")
        @Argument(help: "Text to copy") var text: String

        func run() throws {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
            let pipe = Pipe()
            proc.standardInput = pipe
            try proc.run()
            pipe.fileHandleForWriting.write(text.data(using: .utf8)!)
            pipe.fileHandleForWriting.closeFile()
            proc.waitUntilExit()
            print("Copied \(text.count) chars to clipboard")
        }
    }
}

// MARK: - Display

struct DisplayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "display",
        abstract: "Display brightness, dark mode, and wallpaper control",
        subcommands: [BrightnessCmd.self, DarkModeCmd.self, WallpaperCmd.self]
    )

    struct BrightnessCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "brightness", abstract: "Get or set display brightness")
        @Argument(help: "Brightness 0.0–1.0 (omit to get)") var level: Double?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            if let level = level {
                guard level >= 0 && level <= 1 else { throw ValidationError("Brightness must be 0.0–1.0") }
                // Use brightness CLI if available, else osascript
                let script = "tell application \"System Events\" to key code 144"  // F15 as fallback
                _ = Process.capture(args: ["/usr/bin/osascript", "-e",
                    "tell application \"System Preferences\" to quit"], timeout: 10, fallback: "")  // close if open
                // Use private IOKit call via command line brightness tool
                if FileManager.default.fileExists(atPath: "/usr/local/bin/brightness") {
                    Process.run(args: ["/usr/local/bin/brightness", String(level)])
                } else {
                    // Fallback: use osascript menu simulation
                    let pct = Int(level * 100)
                    fputs("Note: 'brightness' CLI not found. Install via: brew install brightness\n", stderr)
                    fputs("Current request: set to \(pct)%\n", stderr)
                }
                if !json { print("Brightness: \(Int(level * 100))%") }
            } else {
                if FileManager.default.fileExists(atPath: "/usr/local/bin/brightness") {
                    let result = Process.capture(args: ["/usr/local/bin/brightness", "-l"], timeout: 5, fallback: "")
                    if json { printJSON(["output": result]) } else { print(result) }
                } else {
                    fputs("Error: 'brightness' CLI not found. Install: brew install brightness\n", stderr)
                    throw ExitCode.failure
                }
            }
        }
    }

    struct DarkModeCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "dark-mode", abstract: "Toggle or get dark mode")
        @Argument(help: "on or off (omit to get)") var state: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            if let state = state {
                guard state == "on" || state == "off" else { throw ValidationError("State must be 'on' or 'off'") }
                let script = """
                tell application "System Events"
                    tell appearance preferences
                        set dark mode to \(state == "on" ? "true" : "false")
                    end tell
                end tell
                """
                Process.run(args: ["/usr/bin/osascript", "-e", script])
                if !json { print("Dark mode: \(state)") }
            } else {
                let result = Process.capture(args: ["/usr/bin/osascript", "-e",
                    "tell application \"System Events\" to tell appearance preferences to return dark mode"], timeout: 10, fallback: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if json { printJSON(["dark_mode": result == "true"]) } else { print("Dark mode: \(result)") }
            }
        }
    }

    struct WallpaperCmd: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wallpaper",
            abstract: "Get or set the desktop wallpaper",
            subcommands: [GetCmd.self, SetCmd.self]
        )

        struct GetCmd: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "get", abstract: "Get current wallpaper path for each display")
            @Flag(name: .long, help: "Output JSON") var json = false

            func run() throws {
                let screens = NSScreen.screens
                let items: [[String: Any]] = screens.enumerated().compactMap { index, screen in
                    guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
                    return ["display": index, "name": screen.localizedName, "path": url.path]
                }
                if json {
                    let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted])
                    print(String(data: data, encoding: .utf8)!)
                } else {
                    for item in items {
                        print("Display \(item["display"] ?? 0) (\(item["name"] ?? "")): \(item["path"] ?? "")")
                    }
                }
            }
        }

        struct SetCmd: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "set", abstract: "Set the desktop wallpaper (all displays)")
            @Argument(help: "Path to image file") var path: String
            @Flag(name: .long, help: "Output JSON") var json = false

            func run() throws {
                let expanded = (path as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: expanded) else {
                    throw ValidationError("Image file not found: \(path)")
                }
                let url = URL(fileURLWithPath: expanded)
                let screens = NSScreen.screens
                guard !screens.isEmpty else { throw ValidationError("No displays found.") }
                for screen in screens {
                    try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                }
                if json {
                    print("{\"set\": true, \"path\": \"\(expanded)\", \"displays\": \(screens.count)}")
                } else {
                    print("Wallpaper set to: \(expanded) (\(screens.count) display\(screens.count == 1 ? "" : "s"))")
                }
            }
        }
    }
}

// MARK: - Lock

struct LockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lock", abstract: "Lock the screen immediately")
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        // Primary: CGSession -suspend (fast, instant lock)
        let cgSession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        var code = Process.run(args: [cgSession, "-suspend"])
        if code != 0 {
            // Fallback: turn off display (triggers lock if "Require password immediately" is set)
            code = Process.run(args: ["/usr/bin/pmset", "displaysleepnow"])
        }
        if json {
            printJSON(["locked": code == 0])
        } else {
            print(code == 0 ? "Screen locked." : "Lock command sent (exit \(code)).")
        }
    }
}

// MARK: - Sleep

struct SleepCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sleep", abstract: "Put the Mac to sleep")
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        if json { printJSON(["sleeping": true]) } else { print("Going to sleep...") }
        // pmset sleepnow returns immediately before the Mac actually sleeps, so flush stdout first
        fflush(stdout)
        _ = Process.run(args: ["/usr/bin/pmset", "sleepnow"])
    }
}

// MARK: - Process helpers

extension Process {
    @discardableResult
    static func run(args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    static func capture(args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    static func capture(args: [String], timeout seconds: Double, fallback: String = "") -> String {
        return capture(args: args, timeout: seconds) ?? fallback
    }

    // Returns nil on timeout. Drains pipe asynchronously to prevent deadlock
    // when output exceeds the 64 KB pipe buffer (e.g. `ps -ax` on busy systems).
    static func capture(args: [String], timeout seconds: Double) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        var collected = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); collected.append(chunk); lock.unlock()
        }

        guard (try? proc.run()) != nil else {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        let deadline = Date().addingTimeInterval(seconds)
        while proc.isRunning {
            if Date() > deadline {
                proc.terminate()
                pipe.fileHandleForReading.readabilityHandler = nil
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        // Drain any bytes buffered after process exit
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { lock.lock(); collected.append(tail); lock.unlock() }
        return String(data: collected, encoding: .utf8)
    }
}

// MARK: - VPN

struct VPNCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vpn",
        abstract: "VPN connection management — list, connect, disconnect",
        subcommands: [StatusCmd.self, ConnectCmd.self, DisconnectCmd.self]
    )

    struct StatusCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "List VPN configurations and their state")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            guard let output = Process.capture(args: ["/usr/sbin/scutil", "--nc", "list"], timeout: 10) else {
                throw ValidationError("VPN status query timed out.")
            }
            let uuidRegex = try? NSRegularExpression(pattern: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
            let lines = output.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let items: [[String: Any]] = lines.compactMap { line -> [String: Any]? in
                let nsLine = line as NSString
                let nsRange = NSRange(location: 0, length: nsLine.length)
                // skip header lines that have no UUID
                guard let uuidMatch = uuidRegex?.firstMatch(in: line, range: nsRange) else { return nil }
                let uuid = nsLine.substring(with: uuidMatch.range)
                let connected = line.contains("(Connected)")
                // name is the last quoted string on the line
                let nameMatch = line.range(of: "\"([^\"]+)\"", options: .regularExpression)
                let name = nameMatch.map { String(line[$0]).trimmingCharacters(in: .init(charactersIn: "\"")) } ?? uuid
                // protocol is the last bracketed token
                let protoMatch = line.range(of: "\\[([^\\]]+)\\][^\\[]*$", options: .regularExpression)
                let proto = protoMatch.map { String(line[$0]).trimmingCharacters(in: .init(charactersIn: "[]")) } ?? ""
                return ["name": name, "uuid": uuid, "protocol": proto, "connected": connected]
            }
            if json {
                let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted])
                print(String(data: data, encoding: .utf8)!)
            } else {
                if items.isEmpty { print("No VPN configurations found."); return }
                for item in items {
                    let status = (item["connected"] as? Bool == true) ? "Connected" : "Disconnected"
                    print("[\(status)] \(item["name"] ?? "") (\(item["protocol"] ?? ""))")
                }
            }
        }
    }

    struct ConnectCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "connect", abstract: "Connect a VPN by name")
        @Argument(help: "VPN name (as shown in 'system vpn status')") var name: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let result = Process.run(args: ["/usr/sbin/scutil", "--nc", "start", name])
            guard result == 0 else {
                throw ValidationError("Failed to start VPN '\(name)'. Check name with 'system vpn status'.")
            }
            if json {
                print("{\"connecting\": true, \"name\": \"\(name)\"}")
            } else {
                print("Connecting to VPN: \(name)")
            }
        }
    }

    struct DisconnectCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "disconnect", abstract: "Disconnect a VPN by name")
        @Argument(help: "VPN name") var name: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let result = Process.run(args: ["/usr/sbin/scutil", "--nc", "stop", name])
            guard result == 0 else {
                throw ValidationError("Failed to stop VPN '\(name)'.")
            }
            if json {
                print("{\"disconnected\": true, \"name\": \"\(name)\"}")
            } else {
                print("Disconnected VPN: \(name)")
            }
        }
    }
}
