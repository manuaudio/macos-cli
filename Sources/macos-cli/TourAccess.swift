import Foundation
import Security

/// Credentials and HTTP for the tour connectors (`mastertour`, `daysheets`).
///
/// A credential comes from the environment first, then from one generic-password item in
/// the login keychain that `<connector> login` wrote. `MACOS_CLI_KEYCHAIN=off` skips the
/// keychain, for an agent or a test that must use the environment alone. Secrets never
/// travel on argv, and nothing here prints them.
enum TourAccess {

    struct Stored {
        let account: String
        let secret: String
    }

    static var keychainEnabled: Bool {
        ProcessInfo.processInfo.environment["MACOS_CLI_KEYCHAIN"]?.lowercased() != "off"
    }

    static func environment(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func read(service: String) -> Stored? {
        guard keychainEnabled else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let found = item as? [String: Any],
              let data = found[kSecValueData as String] as? Data,
              let secret = String(data: data, encoding: .utf8), !secret.isEmpty
        else { return nil }
        return Stored(account: found[kSecAttrAccount as String] as? String ?? "", secret: secret)
    }

    /// Replaces the one item of `service`.
    static func save(service: String, account: String, secret: String) throws {
        guard keychainEnabled else {
            throw CLIFailure(code: "invalid_argument", message: "MACOS_CLI_KEYCHAIN=off: nothing was saved.",
                             hint: "Unset MACOS_CLI_KEYCHAIN, or pass the credentials in the environment.")
        }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: service,
            kSecValueData as String: Data(secret.utf8),
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            throw CLIFailure.appError("The keychain refused the item: \(reason).")
        }
    }

    /// The secret a `login` command reads: one line of stdin, without echo on a terminal.
    static func readSecret(prompt: String) throws -> String {
        let line: String?
        if isatty(STDIN_FILENO) != 0 {
            line = getpass(prompt).map { String(cString: $0) }
        } else {
            line = readLine(strippingNewline: true)
        }
        guard let value = line?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw CLIFailure(code: "invalid_argument", message: "No secret on stdin; nothing was saved.",
                             hint: "Pipe it in on stdin, or run the command in Terminal and type it at the prompt.")
        }
        return value
    }

    /// GET, waiting at most `timeout` seconds. Error messages never carry the URL: for
    /// Daysheets the URL is the credential.
    static func get(_ request: URLRequest, timeout: TimeInterval = 30) throws -> (status: Int, body: Data) {
        var request = request
        request.timeoutInterval = timeout
        var result: Result<(Int, Data), Error>?
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                result = .failure(error)
            } else {
                result = .success(((response as? HTTPURLResponse)?.statusCode ?? 200, data ?? Data()))
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw CLIFailure.timeout("The server did not answer in \(Int(timeout)) seconds.")
        }
        switch result! {
        case .success(let answer):
            return answer
        case .failure(let error as URLError) where error.code == .timedOut:
            throw CLIFailure.timeout("The server did not answer in \(Int(timeout)) seconds.")
        case .failure(let error as URLError) where error.code == .fileDoesNotExist:
            throw CLIFailure.notFound("The feed file does not exist.")
        case .failure(let error as URLError):
            throw CLIFailure.appError("The request failed: \(error.code.rawValue) (\(error.localizedDescription)).",
                                      hint: "Check the network connection.")
        case .failure(let error):
            throw CLIFailure.appError("The request failed: \(error.localizedDescription).")
        }
    }
}
