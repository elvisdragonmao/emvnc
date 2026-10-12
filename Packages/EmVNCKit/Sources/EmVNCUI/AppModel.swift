import AppKit
import EmVNCCore
import Observation
import SwiftData
import SwiftUI

/// App-wide defaults stored in UserDefaults (no secrets).
enum AppSettings {
    static let showUnencryptedWarningKey = "showUnencryptedWarning"
    static let viewModeKey = "connectionViewMode"
    static let sortOrderKey = "connectionSortOrder"
    static let defaultScalingKey = "defaultScalingMode"
    static let defaultKeyboardProfileKey = "defaultKeyboardProfile"
    static let defaultClipboardSyncKey = "defaultClipboardSync"
    static let defaultAutoScreenshotKey = "defaultAutoScreenshot"

    /// Preferences for new connections, from the Settings window.
    static func newConnectionPreferences(_ defaults: UserDefaults = .standard) -> ConnectionPreferences {
        var preferences = ConnectionPreferences()

        if let raw = defaults.string(forKey: defaultScalingKey), let mode = ScalingMode(rawValue: raw) {
            preferences.scalingMode = mode
        }

        if let raw = defaults.string(forKey: defaultKeyboardProfileKey), let profile = KeyboardProfile(rawValue: raw) {
            preferences.keyboardProfile = profile
        }

        if defaults.object(forKey: defaultClipboardSyncKey) != nil {
            preferences.clipboardSync = defaults.bool(forKey: defaultClipboardSyncKey)
        }

        if defaults.object(forKey: defaultAutoScreenshotKey) != nil {
            preferences.autoScreenshot = defaults.bool(forKey: defaultAutoScreenshotKey)
        }

        return preferences
    }
}

enum EditorRequest: Identifiable, Equatable {
    case new
    case edit(UUID)

    var id: String {
        switch self {
            case .new: "new"
            case .edit(let id): id.uuidString
        }
    }
}

struct QuickConnectRequest {
    var target: ConnectionTarget
    var username: String
    var password: String
    var saveConnection: Bool
    var name: String
}

@MainActor
@Observable
public final class AppModel {
    public let container: ModelContainer
    public let credentialStore: CredentialStore
    public let screenshotStore: ScreenshotStore
    public let clipboard: ClipboardCoordinator

    /// The session whose window is key; drives the Session menu.
    public private(set) var activeSession: SessionController?
    /// Saved connections that currently have a session window.
    public private(set) var openConnectionIDs: Set<UUID> = []
    /// Live status per saved connection for the connection cards.
    public private(set) var liveStatus: [UUID: SessionController.Phase] = [:]

    var editorRequest: EditorRequest?
    var quickConnectRequested = false
    var screenshotBrowserConnectionID: UUID?

    @ObservationIgnored private var sessionWindows: [SessionWindowController] = []
    @ObservationIgnored private var phaseObservers: [UUID: Task<Void, Never>] = [:]

    public init(container: ModelContainer,
                credentialStore: CredentialStore? = nil,
                screenshotStore: ScreenshotStore? = nil,
                pasteboard: TextPasteboard? = nil) {
        self.container = container
        self.credentialStore = credentialStore ?? KeychainCredentialStore()
        self.screenshotStore = screenshotStore ?? ScreenshotStore()
        self.clipboard = ClipboardCoordinator(pasteboard: pasteboard ?? SystemTextPasteboard())
    }

    public var context: ModelContext { container.mainContext }

    // MARK: - Sessions
    public func connect(to connection: SavedConnection) {
        if let existing = sessionWindows.first(where: { $0.session.connectionID == connection.id }) {
            existing.window?.makeKeyAndOrderFront(nil)

            if !existing.session.phase.isConnected, existing.session.phase != .connecting {
                existing.session.reconnect()
            }

            return
        }

        let session = SessionController(connection: connection,
                                        modelContext: context,
                                        credentialStore: credentialStore,
                                        screenshotStore: screenshotStore,
                                        clipboard: clipboard)
        open(session)
    }

