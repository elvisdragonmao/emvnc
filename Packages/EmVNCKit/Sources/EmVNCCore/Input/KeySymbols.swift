import Foundation

/// X11 keysyms (as used by RFB KeyEvent messages) and the mapping from macOS virtual key codes.
public enum KeySymbols {
    // Editing and navigation
    public static let backSpace: UInt32 = 0xff08
    public static let tab: UInt32 = 0xff09
    public static let clear: UInt32 = 0xff0b
    public static let `return`: UInt32 = 0xff0d
    public static let pause: UInt32 = 0xff13
    public static let scrollLock: UInt32 = 0xff14
    public static let sysReq: UInt32 = 0xff15
    public static let escape: UInt32 = 0xff1b
    public static let delete: UInt32 = 0xffff
    public static let home: UInt32 = 0xff50
    public static let left: UInt32 = 0xff51
    public static let up: UInt32 = 0xff52
    public static let right: UInt32 = 0xff53
    public static let down: UInt32 = 0xff54
    public static let pageUp: UInt32 = 0xff55
    public static let pageDown: UInt32 = 0xff56
    public static let end: UInt32 = 0xff57
    public static let print: UInt32 = 0xff61
    public static let insert: UInt32 = 0xff63
    public static let menu: UInt32 = 0xff67
    public static let numLock: UInt32 = 0xff7f
    public static let hiraganaKatakana: UInt32 = 0xff27
    public static let eisuToggle: UInt32 = 0xff30

    // Keypad
    public static let kpEnter: UInt32 = 0xff8d
    public static let kpMultiply: UInt32 = 0xffaa
    public static let kpAdd: UInt32 = 0xffab
    public static let kpSubtract: UInt32 = 0xffad
    public static let kpDecimal: UInt32 = 0xffae
    public static let kpDivide: UInt32 = 0xffaf
    public static let kp0: UInt32 = 0xffb0
    public static let kpEqual: UInt32 = 0xffbd

    // Function keys F1 = 0xffbe ... F35
    public static func function(_ number: Int) -> UInt32 {
        precondition((1...35).contains(number))

        return 0xffbe + UInt32(number - 1)
    }

    // Modifiers
    public static let shiftL: UInt32 = 0xffe1
    public static let shiftR: UInt32 = 0xffe2
    public static let controlL: UInt32 = 0xffe3
    public static let controlR: UInt32 = 0xffe4
    public static let capsLock: UInt32 = 0xffe5
    public static let metaL: UInt32 = 0xffe7
    public static let metaR: UInt32 = 0xffe8
    public static let altL: UInt32 = 0xffe9
    public static let altR: UInt32 = 0xffea
    public static let superL: UInt32 = 0xffeb
    public static let superR: UInt32 = 0xffec

    public static let modifierKeysyms: Set<UInt32> = [
        shiftL, shiftR, controlL, controlR, metaL, metaR, altL, altR, superL, superR
    ]

    /// Keysym for a Unicode scalar: Latin-1 maps directly, everything else uses the 0x01000000 Unicode range.
    public static func keysym(for scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
            case 0x0a, 0x0d: return `return`
            case 0x09: return tab
            case 0x08, 0x7f: return backSpace
            case 0x1b: return escape
            case 0x20...0x7e, 0xa0...0xff: return scalar.value
            default: return 0x0100_0000 | scalar.value
        }
    }

    /// Keys identified by position rather than by the character they produce.
    public static let byKeyCode: [UInt16: UInt32] = [
        MacKeyCode.return: `return`,
        MacKeyCode.tab: tab,
        MacKeyCode.delete: backSpace,
        MacKeyCode.escape: escape,
        MacKeyCode.forwardDelete: delete,
        MacKeyCode.home: home,
        MacKeyCode.end: end,
        MacKeyCode.pageUp: pageUp,
        MacKeyCode.pageDown: pageDown,
        MacKeyCode.help: insert,
        MacKeyCode.leftArrow: left,
        MacKeyCode.rightArrow: right,
        MacKeyCode.downArrow: down,
        MacKeyCode.upArrow: up,
        MacKeyCode.contextualMenu: menu,
        MacKeyCode.jisEisu: eisuToggle,
        MacKeyCode.jisKana: hiraganaKatakana,

        MacKeyCode.f1: function(1), MacKeyCode.f2: function(2), MacKeyCode.f3: function(3),
        MacKeyCode.f4: function(4), MacKeyCode.f5: function(5), MacKeyCode.f6: function(6),
        MacKeyCode.f7: function(7), MacKeyCode.f8: function(8), MacKeyCode.f9: function(9),
        MacKeyCode.f10: function(10), MacKeyCode.f11: function(11), MacKeyCode.f12: function(12),
        MacKeyCode.f13: function(13), MacKeyCode.f14: function(14), MacKeyCode.f15: function(15),
        MacKeyCode.f16: function(16), MacKeyCode.f17: function(17), MacKeyCode.f18: function(18),
        MacKeyCode.f19: function(19), MacKeyCode.f20: function(20),

        MacKeyCode.keypad0: kp0, MacKeyCode.keypad1: kp0 + 1, MacKeyCode.keypad2: kp0 + 2,
        MacKeyCode.keypad3: kp0 + 3, MacKeyCode.keypad4: kp0 + 4, MacKeyCode.keypad5: kp0 + 5,
        MacKeyCode.keypad6: kp0 + 6, MacKeyCode.keypad7: kp0 + 7, MacKeyCode.keypad8: kp0 + 8,
        MacKeyCode.keypad9: kp0 + 9,
        MacKeyCode.keypadDecimal: kpDecimal,
        MacKeyCode.keypadMultiply: kpMultiply,
        MacKeyCode.keypadPlus: kpAdd,
        MacKeyCode.keypadMinus: kpSubtract,
        MacKeyCode.keypadDivide: kpDivide,
        MacKeyCode.keypadEnter: kpEnter,
        MacKeyCode.keypadEquals: kpEqual,
        MacKeyCode.keypadClear: clear
    ]
}

