import Foundation
import Observation
import SwiftData

/// A saved VNC connection profile.
///
/// This is the hand-written equivalent of what `@Model` generates. The SwiftDataMacros plugin is only
/// distributed with Xcode, and this project must also build with the Command Line Tools, so the
/// `PersistentModel` conformance (backing data, schema metadata, observation) is spelled out here.
/// Passwords are never stored in this model — only `credentialReference`, the Keychain account name.
public final class SavedConnection {
    // MARK: Persisted properties
    public var id: UUID {
        get { access(\.id); return getValue(forKey: \.id) }
        set { mutate(\.id) { setValue(forKey: \.id, to: newValue) } }
    }

    public var name: String {
        get { access(\.name); return getValue(forKey: \.name) }
        set { mutate(\.name) { setValue(forKey: \.name, to: newValue) } }
    }

    public var host: String {
        get { access(\.host); return getValue(forKey: \.host) }
        set { mutate(\.host) { setValue(forKey: \.host, to: newValue) } }
    }

    public var port: Int {
        get { access(\.port); return getValue(forKey: \.port) }
        set { mutate(\.port) { setValue(forKey: \.port, to: newValue) } }
    }

    public var authenticationMethodRaw: String {
        get { access(\.authenticationMethodRaw); return getValue(forKey: \.authenticationMethodRaw) }
        set { mutate(\.authenticationMethodRaw) { setValue(forKey: \.authenticationMethodRaw, to: newValue) } }
    }

    /// Optional; only sent when the negotiated security type asks for a username.
    public var username: String {
        get { access(\.username); return getValue(forKey: \.username) }
        set { mutate(\.username) { setValue(forKey: \.username, to: newValue) } }
    }

    /// Keychain account of the saved password, or `nil` when no password is saved.
    public var credentialReference: String? {
        get { access(\.credentialReference); return getValue(forKey: \.credentialReference) }
        set { mutate(\.credentialReference) { setValue(forKey: \.credentialReference, to: newValue) } }
    }

    public var isFavorite: Bool {
        get { access(\.isFavorite); return getValue(forKey: \.isFavorite) }
        set { mutate(\.isFavorite) { setValue(forKey: \.isFavorite, to: newValue) } }
    }

    public var createdAt: Date {
        get { access(\.createdAt); return getValue(forKey: \.createdAt) }
        set { mutate(\.createdAt) { setValue(forKey: \.createdAt, to: newValue) } }
    }

    public var lastConnectedAt: Date? {
        get { access(\.lastConnectedAt); return getValue(forKey: \.lastConnectedAt) }
        set { mutate(\.lastConnectedAt) { setValue(forKey: \.lastConnectedAt, to: newValue) } }
    }

    public var lastStatusRaw: String? {
        get { access(\.lastStatusRaw); return getValue(forKey: \.lastStatusRaw) }
        set { mutate(\.lastStatusRaw) { setValue(forKey: \.lastStatusRaw, to: newValue) } }
    }

    public var lastStatusMessage: String? {
        get { access(\.lastStatusMessage); return getValue(forKey: \.lastStatusMessage) }
        set { mutate(\.lastStatusMessage) { setValue(forKey: \.lastStatusMessage, to: newValue) } }
    }

    /// File name inside the connection's screenshot folder.
    public var lastScreenshotFileName: String? {
        get { access(\.lastScreenshotFileName); return getValue(forKey: \.lastScreenshotFileName) }
        set { mutate(\.lastScreenshotFileName) { setValue(forKey: \.lastScreenshotFileName, to: newValue) } }
    }

    /// SHA-256 fingerprint of the server's RSA key, recorded on first use (RSA-AES only).
    public var trustedServerKeyFingerprint: String? {
        get { access(\.trustedServerKeyFingerprint); return getValue(forKey: \.trustedServerKeyFingerprint) }
        set { mutate(\.trustedServerKeyFingerprint) { setValue(forKey: \.trustedServerKeyFingerprint, to: newValue) } }
    }

    /// JSON-encoded `ConnectionPreferences`.
    public var preferencesData: Data {
        get { access(\.preferencesData); return getValue(forKey: \.preferencesData) }
        set { mutate(\.preferencesData) { setValue(forKey: \.preferencesData, to: newValue) } }
    }

