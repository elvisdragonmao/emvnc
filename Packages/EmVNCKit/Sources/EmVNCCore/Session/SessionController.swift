import AppKit
import Foundation
import IOSurface
import Observation
import SwiftData

/// Receives framebuffer events for display. Implemented by the framebuffer `NSView`, kept out of SwiftUI so
/// remote screen updates never trigger view re-evaluation.
@MainActor
public protocol FramebufferRenderer: AnyObject {
    func framebufferDidResize(_ size: CGSize)
    func framebufferDidUpdate()
    func cursorDidChange(_ cursor: NSCursor)
}

public struct CredentialPrompt: Identifiable, Equatable {
    public let id = UUID()
    public let request: CredentialRequest
    public var username: String
    /// Saved connections can store the password in the Keychain.
    public let canRemember: Bool
    public let rememberByDefault: Bool
    public let message: String?
}

public struct TrustPrompt: Identifiable, Equatable {
    public let id = UUID()
    public let previousFingerprint: String
    public let newFingerprint: String
}

/// Owns one remote desktop session: connection lifecycle, credentials, reconnects, screenshots, clipboard
/// participation and keyboard translation. UI-independent so it can be tested with a mock engine.
@MainActor
@Observable
public final class SessionController {
    public enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting(attempt: Int, maxAttempts: Int, secondsRemaining: Int)
        case disconnected
        case failed(EngineError)

