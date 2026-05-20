// Sources/macos-cli/Helpers.swift
import Foundation
import ArgumentParser

// MARK: - Process helpers (moved out of SystemCommand.swift)

extension Process {
    /// Runs an executable and returns its exit code. stdout and stderr are discarded.
    @discardableResult
    static func run(args: [String]) -> Int32 {
        guard !args.isEmpty else { return -1 }
        let exe = args[0]
        if !FileManager.default.isExecutableFile(atPath: exe) {
            fputs("error: executable not found or not runnable: \(exe)\n", stderr)
            return 127
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = Array(args.dropFirst())
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            fputs("error: failed to spawn \(exe): \(error.localizedDescription)\n", stderr)
            return 126
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    /// Convenience: capture stdout only (no timeout). Used by very short ops.
    static func capture(args: [String]) -> String {
        guard let exe = args.first,
              FileManager.default.isExecutableFile(atPath: exe) else { return "" }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Stdout capture with timeout, returning fallback if timeout fires or exe missing.
    static func capture(args: [String], timeout seconds: Double, fallback: String = "") -> String {
        return capture(args: args, timeout: seconds) ?? fallback
    }

    /// Stdout capture with timeout. Returns nil on timeout or missing executable.
    static func capture(args: [String], timeout seconds: Double) -> String? {
        guard let exe = args.first,
              FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        var collected = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); collected.append(chunk); lock.unlock()
        }

        guard (try? proc.run()) != nil else {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        let deadline = Date().addingTimeInterval(seconds)
        while proc.isRunning {
            if Date() > deadline {
                proc.terminate()
                let killDeadline = Date().addingTimeInterval(0.25)
                while proc.isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
                pipe.fileHandleForReading.readabilityHandler = nil
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { lock.lock(); collected.append(tail); lock.unlock() }
        return String(data: collected, encoding: .utf8)
    }

    /// Capture both stdout and stderr separately, with timeout.
    /// Returns (stdout, stderr, exitCode). exitCode is -1 on timeout.
    static func captureWithStderr(args: [String], timeout seconds: Double) -> (stdout: String, stderr: String, exitCode: Int32) {
        guard let exe = args.first,
              FileManager.default.isExecutableFile(atPath: exe) else {
            return ("", "executable not found: \(args.first ?? "<empty>")", 127)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = Array(args.dropFirst())
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var outData = Data()
        var errData = Data()
        let lock = NSLock()
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData; guard !chunk.isEmpty else { return }
            lock.lock(); outData.append(chunk); lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData; guard !chunk.isEmpty else { return }
            lock.lock(); errData.append(chunk); lock.unlock()
        }

        do { try proc.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return ("", "spawn failed: \(error.localizedDescription)", 126)
        }

        let deadline = Date().addingTimeInterval(seconds)
        while proc.isRunning {
            if Date() > deadline {
                proc.terminate()
                let killDeadline = Date().addingTimeInterval(0.25)
                while proc.isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                return (String(data: outData, encoding: .utf8) ?? "",
                        (String(data: errData, encoding: .utf8) ?? "") + "\n[timed out after \(seconds)s]",
                        -1)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let outTail = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errTail = errPipe.fileHandleForReading.readDataToEndOfFile()
        if !outTail.isEmpty { outData.append(outTail) }
        if !errTail.isEmpty { errData.append(errTail) }
        return (String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "",
                proc.terminationStatus)
    }
}

// MARK: - JXA helpers

/// Escape a Swift string for safe interpolation inside an AppleScript double-quoted string.
/// Only backslash and double-quote need escaping in AppleScript.
/// Order matters: backslash MUST be escaped first.
func appleScriptEscape(_ s: String) -> String {
    return s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Escape a Swift string for safe interpolation inside a single-quoted JXA string literal.
/// Order matters: backslash MUST be escaped first.
func jxaEscape(_ s: String) -> String {
    return s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
}

/// Result returned by a JXA script that uses the structured envelope pattern.
struct JXAEnvelope {
    let ok: Bool
    let resultJSON: String
    let error: String
}

/// Parse a JXA script's stdout into a JXAEnvelope.
func parseJXAEnvelope(_ raw: String) -> JXAEnvelope? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        if trimmed.lowercased().hasPrefix("execution error:") || trimmed.lowercased().hasPrefix("error:") {
            return JXAEnvelope(ok: false, resultJSON: "", error: trimmed)
        }
        return nil
    }
    let ok = obj["ok"] as? Bool ?? false
    let errMsg = obj["error"] as? String ?? ""
    var resultJSON = ""
    if let result = obj["result"] {
        if let d = try? JSONSerialization.data(withJSONObject: result, options: []),
           let s = String(data: d, encoding: .utf8) {
            resultJSON = s
        }
    }
    return JXAEnvelope(ok: ok, resultJSON: resultJSON, error: errMsg)
}

/// Run a JXA script that uses the structured envelope pattern, throw on failure.
@discardableResult
func runJXAEnvelope(_ script: String, timeout: TimeInterval = 10, failureMessage: String) throws -> String {
    let raw = Process.capture(args: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
                              timeout: timeout, fallback: "")
    guard let env = parseJXAEnvelope(raw) else {
        throw ValidationError("\(failureMessage)\nRaw: \(raw.prefix(300))")
    }
    if !env.ok {
        throw ValidationError("\(failureMessage)\n\(env.error)")
    }
    return env.resultJSON
}
