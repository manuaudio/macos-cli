import ArgumentParser
import Foundation

// Voice Memos — reads directly from the iCloud-synced group container.
// No AppleScript/JXA needed; the recordings are plain .m4a files.
// Container path: ~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/
// Each recording is a UUID-named directory containing an .m4a and (on newer OS) a Metadata.plist.

private func recordingsBase() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
        .appendingPathComponent("Library")
        .appendingPathComponent("Group Containers")
        .appendingPathComponent("group.com.apple.VoiceMemos.shared")
        .appendingPathComponent("Recordings")
}

private struct Memo {
    let title: String
    let path: URL          // path to the .m4a file
    let createdAt: Date
    let durationSeconds: Double
}

private func loadMemos() -> [Memo] {
    let base = recordingsBase()
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: base,
                                                     includingPropertiesForKeys: [.creationDateKey],
                                                     options: .skipsHiddenFiles) else {
        return []
    }
    var memos: [Memo] = []
    for dir in entries where dir.hasDirectoryPath {
        // Find the .m4a in this directory
        guard let children = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: [.creationDateKey],
                                                          options: .skipsHiddenFiles) else { continue }
        guard let m4a = children.first(where: { $0.pathExtension.lowercased() == "m4a" }) else { continue }

        let created = (try? m4a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast

        // Try to read title + duration from Metadata.plist if present
        var title = m4a.deletingPathExtension().lastPathComponent
        var duration: Double = 0

        let metaPlist = dir.appendingPathComponent("Metadata.plist")
        if let meta = NSDictionary(contentsOf: metaPlist) {
            if let t = meta["Title"] as? String, !t.isEmpty { title = t }
            if let d = meta["Duration"] as? Double { duration = d }
            // Some OS versions use "RecordingDuration" instead
            if duration == 0, let d = meta["RecordingDuration"] as? Double { duration = d }
        }

        memos.append(Memo(title: title, path: m4a, createdAt: created, durationSeconds: duration))
    }
    return memos.sorted { $0.createdAt > $1.createdAt }
}

private func formatDuration(_ secs: Double) -> String {
    guard secs > 0 else { return "?" }
    let total = Int(secs)
    let m = total / 60
    let s = total % 60
    return String(format: "%d:%02d", m, s)
}

struct VoiceMemosCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voice-memos",
        abstract: "Apple Voice Memos — list and export recordings",
        subcommands: [List.self, Export.self]
    )

    // MARK: - List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all voice memos")
        @Option(name: .long, help: "Max results (default: 50)") var limit: Int = 50
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("voicememos.read")
            let memos = loadMemos().prefix(limit)
            if memos.isEmpty {
                fputs("No voice memos found. Recordings dir: \(recordingsBase().path)\n", stderr)
                return
            }
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate]
            if json {
                let arr = memos.map { m -> [String: Any] in
                    ["title": m.title,
                     "path": m.path.path,
                     "created": fmt.string(from: m.createdAt),
                     "duration_seconds": m.durationSeconds]
                }
                if let data = try? JSONSerialization.data(withJSONObject: arr, options: .prettyPrinted),
                   let s = String(data: data, encoding: .utf8) {
                    print(s)
                }
            } else {
                for m in memos {
                    let dur = formatDuration(m.durationSeconds)
                    let date = fmt.string(from: m.createdAt)
                    print("\(date)  [\(dur)]  \(m.title)")
                }
                print("\(memos.count) memo(s)")
            }
        }
    }

    // MARK: - Export

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy a voice memo to a destination path")

        @Argument(help: "Title substring to match (case-insensitive)")
        var title: String

        @Option(name: [.customShort("o"), .long], help: "Output path (default: /tmp/<title>.m4a)")
        var out: String?

        func run() throws {
            try Auth.check("voicememos.read")
            let memos = loadMemos()
            guard let memo = memos.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) else {
                throw ValidationError("No memo matching '\(title)' found.")
            }
            let dest: URL
            if let o = out {
                dest = URL(fileURLWithPath: o)
            } else {
                let safe = memo.title.replacingOccurrences(of: "/", with: "-")
                dest = URL(fileURLWithPath: "/tmp/\(safe).m4a")
            }
            try FileManager.default.copyItem(at: memo.path, to: dest)
            print("✓ exported: \(dest.path)")
            print("  source:   \(memo.path.path)")
            print("  duration: \(formatDuration(memo.durationSeconds))")
        }
    }
}
