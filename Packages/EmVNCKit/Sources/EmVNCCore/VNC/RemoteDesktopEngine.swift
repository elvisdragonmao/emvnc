import AppKit
import CoreGraphics
import IOSurface

/// Engine-neutral description of a remote desktop session. The UI and session logic only talk to this
/// protocol; `RoyalVNCEngine` is the RoyalVNCKit-backed implementation.
@MainActor
public protocol RemoteDesktopEngine: AnyObject {
    var delegate: RemoteDesktopEngineDelegate? { get set }

    var status: EngineStatus { get }
    var framebufferSize: CGSize? { get }
    var securityInfo: SessionSecurityInfo { get }

    func connect()
    func disconnect()

    /// Point in framebuffer pixel coordinates, origin top-left.
    func sendPointer(at point: CGPoint, buttons: PointerButtons)
    func sendScroll(_ direction: ScrollDirection, steps: Int, at point: CGPoint, buttons: PointerButtons)
    func sendKey(_ keysym: UInt32, isDown: Bool)
    func sendClipboardText(_ text: String)

    /// The live framebuffer surface for zero-copy display, when the engine provides one.
    var framebufferSurface: IOSurface? { get }

    /// A snapshot of the current remote framebuffer (not the local screen).
    func captureFramebuffer() -> CGImage?
}

@MainActor
public protocol RemoteDesktopEngineDelegate: AnyObject {
    func engine(_ engine: RemoteDesktopEngine, didChangeStatus status: EngineStatus)
    func engine(_ engine: RemoteDesktopEngine, needsCredentialsFor request: CredentialRequest) async -> SessionCredentials?
    func engine(_ engine: RemoteDesktopEngine, shouldTrustServerKey fingerprint: String) async -> Bool
    func engine(_ engine: RemoteDesktopEngine, didResizeFramebuffer size: CGSize)
    func engineDidUpdateFramebuffer(_ engine: RemoteDesktopEngine)
    func engine(_ engine: RemoteDesktopEngine, didUpdateCursor cursor: NSCursor)
    func engine(_ engine: RemoteDesktopEngine, didReceiveClipboardText text: String)
}

public enum EngineStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected(EngineError?)

    public var isActive: Bool {
        switch self {
            case .connecting, .connected: true
            default: false
        }
    }
}

public struct EngineError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Wrong credentials or the server refused the login; retrying with other credentials can help.
        case authenticationFailed
        /// The user cancelled the credential prompt or rejected the server identity.
        case cancelledByUser
        /// No security type both sides support (e.g. VeNCrypt-only server).
        case unsupportedSecurity
        /// Network-level failure: unreachable, refused, timed out, dropped.
        case network
        /// Protocol violation or decoding error.
        case protocolError
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// Errors after which an automatic reconnect makes sense.
    public var isTransient: Bool {
        kind == .network
    }
}

public struct CredentialRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case password
        case usernameAndPassword
    }

    public let kind: Kind
    /// Human-readable name of the negotiated method, e.g. "VNC Password" or "RSA-AES-256".
    public let methodName: String

    public init(kind: Kind, methodName: String) {
        self.kind = kind
        self.methodName = methodName
    }
}

public struct SessionCredentials: Sendable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public struct SessionSecurityInfo: Equatable, Sendable {
    public var negotiatedMethod: String?
    public var offeredMethods: [String]
    public var isEncrypted: Bool
    public var serverKeyFingerprint: String?
    public var desktopName: String?
    public var usesExtendedClipboard: Bool

    public init(negotiatedMethod: String? = nil,
                offeredMethods: [String] = [],
                isEncrypted: Bool = false,
                serverKeyFingerprint: String? = nil,
                desktopName: String? = nil,
                usesExtendedClipboard: Bool = false) {
        self.negotiatedMethod = negotiatedMethod
        self.offeredMethods = offeredMethods
        self.isEncrypted = isEncrypted
        self.serverKeyFingerprint = serverKeyFingerprint
        self.desktopName = desktopName
        self.usesExtendedClipboard = usesExtendedClipboard
    }
}

public struct PointerButtons: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let left = Self(rawValue: 1 << 0)
    public static let middle = Self(rawValue: 1 << 1)
    public static let right = Self(rawValue: 1 << 2)
}

public enum ScrollDirection: Sendable {
    case up, down, left, right
}

/// Everything an engine needs to open a session. Contains no secrets; credentials are requested lazily.
public struct ConnectionTarget: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var authenticationMethod: AuthenticationMethod
    public var colorDepth: ColorDepth
    public var isShared: Bool

    public init(host: String,
                port: Int,
                authenticationMethod: AuthenticationMethod,
                colorDepth: ColorDepth = .depth24,
                isShared: Bool = true) {
        self.host = host
        self.port = port
        self.authenticationMethod = authenticationMethod
        self.colorDepth = colorDepth
        self.isShared = isShared
    }
}