    // MARK: Init
    public init(id: UUID = UUID(),
                name: String,
                host: String,
                port: Int = HostAddress.defaultPort,
                authenticationMethod: AuthenticationMethod = .automatic,
                username: String = "",
                preferences: ConnectionPreferences = .default) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.authenticationMethodRaw = authenticationMethod.rawValue
        self.username = username
        self.credentialReference = nil
        self.isFavorite = false
        self.createdAt = Date()
        self.lastConnectedAt = nil
        self.lastStatusRaw = nil
        self.lastStatusMessage = nil
        self.lastScreenshotFileName = nil
        self.trustedServerKeyFingerprint = nil
        self.preferencesData = Self.encode(preferences)
    }

    // MARK: PersistentModel plumbing (what @Model would generate)
    private var _$backingData: any BackingData<SavedConnection> = SavedConnection.createBackingData()
    private let _$observationRegistrar = ObservationRegistrar()

    public var persistentBackingData: any BackingData<SavedConnection> {
        get { _$backingData }
        set { _$backingData = newValue }
    }

    public required init(backingData: any BackingData<SavedConnection>) {
        self.persistentBackingData = backingData
    }

    public static var schemaMetadata: [Schema.PropertyMetadata] {
        [
            .init(name: "id", keypath: \SavedConnection.id, defaultValue: nil, metadata: Schema.Attribute(.unique)),
            .init(name: "name", keypath: \SavedConnection.name),
            .init(name: "host", keypath: \SavedConnection.host),
            .init(name: "port", keypath: \SavedConnection.port),
            .init(name: "authenticationMethodRaw", keypath: \SavedConnection.authenticationMethodRaw),
            .init(name: "username", keypath: \SavedConnection.username),
            .init(name: "credentialReference", keypath: \SavedConnection.credentialReference),
            .init(name: "isFavorite", keypath: \SavedConnection.isFavorite),
            .init(name: "createdAt", keypath: \SavedConnection.createdAt),
            .init(name: "lastConnectedAt", keypath: \SavedConnection.lastConnectedAt),
            .init(name: "lastStatusRaw", keypath: \SavedConnection.lastStatusRaw),
            .init(name: "lastStatusMessage", keypath: \SavedConnection.lastStatusMessage),
            .init(name: "lastScreenshotFileName", keypath: \SavedConnection.lastScreenshotFileName),
            .init(name: "trustedServerKeyFingerprint", keypath: \SavedConnection.trustedServerKeyFingerprint),
            .init(name: "preferencesData", keypath: \SavedConnection.preferencesData)
        ]
    }

    private func access<Value>(_ keyPath: KeyPath<SavedConnection, Value>) {
        _$observationRegistrar.access(self, keyPath: keyPath)
    }

    private func mutate<Value>(_ keyPath: KeyPath<SavedConnection, Value>, _ body: () -> Void) {
        _$observationRegistrar.withMutation(of: self, keyPath: keyPath, body)
    }
}

extension SavedConnection: PersistentModel {}
extension SavedConnection: Observable {}

// MARK: - Convenience
public enum ConnectionOutcome: String, Codable, Sendable {
    case connected
    case authenticationFailed
    case failed
    case cancelled
}

public extension SavedConnection {
    var authenticationMethod: AuthenticationMethod {
        get { AuthenticationMethod(rawValue: authenticationMethodRaw) ?? .automatic }
        set { authenticationMethodRaw = newValue.rawValue }
    }

    var preferences: ConnectionPreferences {
        get { (try? JSONDecoder().decode(ConnectionPreferences.self, from: preferencesData)) ?? .default }
        set { preferencesData = Self.encode(newValue) }
    }

    var lastOutcome: ConnectionOutcome? {
        get { lastStatusRaw.flatMap(ConnectionOutcome.init(rawValue:)) }
        set { lastStatusRaw = newValue?.rawValue }
    }

    var displayAddress: String {
        HostAddress.display(host: host, port: port)
    }

    var hasSavedPassword: Bool {
        credentialReference != nil
    }

    var target: ConnectionTarget {
        let preferences = preferences

        return ConnectionTarget(host: host,
                                port: port,
                                authenticationMethod: authenticationMethod,
                                colorDepth: preferences.colorDepth,
                                isShared: preferences.isShared)
    }

    fileprivate static func encode(_ preferences: ConnectionPreferences) -> Data {
        (try? JSONEncoder().encode(preferences)) ?? Data("{}".utf8)
    }
}
