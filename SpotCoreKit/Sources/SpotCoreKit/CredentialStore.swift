import Foundation
import Security

/// Holds the opaque spotcore credentials blob. Saving twice equals saving once,
/// and deleting a missing item succeeds.
public protocol CredentialStore: Sendable {
    func load() throws -> Data?
    func save(_ blob: Data) throws
    func delete() throws
}

public struct KeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var description: String {
        "KeychainError(OSStatus \(status))"
    }
}

/// Legacy login keychain with the default creator-only ACL (ADR-003). It never
/// sets `kSecUseDataProtectionKeychain` or an access group: ad-hoc builds have
/// no entitlement for them.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func load() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecInternalError) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func save(_ blob: Data) throws {
        var status = update(blob)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = blob
            status = SecItemAdd(item as CFDictionary, nil)
            // Another writer added it between our update and add.
            if status == errSecDuplicateItem {
                status = update(blob)
            }
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func update(_ blob: Data) -> OSStatus {
        SecItemUpdate(query as CFDictionary, [kSecValueData: blob] as CFDictionary)
    }
}
