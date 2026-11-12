import Foundation

// `macos commands`: the catalogue an agent (and the root SKILL.md) reads to learn the
// whole tool in one call. The tree comes from ArgumentParser's own dump of the command
// line, so a command cannot exist without being listed; whether it writes comes from
// `commandWrites`, which names every command once.
extension MacCLICore {

    /// One runnable command.
    public struct CatalogueEntry: Equatable {
        /// The words after `macos`, e.g. "calendar create".
        public let path: String
        /// Its options and flags, long names first, `--help` and `--version` left out.
        public let flags: [String]
        /// The one line of help.
        public let help: String
        /// True when it can change something: data, a setting, the Mac's state, or
        /// something sent, played or shown. Saving a capture or an export to a path the
        /// caller names is not a write.
        public let writes: Bool

        public init(path: String, flags: [String], help: String, writes: Bool) {
            self.path = path
            self.flags = flags
            self.help = help
            self.writes = writes
        }

        public var json: [String: Any] {
            ["path": path, "flags": flags, "help": help, "writes": writes]
        }
    }

    /// Every runnable command in a `--experimental-dump-help` document (ArgumentParser's
    /// ToolInfoV0), sorted by path. Groups are not listed, their commands are; hidden
    /// commands and ArgumentParser's own `help` are left out. A command missing from
    /// `writes` is listed as a write: unknown is never presented as safe.
    public static func commandCatalogue(dumpHelp: Data, writes: [String: Bool] = commandWrites) throws -> [CatalogueEntry] {
        guard let root = try JSONSerialization.jsonObject(with: dumpHelp) as? [String: Any],
              let command = root["command"] as? [String: Any]
        else { throw CocoaError(.propertyListReadCorrupt) }

        var entries: [CatalogueEntry] = []
        func walk(_ node: [String: Any], path: [String]) {
            if node["shouldDisplay"] as? Bool == false { return }
            let subcommands = node["subcommands"] as? [[String: Any]] ?? []
            if !subcommands.isEmpty {
                for sub in subcommands {
                    let name = sub["commandName"] as? String ?? ""
                    if path.isEmpty && name == "help" { continue }
                    walk(sub, path: path + [name])
                }
                return
            }
            guard !path.isEmpty else { return }
            let joined = path.joined(separator: " ")
            entries.append(CatalogueEntry(path: joined,
                                          flags: flagNames(node["arguments"] as? [[String: Any]] ?? []),
                                          help: node["abstract"] as? String ?? "",
                                          writes: writes[joined] ?? true))
        }
        walk(command, path: [])
        return entries.sorted { $0.path < $1.path }
    }

    private static func flagNames(_ arguments: [[String: Any]]) -> [String] {
        arguments.compactMap { argument -> String? in
            guard argument["kind"] as? String != "positional",
                  argument["shouldDisplay"] as? Bool != false
            else { return nil }
            let names = argument["names"] as? [[String: Any]] ?? []
            let long = names.first { $0["kind"] as? String == "long" }
            let single = names.first { $0["kind"] as? String == "longWithSingleDash" }
            let short = names.first { $0["kind"] as? String == "short" }
            let flag: String
            if let name = long?["name"] as? String { flag = "--" + name }
            else if let name = (single ?? short)?["name"] as? String { flag = "-" + name }
            else { return nil }
            return flag == "--help" || flag == "--version" ? nil : flag
        }
    }

    /// The table `macos commands` prints for a person.
    public static func catalogueTable(_ entries: [CatalogueEntry]) -> String {
        let width = entries.map { $0.path.count }.max() ?? 0
        var lines = ["COMMAND".padding(toLength: width, withPad: " ", startingAt: 0) + "  WRITES  HELP"]
        for entry in entries {
            lines.append(entry.path.padding(toLength: width, withPad: " ", startingAt: 0)
                         + "  " + (entry.writes ? "yes   " : "no    ") + "  " + entry.help)
        }
        return lines.joined(separator: "\n")
    }