        public var isConnected: Bool { self == .connected }
    }

    public let sessionID = UUID()
    public let connectionID: UUID?
    public private(set) var displayName: String
    public private(set) var target: ConnectionTarget
    public private(set) var phase: Phase = .idle
    public private(set) var framebufferSize: CGSize?
    public private(set) var securityInfo = SessionSecurityInfo()
    public private(set) var statusMessage: String?
    /// Short-lived feedback for the viewer (e.g. "Screenshot saved"), with a timestamp so repeats re-trigger.
    public private(set) var notice: (message: String, date: Date)?

    public var preferences: ConnectionPreferences {
        didSet { preferencesDidChange(from: oldValue) }
    }

    public var credentialPrompt: CredentialPrompt?
    public var trustPrompt: TrustPrompt?

    @ObservationIgnored public weak var renderer: FramebufferRenderer?

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let credentialStore: CredentialStore
    @ObservationIgnored private let screenshotStore: ScreenshotStore
    @ObservationIgnored private weak var clipboard: ClipboardCoordinator?
    @ObservationIgnored private let engineFactory: @MainActor (ConnectionTarget) -> RemoteDesktopEngine

    @ObservationIgnored private var engine: RemoteDesktopEngine?
    @ObservationIgnored private var translator: KeyTranslator
    @ObservationIgnored private var pointerButtons: PointerButtons = []
    @ObservationIgnored private var isFocused = false

    @ObservationIgnored private var oneShotCredentials: SessionCredentials?
    @ObservationIgnored private var forcePrompt = false
    @ObservationIgnored private var pendingRemember: SessionCredentials?
    @ObservationIgnored private var credentialContinuation: CheckedContinuation<SessionCredentials?, Never>?
    @ObservationIgnored private var trustContinuation: CheckedContinuation<Bool, Never>?

    @ObservationIgnored private var userRequestedDisconnect = false
    @ObservationIgnored private var hasConnectedOnce = false
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var autoScreenshotTask: Task<Void, Never>?
    @ObservationIgnored private var didAutoScreenshot = false

    public init(connection: SavedConnection?,
                quickConnectTarget: ConnectionTarget? = nil,
                quickConnectName: String? = nil,
                quickConnectPreferences: ConnectionPreferences = .default,
                oneShotCredentials: SessionCredentials? = nil,
                modelContext: ModelContext,
                credentialStore: CredentialStore,
                screenshotStore: ScreenshotStore,
                clipboard: ClipboardCoordinator?,
                engineFactory: @escaping @MainActor (ConnectionTarget) -> RemoteDesktopEngine = { RoyalVNCEngine(target: $0) }) {
        precondition(connection != nil || quickConnectTarget != nil, "A session needs a saved connection or a target")

        let preferences = connection?.preferences ?? quickConnectPreferences
        let target = connection?.target ?? quickConnectTarget!

        self.connectionID = connection?.id
        self.displayName = connection?.name ?? quickConnectName ?? HostAddress.display(host: target.host, port: target.port)
        self.target = target
        self.preferences = preferences
        self.oneShotCredentials = oneShotCredentials
        self.modelContext = modelContext
        self.credentialStore = credentialStore
        self.screenshotStore = screenshotStore
        self.clipboard = clipboard
        self.engineFactory = engineFactory
        self.translator = KeyTranslator(mapping: preferences.keyboardMapping)
    }

    public var savedConnection: SavedConnection? {
        connectionID.flatMap { modelContext.connection(withID: $0) }
    }

    public var isQuickConnect: Bool { connectionID == nil }

    // MARK: - Lifecycle
    public func connect() {
        reconnectTask?.cancel()
        reconnectTask = nil

        startEngine()
    }

    /// Reconnect requested by the user (button/menu). Forces a credential prompt after an auth failure.
    public func reconnect() {
        if case .failed(let error) = phase, error.kind == .authenticationFailed {
            forcePrompt = true
        }

        reconnectAttempt = 0
        engine?.disconnect()
        connect()
    }

    public func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        autoScreenshotTask?.cancel()

        if phase.isConnected, preferences.autoScreenshot, preferences.refreshScreenshotOnDisconnect {
            captureScreenshot(isAutomatic: true)
        }

        releaseAllKeys()
        userRequestedDisconnect = true
        cancelPendingPrompts()

        if let engine, engine.status.isActive {
            engine.disconnect()
        } else if case .reconnecting = phase {
            phase = .disconnected
        }
    }

    /// Called when the window closes. Ends the session for good.
    public func close() {
        disconnect()
        clipboard?.unregister(self)
        renderer = nil
    }

    private func startEngine() {
        let engine = engineFactory(target)
        engine.delegate = self

        self.engine = engine
        userRequestedDisconnect = false
        didAutoScreenshot = false
        statusMessage = nil
        phase = .connecting

        clipboard?.register(self)
        engine.connect()
    }

    // MARK: - Framebuffer access for the renderer
    public var framebufferSurface: IOSurface? {
        engine?.framebufferSurface
    }

    public func framebufferImage() -> CGImage? {
        engine?.captureFramebuffer()
    }

    // MARK: - Input
    public func keyDown(_ input: KeyInput) {
        send(translator.keyDown(input))
    }

    public func keyUp(_ input: KeyInput) {
        send(translator.keyUp(input))
    }

    public func modifiersChanged(keyCode: UInt16, modifierFlags: UInt) {
        send(translator.modifierChanged(keyCode: keyCode, modifierFlags: modifierFlags))
    }

    /// A ⌘-combination the viewer decided to forward.
    public func keyEquivalent(_ input: KeyInput) {
        send(translator.keyEquivalent(input))
    }

    /// A ⌘-combination was handled by the viewer; make sure the remote never sees its ⌘ press.
    public func keyEquivalentHandledLocally() {
        translator.discardPendingModifiers()
    }

    public func sendCombination(_ combination: SpecialKeyCombination) {
        send(translator.combination(combination.keysyms))
    }

    /// Releases every key held on the remote side (focus loss, disconnect) so nothing stays stuck.
    public func releaseAllKeys() {
        let actions = translator.releaseAll()

        if engine?.status == .connected {
            send(actions)
        }

        if !pointerButtons.isEmpty, let engine, engine.status == .connected {
            pointerButtons = []
            engine.sendPointer(at: lastPointerPosition, buttons: [])
        }
    }

    @ObservationIgnored private var lastPointerPosition: CGPoint = .zero

    public func pointer(at point: CGPoint, buttons: PointerButtons) {
        guard let engine, engine.status == .connected else { return }

        if buttons != pointerButtons {
            send(translator.flushPendingModifiers())
        }

        pointerButtons = buttons
        lastPointerPosition = point
        engine.sendPointer(at: point, buttons: buttons)
    }

    public func scroll(_ direction: ScrollDirection, steps: Int, at point: CGPoint) {
        guard let engine, engine.status == .connected else { return }

        send(translator.flushPendingModifiers())
        engine.sendScroll(direction, steps: steps, at: point, buttons: pointerButtons)
    }

    private func send(_ actions: [KeyAction]) {
        guard let engine, engine.status == .connected else { return }

        for action in actions {
            engine.sendKey(action.keysym, isDown: action.isDown)
        }
    }

    // MARK: - Focus
    public func windowDidBecomeKey() {
        isFocused = true

        if phase.isConnected {
            clipboard?.sessionFocused(self)
        }
    }

    public func windowDidResignKey() {
        isFocused = false
        releaseAllKeys()
        clipboard?.sessionUnfocused(self)
    }

    // MARK: - Credentials UI
    public func submitCredentials(username: String, password: String, remember: Bool) {
        let credentials = SessionCredentials(username: username, password: password)

        pendingRemember = remember ? credentials : nil
        credentialPrompt = nil
        credentialContinuation?.resume(returning: credentials)
        credentialContinuation = nil
    }

    public func cancelCredentials() {
        credentialPrompt = nil
        credentialContinuation?.resume(returning: nil)
        credentialContinuation = nil
    }

    public func resolveTrust(_ trusted: Bool) {
        trustPrompt = nil
        trustContinuation?.resume(returning: trusted)
        trustContinuation = nil
    }

    private func cancelPendingPrompts() {
        if credentialContinuation != nil {
            cancelCredentials()
        }

        if trustContinuation != nil {
            resolveTrust(false)
        }
    }

    // MARK: - Screenshots
    public enum ScreenshotError: LocalizedError {
        case notConnected
        case noFramebuffer

        public var errorDescription: String? {
            switch self {
                case .notConnected: "Connect to the remote computer to take a screenshot."
                case .noFramebuffer: "The remote screen has not been received yet."
            }
        }
    }

    /// Captures the remote framebuffer (never the local screen) and stores it for the saved connection.
    @discardableResult
    public func captureScreenshot(isAutomatic: Bool) -> Result<CGImage, Error> {
        let result = makeScreenshot(isAutomatic: isAutomatic)

        if !isAutomatic {
            switch result {
                case .success:
                    notice = (isQuickConnect
                              ? "Quick Connect sessions are not saved — save the connection to keep screenshots"
                              : "Screenshot saved", Date())
                case .failure(let error):
                    notice = (error.localizedDescription, Date())
            }
        }

        return result
    }

    private func makeScreenshot(isAutomatic: Bool) -> Result<CGImage, Error> {
        guard phase.isConnected else { return .failure(ScreenshotError.notConnected) }
        guard let image = engine?.captureFramebuffer() else { return .failure(ScreenshotError.noFramebuffer) }

        if let connection = savedConnection {
            do {
                try screenshotStore.save(image, for: connection, isAutomatic: isAutomatic, in: modelContext)
            } catch {
                return .failure(error)
            }
        }

        return .success(image)
    }

    private func scheduleAutomaticScreenshot() {
        guard preferences.autoScreenshot, !didAutoScreenshot, savedConnection != nil else { return }

        didAutoScreenshot = true
        autoScreenshotTask?.cancel()
        // Wait for the initial full-screen update to finish painting before capturing
        autoScreenshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            guard !Task.isCancelled, let self, self.phase.isConnected else { return }

            self.captureScreenshot(isAutomatic: true)
        }
    }

    // MARK: - Preferences
    private func preferencesDidChange(from oldValue: ConnectionPreferences) {
        guard preferences != oldValue else { return }

        if preferences.keyboardMapping != oldValue.keyboardMapping {
            // Release with the old mapping before switching so no modifier stays down remotely
            releaseAllKeys()
            translator.mapping = preferences.keyboardMapping
        }

        if preferences.clipboardSync, !oldValue.clipboardSync, isFocused, phase.isConnected {
            clipboard?.sessionFocused(self)
        }

        if let connection = savedConnection {
            connection.preferences = preferences
            try? modelContext.save()
        }
    }

    // MARK: - Status persistence
    private func recordOutcome(_ outcome: ConnectionOutcome, message: String?) {
        guard let connection = savedConnection else { return }

        connection.lastOutcome = outcome
        connection.lastStatusMessage = message

        if outcome == .connected {
            connection.lastConnectedAt = Date()
        }

        try? modelContext.save()
    }

    // MARK: - Disconnect handling
    private func engineDisconnected(with error: EngineError?) {
        autoScreenshotTask?.cancel()
        engine = nil
        translator = KeyTranslator(mapping: preferences.keyboardMapping)
        pointerButtons = []

        if userRequestedDisconnect {
            phase = .disconnected
            statusMessage = nil

            return
        }

        if let error {
            switch error.kind {
                case .authenticationFailed:
                    forcePrompt = true
                    pendingRemember = nil
                    recordOutcome(.authenticationFailed, message: error.message)
                case .cancelledByUser:
                    recordOutcome(.cancelled, message: error.message)
                default:
                    recordOutcome(.failed, message: error.message)
            }
        }

        let isTransient = error?.isTransient ?? true

        if preferences.autoReconnect, hasConnectedOnce, isTransient,
           reconnectAttempt < preferences.maxReconnectAttempts {
            scheduleReconnect(after: error)
        } else if let error {
            phase = .failed(error)
        } else {
            phase = .disconnected
            statusMessage = "The remote computer closed the session."
        }
    }

    private func scheduleReconnect(after error: EngineError?) {
        reconnectAttempt += 1

        let attempt = reconnectAttempt
        let maxAttempts = preferences.maxReconnectAttempts
        let delay = Self.reconnectDelay(forAttempt: attempt)

        statusMessage = error?.message
        phase = .reconnecting(attempt: attempt, maxAttempts: maxAttempts, secondsRemaining: delay)

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            for remaining in stride(from: delay, to: 0, by: -1) {
                guard let self, !Task.isCancelled else { return }

                self.phase = .reconnecting(attempt: attempt, maxAttempts: maxAttempts, secondsRemaining: remaining)

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            guard let self, !Task.isCancelled else { return }

            self.startEngine()
        }
    }

    /// Exponential backoff: 2, 4, 8, 16, 30, 30, … seconds.
    public nonisolated static func reconnectDelay(forAttempt attempt: Int) -> Int {
        min(30, 1 << min(max(attempt, 1), 5))
    }
}

