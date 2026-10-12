// emvnc fork addition: public metadata about RFB security types so clients can explain negotiation results.

import Foundation

public enum VNCSecurityTypeInfo {
    public static let none: UInt8 = 1
    public static let vncAuthentication: UInt8 = 2
    public static let rsaAES: UInt8 = 5
    public static let rsaAESUnencrypted: UInt8 = 6
    public static let appleRemoteDesktop: UInt8 = 30
    public static let ultraVNCMSLogonII: UInt8 = 113
    public static let rsaAES256: UInt8 = 129
    public static let rsaAES256Unencrypted: UInt8 = 130

    /// Security types this library can complete a handshake for.
    public static let implemented: [UInt8] = [
        none, vncAuthentication, rsaAES, rsaAESUnencrypted, appleRemoteDesktop,
        ultraVNCMSLogonII, rsaAES256, rsaAES256Unencrypted
    ]

    /// Order used when the client does not restrict the security type.
    /// "None" stays first to match upstream behaviour (no credential prompt when the server allows it);
    /// encrypting types are preferred over the ones that only protect the credentials.
    public static let defaultPreference: [UInt8] = [
        none, rsaAES256, rsaAES, appleRemoteDesktop, ultraVNCMSLogonII,
        vncAuthentication, rsaAES256Unencrypted, rsaAESUnencrypted
    ]

    /// Whether the session traffic after authentication is encrypted.
    public static func encryptsSession(_ securityType: UInt8) -> Bool {
        securityType == rsaAES || securityType == rsaAES256
    }

    public static func name(of securityType: UInt8) -> String {
        switch securityType {
            case 0: "Invalid"
            case none: "None"
            case vncAuthentication: "VNC Password"
            case rsaAES: "RSA-AES"
            case rsaAESUnencrypted: "RSA-AES (handshake only)"
            case 13: "RSA-AES Two-step"
            case 16: "Tight"
            case 17: "Ultra"
            case 18: "TLS"
            case 19: "VeNCrypt"
            case 20: "SASL"
            case 22: "xvp"
            case appleRemoteDesktop: "Apple Remote Desktop"
            case 33, 35, 36: "Apple (\(securityType))"
            case ultraVNCMSLogonII: "UltraVNC MS-Logon II"
            case rsaAES256: "RSA-AES-256"
            case rsaAES256Unencrypted: "RSA-AES-256 (handshake only)"
            case 133: "RSA-AES-256 Two-step"
            default: "Type \(securityType)"
        }
    }
}