    /// Whether each command can change something (see `CatalogueEntry.writes`). Every
    /// command the binary has is named here once; CLITests holds the two lists equal.
    public static let commandWrites: [String: Bool] = [
        "apps info": false,
        "apps launch": true,
        "apps list": false,
        "apps quit": true,

        "audio info": false,
        "audio list": false,
        "audio set-input": true,
        "audio set-output": true,

        "auth deny": true,
        "auth grant": true,
        "auth list": false,
        "auth reset": true,
        "auth setup": true,

        "authorize": true,

        "ax click": true,
        "ax find": false,
        "ax hints": true,
        "ax read": false,

        "bluetooth connect": true,
        "bluetooth disconnect": true,
        "bluetooth list": false,

        "calendar calendars": false,
        "calendar create": true,
        "calendar delete": true,
        "calendar events": false,
        "calendar export": false,
        "calendar reload": false,
        "calendar update": true,

        "commands": false,

        "contacts create": true,
        "contacts delete": true,
        "contacts export": false,
        "contacts get": false,
        "contacts get-note": false,
        "contacts search": false,
        "contacts set-note": true,
        "contacts update": true,

        "daysheets day": false,
        "daysheets days": false,
        "daysheets login": true,

        "defaults delete": true,
        "defaults list-domains": false,
        "defaults read": false,
        "defaults write": true,

        "disk eject": true,
        "disk info": false,
        "disk list": false,
        "disk mount": true,
        "disk unmount": true,

        "dock add": true,
        "dock list": false,
        "dock remove": true,
        "dock restart": true,

        "doctor": false,

        "file copy": true,
        "file delete": true,
        "file list": false,
        "file move": true,
        "file read": false,
        "file stat": false,

        "finder cwd": false,
        "finder go-to": true,
        "finder new-folder": true,
        "finder open": true,
        "finder rename": true,
        "finder reveal": true,
        "finder selected": false,
        "finder show-hidden": true,
        "finder tag": true,

        "focus modes": false,
        "focus off": true,
        "focus on": true,
        "focus status": false,

        "info network": false,
        "info power caffeinate": true,
        "info power settings": false,
        "info power sleep": true,
        "info system": false,

        "keyboard key": true,
        "keyboard type": true,

        "keychain delete": true,
        "keychain get": false,
        "keychain list": false,
        "keychain set": true,

        "location get": false,

        "login-items add": true,
        "login-items list": false,
        "login-items remove": true,

        "mail accounts": false,
        "mail delete": true,
        "mail draft": true,
        "mail mailboxes": false,
        "mail mark": true,
        "mail read": false,
        "mail refresh": false,
        "mail reply": true,
        "mail search": false,
        "mail send": true,

        "mastertour crew": false,
        "mastertour day": false,
        "mastertour events": false,
        "mastertour guestlist": false,
        "mastertour hotels": false,
        "mastertour login": true,
        "mastertour summary": false,
        "mastertour tour": false,
        "mastertour tours": false,

        "menu click": true,
        "menu list": false,

        "messages conversations": false,
        "messages delete": true,
        "messages read": false,
        "messages send": true,

        "mouse click": true,
        "mouse drag": true,
        "mouse move": true,
        "mouse position": false,
        "mouse scroll": true,

        "music add-to-playlist": true,
        "music next": true,
        "music pause": true,
        "music play": true,
        "music playlists": false,
        "music prev": true,
        "music queue": false,
        "music search": true,
        "music status": false,
        "music volume": true,

        "network dns": false,
        "network interfaces": false,
        "network ping": false,
        "network port": false,
        "network traceroute": false,

        "notes create": true,
        "notes create-folder": true,
        "notes delete": true,
        "notes export": false,
        "notes folders": false,
        "notes list": false,
        "notes read": false,
        "notes search": false,
        "notes update": true,

        "notify send": true,

        "ocr file": false,
        "ocr full": false,
        "ocr region": false,

        "pdf info": false,
        "pdf text": false,

        "photos add-to-album": true,
        "photos albums": false,
        "photos delete": true,
        "photos export": false,
        "photos recent": false,
        "photos search": false,

        "process find": false,
        "process kill": true,
        "process list": false,

        "reminders complete": true,
        "reminders create": true,
        "reminders delete": true,
        "reminders done": false,
        "reminders export": false,
        "reminders list": false,
        "reminders lists": false,
        "reminders status": false,
        "reminders uncomplete": true,
        "reminders update": true,

        "safari bookmarks": false,
        "safari close": true,
        "safari execute": true,
        "safari history": false,
        "safari new-tab": true,
        "safari open": true,
        "safari read": false,
        "safari reload": true,
        "safari tabs": false,

        "screen capture": false,
        "screen info": false,
        "screen lock": true,

        "screenshot full": false,
        "screenshot region": false,
        "screenshot window": false,

        "script run": true,

        "setup": true,

        "shortcuts list": false,
        "shortcuts run": true,

        "spaces list": false,
        "spaces switch": true,

        "speech say": true,
        "speech voices": false,

        "spotlight search": false,

        "storage usage": false,
        "storage volumes": false,

        "system audio devices": false,
        "system audio mute": true,
        "system audio now-playing": false,
        "system audio volume": true,
        "system battery": false,
        "system clipboard get": false,
        "system clipboard set": true,
        "system display brightness": true,
        "system display dark-mode": true,
        "system display wallpaper get": false,
        "system display wallpaper set": true,
        "system lock": true,
        "system sleep": true,
        "system vpn connect": true,
        "system vpn disconnect": true,
        "system vpn status": false,
        "system wifi join": true,
        "system wifi leave": true,
        "system wifi networks": false,
        "system wifi status": false,

        "timemachine list-destinations": false,
        "timemachine list-snapshots": false,
        "timemachine start": true,
        "timemachine status": false,
        "timemachine stop": true,

        "trash add": true,
        "trash empty": true,
        "trash list": false,

        "update": true,

        "voice-memos export": false,
        "voice-memos list": false,

        "window focus": true,
        "window fullscreen": true,
        "window list": false,
        "window maximize": true,
        "window minimize": true,
        "window move": true,
        "window resize": true,
        "window snap": true,
    ]
}
