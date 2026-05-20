// Sources/macos-cli/Commands/AudioDeviceCommand.swift
import ArgumentParser
import Foundation
import CoreAudio

struct AudioDeviceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Audio device routing — list devices, set default input/output",
        subcommands: [List.self, Info.self, SetOutput.self, SetInput.self]
    )

    // MARK: - CoreAudio helpers

    private static func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else { throw ValidationError("CoreAudio error reading device list: \(status)") }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        guard status == noErr else { throw ValidationError("CoreAudio error reading device IDs: \(status)") }
        return ids
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        return name as String
    }

    private static func hasScope(_ id: AudioDeviceID, input: Bool) -> Bool {
        let scope: AudioObjectPropertyScope = input
            ? kAudioDevicePropertyScopeInput
            : kAudioObjectPropertyScopeOutput
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func getDefault(input: Bool) -> AudioDeviceID {
        let selector: AudioObjectPropertySelector = input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = kAudioDeviceUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func setDefault(_ id: AudioDeviceID, input: Bool) throws {
        let selector: AudioObjectPropertySelector = input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableID = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &mutableID
        )
        guard status == noErr else {
            throw ValidationError("CoreAudio error setting device: \(status)")
        }
    }

    // Match device by name substring or by numeric ID string
    private static func findDevice(_ query: String, input: Bool) throws -> AudioDeviceID {
        let ids = try allDeviceIDs()
        if let idNum = AudioDeviceID(query), ids.contains(idNum) {
            guard hasScope(idNum, input: input) else {
                let kind = input ? "input" : "output"
                throw ValidationError("Device \(idNum) is not an \(kind) device. Run `macos audio list` to see devices.")
            }
            return idNum
        }
        guard let match = ids.first(where: {
            hasScope($0, input: input) &&
            deviceName($0).lowercased().contains(query.lowercased())
        }) else {
            let kind = input ? "input" : "output"
            throw ValidationError(
                "No \(kind) device matching '\(query)'. Run `macos audio list` to see available devices."
            )
        }
        return match
    }

    // MARK: - List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all audio devices")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("audio.read")
            let ids = try AudioDeviceCommand.allDeviceIDs()
            let defaultOut = AudioDeviceCommand.getDefault(input: false)
            let defaultIn = AudioDeviceCommand.getDefault(input: true)

            var result: [[String: Any]] = []
            for id in ids {
                let hasIn = AudioDeviceCommand.hasScope(id, input: true)
                let hasOut = AudioDeviceCommand.hasScope(id, input: false)
                guard hasIn || hasOut else { continue }
                result.append([
                    "id": id,
                    "name": AudioDeviceCommand.deviceName(id),
                    "input": hasIn,
                    "output": hasOut,
                    "default_input": id == defaultIn,
                    "default_output": id == defaultOut
                ])
            }

            if json {
                printJSON(result)
            } else {
                for d in result {
                    var tags: [String] = []
                    if d["default_output"] as? Bool == true { tags.append("default output") }
                    if d["default_input"] as? Bool == true { tags.append("default input") }
                    if d["input"] as? Bool == true, d["output"] as? Bool != true { tags.append("input only") }
                    if d["output"] as? Bool == true, d["input"] as? Bool != true { tags.append("output only") }
                    let suffix = tags.isEmpty ? "" : " [\(tags.joined(separator: ", "))]"
                    print("\(d["id"] ?? 0): \(d["name"] ?? "")\(suffix)")
                }
            }
        }
    }

    // MARK: - Info

    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show current default input and output devices")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("audio.read")
            let outID = AudioDeviceCommand.getDefault(input: false)
            let inID  = AudioDeviceCommand.getDefault(input: true)
            let outName = outID == 0 ? "(unknown)" : AudioDeviceCommand.deviceName(outID)
            let inName  = inID  == 0 ? "(unknown)" : AudioDeviceCommand.deviceName(inID)
            if json {
                printJSON([
                    "output": ["id": outID, "name": outName],
                    "input":  ["id": inID,  "name": inName]
                ])
            } else {
                print("Output: \(outName)")
                print("Input:  \(inName)")
            }
        }
    }

    // MARK: - SetOutput

    struct SetOutput: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set-output", abstract: "Set the default audio output device")
        @Argument(help: "Device name (substring) or numeric ID") var device: String

        func run() throws {
            try Auth.check("audio.write")
            let id = try AudioDeviceCommand.findDevice(device, input: false)
            try AudioDeviceCommand.setDefault(id, input: false)
            print("Default output: \(AudioDeviceCommand.deviceName(id))")
        }
    }

    // MARK: - SetInput

    struct SetInput: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set-input", abstract: "Set the default audio input device")
        @Argument(help: "Device name (substring) or numeric ID") var device: String

        func run() throws {
            try Auth.check("audio.write")
            let id = try AudioDeviceCommand.findDevice(device, input: true)
            try AudioDeviceCommand.setDefault(id, input: true)
            print("Default input: \(AudioDeviceCommand.deviceName(id))")
        }
    }
}
