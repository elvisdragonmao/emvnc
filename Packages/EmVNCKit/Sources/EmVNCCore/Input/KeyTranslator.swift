import Foundation

public struct KeyAction: Equatable, Sendable, CustomStringConvertible {
    public let keysym: UInt32
    public let isDown: Bool

    public init(keysym: UInt32, isDown: Bool) {
        self.keysym = keysym
        self.isDown = isDown
    }

    public static func down(_ keysym: UInt32) -> Self { .init(keysym: keysym, isDown: true) }
    public static func up(_ keysym: UInt32) -> Self { .init(keysym: keysym, isDown: false) }

    public var description: String {
        "\(isDown ? "↓" : "↑")0x\(String(keysym, radix: 16))"
    }
}

/// A key event, decoupled from `NSEvent` so translation can be unit tested.
public struct KeyInput: Sendable {
    public var keyCode: UInt16
    /// `NSEvent.charactersIgnoringModifiers` (Shift is still applied).
    public var charactersIgnoringModifiers: String?

    public init(keyCode: UInt16, charactersIgnoringModifiers: String?) {
        self.keyCode = keyCode
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
    }
}

/// Device-dependent modifier bits of `NSEvent.modifierFlags.rawValue` (IOKit `NX_DEVICE*KEYMASK`).
public enum DeviceModifierMask {
    public static let leftControl: UInt = 0x0000_0001
    public static let leftShift: UInt = 0x0000_0002
    public static let rightShift: UInt = 0x0000_0004
    public static let leftCommand: UInt = 0x0000_0008
    public static let rightCommand: UInt = 0x0000_0010
    public static let leftOption: UInt = 0x0000_0020
    public static let rightOption: UInt = 0x0000_0040
    public static let rightControl: UInt = 0x0000_2000

    // Device-independent flags (NSEvent.ModifierFlags)
    public static let shift: UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option: UInt = 1 << 19
    public static let command: UInt = 1 << 20
}

/// Translates Mac key events into RFB key events according to a `KeyboardMapping`, keeping track of what is
/// pressed on the remote side so every press gets a matching release.
///
/// ⌘, ⌥ and ⌃ are sent lazily: their press is held back until another key, a click, or their own release.
/// That way a shortcut the viewer handles locally (e.g. ⌘Q or ⌥⌘S) never leaks a stray modifier tap to the
/// remote — a lone Windows-key tap would open the Start menu, a lone Alt tap focuses menu bars.
/// Shift is sent immediately; it never triggers anything on its own.
public struct KeyTranslator: Sendable {
    public var mapping: KeyboardMapping

    /// Non-modifier keys currently down: key code → keysym sent on press (reused on release).
    private var pressedKeys: [UInt16: UInt32] = [:]
    /// Remote modifier keysym → physical key codes holding it (⌘ and ⌃ can both map to Control).
    private var modifierHolders: [UInt32: Set<UInt16>] = [:]
    /// Modifier keys pressed but not yet sent, in press order.
    private var pendingModifiers: [(keyCode: UInt16, keysym: UInt32)] = []

    public init(mapping: KeyboardMapping) {
        self.mapping = mapping
    }

    public var hasPressedKeys: Bool {
        !pressedKeys.isEmpty || !modifierHolders.isEmpty || !pendingModifiers.isEmpty
    }

    /// Keysyms currently held down on the remote side.
    public var remotePressedKeysyms: Set<UInt32> {
        Set(pressedKeys.values).union(modifierHolders.keys)
    }

