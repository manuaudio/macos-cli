import Foundation

/// What `macos update` and `install.sh` agree on about a published Release: the asset
/// names, the identity a downloaded binary must carry, and how two versions compare.
public enum Release {
    public static let latestURL = "https://api.github.com/repos/manuaudio/macos-cli/releases/latest"
    public static let bundleIdentifier = "com.manuaudio.macos-cli"
    public static let teamIdentifier = "4M72M3J3UN"

    public static func zipName(version: String) -> String { "macos-cli-\(version)-arm64.zip" }
    public static func shaName(version: String) -> String { zipName(version: version) + ".sha256" }

    /// `v0.9.0` and `0.9.0` are the same version.
    public static func version(fromTag tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// True when `candidate` is a later version than `current` (numeric, part by part).
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (text: String) in text.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The newest Release as GitHub's API returns it: its version and the download URL of
    /// each asset by name. Nil when the body is not a Release.
    public static func parse(_ data: Data) -> (version: String, assets: [String: String])? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = body["tag_name"] as? String else { return nil }
        var assets: [String: String] = [:]
        for asset in body["assets"] as? [[String: Any]] ?? [] {
            if let name = asset["name"] as? String, let url = asset["browser_download_url"] as? String {
                assets[name] = url
            }
        }
        return (version(fromTag: tag), assets)
    }

    /// The hash a `.sha256` asset names (`<hex>  <file>`), lowercased.
    public static func expectedSHA256(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first,
              first.count == 64, first.allSatisfy(\.isHexDigit) else { return nil }
        return first.lowercased()
    }
}
