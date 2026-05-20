// Sources/macos-cli/Commands/SpacesCommand.swift
import ArgumentParser
import Foundation
import CoreGraphics

// Private CGS APIs — stable since macOS 10.15, used by Yabai/Amethyst
// CGSMainConnectionID, CGSCopyManagedDisplaySpaces, CGSGetActiveSpace are exported
// from CoreGraphics.framework and resolve at link time via @_silgen_name.
// CGSChangeSpaces is NOT in any SDK TBD (it's deep-private), so we resolve
// it at runtime via dlsym to avoid a link-time undefined-symbol error.

private typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: CGSConnectionID) -> UInt64

// CGSChangeSpaces resolved at runtime
private typealias CGSChangeSpacesFn = @convention(c) (CGSConnectionID, CFArray, Int32) -> Int32

// RTLD_DEFAULT is a C macro that Swift cannot import directly; define it explicitly.
private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

private func resolvedCGSChangeSpaces() -> CGSChangeSpacesFn? {
    guard let sym = dlsym(rtldDefault, "CGSChangeSpaces") else { return nil }
    return unsafeBitCast(sym, to: CGSChangeSpacesFn.self)
}

struct SpacesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spaces",
        abstract: "Mission Control Spaces — list, switch, manage",
        subcommands: [List.self, Switch.self]
    )

    // MARK: - Shared helpers

    private static func loadSpaces() throws -> (spaces: [UInt64], active: UInt64) {
        let conn = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]] else {
            throw ValidationError(
                "Could not read spaces. This uses private macOS APIs — if running on macOS 15+, please file a bug."
            )
        }
        let activeID = CGSGetActiveSpace(conn)
        var spaceIDs: [UInt64] = []
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                if let id = space["id64"] as? UInt64 { spaceIDs.append(id) }
                else if let id = space["id64"] as? Int { spaceIDs.append(UInt64(id)) }
            }
        }
        return (spaceIDs, activeID)
    }

    // MARK: - List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all Mission Control spaces")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            try Auth.check("spaces.read")
            let (spaces, active) = try SpacesCommand.loadSpaces()

            var result: [[String: Any]] = []
            for (i, id) in spaces.enumerated() {
                result.append([
                    "index": i + 1,
                    "id": id,
                    "active": id == active
                ])
            }
            if json {
                printJSON(result)
            } else {
                for s in result {
                    let flag = (s["active"] as? Bool == true) ? " [active]" : ""
                    print("Space \(s["index"] ?? 0)\(flag)")
                }
                print("\(result.count) space(s)")
            }
        }
    }

    // MARK: - Switch

    struct Switch: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "switch", abstract: "Switch to a space by index (1-based)")
        @Argument(help: "Space index (1-based)") var index: Int

        func run() throws {
            try Auth.check("spaces.write")
            let (spaces, _) = try SpacesCommand.loadSpaces()

            guard index >= 1, index <= spaces.count else {
                throw ValidationError("Space \(index) out of range — there are \(spaces.count) space(s). Run `macos spaces list` to see them.")
            }
            let targetID = spaces[index - 1]
            let conn = CGSMainConnectionID()

            guard let changeSpaces = resolvedCGSChangeSpaces() else {
                throw ValidationError("CGSChangeSpaces not available on this macOS version — cannot switch spaces.")
            }
            let result = changeSpaces(conn, [targetID] as CFArray, 0)
            if result != 0 {
                throw ValidationError("Could not switch to space \(index) (CGSChangeSpaces returned \(result)).")
            }
            print("Switched to space \(index)")
        }
    }
}