    // MARK: Modifiers
    public mutating func modifierChanged(keyCode: UInt16, modifierFlags: UInt) -> [KeyAction] {
        if keyCode == MacKeyCode.capsLock {
            // macOS reports Caps Lock as a toggle; toggle the remote state the same way.
            return [ .down(KeySymbols.capsLock), .up(KeySymbols.capsLock) ]
        }

        guard let modifier = Self.modifiers[keyCode] else {
            return []
        }

        let hasDeviceBits = modifierFlags & Self.allDeviceBits != 0
        let isDown = hasDeviceBits
            ? modifierFlags & modifier.deviceMask != 0
            : modifierFlags & modifier.genericMask != 0

        let keysym = keysym(for: modifier)

        if modifier.role != .shift {
            if isDown {
                if !isHolding(keyCode), !pendingModifiers.contains(where: { $0.keyCode == keyCode }) {
                    pendingModifiers.append((keyCode, keysym))
                }

                return []
            }

            if let index = pendingModifiers.firstIndex(where: { $0.keyCode == keyCode }) {
                // Tapped on its own: deliver the tap now
                let pending = pendingModifiers.remove(at: index)

                return press(pending.keysym, holder: keyCode) + release(holder: keyCode)
            }

            return release(holder: keyCode)
        }

        return isDown ? press(keysym, holder: keyCode) : release(holder: keyCode)
    }

    /// Sends modifier presses that were held back. Call before forwarding keys, clicks and scrolls.
    public mutating func flushPendingModifiers() -> [KeyAction] {
        let pending = pendingModifiers
        pendingModifiers.removeAll()

        return pending.flatMap { press($0.keysym, holder: $0.keyCode) }
    }

    /// Drops held-back modifier presses because the shortcut was handled locally.
    public mutating func discardPendingModifiers() {
        pendingModifiers.removeAll()
    }

    // MARK: Keys
    public mutating func keyDown(_ input: KeyInput) -> [KeyAction] {
        var actions = flushPendingModifiers()

        let keysym = pressedKeys[input.keyCode] ?? Self.keysym(for: input)

        guard let keysym else {
            return actions
        }

        pressedKeys[input.keyCode] = keysym
        actions.append(.down(keysym))

        return actions
    }

    public mutating func keyUp(_ input: KeyInput) -> [KeyAction] {
        guard let keysym = pressedKeys.removeValue(forKey: input.keyCode) else {
            // Never sent a press for this key (e.g. it went down before the view had focus)
            return []
        }

        return [ .up(keysym) ]
    }

    /// AppKit delivers no key-up for keys pressed while ⌘ is held, so ⌘-combinations are sent as a full tap.
    public mutating func keyEquivalent(_ input: KeyInput) -> [KeyAction] {
        var actions = keyDown(input)

        if let keysym = pressedKeys.removeValue(forKey: input.keyCode) {
            actions.append(.up(keysym))
        }

        return actions
    }

    /// Releases everything held on the remote side, e.g. when the window loses focus or the session ends.
    public mutating func releaseAll() -> [KeyAction] {
        var actions = pressedKeys.sorted { $0.key < $1.key }.map { KeyAction.up($0.value) }
        actions += modifierHolders.keys.sorted().map { KeyAction.up($0) }

        pressedKeys.removeAll()
        modifierHolders.removeAll()
        pendingModifiers.removeAll()

        return actions
    }

    /// Presses a combination in order and releases it in reverse order, without disturbing keys the user holds.
    public func combination(_ keysyms: [UInt32]) -> [KeyAction] {
        let held = remotePressedKeysyms
        let toPress = keysyms.filter { !held.contains($0) }

        return toPress.map { .down($0) } + toPress.reversed().map { .up($0) }
    }

    // MARK: Helpers
    public static func keysym(for input: KeyInput) -> UInt32? {
        if let keysym = KeySymbols.byKeyCode[input.keyCode] {
            return keysym
        }

        guard let scalar = input.charactersIgnoringModifiers?.unicodeScalars.first else {
            return nil
        }

        // AppKit's private-use function key characters (U+F700–U+F8FF) are not real text
        if (0xf700...0xf8ff).contains(scalar.value) {
            return nil
        }

        return KeySymbols.keysym(for: scalar)
    }

    private func isHolding(_ keyCode: UInt16) -> Bool {
        modifierHolders.values.contains { $0.contains(keyCode) }
    }

    private mutating func press(_ keysym: UInt32, holder: UInt16) -> [KeyAction] {
        var holders = modifierHolders[keysym, default: []]
        let wasReleased = holders.isEmpty

        holders.insert(holder)
        modifierHolders[keysym] = holders

        return wasReleased ? [ .down(keysym) ] : []
    }

