import ArgumentParser
import Foundation
import MacCLICore
import NetFS

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
            try Auth.check("disk.read")
            guard let plist = Process.capture(args: ["/usr/sbin/diskutil", "list", "-plist"], timeout: 10),
                  let data = plist.data(using: .utf8),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let allDisks = obj["AllDisksAndPartitions"] as? [[String: Any]] else {
                throw CLIFailure.timeout("diskutil list failed or timed out")
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
            try Auth.check("disk.read")
            guard let plist = Process.capture(args: ["/usr/sbin/diskutil", "info", "-plist", path], timeout: 10),
                  let data = plist.data(using: .utf8),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CLIFailure.appError("diskutil info failed for: \(path)")
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
                throw CLIFailure.appError("Eject failed for: \(path) (exit \(code))")
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
                throw CLIFailure.appError("Unmount failed for: \(path)")
            }
        }
    }

    // MARK: - Mount
    struct Mount: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Mount a disk image, a volume, or a network share (smb://user@host/share)",
            discussion: """
            A network share mounts through NetFS under /Volumes, no root needed. The password \
            comes from the login keychain item Finder saved for the server, or from the \
            environment variable --password-env names; never from the command line. A share \
            already mounted is reported where it is, not mounted twice.
            """
        )

        @Argument(help: "Device path (/dev/disk2s1), .dmg file path, or smb://user@host/share")
        var path: String

        @Option(name: .long, help: "Environment variable holding the share's password")
        var passwordEnv: String?

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            if path.contains("://") {
                try Auth.check("disk.mount")
                try mountShare()
                return
            }
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
                throw CLIFailure.appError("Mount failed for: \(path)")
            }
        }

        private func mountShare() throws {
            guard let share = NetworkShare.parse(url: path), let url = URL(string: path) else {
                throw ValidationError(URLComponents(string: path)?.password != nil
                    ? "A share URL never carries the password: use the keychain item or --password-env."
                    : "Not a share URL (smb://user@host/share): \(path)")
            }
            if let mountPoint = Self.mountPoint(of: share) {
                report(mountPoint: mountPoint, already: true)
                return
            }
            var password: String?
            if let name = passwordEnv {
                guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
                    throw ValidationError("--password-env \(name): the variable is not set")
                }
                password = value
            }
            // No dialog ever: without --password-env NetFS takes the keychain item for the server.
            let openOptions = NSMutableDictionary(dictionary: ["UIOption": "NoUI"])
            var mountPoints: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(url as CFURL, nil, share.user as CFString?, password as CFString?,
                                           openOptions, nil, &mountPoints)
            let points = (mountPoints?.takeRetainedValue() as? [String]) ?? []
            guard status == 0, let mountPoint = points.first ?? Self.mountPoint(of: share) else {
                throw CLIFailure.appError("Could not mount \(path): \(Self.describe(status))")
            }
            report(mountPoint: mountPoint, already: false)
        }

        private func report(mountPoint: String, already: Bool) {
            if json {
                printJSON(["mounted": true, "already": already, "mount_point": mountPoint, "url": path])
            } else {
                print(already ? "Already mounted: \(path) at \(mountPoint)" : "Mounted: \(path) at \(mountPoint)")
            }
        }

        /// Where the share is mounted now, from the kernel's mount table.
        static func mountPoint(of share: NetworkShare) -> String? {
            var buf: UnsafeMutablePointer<statfs>?
            let count = getmntinfo(&buf, MNT_NOWAIT)
            guard count > 0, let mounts = buf else { return nil }
            for i in 0..<Int(count) {
                var entry = mounts[i]
                let from = withUnsafePointer(to: &entry.f_mntfromname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                let on = withUnsafePointer(to: &entry.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                if let mounted = NetworkShare.parse(mountedFrom: from.removingPercentEncoding ?? from),
                   share.isSameShare(as: mounted) {
                    return on
                }
            }
            return nil
        }

        static func describe(_ status: Int32) -> String {
            switch status {
            case EAUTH, EACCES, EPERM: return "the server refused the user or password (\(status))"
            case ENOENT: return "no such share on the server (\(status))"
            case EHOSTUNREACH, ETIMEDOUT, ECONNREFUSED: return "the server is unreachable (\(status))"
            case -128: return "authentication needed: no keychain item for the server and no --password-env"
            default: return String(cString: strerror(status)) + " (\(status))"
            }
        }
    }
}
