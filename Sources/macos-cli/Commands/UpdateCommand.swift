import ArgumentParser
import CryptoKit
import Foundation
import MacCLICore

/// `macos update`: the newest signed Release replaces this binary at the same path, so the
/// permissions macOS granted to it stay with it (docs/SIGNING.md). Nothing is replaced
/// until the download's hash, signature, Gatekeeper verdict, identity and version check out.
struct UpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Replace this binary with the newest signed Release, in place"
    )

    @Flag(name: .long, help: "Only report whether a newer Release exists") var check = false
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let source = ProcessInfo.processInfo.environment["MACOS_CLI_RELEASES_URL"] ?? Release.latestURL
        guard let url = URL(string: source),
              let release = Release.parse(try fetch(url, what: "the newest Release")) else {
            throw CLIFailure.appError("The Releases page did not describe a Release.", hint: "Try again later.")
        }
        let newer = Release.isNewer(release.version, than: macosCLIVersion)
        var report: [String: Any] = ["current": macosCLIVersion, "latest": release.version,
                                     "update_available": newer, "updated": false]
        guard newer, !check else {
            return say(report, newer ? "macos \(release.version) is available (this is \(macosCLIVersion)); run `macos update`."
                                     : "macos \(macosCLIVersion) is up to date.")
        }

        let target = Bundle.main.executableURL!.resolvingSymlinksInPath()
        if target.path.contains("/Cellar/") {
            throw CLIFailure.appError("This copy was installed by Homebrew.", hint: "Run `brew upgrade macos-cli`.")
        }
        guard let zipURL = release.assets[Release.zipName(version: release.version)].flatMap(URL.init(string:)),
              let shaURL = release.assets[Release.shaName(version: release.version)].flatMap(URL.init(string:)) else {
            throw CLIFailure.notFound("Release \(release.version) has no \(Release.zipName(version: release.version)).")
        }
        let zip = try fetch(zipURL, what: "the binary")
        let expected = Release.expectedSHA256(String(decoding: try fetch(shaURL, what: "its sha256"), as: UTF8.self))
        let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard expected == actual else {
            throw CLIFailure(code: "verification_failed",
                             message: "The download's sha256 does not match the Release; nothing was replaced.",
                             extra: ["expected": expected ?? "", "actual": actual])
        }

        // Unpacked next to the target, so the swap is one rename on the same volume.
        let work = target.deletingLastPathComponent().appendingPathComponent(".macos-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("release.zip")
        try zip.write(to: archive)
        guard Process.captureWithStderr(args: ["/usr/bin/ditto", "-x", "-k", archive.path, work.path], timeout: 60).exitCode == 0 else {
            throw CLIFailure.appError("Could not unpack the download; nothing was replaced.")
        }
        let fresh = work.appendingPathComponent("macos")
        try verify(fresh, version: release.version)
        guard rename(fresh.path, target.path) == 0 else {
            throw CLIFailure.appError("Could not replace \(target.path): \(String(cString: strerror(errno))).",
                                      hint: "Check that you can write to \(target.deletingLastPathComponent().path).")
        }
        report["updated"] = true
        report["path"] = target.path
        say(report, "Updated \(target.path) from \(macosCLIVersion) to \(release.version).")
    }

    private func say(_ report: [String: Any], _ line: String) {
        if json { printJSON(report) } else { print(line) }
    }

    /// The same checks install.sh makes: a strict signature, Gatekeeper's verdict, our
    /// identifier and team, and the version the Release names.
    private func verify(_ binary: URL, version: String) throws {
        func refuse(_ why: String) -> CLIFailure {
            CLIFailure(code: "verification_failed", message: "The downloaded binary \(why); nothing was replaced.")
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw refuse("is missing from the zip") }
        guard Process.captureWithStderr(args: ["/usr/bin/codesign", "--verify", "--strict", binary.path], timeout: 30).exitCode == 0 else {
            throw refuse("has no valid signature")
        }
        guard Process.captureWithStderr(args: ["/usr/sbin/spctl", "--assess", "--type", "execute", binary.path], timeout: 60).exitCode == 0 else {
            throw refuse("is not accepted by Gatekeeper")
        }
        let details = Process.captureWithStderr(args: ["/usr/bin/codesign", "-dv", binary.path], timeout: 30).stderr
        guard details.contains("Identifier=\(Release.bundleIdentifier)\n"),
              details.contains("TeamIdentifier=\(Release.teamIdentifier)\n") else {
            throw refuse("is not signed as \(Release.bundleIdentifier) by team \(Release.teamIdentifier)")
        }
        let reported = Process.captureWithStderr(args: [binary.path, "--version"], timeout: 30).stdout
        guard reported.trimmingCharacters(in: .whitespacesAndNewlines) == version else {
            throw refuse("reports version \(reported.trimmingCharacters(in: .whitespacesAndNewlines)), not \(version)")
        }
    }

    private func fetch(_ url: URL, what: String) throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("macos-cli/\(macosCLIVersion)", forHTTPHeaderField: "User-Agent")
        var result: Result<Data, CLIFailure> = .failure(.timeout("Fetching \(what) timed out."))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                result = .failure(status == 404 ? .notFound("No \(what) at \(url.absoluteString).")
                                                : .appError("Fetching \(what) returned HTTP \(status)."))
            } else if (error as? URLError)?.code == .fileDoesNotExist {
                result = .failure(.notFound("No \(what) at \(url.absoluteString)."))
            } else if let data = data, error == nil {
                result = .success(data)
            } else {
                result = .failure(.appError("Could not fetch \(what): \(error?.localizedDescription ?? "no data").",
                                            hint: "Check the network and try again."))
            }
        }.resume()
        if done.wait(timeout: .now() + 90) == .timedOut { throw CLIFailure.timeout("Fetching \(what) timed out.") }
        return try result.get()
    }
}
