import ArgumentParser
import Foundation

struct MusicCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "music",
        abstract: "Control Apple Music playback",
        subcommands: [Status.self, Play.self, Pause.self, Next.self, Previous.self, Volume.self, Search.self, Playlists.self, AddToPlaylist.self, Queue.self]
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
            try Auth.check("music.write")
            guard jxa("Application('Music').play(); 'ok'") != nil else { throw ExitCode.failure }
            print("Playing")
        }
    }

    struct Pause: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "pause", abstract: "Pause playback")
        func run() throws {
            try Auth.check("music.write")
            guard jxa("Application('Music').pause(); 'ok'") != nil else { throw ExitCode.failure }
            print("Paused")
        }
    }

    struct Next: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "next", abstract: "Skip to next track")
        func run() throws {
            try Auth.check("music.write")
            guard jxa("Application('Music').nextTrack(); 'ok'") != nil else { throw ExitCode.failure }
            print("Skipped to next track")
        }
    }

    struct Previous: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "prev", abstract: "Go to previous track")
        func run() throws {
            try Auth.check("music.write")
            guard jxa("Application('Music').previousTrack(); 'ok'") != nil else { throw ExitCode.failure }
            print("Went to previous track")
        }
    }

    struct Volume: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "volume", abstract: "Get or set volume (0–100)")
        @Argument(help: "Volume level 0–100 (omit to read current)") var level: Int?

        func run() throws {
            if let v = level {
                try Auth.check("music.write")
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
            try Auth.check("music.write")
            let q = jxaEscape(query).lowercased()
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
    // MARK: - Playlists

    struct Playlists: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "playlists", abstract: "List playlists")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let script = """
            (function() {
              var music = Application("Music");
              var lists = music.playlists().map(function(p) {
                try { return {name: p.name(), count: p.tracks().length}; }
                catch(e) { return null; }
              }).filter(Boolean);
              return JSON.stringify(lists);
            })()
            """
            guard let raw = jxa(script) else {
                fputs("Error: Could not reach Music app\n", stderr)
                throw ExitCode.failure
            }
            if json {
                print(raw)
            } else {
                guard let data = raw.data(using: .utf8),
                      let lists = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    print(raw); return
                }
                for p in lists {
                    let name  = p["name"]  as? String ?? ""
                    let count = p["count"] as? Int ?? 0
                    print("\(name)  (\(count) tracks)")
                }
                print("\(lists.count) playlist(s)")
            }
        }
    }

    // MARK: - AddToPlaylist

    struct AddToPlaylist: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add-to-playlist", abstract: "Add a track to a playlist")

        @Option(name: .long, help: "Track name to add (searches library, takes first match)")
        var track: String

        @Option(name: .long, help: "Playlist name")
        var playlist: String

        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("music.write")
            let qTrack    = jxaEscape(track).lowercased()
            let qPlaylist = jxaEscape(playlist).lowercased()
            let script = """
            (function() {
              var music = Application("Music");
              var qt = '\(qTrack)';
              var qp = '\(qPlaylist)';
              var found = music.tracks().find(function(t) {
                try { return t.name().toLowerCase().includes(qt) || t.artist().toLowerCase().includes(qt); }
                catch(e) { return false; }
              });
              if (!found) { return JSON.stringify({error: 'no-track'}); }
              var pl = music.playlists().find(function(p) {
                try { return p.name().toLowerCase().includes(qp); }
                catch(e) { return false; }
              });
              if (!pl) { return JSON.stringify({error: 'no-playlist'}); }
              music.add([found], {to: pl});
              return JSON.stringify({added: true, track: found.name(), playlist: pl.name()});
            })()
            """
            guard let raw = jxa(script) else {
                fputs("Error: Could not reach Music app\n", stderr)
                throw ExitCode.failure
            }
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fputs("Error: Unexpected response\n", stderr); throw ExitCode.failure
            }
            if let err = obj["error"] as? String {
                if err == "no-track" { throw ValidationError("No track found matching '\(track)'") }
                else { throw ValidationError("No playlist found matching '\(playlist)'") }
            }
            if json {
                print(raw)
            } else {
                let trackName = obj["track"] as? String ?? track
                let plName    = obj["playlist"] as? String ?? playlist
                print("Added '\(trackName)' to playlist '\(plName)'")
            }
        }
    }

    // MARK: - Queue

    struct Queue: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "queue", abstract: "Show upcoming tracks from current playlist")

        @Option(name: .long, help: "Max tracks to show (default: 10)") var limit: Int = 10
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let script = """
            (function() {
              var music = Application("Music");
              var pos = Math.round(music.playerPosition());
              var current;
              try { current = music.currentTrack().name(); } catch(e) { current = null; }
              var pl;
              try { pl = music.currentPlaylist(); } catch(e) { return JSON.stringify([]); }
              var tracks = pl.tracks();
              // find current index by matching name
              var startIdx = 0;
              if (current) {
                for (var i = 0; i < tracks.length; i++) {
                  try { if (tracks[i].name() === current) { startIdx = i + 1; break; } } catch(e) {}
                }
              }
              var upcoming = tracks.slice(startIdx, startIdx + \(limit)).map(function(t) {
                try { return {title: t.name(), artist: t.artist(), album: t.album()}; }
                catch(e) { return null; }
              }).filter(Boolean);
              return JSON.stringify(upcoming);
            })()
            """
            guard let raw = jxa(script) else {
                fputs("Error: Could not reach Music app\n", stderr)
                throw ExitCode.failure
            }
            if json {
                print(raw)
            } else {
                guard let data = raw.data(using: .utf8),
                      let tracks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    print(raw); return
                }
                if tracks.isEmpty {
                    print("Queue is empty or no playlist playing")
                } else {
                    for (i, t) in tracks.enumerated() {
                        let title  = t["title"]  as? String ?? "—"
                        let artist = t["artist"] as? String ?? "—"
                        let album  = t["album"]  as? String ?? "—"
                        print("\(i + 1). \(title) — \(artist)  [\(album)]")
                    }
                }
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
    // Only filter on definitive permission-denial prefix, not generic "error" substring
    // (which would false-positive on track titles, album names, etc. containing "error").
    guard !r.isEmpty,
          !r.lowercased().hasPrefix("not allowed") else { return nil }
    return r
}
