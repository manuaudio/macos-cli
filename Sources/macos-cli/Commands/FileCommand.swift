import ArgumentParser
import Foundation

struct FileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "file",
        abstract: "Headless file operations — list, copy, move, delete, stat, read",
        subcommands: [ListCmd.self, CopyCmd.self, MoveCmd.self, DeleteCmd.self, StatCmd.self, ReadCmd.self]
    )

    struct ListCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List directory contents")
        @Argument(help: "Directory path (default: current directory)") var path: String = "."
        @Flag(name: .long, help: "Include hidden files") var all = false
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                throw ValidationError("Not a directory: \(path)")
            }
            let keys: [URLResourceKey] = [.nameKey, .fileSizeKey, .isDirectoryKey, .contentModificationDateKey]
            var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
            if !all { options.insert(.skipsHiddenFiles) }
            let items = (try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: options))
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            if json {
                let result: [[String: Any]] = items.compactMap { itemURL in
                    guard let resources = try? itemURL.resourceValues(forKeys: Set(keys)) else { return nil }
                    return [
                        "name": resources.name ?? itemURL.lastPathComponent,
                        "path": itemURL.path,
                        "size": resources.fileSize ?? 0,
                        "is_directory": resources.isDirectory ?? false,
                        "modified": resources.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
                print(String(data: data, encoding: .utf8)!)
            } else {
                print(String(format: "%-8s %-12s %s", "TYPE", "SIZE", "NAME"))
                print(String(repeating: "-", count: 60))
                for itemURL in items {
                    let resources = try? itemURL.resourceValues(forKeys: Set(keys))
                    let isDirectory = resources?.isDirectory ?? false
                    let typeLabel = isDirectory ? "DIR" : "FILE"
                    let size = isDirectory ? "-" : (resources?.fileSize.map { fileFormatBytes($0) } ?? "-")
                    print(String(format: "%-8s %-12s %s", typeLabel, size, itemURL.lastPathComponent))
                }
            }
        }
    }

    struct CopyCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "copy", abstract: "Copy a file or directory")
        @Argument(help: "Source path") var src: String
        @Argument(help: "Destination path") var dst: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let srcURL = URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
            let dstURL = URL(fileURLWithPath: (dst as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: srcURL.path) else {
                throw ValidationError("Source not found: \(src)")
            }
            var isDir: ObjCBool = false
            let finalDst: URL
            if FileManager.default.fileExists(atPath: dstURL.path, isDirectory: &isDir), isDir.boolValue {
                finalDst = dstURL.appendingPathComponent(srcURL.lastPathComponent)
            } else {
                finalDst = dstURL
            }
            try FileManager.default.copyItem(at: srcURL, to: finalDst)
            if json {
                print("{\"copied\": true, \"src\": \"\(srcURL.path)\", \"dst\": \"\(finalDst.path)\"}")
            } else {
                print("Copied: \(srcURL.path) → \(finalDst.path)")
            }
        }
    }

    struct MoveCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "move", abstract: "Move or rename a file or directory")
        @Argument(help: "Source path") var src: String
        @Argument(help: "Destination path") var dst: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let srcURL = URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
            let dstURL = URL(fileURLWithPath: (dst as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: srcURL.path) else {
                throw ValidationError("Source not found: \(src)")
            }
            var isDir: ObjCBool = false
            let finalDst: URL
            if FileManager.default.fileExists(atPath: dstURL.path, isDirectory: &isDir), isDir.boolValue {
                finalDst = dstURL.appendingPathComponent(srcURL.lastPathComponent)
            } else {
                finalDst = dstURL
            }
            try FileManager.default.moveItem(at: srcURL, to: finalDst)
            if json {
                print("{\"moved\": true, \"src\": \"\(srcURL.path)\", \"dst\": \"\(finalDst.path)\"}")
            } else {
                print("Moved: \(srcURL.path) → \(finalDst.path)")
            }
        }
    }

    struct DeleteCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "delete", abstract: "Permanently delete a file or directory (use 'trash add' for recoverable delete)")
        @Argument(help: "Path to delete") var path: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("Path not found: \(path)")
            }
            try FileManager.default.removeItem(at: url)
            if json {
                print("{\"deleted\": true, \"path\": \"\(url.path)\"}")
            } else {
                print("Deleted: \(url.path)")
            }
        }
    }

    struct StatCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stat", abstract: "Show file metadata")
        @Argument(help: "File or directory path") var path: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ValidationError("Path not found: \(path)")
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: expanded)
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let size = attrs[.size] as? Int ?? 0
            let created = (attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let permissions = attrs[.posixPermissions] as? Int ?? 0
            let owner = attrs[.ownerAccountName] as? String ?? ""

            if json {
                let result: [String: Any] = [
                    "path": url.path,
                    "name": url.lastPathComponent,
                    "is_directory": isDir,
                    "size": size,
                    "permissions": String(format: "%o", permissions),
                    "owner": owner,
                    "created": created,
                    "modified": modified,
                ]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8)!)
            } else {
                print("Path:        \(url.path)")
                print("Type:        \(isDir ? "directory" : "file")")
                print("Size:        \(fileFormatBytes(size))")
                print("Permissions: \(String(format: "%o", permissions))")
                print("Owner:       \(owner)")
                print("Created:     \(Date(timeIntervalSince1970: created))")
                print("Modified:    \(Date(timeIntervalSince1970: modified))")
            }
        }
    }

    struct ReadCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "read", abstract: "Print text file contents")
        @Argument(help: "File path") var path: String
        @Option(name: .long, help: "Max bytes to read (default: 102400)") var maxBytes: Int = 102_400

        func run() throws {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("File not found: \(path)")
            }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data.prefix(maxBytes), encoding: .utf8) else {
                throw ValidationError("File is not valid UTF-8 text: \(path)")
            }
            print(text)
            if data.count > maxBytes {
                fputs("[truncated: \(data.count - maxBytes) bytes remaining — use --max-bytes to read more]\n", stderr)
            }
        }
    }
}

private func fileFormatBytes(_ bytes: Int) -> String {
    let kb = Double(bytes) / 1024
    if kb < 1 { return "\(bytes)B" }
    let mb = kb / 1024
    if mb < 1 { return String(format: "%.1fK", kb) }
    let gb = mb / 1024
    if gb < 1 { return String(format: "%.1fM", mb) }
    return String(format: "%.1fG", gb)
}
