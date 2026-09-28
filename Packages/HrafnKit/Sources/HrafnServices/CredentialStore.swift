import Foundation
import Security
import XMPPStream

/// Where account passwords live. The keychain in the app; memory in tests.
/// XEP-0484 FAST tokens are credentials too, and live beside them, as does
/// the private half of the account's OMEMO identity key.
public protocol CredentialStore: Sendable {
    func password(for accountID: String) throws -> String?
    func setPassword(_ password: String, for accountID: String) throws
    /// Also forgets the account's FAST token and OMEMO identity key.
    func removePassword(for accountID: String) throws
    func fastToken(for accountID: String) -> FASTToken?
    func setFASTToken(_ token: FASTToken?, for accountID: String)
    /// The OMEMO identity's private key. Bound to this device: never in a
    /// backup, so a restored database cannot resume this device's ratchets
    /// on another phone.
    func omemoIdentityKey(for accountID: String) throws -> Data?
    func setOMEMOIdentityKey(_ key: Data?, for accountID: String) throws
}

extension CredentialStore {
    public func fastToken(for accountID: String) -> FASTToken? { nil }
    public func setFASTToken(_ token: FASTToken?, for accountID: String) {}
}

/// One account's FAST token, as XMPPKit asks for it.
struct AccountFASTTokens: FASTTokenStore {
    let credentials: any CredentialStore
    let accountID: String

    func load() -> FASTToken? { credentials.fastToken(for: accountID) }
    func save(_ token: FASTToken?) { credentials.setFASTToken(token, for: accountID) }
}

public struct CredentialStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "keychain error \(status)" }
}

/// Generic-password items, one per account, readable after first unlock so the
/// notification service extension can log in while the phone is locked.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    /// Keychain sharing group, so extensions see the same items. `nil` uses
    /// the app's default group.
    public let accessGroup: String?

    public init(service: String = "dev.stevedylandev.hrafn.account", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(_ accountID: String, service: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
            kSecAttrAccount as String: accountID,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    /// FAST tokens: a service of their own, same account key.
    private var tokenService: String { service + ".fast" }
    /// OMEMO identity keys, likewise.
    private var omemoService: String { service + ".omemo" }

    public func password(for accountID: String) throws -> String? {
        try read(query(accountID)).map { String(decoding: $0, as: UTF8.self) }
    }

    public func setPassword(_ password: String, for accountID: String) throws {
        try write(Data(password.utf8), query(accountID))
    }

    public func removePassword(for accountID: String) throws {
        setFASTToken(nil, for: accountID)
        try setOMEMOIdentityKey(nil, for: accountID)
        let status = SecItemDelete(query(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError(status: status) }
    }

    public func fastToken(for accountID: String) -> FASTToken? {
        guard let data = try? read(query(accountID, service: tokenService)) else { return nil }
        return try? JSONDecoder().decode(FASTToken.self, from: data)
    }

    public func setFASTToken(_ token: FASTToken?, for accountID: String) {
        let item = query(accountID, service: tokenService)
        if let token, let data = try? JSONEncoder().encode(token) {
            try? write(data, item)
        } else {
            SecItemDelete(item as CFDictionary)
        }
    }

    public func omemoIdentityKey(for accountID: String) throws -> Data? {
        try read(query(accountID, service: omemoService))
    }

    public func setOMEMOIdentityKey(_ key: Data?, for accountID: String) throws {
        let item = query(accountID, service: omemoService)
        if let key {
            try write(key, item)
        } else {
            let status = SecItemDelete(item as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError(status: status) }
        }
    }

    private func read(_ query: [String: Any]) throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialStoreError(status: status) }
        return data
    }

    private func write(_ data: Data, _ query: [String: Any]) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { $1 }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String] = [:]
    private var tokens: [String: FASTToken] = [:]
    private var omemoKeys: [String: Data] = [:]

    public init() {}

    public func password(for accountID: String) throws -> String? { lock.withLock { passwords[accountID] } }
    public func setPassword(_ password: String, for accountID: String) throws { lock.withLock { passwords[accountID] = password } }
    public func removePassword(for accountID: String) throws {
        lock.withLock {
            passwords[accountID] = nil
            tokens[accountID] = nil
            omemoKeys[accountID] = nil
        }
    }
    public func fastToken(for accountID: String) -> FASTToken? { lock.withLock { tokens[accountID] } }
    public func setFASTToken(_ token: FASTToken?, for accountID: String) { lock.withLock { tokens[accountID] = token } }
    public func omemoIdentityKey(for accountID: String) throws -> Data? { lock.withLock { omemoKeys[accountID] } }
    public func setOMEMOIdentityKey(_ key: Data?, for accountID: String) throws { lock.withLock { omemoKeys[accountID] = key } }
}