// MARK: - RemoteDesktopEngineDelegate
extension SessionController: RemoteDesktopEngineDelegate {
    public func engine(_ engine: RemoteDesktopEngine, didChangeStatus status: EngineStatus) {
        guard engine === self.engine else { return }

        securityInfo = engine.securityInfo

        switch status {
            case .idle:
                break
            case .connecting:
                if case .reconnecting = phase {
                    // Keep showing the reconnect state until it succeeds or fails
                } else {
                    phase = .connecting
                }
            case .connected:
                phase = .connected
                hasConnectedOnce = true
                reconnectAttempt = 0
                forcePrompt = false
                statusMessage = nil
                recordOutcome(.connected, message: nil)
                rememberCredentialsIfRequested()

                if isFocused {
                    clipboard?.sessionFocused(self)
                }
            case .disconnected(let error):
                engineDisconnected(with: error)
        }
    }

    public func engine(_ engine: RemoteDesktopEngine, needsCredentialsFor request: CredentialRequest) async -> SessionCredentials? {
        // 1. Credentials typed into Quick Connect, used once
        if let credentials = oneShotCredentials {
            oneShotCredentials = nil

            if request.kind == .password || !credentials.username.isEmpty {
                return credentials
            }
        }

        let connection = savedConnection
        let savedUsername = connection?.username ?? ""

        // 2. Keychain, unless the last attempt with them failed
        if !forcePrompt, let reference = connection?.credentialReference,
           let password = try? await CredentialManager.loadPassword(reference: reference, from: credentialStore) {
            if request.kind == .password || !savedUsername.isEmpty {
                return SessionCredentials(username: savedUsername, password: password)
            }
        }

        // 3. Ask the user
        let message = forcePrompt ? "The server rejected the credentials. Please try again." : nil
        forcePrompt = false

        return await withCheckedContinuation { continuation in
            credentialContinuation?.resume(returning: nil)
            credentialContinuation = continuation
            credentialPrompt = CredentialPrompt(request: request,
                                                username: savedUsername,
                                                canRemember: connection != nil,
                                                rememberByDefault: true,
                                                message: message)
        }
    }

