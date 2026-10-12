// emvnc fork addition: APIs a full client needs that upstream does not expose — negotiated security
// metadata, server identity verification, and clipboard text in both directions without the built-in
// NSPasteboard polling (which would push one Mac clipboard to every open session).

import Foundation

public protocol VNCConnectionExtendedDelegate: AnyObject {
    /// Clipboard text received from the server (standard or Extended Clipboard). Line endings are LF.
    /// Called on a background queue.
    func connection(_ connection: VNCConnection,
                    didReceiveClipboardText text: String)

    /// Called during RSA-AES handshakes with the SHA-256 fingerprint of the server's public key.
    /// Call `completion(false)` to abort the connection. Called on a background queue.
    func connection(_ connection: VNCConnection,
                    shouldTrustServerKeyWithFingerprint fingerprint: String,
                    completion: @escaping (Bool) -> Void)
}

public extension VNCConnection {
    /// Security types the server offered during the handshake (raw RFB values).
    var offeredSecurityTypes: [UInt8] {
        state.offeredSecurityTypes
    }

    /// The security type the client selected, once negotiated.
    var negotiatedSecurityType: UInt8? {
        state.negotiatedSecurityType
    }

    /// Whether all traffic of this session is encrypted (RSA-AES / RSA-AES-256).
    var isSessionEncrypted: Bool {
        connection.isEncrypted
    }

    /// SHA-256 fingerprint of the server's RSA key, if an RSA-AES handshake took place.
    var serverKeyFingerprint: String? {
        state.serverKeyFingerprint
    }

    var desktopName: String? {
        state.desktopName
    }

    /// Whether the server confirmed support for the Extended Clipboard pseudo-encoding (UTF-8 clipboard).
    var isExtendedClipboardActive: Bool {
        state.clipboard.withLock { $0.serverCapabilities != nil }
    }

    /// Sends clipboard text to the server. Uses the Extended Clipboard (UTF-8) when the server supports it,
    /// otherwise a standard ClientCutText message.
    func sendClipboardText(_ text: String) {
        let action = state.clipboard.withLock { clipboard -> ClipboardSendAction in
            clipboard.localText = text

            guard let capabilities = clipboard.serverCapabilities else {
                return .legacy
            }

            let size = VNCProtocol.ExtendedClipboard.encodedTextSize(text)

            if capabilities.actions.contains(.provide),
               capabilities.formats.contains(.text),
               size <= capabilities.maximumTextSize {
                return .provide
            }

            if capabilities.actions.contains(.notify) {
                return .notify
            }

            return .legacy
        }

        switch action {
            case .legacy:
                enqueueClientToServerMessage(VNCProtocol.ClientCutText(text: text))
            case .provide:
                enqueueClientToServerMessage(VNCProtocol.ExtendedClipboard.provide(text: text))
            case .notify:
                enqueueClientToServerMessage(VNCProtocol.ExtendedClipboard.notify(hasText: true))
        }
    }
}

enum ClipboardSendAction {
    case legacy
    case provide
    case notify
}

/// Protected Extended Clipboard state shared by the receive loop and API callers.
struct ExtendedClipboardState {
    struct ServerCapabilities {
        let formats: VNCProtocol.ExtendedClipboard.Format
        let actions: VNCProtocol.ExtendedClipboard.Action
        let maximumTextSize: Int
    }

    var serverCapabilities: ServerCapabilities?
    var localText: String?
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }

        return try body(&value)
    }
}