    func quickConnect(_ request: QuickConnectRequest) {
        let credentials = request.password.isEmpty && request.username.isEmpty
            ? nil
            : SessionCredentials(username: request.username, password: request.password)

        if request.saveConnection {
            let connection = SavedConnection(name: request.name.isEmpty ? request.target.host : request.name,
                                             host: request.target.host,
                                             port: request.target.port,
                                             authenticationMethod: request.target.authenticationMethod,
                                             username: request.username,
                                             preferences: AppSettings.newConnectionPreferences())
            context.insert(connection)

            if !request.password.isEmpty {
                try? CredentialManager.savePassword(request.password, for: connection, in: credentialStore)
            }

            try? context.save()
            connect(to: connection)

            return
        }

        let session = SessionController(connection: nil,
                                        quickConnectTarget: request.target,
                                        quickConnectName: request.name.isEmpty ? nil : request.name,
                                        quickConnectPreferences: AppSettings.newConnectionPreferences(),
                                        oneShotCredentials: credentials,
                                        modelContext: context,
                                        credentialStore: credentialStore,
                                        screenshotStore: screenshotStore,
                                        clipboard: clipboard)
        open(session)
    }

    private func open(_ session: SessionController) {
        let controller = SessionWindowController(session: session, appModel: self)
        sessionWindows.append(controller)

        if let id = session.connectionID {
            openConnectionIDs.insert(id)
            observePhase(of: session, connectionID: id)
        }

        controller.showAndConnect()
    }

    /// Mirrors a session's phase into `liveStatus` so cards can show "Connected" without holding sessions.
    private func observePhase(of session: SessionController, connectionID: UUID) {
        phaseObservers[connectionID]?.cancel()
        phaseObservers[connectionID] = Task { @MainActor [weak self, weak session] in
            while !Task.isCancelled, let session {
                self?.liveStatus[connectionID] = session.phase

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = session.phase
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    func sessionWindowDidBecomeKey(_ controller: SessionWindowController) {
        activeSession = controller.session
    }

    func sessionWindowDidResignKey(_ controller: SessionWindowController) {
        if activeSession === controller.session {
            activeSession = nil
        }
    }

    func sessionWindowWillClose(_ controller: SessionWindowController) {
        sessionWindows.removeAll { $0 === controller }

        if activeSession === controller.session {
            activeSession = nil
        }

        if let id = controller.session.connectionID {
            openConnectionIDs.remove(id)
            liveStatus.removeValue(forKey: id)
            phaseObservers.removeValue(forKey: id)?.cancel()
        }
    }

    var activeSessionWindow: SessionWindowController? {
        sessionWindows.first { $0.session === activeSession }
    }

    func setScaling(_ mode: ScalingMode) {
        activeSessionWindow?.setScalingMode(mode)
    }

    func toggleFullScreen() {
        activeSessionWindow?.window?.toggleFullScreen(nil)
    }

    func closeSession(for connectionID: UUID) {
        sessionWindows.first { $0.session.connectionID == connectionID }?.window?.close()
    }

    // MARK: - Connection management
    func requestNewConnection() {
        editorRequest = .new
    }

    func requestEdit(connectionID: UUID) {
        editorRequest = .edit(connectionID)
        NSApp.activate(ignoringOtherApps: true)
    }

    func requestQuickConnect() {
        quickConnectRequested = true
    }

    func toggleFavorite(_ connection: SavedConnection) {
        connection.isFavorite.toggle()
        try? context.save()
    }

    @discardableResult
    func duplicate(_ connection: SavedConnection) -> SavedConnection {
        let copy = SavedConnection(name: "\(connection.name) copy",
                                   host: connection.host,
                                   port: connection.port,
                                   authenticationMethod: connection.authenticationMethod,
                                   username: connection.username,
                                   preferences: connection.preferences)
        copy.trustedServerKeyFingerprint = connection.trustedServerKeyFingerprint
        context.insert(copy)

        // The copy gets its own Keychain item so editing one never changes the other
        if let password = try? CredentialManager.password(for: connection, in: credentialStore) {
            try? CredentialManager.savePassword(password, for: copy, in: credentialStore)
        }

        screenshotStore.copyLatest(from: connection, to: copy)

        if let fileName = copy.lastScreenshotFileName, let original = context.screenshots(for: connection.id).first(where: { $0.fileName == fileName }) {
            context.insert(ScreenshotRecord(connectionID: copy.id,
                                            fileName: fileName,
                                            capturedAt: original.capturedAt,
                                            width: original.width,
                                            height: original.height,
                                            isAutomatic: original.isAutomatic))
        }

        try? context.save()

        return copy
    }

    func delete(_ connection: SavedConnection) {
        closeSession(for: connection.id)
        try? CredentialManager.removePassword(for: connection, in: credentialStore)
        screenshotStore.deleteAll(for: connection.id, in: context)
        context.delete(connection)
        try? context.save()
    }
}