/// macOS virtual key codes (Carbon `kVK_*`), duplicated to avoid importing Carbon.
public enum MacKeyCode {
    public static let ansiA: UInt16 = 0x00
    public static let ansiC: UInt16 = 0x08
    public static let ansiV: UInt16 = 0x09
    public static let ansiX: UInt16 = 0x07
    public static let ansiQ: UInt16 = 0x0c
    public static let ansiW: UInt16 = 0x0d

    public static let `return`: UInt16 = 0x24
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let delete: UInt16 = 0x33
    public static let escape: UInt16 = 0x35
    public static let rightCommand: UInt16 = 0x36
    public static let command: UInt16 = 0x37
    public static let shift: UInt16 = 0x38
    public static let capsLock: UInt16 = 0x39
    public static let option: UInt16 = 0x3a
    public static let control: UInt16 = 0x3b
    public static let rightShift: UInt16 = 0x3c
    public static let rightOption: UInt16 = 0x3d
    public static let rightControl: UInt16 = 0x3e
    public static let function: UInt16 = 0x3f
    public static let f17: UInt16 = 0x40
    public static let keypadDecimal: UInt16 = 0x41
    public static let keypadMultiply: UInt16 = 0x43
    public static let keypadPlus: UInt16 = 0x45
    public static let keypadClear: UInt16 = 0x47
    public static let keypadDivide: UInt16 = 0x4b
    public static let keypadEnter: UInt16 = 0x4c
    public static let keypadMinus: UInt16 = 0x4e
    public static let f18: UInt16 = 0x4f
    public static let f19: UInt16 = 0x50
    public static let keypadEquals: UInt16 = 0x51
    public static let keypad0: UInt16 = 0x52
    public static let keypad1: UInt16 = 0x53
    public static let keypad2: UInt16 = 0x54
    public static let keypad3: UInt16 = 0x55
    public static let keypad4: UInt16 = 0x56
    public static let keypad5: UInt16 = 0x57
    public static let keypad6: UInt16 = 0x58
    public static let keypad7: UInt16 = 0x59
    public static let f20: UInt16 = 0x5a
    public static let keypad8: UInt16 = 0x5b
    public static let keypad9: UInt16 = 0x5c
    public static let f5: UInt16 = 0x60
    public static let f6: UInt16 = 0x61
    public static let f7: UInt16 = 0x62
    public static let f3: UInt16 = 0x63
    public static let f8: UInt16 = 0x64
    public static let f9: UInt16 = 0x65
    public static let jisEisu: UInt16 = 0x66
    public static let f11: UInt16 = 0x67
    public static let jisKana: UInt16 = 0x68
    public static let f13: UInt16 = 0x69
    public static let f16: UInt16 = 0x6a
    public static let f14: UInt16 = 0x6b
    public static let f10: UInt16 = 0x6d
    public static let contextualMenu: UInt16 = 0x6e
    public static let f12: UInt16 = 0x6f
    public static let f15: UInt16 = 0x71
    public static let help: UInt16 = 0x72
    public static let home: UInt16 = 0x73
    public static let pageUp: UInt16 = 0x74
    public static let forwardDelete: UInt16 = 0x75
    public static let f4: UInt16 = 0x76
    public static let end: UInt16 = 0x77
    public static let f2: UInt16 = 0x78
    public static let pageDown: UInt16 = 0x79
    public static let f1: UInt16 = 0x7a
    public static let leftArrow: UInt16 = 0x7b
    public static let rightArrow: UInt16 = 0x7c
    public static let downArrow: UInt16 = 0x7d
    public static let upArrow: UInt16 = 0x7e
}
