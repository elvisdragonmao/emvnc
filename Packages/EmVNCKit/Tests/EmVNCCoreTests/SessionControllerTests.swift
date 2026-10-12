import AppKit
import Foundation
import IOSurface
import SwiftData
import Testing
@testable import EmVNCCore

/// Scriptable engine: tests drive connection events and inspect what the session sent.
@MainActor
final class MockEngine: RemoteDesktopEngine {
    weak var delegate: RemoteDesktopEngineDelegate?
    private(set) var status: EngineStatus = .idle
    var framebufferSize: CGSize? = CGSize(width: 800, height: 600)
    var securityInfo = SessionSecurityInfo()
    var framebufferSurface: IOSurface? { nil }

    private(set) var keys: [KeyAction] = []
    private(set) var clipboard: [String] = []
    private(set) var disconnectCalls = 0

    func connect() {
        set(.connecting)
    }

    func disconnect() {
        disconnectCalls += 1
        set(.disconnected(nil))
    }

    func sendPointer(at point: CGPoint, buttons: PointerButtons) {}
    func sendScroll(_ direction: ScrollDirection, steps: Int, at point: CGPoint, buttons: PointerButtons) {}

    func sendKey(_ keysym: UInt32, isDown: Bool) {
        keys.append(.init(keysym: keysym, isDown: isDown))
    }

    func sendClipboardText(_ text: String) {
        clipboard.append(text)
    }

    func captureFramebuffer() -> CGImage? {
        ScreenshotStoreTests.makeImage()
    }

    func set(_ status: EngineStatus) {
        self.status = status
        delegate?.engine(self, didChangeStatus: status)
    }

    func requestCredentials(_ kind: CredentialRequest.Kind = .password) async -> SessionCredentials? {
        await delegate?.engine(self, needsCredentialsFor: CredentialRequest(kind: kind, methodName: "Test"))
    }

    func requestTrust(_ fingerprint: String) async -> Bool {
        await delegate?.engine(self, shouldTrustServerKey: fingerprint) ?? false
    }
}

@MainActor
final class SessionHarness {
    let container: ModelContainer
    let store = InMemoryCredentialStore()
    let screenshots: ScreenshotStore
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let connection: SavedConnection
    var engines: [MockEngine] = []
    var session: SessionController!

    init(preferences: ConnectionPreferences = .default) throws {
        container = try Persistence.makeContainer(inMemory: true)
        screenshots = ScreenshotStore(directory: directory)
        connection = SavedConnection(name: "Test", host: "test.local", authenticationMethod: .vncPassword,
                                     preferences: preferences)
        container.mainContext.insert(connection)

        session = SessionController(connection: connection,
                                    modelContext: container.mainContext,
                                    credentialStore: store,
                                    screenshotStore: screenshots,
                                    clipboard: nil,
                                    engineFactory: { [unowned self] _ in
                                        let engine = MockEngine()
                                        self.engines.append(engine)
                                        return engine
                                    })
    }

    var engine: MockEngine { engines.last! }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Waits until the session shows a credential prompt.
    func waitForPrompt() async throws -> CredentialPrompt {
        for _ in 0..<200 {
            if let prompt = session.credentialPrompt { return prompt }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        throw CancellationError()
    }
}

@Suite("Session lifecycle")
@MainActor
struct SessionControllerTests {
    @Test func storedKeychainPasswordIsUsedWithoutPrompting() async throws {
        let harness = try SessionHarness()
        try CredentialManager.savePassword("stored", for: harness.connection, in: harness.store)

        harness.session.connect()
        let credentials = await harness.engine.requestCredentials()

        #expect(credentials?.password == "stored")
        #expect(harness.session.credentialPrompt == nil)
    }

    @Test func missingPasswordPromptsAndRemembersOnlyAfterSuccess() async throws {
        let harness = try SessionHarness()
        harness.session.connect()

        let request = Task { await harness.engine.requestCredentials() }
        let prompt = try await harness.waitForPrompt()

        #expect(prompt.canRemember)
        #expect(prompt.message == nil)

        harness.session.submitCredentials(username: "", password: "typed", remember: true)
        #expect(await request.value?.password == "typed")
        #expect(harness.store.passwords.isEmpty)

        harness.engine.set(.connected)

        for _ in 0..<100 where harness.store.passwords.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(harness.store.passwords[harness.connection.id.uuidString] == "typed")
        #expect(harness.connection.hasSavedPassword)
    }

