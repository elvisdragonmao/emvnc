import AppKit
import CoreGraphics
import IOSurface
@preconcurrency import RoyalVNCKit

/// `RemoteDesktopEngine` backed by (the emvnc fork of) RoyalVNCKit. RoyalVNCKit reports events on its own
/// queues; this adapter forwards them to the main actor.
@MainActor
public final class RoyalVNCEngine: RemoteDesktopEngine {
    public weak var delegate: RemoteDesktopEngineDelegate?

    public private(set) var status: EngineStatus = .idle
    public private(set) var framebufferSize: CGSize?
    /// Read live from the connection: some details (e.g. Extended Clipboard support) arrive after connecting.
    public var securityInfo: SessionSecurityInfo {
        if let connection {
            refreshSecurityInfo(from: connection)
        }

        return lastSecurityInfo
    }

    private var lastSecurityInfo = SessionSecurityInfo()

    private let target: ConnectionTarget
    private var connection: VNCConnection?
    private var bridge: DelegateBridge?
    private var framebuffer: VNCFramebuffer?
    private var pressedButtons: PointerButtons = []

    public init(target: ConnectionTarget) {
        self.target = target
    }

    public func connect() {
        guard !status.isActive else { return }

        let settings = VNCConnection.Settings(isDebugLoggingEnabled: false,
                                              hostname: target.host,
                                              port: UInt16(clamping: target.port),
                                              isShared: target.isShared,
                                              isScalingEnabled: false,
                                              useDisplayLink: false,
                                              inputMode: .forwardKeyboardShortcutsEvenIfInUseLocally,
                                              // emvnc syncs the clipboard itself (scoped to the focused session)
                                              isClipboardRedirectionEnabled: false,
                                              colorDepth: target.colorDepth.royalColorDepth,
                                              frameEncodings: .default)

        let connection = VNCConnection(settings: settings, logger: SilentLogger())
        let bridge = DelegateBridge(engine: self)

        connection.delegate = bridge
        connection.extendedDelegate = bridge
        connection.securityTypePreference = target.authenticationMethod.securityTypes

        self.connection = connection
        self.bridge = bridge
        self.framebuffer = nil
        self.framebufferSize = nil
        self.pressedButtons = []
        self.lastSecurityInfo = SessionSecurityInfo()

        updateStatus(.connecting)
        connection.connect()
    }

    public func disconnect() {
        guard let connection else { return }

        connection.disconnect()
    }

    public func sendPointer(at point: CGPoint, buttons: PointerButtons) {
        guard let connection, status == .connected else { return }

        let (x, y) = clamped(point)

        // RoyalVNCKit tracks button state internally; translate the full button set into transitions.
        for (button, vncButton) in Self.buttonMap {
            let wasDown = pressedButtons.contains(button)
            let isDown = buttons.contains(button)

            if isDown && !wasDown {
                connection.mouseButtonDown(vncButton, x: x, y: y)
            } else if !isDown && wasDown {
                connection.mouseButtonUp(vncButton, x: x, y: y)
            }
        }

        if buttons == pressedButtons {
            connection.mouseMove(x: x, y: y)
        }

        pressedButtons = buttons
    }

    public func sendScroll(_ direction: ScrollDirection, steps: Int, at point: CGPoint, buttons: PointerButtons) {
        guard let connection, status == .connected, steps > 0 else { return }

        let (x, y) = clamped(point)

        let wheel: VNCMouseWheel = switch direction {
            case .up: .up
            case .down: .down
            case .left: .left
            case .right: .right
        }

        connection.mouseWheel(wheel, x: x, y: y, steps: UInt32(steps))
    }

    public func sendKey(_ keysym: UInt32, isDown: Bool) {
        guard let connection, status == .connected else { return }

        if isDown {
            connection.keyDown(VNCKeyCode(keysym))
        } else {
            connection.keyUp(VNCKeyCode(keysym))
        }
    }

    public func sendClipboardText(_ text: String) {
        guard let connection, status == .connected else { return }

        connection.sendClipboardText(text)
    }

    public var framebufferSurface: IOSurface? {
        framebuffer?.ioSurface
    }

    public func captureFramebuffer() -> CGImage? {
        framebuffer?.cgImage
    }

