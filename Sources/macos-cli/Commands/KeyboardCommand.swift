import ArgumentParser
import Foundation

// Keyboard input via System Events osascript — handles Unicode and modifier keys correctly.
// Requires Accessibility permission for System Events.

struct KeyboardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keyboard",
        abstract: "Keyboard input — type text or send key shortcuts",
        subcommands: [TypeText.self, Key.self]
    )

    // MARK: - Type

    struct TypeText: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "type", abstract: "Type text into the frontmost app")

        @Argument(help: "Text to type")
        var text: String

        @Option(name: .long, help: "Delay between keystrokes in milliseconds (default: 0)")
        var delay: Int = 0

        func run() throws {
            try Auth.check("keyboard.write")
            let escaped = jxaEscape(text)
            let script: String
            if delay > 0 {
                // Type char by char with delay
                let chars = text.map { String($0) }
                let stmts = chars.map { c -> String in
                    let ce = jxaEscape(c)
                    return "se.keystroke('\(ce)'); delay(\(Double(delay) / 1000.0))"
                }.joined(separator: "; ")
                script = "try { const se = Application('System Events'); \(stmts); JSON.stringify({ok:true,result:'typed'}); } catch(e) { JSON.stringify({ok:false,error:String(e&&e.message?e.message:e)}); }"
            } else {
                script = "try { Application('System Events').keystroke('\(escaped)'); JSON.stringify({ok:true,result:'typed'}); } catch(e) { JSON.stringify({ok:false,error:String(e&&e.message?e.message:e)}); }"
            }
            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw ValidationError("Type failed — grant Accessibility permission to Terminal in System Settings → Privacy → Accessibility\n\(errMsg)")
            }
            print("Typed: \(text.prefix(50))\(text.count > 50 ? "..." : "")")
        }
    }

    // MARK: - Key

    // Supported modifier names → JXA modifier strings
    private static let modifiers: [String: String] = [
        "cmd": "command down", "command": "command down",
        "opt": "option down",  "option": "option down", "alt": "option down",
        "ctrl": "control down", "control": "control down",
        "shift": "shift down",
    ]

    // Common key names → key codes (for key code approach)
    private static let keyCodes: [String: Int] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
        "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    ]

    struct Key: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "key", abstract: "Send a key or shortcut (e.g. 'cmd+c', 'escape', 'return')")

        @Argument(help: "Key combo (e.g. 'cmd+c', 'shift+tab', 'escape')")
        var combo: String

        func run() throws {
            try Auth.check("keyboard.write")
            let parts = combo.lowercased().split(separator: "+").map(String.init)
            let key = parts.last ?? combo
            let mods = parts.dropLast()

            let modList = mods.compactMap { KeyboardCommand.modifiers[$0] }
            let modStr = modList.isEmpty ? "" : "using: [\(modList.map { "\"\($0)\"" }.joined(separator: ", "))]"

            let script: String
            if let code = KeyboardCommand.keyCodes[key] {
                if modStr.isEmpty {
                    script = "try { Application('System Events').keyCode(\(code)); JSON.stringify({ok:true,result:'key'}); } catch(e) { JSON.stringify({ok:false,error:String(e&&e.message?e.message:e)}); }"
                } else {
                    script = "try { Application('System Events').keyCode(\(code), {\(modStr)}); JSON.stringify({ok:true,result:'key'}); } catch(e) { JSON.stringify({ok:false,error:String(e&&e.message?e.message:e)}); }"
                }
            } else if key.count == 1 {
                let escaped = jxaEscape(key)
                if modStr.isEmpty {
                    script = "try { Application('System Events').keystroke('\(escaped)'); JSON.stringify({ok:true,result:'key'}); } catch(e) { JSON.stringify({ok:false,error:String(e&&e.message?e.message:e)}); }"
                } else {
                    script = "try { Application('System Events').keystroke('\(escaped)', {\(modStr)}); JSON.stringify({ok:true,result:'key'}); } catch(e) { JSON.stringify({ok:false,error:String(e&&e.message?e.message:e)}); }"
                }
            } else {
                throw ValidationError("Unknown key: '\(key)'. Use single chars or: return, tab, space, escape, delete, arrow keys, f1-f12")
            }

            let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script], timeout: 10, fallback: "")
            guard let env = parseJXAEnvelope(raw), env.ok else {
                let errMsg = parseJXAEnvelope(raw)?.error ?? raw
                throw ValidationError("Key failed — grant Accessibility permission to Terminal in System Settings\n\(errMsg)")
            }
            print("Key: \(combo)")
        }
    }
}
