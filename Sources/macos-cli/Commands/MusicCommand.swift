import ArgumentParser
import Foundation

struct MusicCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "music",
        abstract: "Control Apple Music playback",
        subcommands: [Status.self, Play.self, Pause.self, Next.self, Previous.self, Volume.self, Search.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Show current track and playback state")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let script = """
            var music = Application("Music");
            var state = music.playerState();
            var result = {state: state.toString()};
            try {
              var t = music.currentTrack();
              result.track = t.name();
              result.artist = t.artist();
              result.album = t.album();
              result.duration = Math.round(t.duration());
              result.position = Math.round(music.playerPosition());
              result.volume = music.soundVolume();
            } catch(e) {}
            JSON.stringify(result);
            """
            guard let raw = jxa(script) else {
                fputs("Error: Could not reach Music app\n", stderr)
                throw ExitCode.failure
            }
            if json {
                print(raw)
            } else {
                guard let data = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    print(raw); return
                }
                let state  = obj["state"] as? String ?? "unknown"
                let track  = obj["track"] as? String ?? "—"
                let artist = obj["artist"] as? String ?? "—"
                let album  = obj["album"] as? String ?? "—"
                let pos    = obj["position"] as? Int ?? 0
                let dur    = obj["duration"] as? Int ?? 0
                let vol    = obj["volume"] as? Int ?? 0
                print("State:   \(state)")
                print("Track:   \(track)")
                print("Artist:  \(artist)")
                print("Album:   \(album)")
                print("Time:    \(formatTime(pos)) / \(formatTime(dur))")
                print("Volume:  \(vol)%")
            }
        }

        private func formatTime(_ s: Int) -> String {
            "\(s / 60):\(String(format: "%02d", s % 60))"
        }
    }

    struct Play: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "play", abstract: "Play or resume")
        func run() throws {
            guard jxa("Application('Music').play(); 'ok'") != nil else { throw ExitCode.failure }
            print("Playing")
        }
    }

    struct Pause: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "pause", abstract: "Pause playback")
        func run() throws {
            guard jxa("Application('Music').pause(); 'ok'") != nil else { throw ExitCode.failure }
            print("Paused")
        }
    }

    struct Next: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "next", abstract: "Skip to next track")
        func run() throws {
            guard jxa("Application('Music').nextTrack(); 'ok'") != nil else { throw ExitCode.failure }
            print("Skipped to next track")
        }
    }

    struct Previous: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "prev", abstract: "Go to previous track")
        func run() throws {
            guard jxa("Application('Music').previousTrack(); 'ok'") != nil else { throw ExitCode.failure }
            print("Went to previous track")
        }
    }

    struct Volume: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "volume", abstract: "Get or set volume (0–100)")
        @Argument(help: "Volume level 0–100 (omit to read current)") var level: Int?

        func run() throws {
            if let v = level {
                let clamped = max(0, min(100, v))
                guard jxa("Application('Music').soundVolume = \(clamped); 'ok'") != nil else { throw ExitCode.failure }
                print("Volume set to \(clamped)%")
            } else {
                guard let raw = jxa("Application('Music').soundVolume()") else { throw ExitCode.failure }
                print("Volume: \(raw.trimmingCharacters(in: .whitespacesAndNewlines))%")
            }
        }
    }

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "search", abstract: "Search library and play first result")
        @Argument(help: "Search query") var query: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let q = query.replacingOccurrences(of: "'", with: "\\'").lowercased()
            let script = """
            (function() {
              var music = Application("Music");
              var q = '\(q)';
              var tracks = music.tracks();
              var matches = tracks.filter(function(t) {
                try { return t.name().toLowerCase().includes(q) || t.artist().toLowerCase().includes(q); }
                catch(e) { return false; }
              });
              if (matches.length === 0) { return "not found"; }
              music.play(matches[0]);
              return JSON.stringify({track: matches[0].name(), artist: matches[0].artist()});
            })()
            """
            guard let raw = jxa(script) else { throw ExitCode.failure }
            if raw.contains("not found") {
                if json { printJSON(["results": [] as [Any]]) } else { print("No results for '\(query)'") }
            } else if json {
                print(raw)  // already JSON from JSON.stringify
            } else if let data = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let track = obj["track"] as? String ?? query
                let artist = obj["artist"] as? String ?? ""
                print("Playing: \(track) — \(artist)")
            } else {
                print("Playing: \(raw)")
            }
        }
    }
}

private func jxa(_ expr: String) -> String? {
    guard let raw = Process.capture(
        args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", expr],
        timeout: 8
    ) else { return nil }
    let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !r.isEmpty,
          !r.lowercased().contains("not allowed"),
          !r.lowercased().contains("error") else { return nil }
    return r
}