    // MARK: - Internals
    private static let buttonMap: [(PointerButtons, VNCMouseButton)] = [
        (.left, .left), (.middle, .middle), (.right, .right)
    ]

    private func clamped(_ point: CGPoint) -> (UInt16, UInt16) {
        let size = framebufferSize ?? .zero
        let x = min(max(0, point.x.rounded(.down)), max(0, size.width - 1))
        let y = min(max(0, point.y.rounded(.down)), max(0, size.height - 1))

        return (UInt16(clamping: Int(x)), UInt16(clamping: Int(y)))
    }

    private func updateStatus(_ newStatus: EngineStatus) {
        guard newStatus != status else { return }

        status = newStatus
        delegate?.engine(self, didChangeStatus: newStatus)
    }

    fileprivate func refreshSecurityInfo(from connection: VNCConnection) {
        lastSecurityInfo = SessionSecurityInfo(
            negotiatedMethod: connection.negotiatedSecurityType.map(VNCSecurityTypeInfo.name(of:)),
            offeredMethods: connection.offeredSecurityTypes.map(VNCSecurityTypeInfo.name(of:)),
            isEncrypted: connection.isSessionEncrypted,
            serverKeyFingerprint: connection.serverKeyFingerprint,
            desktopName: connection.desktopName,
            usesExtendedClipboard: connection.isExtendedClipboardActive
        )
    }

    // MARK: Events from the bridge (already on the main actor)
    fileprivate func connectionStateChanged(_ connection: VNCConnection, state: VNCConnection.ConnectionState) {
        guard connection === self.connection else { return }

        refreshSecurityInfo(from: connection)

        switch state.status {
            case .connecting:
                updateStatus(.connecting)
            case .connected:
                updateStatus(.connected)
            case .disconnecting:
                break
            case .disconnected:
                let error = state.error.map(Self.engineError(from:))

                self.connection = nil
                self.bridge = nil
                self.pressedButtons = []

                updateStatus(.disconnected(error))
        }
    }

    fileprivate func framebufferChanged(_ framebuffer: VNCFramebuffer) {
        self.framebuffer = framebuffer

        let size = framebuffer.cgSize

        if size != framebufferSize {
            framebufferSize = size
            delegate?.engine(self, didResizeFramebuffer: size)
        }
    }

    fileprivate func framebufferUpdated() {
        delegate?.engineDidUpdateFramebuffer(self)
    }

    fileprivate func cursorUpdated(_ cursor: NSCursor) {
        delegate?.engine(self, didUpdateCursor: cursor)
    }

    fileprivate func clipboardReceived(_ text: String) {
        if let connection {
            refreshSecurityInfo(from: connection)
        }

        delegate?.engine(self, didReceiveClipboardText: text)
    }

    fileprivate func credentials(for authenticationType: VNCAuthenticationType) async -> VNCCredential? {
        guard let delegate else { return nil }

        let methodName = connection?.negotiatedSecurityType.map(VNCSecurityTypeInfo.name(of:)) ?? "VNC"

        let request = CredentialRequest(kind: authenticationType.requiresUsername ? .usernameAndPassword : .password,
                                        methodName: methodName)

        guard let credentials = await delegate.engine(self, needsCredentialsFor: request) else {
            return nil
        }

        if authenticationType.requiresUsername {
            return VNCUsernamePasswordCredential(username: credentials.username, password: credentials.password)
        }

        return VNCPasswordCredential(password: credentials.password)
    }

    fileprivate func shouldTrust(fingerprint: String) async -> Bool {
        guard let delegate else { return true }

        return await delegate.engine(self, shouldTrustServerKey: fingerprint)
    }

    static func engineError(from error: Error) -> EngineError {
        let message = (error as? VNCError)?.localizedDescription ?? error.localizedDescription

        guard let vncError = error as? VNCError else {
            return .init(kind: .network, message: message)
        }

        switch vncError {
            case .authentication(let authError):
                switch authError {
                    case .noAuthenticationDataProvided, .serverIdentityRejected:
                        return .init(kind: .cancelledByUser, message: message)
                    case .noMutuallySupportedSecurityType, .serverOfferedNoAuthTypes, .clientCouldNotDecideOnSecurityType:
                        return .init(kind: .unsupportedSecurity, message: message)
                    default:
                        return .init(kind: .authenticationFailed, message: message)
                }
            case .connection:
                return .init(kind: .network, message: Self.networkMessage(for: vncError) ?? message)
            case .protocol:
                return .init(kind: .protocolError, message: message)
        }
    }

