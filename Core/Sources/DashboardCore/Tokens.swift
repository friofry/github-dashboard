import Foundation
import Security

public enum TokenSource: String, Sendable {
    case keychain = "Keychain"
    case environment = "GH_TOKEN"
    case ghCLI = "GitHub CLI"
}

public struct Token: Sendable {
    public let value: String
    public let source: TokenSource

    public init(value: String, source: TokenSource) {
        self.value = value
        self.source = source
    }
}

public protocol TokenProvider: Sendable {
    /// Returns nil when this provider has nothing to offer.
    func token() async -> Token?
}

/// A provider the user can write to from Settings.
public protocol TokenStore: TokenProvider {
    func save(_ value: String) throws
    func delete() throws
}

/// Asks each provider in order and returns the first token found.
public struct TokenChain: TokenProvider {
    private let providers: [TokenProvider]

    public init(_ providers: [TokenProvider]) {
        self.providers = providers
    }

    public func token() async -> Token? {
        for provider in providers {
            if let token = await provider.token() { return token }
        }
        return nil
    }
}

public struct StaticTokenProvider: TokenProvider {
    private let value: String?
    private let source: TokenSource

    public init(_ value: String?, source: TokenSource = .environment) {
        self.value = value
        self.source = source
    }

    public func token() async -> Token? {
        guard let value, !value.isEmpty else { return nil }
        return Token(value: value, source: source)
    }
}

public struct KeychainError: LocalizedError {
    let status: OSStatus
    public var errorDescription: String? {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let account: String

    /// - Parameter account: one item per secret; the GitHub token is the default.
    public init(service: String, account: String = "github-token") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func token() async -> Token? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return Token(value: value, source: .keychain)
    }

    public func save(_ value: String) throws {
        try delete()
        var query = query
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Reads the token the GitHub CLI keeps in the login keychain, without starting `gh`.
///
/// Started from a GUI app, `gh auth token` waits on a keychain confirmation it never gets, so the app
/// asks the keychain itself: macOS then shows its own "Always Allow" prompt for this app.
public struct GitHubCLIKeychainTokenProvider: TokenProvider {
    /// Reads a generic password; nil when there is none or access is refused.
    public typealias SecretReader = @Sendable (_ service: String, _ account: String?) -> String?

    private let configDirectory: URL
    private let readSecret: SecretReader
    private let host: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                host: String = "github.com",
                readSecret: @escaping SecretReader = Self.keychainSecret) {
        self.init(configDirectory: Self.configDirectory(environment: environment), host: host, readSecret: readSecret)
    }

    public init(configDirectory: URL, host: String = "github.com", readSecret: @escaping SecretReader) {
        self.configDirectory = configDirectory
        self.host = host
        self.readSecret = readSecret
    }

    public func token() async -> Token? {
        let hosts = (try? String(contentsOf: configDirectory.appendingPathComponent("hosts.yml"), encoding: .utf8)) ?? ""
        let user = Self.activeUser(inHosts: hosts, host: host)
        let service = "gh:\(host)"
        let readSecret = readSecret
        // The read blocks while macOS asks the user, so keep it off the caller's thread.
        let secret = await Task.detached { readSecret(service, user) }.value
        guard let secret, let value = Self.decode(secret), !value.isEmpty else { return nil }
        return Token(value: value, source: .ghCLI)
    }

    /// `GH_CONFIG_DIR`, then `$XDG_CONFIG_HOME/gh`, then `~/.config/gh`, as the CLI itself resolves it.
    static func configDirectory(environment: [String: String]) -> URL {
        if let dir = environment["GH_CONFIG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("gh")
        }
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/gh")
    }

    /// The `user:` of the host's block in `hosts.yml`; nil when the file names none.
    public static func activeUser(inHosts yaml: String, host: String) -> String? {
        var inHost = false
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix(while: { $0 == " " }).count
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { continue }
            if indent == 0 {
                inHost = text == "\(host):"
            } else if inHost, indent <= 4, text.hasPrefix("user:") {
                let value = text.dropFirst("user:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// The CLI's keyring library stores secrets base64- or hex-encoded behind a prefix.
    public static func decode(_ stored: String) -> String? {
        let base64Prefix = "go-keyring-base64:", hexPrefix = "go-keyring-encoded:"
        let text: String?
        if stored.hasPrefix(base64Prefix) {
            text = Data(base64Encoded: String(stored.dropFirst(base64Prefix.count))).map { String(decoding: $0, as: UTF8.self) }
        } else if stored.hasPrefix(hexPrefix) {
            text = Self.hexDecoded(String(stored.dropFirst(hexPrefix.count)))
        } else {
            text = stored
        }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hexDecoded(_ hex: String) -> String? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8](), index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static let keychainSecret: SecretReader = { service, account in
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

#if os(macOS)
/// Borrows the token from an installed, logged-in GitHub CLI. Nothing is stored by this app.
public struct GitHubCLITokenProvider: TokenProvider {
    private static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public func token() async -> Token? {
        guard let gh = Self.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let timeout = timeout
        return await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = ["auth", "token"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }

            // A hung `gh` must not hang the refresh loop.
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()

            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !value.isEmpty else { return nil }
            return Token(value: value, source: .ghCLI)
        }.value
    }
}
#endif