    @Test func authenticationFailureAsksAgainWithAnExplanation() async throws {
        let harness = try SessionHarness()
        try CredentialManager.savePassword("wrong", for: harness.connection, in: harness.store)

        harness.session.connect()
        _ = await harness.engine.requestCredentials()
        harness.engine.set(.disconnected(EngineError(kind: .authenticationFailed, message: "Bad password")))

        #expect(harness.session.phase == .failed(EngineError(kind: .authenticationFailed, message: "Bad password")))
        #expect(harness.connection.lastOutcome == .authenticationFailed)

        // Retrying must not silently reuse the rejected Keychain password
        harness.session.reconnect()
        let request = Task { await harness.engine.requestCredentials() }
        let prompt = try await harness.waitForPrompt()

        #expect(prompt.message != nil)

        harness.session.cancelCredentials()
        #expect(await request.value == nil)
    }

    @Test func connectingRecordsStatusAndTimestamp() throws {
        let harness = try SessionHarness()
        harness.session.connect()
        harness.engine.set(.connected)

        #expect(harness.session.phase == .connected)
        #expect(harness.connection.lastOutcome == .connected)
        #expect(harness.connection.lastConnectedAt != nil)
    }

    @Test func serverKeyIsTrustedOnFirstUseAndChangesNeedApproval() async throws {
        let harness = try SessionHarness()
        harness.session.connect()

        #expect(await harness.engine.requestTrust("aa:bb"))
        #expect(harness.connection.trustedServerKeyFingerprint == "aa:bb")
        #expect(await harness.engine.requestTrust("aa:bb"))

        let changed = Task { await harness.engine.requestTrust("cc:dd") }

        for _ in 0..<200 where harness.session.trustPrompt == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(harness.session.trustPrompt?.previousFingerprint == "aa:bb")
        harness.session.resolveTrust(false)

        #expect(await changed.value == false)
        #expect(harness.connection.trustedServerKeyFingerprint == "aa:bb")
    }

    @Test func networkDropsReconnectAutomaticallyWhenEnabled() throws {
        var preferences = ConnectionPreferences()
        preferences.autoReconnect = true
        let harness = try SessionHarness(preferences: preferences)

        harness.session.connect()
        harness.engine.set(.connected)
        harness.engine.set(.disconnected(EngineError(kind: .network, message: "Dropped")))

        guard case .reconnecting(let attempt, let maxAttempts, _) = harness.session.phase else {
            Issue.record("Expected reconnecting, got \(harness.session.phase)")
            return
        }

        #expect(attempt == 1)
        #expect(maxAttempts == 5)

        // The user can stop it
        harness.session.disconnect()
        #expect(harness.session.phase == .disconnected)
    }

    @Test func networkDropsDoNotReconnectWhenDisabled() throws {
        let harness = try SessionHarness()

        harness.session.connect()
        harness.engine.set(.connected)
        harness.engine.set(.disconnected(EngineError(kind: .network, message: "Dropped")))

        #expect(harness.session.phase == .failed(EngineError(kind: .network, message: "Dropped")))
    }

    @Test func userDisconnectIsCleanAndCapturesAThumbnail() throws {
        let harness = try SessionHarness()

        harness.session.connect()
        harness.engine.set(.connected)
        harness.session.disconnect()

        #expect(harness.session.phase == .disconnected)
        #expect(harness.connection.lastScreenshotFileName != nil)
    }

    @Test func focusLossReleasesHeldKeys() throws {
        let harness = try SessionHarness()
        harness.session.connect()
        harness.engine.set(.connected)

        let shift = DeviceModifierMask.shift | DeviceModifierMask.leftShift
        harness.session.modifiersChanged(keyCode: MacKeyCode.shift, modifierFlags: shift)
        harness.session.keyDown(KeyInput(keyCode: MacKeyCode.ansiA, charactersIgnoringModifiers: "A"))
        harness.session.windowDidResignKey()

        #expect(harness.engine.keys == [ .down(KeySymbols.shiftL), .down(0x41), .up(0x41), .up(KeySymbols.shiftL) ])
    }

    @Test func changingTheMappingReleasesKeysAndPersists() throws {
        let harness = try SessionHarness()
        harness.session.connect()
        harness.engine.set(.connected)

        harness.session.modifiersChanged(keyCode: MacKeyCode.option, modifierFlags: DeviceModifierMask.option | DeviceModifierMask.leftOption)
        harness.session.keyDown(KeyInput(keyCode: MacKeyCode.leftArrow, charactersIgnoringModifiers: nil))
        harness.session.preferences.keyboardProfile = .pcWithMacShortcuts

        #expect(harness.engine.keys.suffix(2) == [ .up(KeySymbols.left), .up(KeySymbols.altL) ])
        #expect(harness.connection.preferences.keyboardProfile == .pcWithMacShortcuts)
    }

    @Test func reconnectBackoff() {
        #expect((1...7).map(SessionController.reconnectDelay(forAttempt:)) == [ 2, 4, 8, 16, 30, 30, 30 ])
    }
}
