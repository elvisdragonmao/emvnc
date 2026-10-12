import Foundation

/// The modifier a Mac modifier key produces on the remote side.
public enum RemoteModifier: String, CaseIterable, Codable, Identifiable, Sendable {
    case control
    case alt
    /// Super / Windows key; Command on macOS servers.
    case superKey
    case meta

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
            case .control: "Control"
            case .alt: "Alt / Option"
            case .superKey: "Super / Windows / Command"
            case .meta: "Meta"
        }
    }

    public func keysym(isRight: Bool) -> UInt32 {
        switch self {
            case .control: isRight ? KeySymbols.controlR : KeySymbols.controlL
            case .alt: isRight ? KeySymbols.altR : KeySymbols.altL
            case .superKey: isRight ? KeySymbols.superR : KeySymbols.superL
            case .meta: isRight ? KeySymbols.metaR : KeySymbols.metaL
        }
    }
}

/// How the Mac's ⌘ ⌥ ⌃ keys are sent to the remote computer.
public struct KeyboardMapping: Codable, Equatable, Hashable, Sendable {
    public var command: RemoteModifier
    public var option: RemoteModifier
    public var control: RemoteModifier

    public init(command: RemoteModifier, option: RemoteModifier, control: RemoteModifier) {
        self.command = command
        self.option = option
        self.control = control
    }

    /// Mac servers: every key keeps its meaning. (RoyalVNCKit rewrites Super/Alt to the keysyms Apple's
    /// server expects when it detects Apple Remote Desktop.)
    public static let mac = KeyboardMapping(command: .superKey, option: .alt, control: .control)

    /// Windows/Linux with Mac habits: ⌘C/⌘V/⌘Z become Ctrl+C/V/Z. The Windows key is in the Keyboard menu.
    public static let pcWithMacShortcuts = KeyboardMapping(command: .control, option: .alt, control: .control)

    /// Windows/Linux with PC habits: ⌘ is the Windows/Super key, ⌃ is Ctrl.
    public static let pcStandard = KeyboardMapping(command: .superKey, option: .alt, control: .control)
}

/// User-facing keyboard presets per connection.
public enum KeyboardProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case mac
    case pcWithMacShortcuts
    case pcStandard
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
            case .mac: "Mac"
            case .pcWithMacShortcuts: "Windows / Linux (Mac shortcuts)"
            case .pcStandard: "Windows / Linux (PC keys)"
            case .custom: "Custom"
        }
    }

    public var detail: String {
        switch self {
            case .mac: "⌘ → Command, ⌥ → Option, ⌃ → Control"
            case .pcWithMacShortcuts: "⌘ → Ctrl, ⌥ → Alt, ⌃ → Ctrl (⌘C copies, ⌘V pastes)"
            case .pcStandard: "⌘ → Windows/Super, ⌥ → Alt, ⌃ → Ctrl"
            case .custom: "Choose what ⌘ ⌥ ⌃ send"
        }
    }

    /// The fixed mapping of a preset; `nil` for `.custom`.
    public var presetMapping: KeyboardMapping? {
        switch self {
            case .mac: .mac
            case .pcWithMacShortcuts: .pcWithMacShortcuts
            case .pcStandard: .pcStandard
            case .custom: nil
        }
    }
}

/// Key combinations that macOS or the viewer would otherwise intercept, sendable from the Keyboard menu.
public struct SpecialKeyCombination: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Pressed in order, released in reverse order.
    public let keysyms: [UInt32]

    public init(id: String, title: String, keysyms: [UInt32]) {
        self.id = id
        self.title = title
        self.keysyms = keysyms
    }

    public static let ctrlAltDelete = Self(id: "ctrl-alt-del", title: "Ctrl-Alt-Delete",
                                           keysyms: [ KeySymbols.controlL, KeySymbols.altL, KeySymbols.delete ])
    public static let windowsKey = Self(id: "super", title: "Windows / Super Key",
                                        keysyms: [ KeySymbols.superL ])
    public static let altTab = Self(id: "alt-tab", title: "Alt-Tab",
                                    keysyms: [ KeySymbols.altL, KeySymbols.tab ])
    public static let altF4 = Self(id: "alt-f4", title: "Alt-F4",
                                   keysyms: [ KeySymbols.altL, KeySymbols.function(4) ])
    public static let ctrlEscape = Self(id: "ctrl-esc", title: "Ctrl-Esc",
                                        keysyms: [ KeySymbols.controlL, KeySymbols.escape ])
    public static let printScreen = Self(id: "print", title: "Print Screen",
                                         keysyms: [ KeySymbols.print ])
    public static let commandTab = Self(id: "cmd-tab", title: "⌘Tab",
                                        keysyms: [ KeySymbols.superL, KeySymbols.tab ])
    public static let commandSpace = Self(id: "cmd-space", title: "⌘Space",
                                          keysyms: [ KeySymbols.superL, 0x20 ])
    public static let commandOptionEscape = Self(id: "cmd-opt-esc", title: "⌘⌥Esc (Force Quit)",
                                                 keysyms: [ KeySymbols.superL, KeySymbols.altL, KeySymbols.escape ])
    public static let controlAltF1 = Self(id: "ctrl-alt-f1", title: "Ctrl-Alt-F1",
                                          keysyms: [ KeySymbols.controlL, KeySymbols.altL, KeySymbols.function(1) ])
    public static let controlAltF7 = Self(id: "ctrl-alt-f7", title: "Ctrl-Alt-F7",
                                          keysyms: [ KeySymbols.controlL, KeySymbols.altL, KeySymbols.function(7) ])

    public static let pcCombinations: [Self] = [
        .ctrlAltDelete, .windowsKey, .altTab, .altF4, .ctrlEscape, .printScreen, .controlAltF1, .controlAltF7
    ]

    public static let macCombinations: [Self] = [
        .commandTab, .commandSpace, .commandOptionEscape
    ]
}
