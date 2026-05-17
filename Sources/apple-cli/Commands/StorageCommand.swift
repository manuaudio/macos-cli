import ArgumentParser
import Foundation

struct StorageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "storage",
        abstract: "Disk and storage information",
        subcommands: [VolumesCmd.self, DiskUsageCmd.self]
    )

    struct VolumesCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "volumes", abstract: "List mounted volumes")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let fm = FileManager.default
            let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: [
                .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                .volumeIsRemovableKey, .volumeIsInternalKey,
            ], options: [.skipHiddenVolumes]) ?? []

            if json {
                let out = vols.compactMap { url -> [String: Any]? in
                    guard let vals = try? url.resourceValues(forKeys: [
                        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                        .volumeIsRemovableKey, .volumeIsInternalKey,
                    ]) else { return nil }
                    return [
                        "path": url.path,
                        "name": vals.volumeName ?? "",
                        "total_gb": Double(vals.volumeTotalCapacity ?? 0) / 1_073_741_824,
                        "free_gb": Double(vals.volumeAvailableCapacity ?? 0) / 1_073_741_824,
                        "removable": vals.volumeIsRemovable ?? false,
                        "internal": vals.volumeIsInternal ?? false,
                    ]
                }
                printJSON(out)
            } else {
                for url in vols {
                    if let vals = try? url.resourceValues(forKeys: [
                        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey
                    ]) {
                        let total = Double(vals.volumeTotalCapacity ?? 0) / 1_073_741_824
                        let free  = Double(vals.volumeAvailableCapacity ?? 0) / 1_073_741_824
                        let name  = (vals.volumeName ?? url.lastPathComponent)
                                    .padding(toLength: 28, withPad: " ", startingAt: 0)
                        print("\(name)  \(String(format: "%.1f", free)) GB free / \(String(format: "%.1f", total)) GB total")
                    }
                }
            }
        }
    }

    struct DiskUsageCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "usage", abstract: "Disk usage of a path")

        @Argument(help: "Path to measure (default: home directory)") var path: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let target = path ?? FileManager.default.homeDirectoryForCurrentUser.path
            let result = Process.capture(args: ["/usr/bin/du", "-sh", target])
            let parts = result.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\t")
            let size = parts.count > 0 ? parts[0] : "?"
            if json {
                printJSON(["path": target, "size": size])
            } else {
                print("\(size)\t\(target)")
            }
        }
    }
}
