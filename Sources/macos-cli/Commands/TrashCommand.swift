import ArgumentParser
import Foundation
import AppKit

struct TrashCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash",
        abstract: "Manage the Trash — move files to trash, empty, list contents",
        subcommands: [AddCmd.self, EmptyCmd.self, ListCmd.self]
    )

    struct AddCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Move a file or folder to the Trash")
        @Argument(help: "Path of file or directory to trash") var path: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("file.write")
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("Path not found: \(path)")
            }
            var resultURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
            let trashPath = resultURL?.path ?? "~/.Trash/"
            if json {
                printJSON(["trashed": true, "original": url.path, "trash_path": trashPath] as [String: Any])
            } else {
                print("Moved to Trash: \(url.path)")
            }
        }
    }

    struct EmptyCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "empty", abstract: "Empty the Trash")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("trash.empty")
            let script = "tell application \"Finder\" to empty trash"
            let result = Process.capture(args: ["/usr/bin/osascript", "-e", script], timeout: 30)
            if result == nil {
                throw ValidationError("Empty trash timed out after 30s. Trash may be large.")
            }
            if json {
                print("{\"emptied\": true}")
            } else {
                print("Trash emptied.")
            }
        }
    }

    struct ListCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List Trash contents")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let trashURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
            guard FileManager.default.fileExists(atPath: trashURL.path) else {
                if json { print("[]") } else { print("Trash is empty.") }
                return
            }
            let keys: [URLResourceKey] = [.nameKey, .fileSizeKey, .isDirectoryKey, .contentModificationDateKey]
            let items = (try? FileManager.default.contentsOfDirectory(
                at: trashURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            if json {
                let result: [[String: Any]] = items.compactMap { url in
                    guard let resources = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                    return [
                        "name": resources.name ?? url.lastPathComponent,
                        "path": url.path,
                        "size": resources.fileSize ?? 0,
                        "is_directory": resources.isDirectory ?? false,
                        "modified": resources.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
                print(String(data: data, encoding: .utf8)!)
            } else {
                if items.isEmpty { print("Trash is empty."); return }
                print(String(format: "%-40s %10s", "NAME", "SIZE"))
                print(String(repeating: "-", count: 52))
                for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let resources = try? url.resourceValues(forKeys: Set(keys))
                    let size = resources?.fileSize.map { trashFormatBytes($0) } ?? "-"
                    print(String(format: "%-40s %10s", String(url.lastPathComponent.prefix(38)), size))
                }
            }
        }
    }
}

private func trashFormatBytes(_ bytes: Int) -> String {
    let kb = Double(bytes) / 1024
    if kb < 1 { return "\(bytes)B" }
    let mb = kb / 1024
    if mb < 1 { return String(format: "%.1fK", kb) }
    let gb = mb / 1024
    if gb < 1 { return String(format: "%.1fM", mb) }
    return String(format: "%.1fG", gb)
}
