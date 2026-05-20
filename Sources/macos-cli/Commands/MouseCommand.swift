import ArgumentParser
import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

// Mouse control via CoreGraphics CGEvent.
// Requires Accessibility permission: System Settings → Privacy → Accessibility → Terminal (or macos-cli)

struct MouseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mouse",
        abstract: "Control the mouse cursor — move, click, drag, scroll",
        subcommands: [Move.self, Click.self, Drag.self, Scroll.self, Position.self]
    )

    // MARK: - Shared helpers

    static func checkAccessibility() throws {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            throw ValidationError("Accessibility permission required. Grant it in System Settings → Privacy & Security → Accessibility → Terminal")
        }
    }

    static func post(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
        usleep(20_000)  // 20ms settle
    }

    // MARK: - Move

    struct Move: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move cursor to position")
        @Option(help: "X coordinate") var x: Int
        @Option(help: "Y coordinate") var y: Int

        func run() throws {
            try Auth.check("mouse.write")
            try MouseCommand.checkAccessibility()
            let point = CGPoint(x: x, y: y)
            guard let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                   mouseCursorPosition: point, mouseButton: .left) else {
                throw ValidationError("Could not create mouse event")
            }
            MouseCommand.post(ev)
            print("Moved to (\(x), \(y))")
        }
    }

    // MARK: - Click

    struct Click: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Click at position")
        @Option(help: "X coordinate") var x: Int
        @Option(help: "Y coordinate") var y: Int
        @Flag(name: .long, help: "Right-click") var right = false
        @Flag(name: .long, help: "Double-click") var double = false

        func run() throws {
            try Auth.check("mouse.write")
            try MouseCommand.checkAccessibility()
            let point = CGPoint(x: x, y: y)
            let button: CGMouseButton = right ? .right : .left
            let downType: CGEventType = right ? .rightMouseDown : .leftMouseDown
            let upType:   CGEventType = right ? .rightMouseUp   : .leftMouseUp

            func singleClick() throws {
                guard let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                                         mouseCursorPosition: point, mouseButton: button),
                      let up   = CGEvent(mouseEventSource: nil, mouseType: upType,
                                         mouseCursorPosition: point, mouseButton: button) else {
                    throw ValidationError("Could not create click event")
                }
                MouseCommand.post(down)
                MouseCommand.post(up)
            }

            try singleClick()
            if double {
                usleep(50_000)
                try singleClick()
                // Mark as double-click
                guard let dbl = CGEvent(mouseEventSource: nil, mouseType: downType,
                                         mouseCursorPosition: point, mouseButton: button) else { return }
                dbl.setIntegerValueField(.mouseEventClickState, value: 2)
                MouseCommand.post(dbl)
            }
            let label = double ? "Double-clicked" : (right ? "Right-clicked" : "Clicked")
            print("\(label) at (\(x), \(y))")
        }
    }

    // MARK: - Drag

    struct Drag: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Click and drag from one position to another")
        @Option(name: .customLong("from-x"), help: "Start X") var fromX: Int
        @Option(name: .customLong("from-y"), help: "Start Y") var fromY: Int
        @Option(name: .customLong("to-x"),   help: "End X")   var toX: Int
        @Option(name: .customLong("to-y"),   help: "End Y")   var toY: Int

        func run() throws {
            try Auth.check("mouse.write")
            try MouseCommand.checkAccessibility()
            let start = CGPoint(x: fromX, y: fromY)
            let end   = CGPoint(x: toX,   y: toY)
            guard let down  = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                       mouseCursorPosition: start, mouseButton: .left),
                  let drag  = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                       mouseCursorPosition: end,   mouseButton: .left),
                  let up    = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                       mouseCursorPosition: end,   mouseButton: .left) else {
                throw ValidationError("Could not create drag events")
            }
            MouseCommand.post(down)
            usleep(50_000)
            MouseCommand.post(drag)
            usleep(50_000)
            MouseCommand.post(up)
            print("Dragged from (\(fromX), \(fromY)) to (\(toX), \(toY))")
        }
    }

    // MARK: - Scroll

    struct Scroll: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Scroll at position")
        @Option(help: "X coordinate") var x: Int
        @Option(help: "Y coordinate") var y: Int
        @Option(help: "Amount (positive = up, negative = down)") var amount: Int = -3

        func run() throws {
            try Auth.check("mouse.write")
            try MouseCommand.checkAccessibility()
            // Move to position first
            let point = CGPoint(x: x, y: y)
            if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                   mouseCursorPosition: point, mouseButton: .left) {
                MouseCommand.post(move)
            }
            guard let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                        wheelCount: 1, wheel1: Int32(amount), wheel2: 0, wheel3: 0) else {
                throw ValidationError("Could not create scroll event")
            }
            MouseCommand.post(scroll)
            print("Scrolled \(amount > 0 ? "up" : "down") \(abs(amount)) at (\(x), \(y))")
        }
    }

    // MARK: - Position

    struct Position: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get current cursor position")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let pos = NSEvent.mouseLocation
            let screenH = NSScreen.main?.frame.height ?? 0
            // NSEvent uses bottom-left origin; CGEvent uses top-left — convert
            let cgY = Int(screenH - pos.y)
            if json {
                printJSON(["x": Int(pos.x), "y": cgY])
            } else {
                print("x=\(Int(pos.x)) y=\(cgY)")
            }
        }
    }
}
