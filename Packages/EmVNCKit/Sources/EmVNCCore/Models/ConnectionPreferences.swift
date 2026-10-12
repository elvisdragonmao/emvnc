import Foundation

public enum ScalingMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Scale the remote screen to fit the window, keeping its aspect ratio.
    case fit
    /// One remote pixel per point; scroll when the window is smaller.
    case actualSize

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
            case .fit: "Fit to Window"
            case .actualSize: "Actual Size"
        }
    }
}

/// Per-connection behaviour. Stored as JSON in `SavedConnection.preferencesData` so new options can be added
/// without a SwiftData migration; unknown or missing keys fall back to defaults.
public struct ConnectionPreferences: Codable, Equatable, Sendable {
    public var scalingMode: ScalingMode = .fit
    public var colorDepth: ColorDepth = .depth24
    public var isShared: Bool = true

    public var keyboardProfile: KeyboardProfile = .mac
    public var customKeyboardMapping: KeyboardMapping = .mac
    /// Send ⌘-shortcuts (⌘Q, ⌘H, …) to the remote computer instead of handling them locally.
    public var shortcutPassthrough: Bool = false

    public var clipboardSync: Bool = true

    public var autoScreenshot: Bool = true
    public var refreshScreenshotOnDisconnect: Bool = true
    public var keepScreenshotHistory: Bool = true

    public var autoReconnect: Bool = false
    public var maxReconnectAttempts: Int = 5

    public init() {}

    public var keyboardMapping: KeyboardMapping {
        keyboardProfile.presetMapping ?? customKeyboardMapping
    }

    public static let `default` = ConnectionPreferences()

    // Decode leniently so preferences written by older or newer versions still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ConnectionPreferences.default

        scalingMode = (try? container.decode(ScalingMode.self, forKey: .scalingMode)) ?? defaults.scalingMode
        colorDepth = (try? container.decode(ColorDepth.self, forKey: .colorDepth)) ?? defaults.colorDepth
        isShared = (try? container.decode(Bool.self, forKey: .isShared)) ?? defaults.isShared
        keyboardProfile = (try? container.decode(KeyboardProfile.self, forKey: .keyboardProfile)) ?? defaults.keyboardProfile
        customKeyboardMapping = (try? container.decode(KeyboardMapping.self, forKey: .customKeyboardMapping)) ?? defaults.customKeyboardMapping
        shortcutPassthrough = (try? container.decode(Bool.self, forKey: .shortcutPassthrough)) ?? defaults.shortcutPassthrough
        clipboardSync = (try? container.decode(Bool.self, forKey: .clipboardSync)) ?? defaults.clipboardSync
        autoScreenshot = (try? container.decode(Bool.self, forKey: .autoScreenshot)) ?? defaults.autoScreenshot
        refreshScreenshotOnDisconnect = (try? container.decode(Bool.self, forKey: .refreshScreenshotOnDisconnect)) ?? defaults.refreshScreenshotOnDisconnect
        keepScreenshotHistory = (try? container.decode(Bool.self, forKey: .keepScreenshotHistory)) ?? defaults.keepScreenshotHistory
        autoReconnect = (try? container.decode(Bool.self, forKey: .autoReconnect)) ?? defaults.autoReconnect
        maxReconnectAttempts = (try? container.decode(Int.self, forKey: .maxReconnectAttempts)) ?? defaults.maxReconnectAttempts
    }

    private enum CodingKeys: String, CodingKey {
        case scalingMode, colorDepth, isShared, keyboardProfile, customKeyboardMapping, shortcutPassthrough
        case clipboardSync, autoScreenshot, refreshScreenshotOnDisconnect, keepScreenshotHistory
        case autoReconnect, maxReconnectAttempts
    }
}
