import Foundation

/// The authentication method a connection asks for. Each case maps to the RFB security types the client is
/// willing to negotiate; the server decides among those it offers.
public enum AuthenticationMethod: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Let the server choose among every method emvnc implements.
    case automatic
    case none
    case vncPassword
    case appleRemoteDesktop
    /// RSA-AES / RSA-AES-256 (TigerVNC, RealVNC "RA2", wayvnc). The server decides whether a username is needed.
    case rsaAES
    case ultraVNCMSLogonII

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
            case .automatic: "Automatic"
            case .none: "No Authentication"
            case .vncPassword: "VNC Password"
            case .appleRemoteDesktop: "Apple Remote Desktop"
            case .rsaAES: "RSA-AES (Encrypted)"
            case .ultraVNCMSLogonII: "UltraVNC MS-Logon II"
        }
    }

    public var detail: String {
        switch self {
            case .automatic:
                "Uses the first method the server offers. You will be asked for credentials when needed."
            case .none:
                "Connects without credentials. Only works when the server allows it."
            case .vncPassword:
                "Classic VNC authentication. Requires a password only; the session is not encrypted."
            case .appleRemoteDesktop:
                "macOS Screen Sharing user account. Credentials are encrypted; the session is not."
            case .rsaAES:
                "Encrypts credentials and the whole session. The server decides whether a username is required."
            case .ultraVNCMSLogonII:
                "Windows account login for UltraVNC servers. Credentials are encrypted; the session is not."
        }
    }

    /// Raw RFB security types, in preference order. `nil` means "any implemented type".
    public var securityTypes: [UInt8]? {
        switch self {
            case .automatic: nil
            case .none: [ 1 ]
            case .vncPassword: [ 2 ]
            case .appleRemoteDesktop: [ 30 ]
            case .rsaAES: [ 129, 5, 130, 6 ]
            case .ultraVNCMSLogonII: [ 113 ]
        }
    }

    public var usesUsername: Bool {
        switch self {
            case .automatic, .appleRemoteDesktop, .rsaAES, .ultraVNCMSLogonII: true
            case .none, .vncPassword: false
        }
    }

    public var requiresUsername: Bool {
        switch self {
            case .appleRemoteDesktop, .ultraVNCMSLogonII: true
            default: false
        }
    }

    public var usesPassword: Bool {
        self != .none
    }
}

public enum ColorDepth: Int, CaseIterable, Codable, Identifiable, Sendable {
    case depth24 = 24
    case depth16 = 16
    case depth8 = 8

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
            case .depth24: "Millions of Colors (24-bit)"
            case .depth16: "Thousands of Colors (16-bit)"
            case .depth8: "256 Colors (8-bit)"
        }
    }
}

/// Parses user input such as `host`, `host:5901`, `192.168.1.2`, `::1`, `[fe80::1]:5900`.
public enum HostAddress {
    public static let defaultPort = 5900

    public struct Parsed: Equatable, Sendable {
        public let host: String
        public let port: Int?
    }

    public static func parse(_ input: String) -> Parsed? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else {
            return nil
        }

        // Bracketed IPv6, optionally with a port
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }

            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]

            guard !host.isEmpty else { return nil }

            if rest.isEmpty {
                return .init(host: host, port: nil)
            }

            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), isValidPort(port) else {
                return nil
            }

            return .init(host: host, port: port)
        }

        let colonCount = trimmed.filter { $0 == ":" }.count

        // A bare IPv6 literal has several colons and cannot carry a port without brackets
        if colonCount > 1 {
            return .init(host: trimmed, port: nil)
        }

        if colonCount == 1 {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)

            guard parts.count == 2, !parts[0].isEmpty,
                  let port = Int(parts[1]), isValidPort(port) else {
                return nil
            }

            return .init(host: String(parts[0]), port: port)
        }

        return .init(host: trimmed, port: nil)
    }

    public static func isValidPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }

    /// Formats a host for display, bracketing IPv6 literals when a port follows.
    public static func display(host: String, port: Int) -> String {
        let bracketed = host.contains(":") ? "[\(host)]" : host

        return port == defaultPort ? bracketed : "\(bracketed):\(port)"
    }
}
