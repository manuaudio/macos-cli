import ArgumentParser
import Foundation

struct SpotlightCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spotlight",
        abstract: "Search the filesystem via Spotlight (mdfind)",
        subcommands: [SearchCmd.self]
    )

    struct SearchCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "search", abstract: "Search files and folders via Spotlight")
        @Argument(help: "Search query") var query: String
        @Flag(name: .long, help: "Match filename only (faster)") var nameOnly = false
        @Option(name: .long, help: "Filter by kind: app, image, pdf, audio, video, document, folder") var kind: String?
        @Option(name: .long, help: "Limit results (default 50)") var limit: Int = 50
        @Option(name: .long, help: "Search within this directory only") var inDir: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            var args = ["/usr/bin/mdfind"]

            if let kindFilter = kind {
                let kindMap: [String: String] = [
                    "app": "kMDItemContentTypeTree == 'com.apple.application'cd",
                    "image": "kMDItemContentTypeTree == 'public.image'cd",
                    "pdf": "kMDItemContentType == 'com.adobe.pdf'",
                    "audio": "kMDItemContentTypeTree == 'public.audio'cd",
                    "video": "kMDItemContentTypeTree == 'public.movie'cd",
                    "document": "kMDItemContentTypeTree == 'public.text'cd",
                    "folder": "kMDItemContentType == 'public.folder'",
                ]
                if let predicate = kindMap[kindFilter] {
                    let nameClause = nameOnly
                        ? "kMDItemFSName == '*\(query)*'cd"
                        : "kMDItemTextContent == '*\(query)*'cd || kMDItemFSName == '*\(query)*'cd"
                    args.append("\(predicate) && (\(nameClause))")
                } else {
                    throw ValidationError("Unknown kind '\(kindFilter)'. Use: app, image, pdf, audio, video, document, folder")
                }
            } else if nameOnly {
                args += ["-name", query]
            } else {
                args.append(query)
            }

            if let dir = inDir {
                let expanded = (dir as NSString).expandingTildeInPath
                args += ["-onlyin", expanded]
            }

            guard let output = Process.capture(args: args, timeout: 15) else {
                throw ValidationError("Spotlight search timed out after 15s.")
            }

            let allPaths = output
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let paths = Array(allPaths.prefix(limit))

            if json {
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                let items: [[String: Any]] = paths.map { path in
                    let url = URL(fileURLWithPath: path)
                    let resources = try? url.resourceValues(forKeys: keys)
                    return [
                        "path": path,
                        "name": url.lastPathComponent,
                        "is_directory": resources?.isDirectory ?? false,
                        "size": resources?.fileSize ?? 0,
                        "modified": resources?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    ]
                }
                let wrapper: [String: Any] = [
                    "count": paths.count,
                    "total_matches": allPaths.count,
                    "results": items,
                ]
                let data = try JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted])
                print(String(data: data, encoding: .utf8)!)
            } else {
                if paths.isEmpty { print("No results for: \(query)"); return }
                print("Found \(allPaths.count) matches (showing \(paths.count)):")
                paths.forEach { print($0) }
            }
        }
    }
}