    private mutating func release(holder: UInt16) -> [KeyAction] {
        guard let (keysym, holders) = modifierHolders.first(where: { $0.value.contains(holder) }) else {
            return []
        }

        var remaining = holders
        remaining.remove(holder)

        if remaining.isEmpty {
            modifierHolders.removeValue(forKey: keysym)

            return [ .up(keysym) ]
        }

        modifierHolders[keysym] = remaining

        return []
    }

    private func keysym(for modifier: Modifier) -> UInt32 {
        switch modifier.role {
            case .shift: modifier.isRight ? KeySymbols.shiftR : KeySymbols.shiftL
            case .command: mapping.command.keysym(isRight: modifier.isRight)
            case .option: mapping.option.keysym(isRight: modifier.isRight)
            case .control: mapping.control.keysym(isRight: modifier.isRight)
        }
    }

    private struct Modifier: Sendable {
        enum Role: Sendable { case shift, control, option, command }

        let role: Role
        let isRight: Bool
        let deviceMask: UInt
        let genericMask: UInt
    }

    private static let modifiers: [UInt16: Modifier] = [
        MacKeyCode.shift: .init(role: .shift, isRight: false, deviceMask: DeviceModifierMask.leftShift, genericMask: DeviceModifierMask.shift),
        MacKeyCode.rightShift: .init(role: .shift, isRight: true, deviceMask: DeviceModifierMask.rightShift, genericMask: DeviceModifierMask.shift),
        MacKeyCode.control: .init(role: .control, isRight: false, deviceMask: DeviceModifierMask.leftControl, genericMask: DeviceModifierMask.control),
        MacKeyCode.rightControl: .init(role: .control, isRight: true, deviceMask: DeviceModifierMask.rightControl, genericMask: DeviceModifierMask.control),
        MacKeyCode.option: .init(role: .option, isRight: false, deviceMask: DeviceModifierMask.leftOption, genericMask: DeviceModifierMask.option),
        MacKeyCode.rightOption: .init(role: .option, isRight: true, deviceMask: DeviceModifierMask.rightOption, genericMask: DeviceModifierMask.option),
        MacKeyCode.command: .init(role: .command, isRight: false, deviceMask: DeviceModifierMask.leftCommand, genericMask: DeviceModifierMask.command),
        MacKeyCode.rightCommand: .init(role: .command, isRight: true, deviceMask: DeviceModifierMask.rightCommand, genericMask: DeviceModifierMask.command)
    ]

    private static let allDeviceBits: UInt = DeviceModifierMask.leftControl | DeviceModifierMask.leftShift
        | DeviceModifierMask.rightShift | DeviceModifierMask.leftCommand | DeviceModifierMask.rightCommand
        | DeviceModifierMask.leftOption | DeviceModifierMask.rightOption | DeviceModifierMask.rightControl
}

/// Decides whether a ⌘-key combination is handled by the viewer or sent to the remote computer.
public enum ShortcutRouter {
    public enum Route: Equatable, Sendable {
        /// Try the app's menus first; forward to the remote computer if no menu item handles it.
        case localFirst
        case remote
    }

    /// ⌘-shortcuts that stay with macOS by default (quit, hide, minimize, cycle windows, settings).
    public static let localCommandKeys: Set<String> = [ "q", "h", "m", "`", "," ]

    public static func route(charactersIgnoringModifiers: String?,
                             modifierFlags: UInt,
                             passthrough: Bool) -> Route {
        let command = modifierFlags & DeviceModifierMask.command != 0
        let option = modifierFlags & DeviceModifierMask.option != 0
        let control = modifierFlags & DeviceModifierMask.control != 0

        guard command else {
            return .remote
        }

        // ⌃⌥⌘ chords are reserved for the viewer, even in pass-through mode
        if option && control {
            return .localFirst
        }

        if passthrough {
            return .remote
        }

        // ⌥⌘ / ⌃⌘ chords are the viewer's own commands (full screen, scaling, screenshot, …)
        if option || control {
            return .localFirst
        }

        let key = (charactersIgnoringModifiers ?? "").lowercased()

        return localCommandKeys.contains(key) ? .localFirst : .remote
    }
}
