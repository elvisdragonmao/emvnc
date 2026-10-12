#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(ObjectiveC)
@objc(VNCAuthenticationType)
#endif
public enum VNCAuthenticationType: Int {
	case vnc
	case appleRemoteDesktop
	case ultraVNCMSLogonII

	// emvnc fork additions: RSA-AES (RFB security types 5, 6, 129, 130). The server picks the subtype.
	case rsaAESUsernamePassword
	case rsaAESPassword
}

public extension VNCAuthenticationType {
	var requiresUsername: Bool {
		switch self {
			case .vnc:
				false
			case .appleRemoteDesktop:
				true
			case .ultraVNCMSLogonII:
				true
			case .rsaAESUsernamePassword:
				true
			case .rsaAESPassword:
				false
		}
	}

	var requiresPassword: Bool {
		switch self {
			case .vnc:
				true
			case .appleRemoteDesktop:
				true
			case .ultraVNCMSLogonII:
				true
			case .rsaAESUsernamePassword:
				true
			case .rsaAESPassword:
				true
		}
	}
}

#if canImport(ObjectiveC)
@objc(VNCAuthenticationTypeUtils)
// swiftlint:disable:next type_name
public final class _ObjC_VNCAuthenticationTypeUtils: NSObject {
    @objc
	public static func authenticationTypeRequiresUsername(_ authenticationType: VNCAuthenticationType) -> Bool {
		authenticationType.requiresUsername
	}

    @objc
	public static func authenticationTypeRequiresPassword(_ authenticationType: VNCAuthenticationType) -> Bool {
		authenticationType.requiresPassword
	}
}
#endif
