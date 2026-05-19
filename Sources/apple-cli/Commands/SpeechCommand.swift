import ArgumentParser
import Foundation

struct SpeechCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speech",
        abstract: "Text-to-speech via macOS voices",
        subcommands: [SayCmd.self, VoicesCmd.self]
    )

    struct SayCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "say", abstract: "Speak text aloud")

        @Argument(help: "Text to speak") var text: String
        @Option(name: .long, help: "Voice name (e.g. 'Samantha', 'Karen', 'Alex')") var voice: String?
        @Option(name: .long, help: "Speaking rate words-per-minute (default: 175)") var rate: Int?
        @Option(name: .long, help: "Output audio file path (e.g. /tmp/speech.aiff)") var output: String?

        func run() throws {
            var args = ["/usr/bin/say"]
            if let v = voice { args += ["-v", v] }
            if let r = rate { args += ["-r", String(r)] }
            if let o = output { args += ["-o", o] }
            args.append(text)
            let result = Process.run(args: args)
            if result != 0 { throw ValidationError("say command failed") }
            if let o = output {
                print("Audio saved to: \(o)")
            } else {
                print("Spoken: \(text.prefix(50))\(text.count > 50 ? "..." : "")")
            }
        }
    }

    struct VoicesCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "voices", abstract: "List available voices")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let result = Process.capture(args: ["/usr/bin/say", "-v", "?"])
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
            if json {
                // `say -v ?` format: "VoiceName   en_US    # Sample text"
                // Locale is always a 5-char IETF tag (xx_XX). Use regex to extract reliably.
                let localeRe = try? NSRegularExpression(pattern: #"\b([a-z]{2}_[A-Z]{2})\b"#)
                let voices = lines.map { line -> [String: String] in
                    var name = line
                    var locale = ""
                    var sample = ""
                    if let m = localeRe?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                       let locRange = Range(m.range(at: 1), in: line) {
                        locale = String(line[locRange])
                        // Name is everything before the locale match
                        name = line[..<locRange.lowerBound].trimmingCharacters(in: .whitespaces)
                        // Sample is everything after locale, strip leading "# " and whitespace
                        let after = String(line[locRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                        sample = after.hasPrefix("#") ? after.dropFirst().trimmingCharacters(in: .whitespaces) : after
                    }
                    return ["name": name, "locale": locale, "sample": sample]
                }
                printJSON(voices)
            } else {
                print(result)
            }
        }
    }
}