    public func engine(_ engine: RemoteDesktopEngine, shouldTrustServerKey fingerprint: String) async -> Bool {
        // Quick Connect has nowhere to remember keys; the fingerprint is shown in the session info instead.
        guard let connection = savedConnection else { return true }

        guard let known = connection.trustedServerKeyFingerprint else {
            connection.trustedServerKeyFingerprint = fingerprint
            try? modelContext.save()

            return true
        }

        if known == fingerprint {
            return true
        }

        let trusted = await withCheckedContinuation { continuation in
            trustContinuation?.resume(returning: false)
            trustContinuation = continuation
            trustPrompt = TrustPrompt(previousFingerprint: known, newFingerprint: fingerprint)
        }

        if trusted {
            connection.trustedServerKeyFingerprint = fingerprint
            try? modelContext.save()
        }

        return trusted
    }

    public func engine(_ engine: RemoteDesktopEngine, didResizeFramebuffer size: CGSize) {
        framebufferSize = size
        renderer?.framebufferDidResize(size)
    }

    public func engineDidUpdateFramebuffer(_ engine: RemoteDesktopEngine) {
        renderer?.framebufferDidUpdate()

        if phase.isConnected {
            scheduleAutomaticScreenshot()
        }
    }

    public func engine(_ engine: RemoteDesktopEngine, didUpdateCursor cursor: NSCursor) {
        renderer?.cursorDidChange(cursor)
    }

    public func engine(_ engine: RemoteDesktopEngine, didReceiveClipboardText text: String) {
        clipboard?.remoteTextReceived(text, from: self)
    }

    private func rememberCredentialsIfRequested() {
        guard let credentials = pendingRemember, let connection = savedConnection else {
            pendingRemember = nil
            return
        }

        pendingRemember = nil

        if !credentials.username.isEmpty, credentials.username != connection.username {
            connection.username = credentials.username
        }

        let reference = CredentialManager.reference(for: connection)
        let label = CredentialManager.label(for: connection)
        let store = credentialStore

        Task { @MainActor [weak self] in
            do {
                try await CredentialManager.storePassword(credentials.password, reference: reference, label: label, in: store)
                connection.credentialReference = reference
                try self?.modelContext.save()
            } catch {
                self?.statusMessage = "Connected, but the password could not be saved: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - ClipboardParticipant
extension SessionController: ClipboardParticipant {
    public var clipboardSessionID: UUID { sessionID }

    public var isClipboardSyncEnabled: Bool { preferences.clipboardSync }

    public var isReadyForClipboard: Bool { phase.isConnected }

    public func sendClipboardTextToRemote(_ text: String) {
        engine?.sendClipboardText(text)
    }
}
