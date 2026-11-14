import Foundation

/// Result returned by a JXA script that uses the structured envelope pattern:
/// `JSON.stringify({ok:true,result:…})` or `JSON.stringify({ok:false,error:"…"})`.
public struct JXAEnvelope: Equatable {
    public let ok: Bool
    /// The `result` value re-serialized as JSON: an object, an array, or a bare
    /// string, number or boolean (`"launched"`, `3`, `true`). Empty when absent.
    public let resultJSON: String
    public let error: String
    public init(ok: Bool, resultJSON: String, error: String) {
        self.ok = ok
        self.resultJSON = resultJSON
        self.error = error
    }
}

/// Parse a JXA script's stdout into a JXAEnvelope.
///
/// `result` may be any JSON value. A bare string such as `'launched'` is not a valid
/// top-level object for `JSONSerialization.data(withJSONObject:)`, which raises an
/// Objective-C exception Swift cannot catch, so it is written with `.fragmentsAllowed`.
public func parseJXAEnvelope(_ raw: String) -> JXAEnvelope? {
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
    if let result = obj["result"], !(result is NSNull) {
        if let d = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
           let s = String(data: d, encoding: .utf8) {
            resultJSON = s
        }
    }
    return JXAEnvelope(ok: ok, resultJSON: resultJSON, error: errMsg)
}
