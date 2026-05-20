import ArgumentParser
import Foundation
import Vision
import AppKit
import CoreGraphics

struct OcrCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ocr",
        abstract: "Read text from the screen using Vision OCR",
        subcommands: [Full.self, Region.self, File.self]
    )

    struct Full: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "full",
            abstract: "OCR the entire screen"
        )
        @Flag(name: .long, help: "Output JSON array of text lines") var json = false

        func run() throws {
            try Auth.check("ocr.capture")
            guard let img = captureScreen() else {
                fputs("Error: Could not capture screen — check Screen Recording permission\n", stderr)
                throw ExitCode.failure
            }
            let lines = recognizeText(in: img)
            if json {
                let data = try JSONSerialization.data(withJSONObject: lines)
                print(String(data: data, encoding: .utf8) ?? "[]")
            } else {
                print(lines.joined(separator: "\n"))
            }
        }
    }

    struct Region: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "region",
            abstract: "OCR a screen region"
        )
        @Option(name: .long, help: "X coordinate") var x: Int
        @Option(name: .long, help: "Y coordinate") var y: Int
        @Option(name: .long, help: "Width") var width: Int
        @Option(name: .long, help: "Height") var height: Int
        @Flag(name: .long, help: "Output JSON array of text lines") var json = false

        func run() throws {
            try Auth.check("ocr.capture")
            guard let full = captureScreen() else {
                fputs("Error: Could not capture screen — check Screen Recording permission\n", stderr)
                throw ExitCode.failure
            }
            guard let img = full.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else {
                fputs("Error: Region out of bounds\n", stderr)
                throw ExitCode.failure
            }
            let lines = recognizeText(in: img)
            if json {
                let data = try JSONSerialization.data(withJSONObject: lines)
                print(String(data: data, encoding: .utf8) ?? "[]")
            } else {
                print(lines.joined(separator: "\n"))
            }
        }
    }

    struct File: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "file",
            abstract: "OCR an image file (JPEG, PNG, HEIC, etc.)"
        )
        @Option(name: .long, help: "Path to image file") var path: String
        @Flag(name: .long, help: "Output JSON array of text lines") var json = false

        func run() throws {
            try Auth.check("ocr.capture")
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                fputs("Error: Could not load image at \(path)\n", stderr)
                throw ExitCode.failure
            }
            let lines = recognizeText(in: img)
            if json {
                let encoded = try JSONSerialization.data(withJSONObject: lines)
                print(String(data: encoded, encoding: .utf8) ?? "[]")
            } else {
                print(lines.joined(separator: "\n"))
            }
        }
    }
}

private func captureScreen() -> CGImage? {
    // Use screencapture to a temp file then load it (avoids CGWindowListCreate complications)
    let path = "/tmp/apple_ocr_\(Int.random(in: 100000...999999)).png"
    let result = Process.run(args: ["/usr/sbin/screencapture", "-x", path])
    guard result == 0 else { return nil }
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return img
}

private func recognizeText(in image: CGImage) -> [String] {
    var lines: [String] = []
    let sem = DispatchSemaphore(value: 0)
    let request = VNRecognizeTextRequest { req, _ in
        defer { sem.signal() }
        guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
        lines = observations.compactMap { $0.topCandidates(1).first?.string }
    }
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    var performError: Error? = nil
    do {
        try handler.perform([request])
    } catch {
        performError = error
        sem.signal()
    }
    sem.wait()
    if let e = performError {
        fputs("OCR warning: \(e.localizedDescription)\n", stderr)
    }
    return lines
}
