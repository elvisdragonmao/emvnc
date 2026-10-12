import Foundation
import Security

/// Stores connection passwords. The only production implementation is the macOS Keychain.
/// Calls can block (the Keychain may ask the user for permission), so callers on the main actor should use
/// the async helpers in `CredentialManager`.
public protocol CredentialStore: AnyObject, Sendable {
    func savePassword(_ password: String, reference: String, label: String) throws
    func password(reference: String) throws -> String?
    func deletePassword(reference: String) throws
}

public enum CredentialStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(message)"
            case .invalidData:
                return "The saved password could not be read."
        }
    }
}

/// Generic-password items in the user's login keychain, one per saved connection.
/// Account = the connection's credential reference; nothing else about the connection is stored there.
public final class KeychainCredentialStore: CredentialStore, Sendable {
    /// `EMVNC_KEYCHAIN_SERVICE` overrides the service for automated tests, like `EMVNC_DATA_DIR` for files.
    public static var defaultService: String {
        if let override = ProcessInfo.processInfo.environment["EMVNC_KEYCHAIN_SERVICE"], !override.isEmpty {
            return override
        }

        return "dev.emvnc.emvnc.vnc-password"
    }

    private let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    public func savePassword(_ password: String, reference: String, label: String) throws {
        let data = Data(password.utf8)
        let query = baseQuery(reference: reference)

        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrLabel: label,
            kSecAttrDescription: "VNC password"
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch updateStatus {
            case errSecSuccess:
                return
            case errSecItemNotFound:
                var addQuery = query
                addQuery.merge(attributes) { $1 }
                addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked

                let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

                guard addStatus == errSecSuccess else {
                    throw CredentialStoreError.keychain(addStatus)
                }
            default:
                throw CredentialStoreError.keychain(updateStatus)
        }
    }

    public func password(reference: String) throws -> String? {
        var query = baseQuery(reference: reference)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
            case errSecSuccess:
                guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
                    throw CredentialStoreError.invalidData
                }

                return password
            case errSecItemNotFound:
                return nil
            default:
                throw CredentialStoreError.keychain(status)
        }
    }

    public func deletePassword(reference: String) throws {
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(reference: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: reference
        ]
    }
}

/// In-memory store for tests and previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public var passwords: [String: String] {
        lock.withLock { storage }
    }

    public func savePassword(_ password: String, reference: String, label: String) throws {
        lock.withLock { storage[reference] = password }
    }

    public func password(reference: String) throws -> String? {
        lock.withLock { storage[reference] }
    }

    public func deletePassword(reference: String) throws {
        lock.withLock { _ = storage.removeValue(forKey: reference) }
    }
}

/// Connection-level credential operations shared by the editor, the session and duplication.
public enum CredentialManager {
    public static func reference(for connection: SavedConnection) -> String {
        connection.id.uuidString
    }

    public static func label(for connection: SavedConnection) -> String {
        "emvnc – \(connection.name) (\(connection.displayAddress))"
    }

    public static func savePassword(_ password: String, for connection: SavedConnection, in store: CredentialStore) throws {
        let reference = reference(for: connection)

        try store.savePassword(password, reference: reference, label: label(for: connection))
        connection.credentialReference = reference
    }

    public static func password(for connection: SavedConnection, in store: CredentialStore) throws -> String? {
        guard let reference = connection.credentialReference else { return nil }

        return try store.password(reference: reference)
    }

    /// Reads the password off the main thread so a Keychain permission prompt never freezes the UI.
    public static func loadPassword(reference: String, from store: CredentialStore) async throws -> String? {
        try await Task.detached(priority: .userInitiated) {
            try store.password(reference: reference)
        }.value
    }

    public static func storePassword(_ password: String, reference: String, label: String, in store: CredentialStore) async throws {
        try await Task.detached(priority: .userInitiated) {
            try store.savePassword(password, reference: reference, label: label)
        }.value
    }

    public static func removePassword(for connection: SavedConnection, in store: CredentialStore) throws {
        if let reference = connection.credentialReference {
            try store.deletePassword(reference: reference)
        }

        connection.credentialReference = nil
    }
}
