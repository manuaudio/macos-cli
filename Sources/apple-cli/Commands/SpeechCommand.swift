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
                let voices = lines.map { line -> [String: String] in
                    let parts = line.components(separatedBy: "  ").filter { !$0.isEmpty }
                    return [
                        "name": parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespaces) : "",
                        "locale": parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "",
                        "sample": parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : "",
                    ]
                }
                printJSON(voices)
            } else {
                print(result)
            }
        }
    }
}
