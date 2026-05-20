import ArgumentParser
import Foundation

struct DiskCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disk",
        abstract: "Mount, unmount, and inspect disks and volumes",
        subcommands: [List.self, Info.self, Eject.self, Unmount.self, Mount.self]
    )

    // MARK: - List
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all disks and partitions")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            guard let plist = Process.capture(args: ["/usr/sbin/diskutil", "list", "-plist"], timeout: 10),
                  let data = plist.data(using: .utf8),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let allDisks = obj["AllDisksAndPartitions"] as? [[String: Any]] else {
                throw ValidationError("diskutil list failed or timed out")
            }

            if json {
                let result = allDisks.map { disk -> [String: Any] in
                    var d: [String: Any] = [:]
                    if let id   = disk["DeviceIdentifier"] as? String { d["device"]    = "/dev/" + id }
                    if let size = disk["Size"]             as? Int    { d["size_bytes"] = size }
                    if let parts = disk["Partitions"] as? [[String: Any]] {
                        d["partitions"] = parts.map { p -> [String: Any] in
                            var out: [String: Any] = [:]
                            if let pid   = p["DeviceIdentifier"] as? String { out["device"]     = "/dev/" + pid }
                            if let name  = p["VolumeName"]       as? String { out["name"]        = name }
                            if let mnt   = p["MountPoint"]       as? String { out["mount_point"] = mnt }
                            if let size  = p["Size"]             as? Int    { out["size_bytes"]  = size }
                            if let type  = p["Content"]          as? String { out["type"]        = type }
                            return out
                        }
                    }
                    return d
                }
                printJSON(result)
            } else {
                let raw = Process.capture(args: ["/usr/sbin/diskutil", "list"], timeout: 15, fallback: "")
                print(raw)
            }
        }
    }

    // MARK: - Info
    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show detailed info for a disk or volume")

        @Argument(help: "Device path (/dev/disk2) or volume mount point (/Volumes/Name)")
        var path: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            guard let plist = Process.capture(args: ["/usr/sbin/diskutil", "info", "-plist", path], timeout: 10),
                  let data = plist.data(using: .utf8),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw ValidationError("diskutil info failed for: \(path)")
            }

            if json {
                var out: [String: Any] = [:]
                let keys: [(String, String)] = [
                    ("DeviceIdentifier", "device"),
                    ("DeviceNode", "device_node"),
                    ("VolumeName", "name"),
                    ("MountPoint", "mount_point"),
                    ("FilesystemType", "filesystem"),
                    ("TotalSize", "size_bytes"),
                    ("FreeSpace", "free_bytes"),
                    ("Ejectable", "ejectable"),
                    ("Removable", "removable"),
                    ("Internal", "internal"),
                    ("Writable", "writable"),
                ]
                for (src, dst) in keys {
                    if let v = obj[src] { out[dst] = v }
                }
                printJSON(out)
            } else {
                let raw = Process.capture(args: ["/usr/sbin/diskutil", "info", path], timeout: 15, fallback: "")
                print(raw)
            }
        }
    }

    // MARK: - Eject
    struct Eject: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Eject a disk or volume")

        @Argument(help: "Device path (/dev/disk2) or volume mount point (/Volumes/Name)")
        var path: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("disk.write")
            let code = Process.run(args: ["/usr/sbin/diskutil", "eject", path])
            if json {
                printJSON(["ejected": code == 0, "path": path])
            } else if code == 0 {
                print("Ejected: \(path)")
            } else {
                throw ValidationError("Eject failed for: \(path) (exit \(code))")
            }
        }
    }

    // MARK: - Unmount
    struct Unmount: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unmount a volume (without ejecting the disk)")

        @Argument(help: "Device path or mount point")
        var path: String

        @Flag(name: .long, help: "Force unmount even if busy")
        var force = false

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("disk.write")
            var args = ["/usr/sbin/diskutil", "unmount"]
            if force { args.append("force") }
            args.append(path)
            let code = Process.run(args: args)
            if json {
                printJSON(["unmounted": code == 0, "path": path])
            } else if code == 0 {
                print("Unmounted: \(path)")
            } else {
                throw ValidationError("Unmount failed for: \(path)")
            }
        }
    }

    // MARK: - Mount
    struct Mount: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Mount a disk image or volume")

        @Argument(help: "Device path (/dev/disk2s1) or .dmg file path")
        var path: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("disk.write")
            let expanded = (path as NSString).expandingTildeInPath
            let isDmg = expanded.hasSuffix(".dmg") || expanded.hasSuffix(".iso")
            let args: [String]
            if isDmg {
                args = ["/usr/bin/hdiutil", "attach", expanded]
            } else {
                args = ["/usr/sbin/diskutil", "mount", path]
            }
            let code = Process.run(args: args)
            if json {
                printJSON(["mounted": code == 0, "path": path])
            } else if code == 0 {
                print("Mounted: \(path)")
            } else {
                throw ValidationError("Mount failed for: \(path)")
            }
        }
    }
}
