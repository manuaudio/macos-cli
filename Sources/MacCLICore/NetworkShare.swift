import Foundation

/// A network share as `disk mount smb://user@host/share` names it, and as the mount
/// table (`f_mntfromname`, e.g. `//manu@ManuStorage._smb._tcp.local/Arimaka`) shows it.
public struct NetworkShare: Equatable {
    public let user: String?
    public let host: String
    public let share: String

    public init(user: String?, host: String, share: String) {
        self.user = user
        self.host = host
        self.share = share
    }

    /// Parse `smb://[user@]host/share` (also `afp://`, `nfs://`). Nil without a host or share,
    /// and nil when the URL carries a password: a password never travels on argv.
    public static func parse(url: String) -> NetworkShare? {
        guard let comps = URLComponents(string: url),
              let scheme = comps.scheme?.lowercased(), ["smb", "afp", "nfs", "cifs"].contains(scheme),
              comps.password == nil,
              let host = comps.host, !host.isEmpty else { return nil }
        let share = comps.path.split(separator: "/").first.map(String.init) ?? ""
        guard !share.isEmpty else { return nil }
        return NetworkShare(user: comps.user, host: host, share: share)
    }

    /// Parse a mount table source, `//[user@]host/share`.
    public static func parse(mountedFrom from: String) -> NetworkShare? {
        guard from.hasPrefix("//") else { return nil }
        return parse(url: "smb:" + from)
    }

    /// The same share: share names equal, the user equal when both name one, and the host
    /// equal once its Bonjour or `.local` suffix is gone (Finder mounts the NAS as
    /// `ManuStorage._smb._tcp.local`, a script names it `ManuStorage.local`).
    public func isSameShare(as other: NetworkShare) -> Bool {
        guard share.lowercased() == other.share.lowercased() else { return false }
        if let a = user, let b = other.user, a.lowercased() != b.lowercased() { return false }
        return Self.bareHost(host) == Self.bareHost(other.host)
    }

    static func bareHost(_ host: String) -> String {
        var h = host.lowercased()
        for suffix in ["._smb._tcp.local", "._afpovertcp._tcp.local", ".local"] where h.hasSuffix(suffix) {
            h = String(h.dropLast(suffix.count))
            break
        }
        return h
    }
}
