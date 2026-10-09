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