    /// Turns Network.framework errors into short, actionable messages.
    static func networkMessage(for error: VNCError) -> String? {
        guard case .connection(let connectionError) = error else { return nil }

        switch connectionError {
            case .closed:
                return "The server closed the connection."
            case .cancelled:
                return "The connection was cancelled."
            default:
                break
        }

        let text = error.localizedDescription.lowercased()

        if text.contains("refused") {
            return "Connection refused. Check that a VNC server is running and the port is correct."
        }

        if text.contains("timed out") || text.contains("timeout") {
            return "The connection timed out. Check the address, network, and firewall."
        }

        if text.contains("unreachable") || text.contains("no route") {
            return "The host is unreachable. Check the network connection."
        }

        if text.contains("nodename nor servname") || text.contains("nosuchrecord") || text.contains("-65554") || text.contains("dns") {
            return "The host name could not be resolved."
        }

        return nil
    }
}

// MARK: - Delegate bridge
/// Receives RoyalVNCKit callbacks on its queues and forwards them to the engine on the main actor.
private final class DelegateBridge: NSObject, VNCConnectionDelegate, VNCConnectionExtendedDelegate, @unchecked Sendable {
    weak var engine: RoyalVNCEngine?

    /// Coalesces framebuffer update notifications so the main thread sees at most one pending update.
    private let updatePending = PendingFlag()

    init(engine: RoyalVNCEngine) {
        self.engine = engine
    }

    func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        Task { @MainActor [weak engine] in
            engine?.connectionStateChanged(connection, state: connectionState)
        }
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) {
        Task { @MainActor [weak engine] in
            let credential = await engine?.credentials(for: authenticationType)
            completion(credential)
        }
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        Task { @MainActor [weak engine] in
            engine?.framebufferChanged(framebuffer)
        }
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        Task { @MainActor [weak engine] in
            engine?.framebufferChanged(framebuffer)
        }
    }

    func connection(_ connection: VNCConnection,
                    didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        guard updatePending.setIfClear() else { return }

        DispatchQueue.main.async { [weak engine, updatePending] in
            updatePending.clear()

            MainActor.assumeIsolated {
                engine?.framebufferUpdated()
            }
        }
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        Task { @MainActor [weak engine] in
            engine?.cursorUpdated(cursor.nsCursor)
        }
    }

    func connection(_ connection: VNCConnection, didReceiveClipboardText text: String) {
        Task { @MainActor [weak engine] in
            engine?.clipboardReceived(text)
        }
    }

    func connection(_ connection: VNCConnection,
                    shouldTrustServerKeyWithFingerprint fingerprint: String,
                    completion: @escaping (Bool) -> Void) {
        Task { @MainActor [weak engine] in
            let trusted = await engine?.shouldTrust(fingerprint: fingerprint) ?? false
            completion(trusted)
        }
    }
}

private final class PendingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// Returns true if the flag was clear and is now set.
    func setIfClear() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isSet else { return false }

        isSet = true

        return true
    }

    func clear() {
        lock.lock()
        isSet = false
        lock.unlock()
    }
}

/// Keeps RoyalVNCKit quiet; it can log protocol details, and emvnc never wants credentials in logs.
private final class SilentLogger: NSObject, VNCLogger {
    var isDebugLoggingEnabled = false

    func logDebug(_ message: @autoclosure () -> String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}

private extension ColorDepth {
    var royalColorDepth: VNCConnection.Settings.ColorDepth {
        switch self {
            case .depth24: .depth24Bit
            case .depth16: .depth16Bit
            case .depth8: .depth8Bit
        }
    }
}

private extension Array where Element == VNCFrameEncodingType {
    static var `default`: [VNCFrameEncodingType] {
        [ .tight, .zlib, .zrle, .hextile, .coRRE, .rre ]
    }
}
