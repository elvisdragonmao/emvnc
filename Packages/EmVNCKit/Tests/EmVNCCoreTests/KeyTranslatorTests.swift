import Testing
@testable import EmVNCCore

private let commandDown = DeviceModifierMask.command | DeviceModifierMask.leftCommand
private let optionDown = DeviceModifierMask.option | DeviceModifierMask.leftOption
private let controlDown = DeviceModifierMask.control | DeviceModifierMask.leftControl
private let shiftDown = DeviceModifierMask.shift | DeviceModifierMask.leftShift

private func key(_ code: UInt16, _ chars: String?) -> KeyInput {
    KeyInput(keyCode: code, charactersIgnoringModifiers: chars)
}

@Suite("Key translation")
struct KeyTranslatorTests {
    @Test func plainCharactersUseTheirKeysym() {
        var translator = KeyTranslator(mapping: .mac)

        let r1 = translator.keyDown(key(MacKeyCode.ansiA, "a"))
        #expect(r1 == [ .down(0x61) ])
        let r2 = translator.keyUp(key(MacKeyCode.ansiA, "a"))
        #expect(r2 == [ .up(0x61) ])
    }

    @Test func specialKeysMapByKeyCode() {
        #expect(KeyTranslator.keysym(for: key(MacKeyCode.escape, "\u{1b}")) == KeySymbols.escape)
        #expect(KeyTranslator.keysym(for: key(MacKeyCode.delete, "\u{7f}")) == KeySymbols.backSpace)
        #expect(KeyTranslator.keysym(for: key(MacKeyCode.forwardDelete, nil)) == KeySymbols.delete)
        #expect(KeyTranslator.keysym(for: key(MacKeyCode.return, "\r")) == KeySymbols.return)
        #expect(KeyTranslator.keysym(for: key(MacKeyCode.tab, "\t")) == KeySymbols.tab)
        #expect(KeyTranslator.keysym(for: key(MacKeyCode.leftArrow, "\u{f702}")) == KeySymbols.left)
        #expect(KeyTranslator.keysym(for: key(MacKeyCode.f1, "\u{f704}")) == 0xffbe)
        #expect(KeyTranslator.keysym(for: key(MacKeyCode.f12, "\u{f70f}")) == 0xffc9)
        #expect(KeyTranslator.keysym(for: key(MacKeyCode.keypad5, "5")) == 0xffb5)
    }

    @Test func unknownPrivateUseFunctionCharactersAreIgnored() {
        #expect(KeyTranslator.keysym(for: key(0x99, "\u{f739}")) == nil)
    }

    @Test func unicodeCharactersUseUnicodeKeysyms() {
        #expect(KeySymbols.keysym(for: "é") == 0xe9)
        #expect(KeySymbols.keysym(for: "€") == 0x0100_20ac)
        #expect(KeySymbols.keysym(for: "中") == 0x0100_4e2d)
    }

    @Test func keyReleaseUsesTheKeysymSentOnPress() {
        var translator = KeyTranslator(mapping: .mac)

        // Shift+A pressed, Shift released first, then A: the release must still be "A"
        let r3 = translator.modifierChanged(keyCode: MacKeyCode.shift, modifierFlags: shiftDown)
        #expect(r3 == [ .down(KeySymbols.shiftL) ])
        let r4 = translator.keyDown(key(MacKeyCode.ansiA, "A"))
        #expect(r4 == [ .down(0x41) ])
        let r5 = translator.modifierChanged(keyCode: MacKeyCode.shift, modifierFlags: 0)
        #expect(r5 == [ .up(KeySymbols.shiftL) ])
        let r6 = translator.keyUp(key(MacKeyCode.ansiA, "a"))
        #expect(r6 == [ .up(0x41) ])
    }

    @Test(arguments: [
        (KeyboardMapping.mac, KeySymbols.superL),
        (KeyboardMapping.pcWithMacShortcuts, KeySymbols.controlL),
        (KeyboardMapping.pcStandard, KeySymbols.superL)
    ])
    func commandCMapsPerProfile(mapping: KeyboardMapping, expectedModifier: UInt32) {
        var translator = KeyTranslator(mapping: mapping)
        var actions = translator.modifierChanged(keyCode: MacKeyCode.command, modifierFlags: commandDown)

        // ⌘ is held back until the next key
        #expect(actions.isEmpty)

        actions += translator.keyEquivalent(key(MacKeyCode.ansiC, "c"))
        actions += translator.modifierChanged(keyCode: MacKeyCode.command, modifierFlags: 0)

        #expect(actions == [ .down(expectedModifier), .down(0x63), .up(0x63), .up(expectedModifier) ])
    }

    @Test func optionAndControlMapToAltAndControl() {
        var translator = KeyTranslator(mapping: .pcWithMacShortcuts)
        var actions = translator.modifierChanged(keyCode: MacKeyCode.option, modifierFlags: optionDown)
        actions += translator.keyDown(key(MacKeyCode.leftArrow, nil))
        actions += translator.keyUp(key(MacKeyCode.leftArrow, nil))
        actions += translator.modifierChanged(keyCode: MacKeyCode.option, modifierFlags: 0)

        #expect(actions == [ .down(KeySymbols.altL), .down(KeySymbols.left), .up(KeySymbols.left), .up(KeySymbols.altL) ])
    }

    @Test func rightModifiersUseRightKeysyms() {
        var translator = KeyTranslator(mapping: .mac)
        let flags = DeviceModifierMask.option | DeviceModifierMask.rightOption
        var actions = translator.modifierChanged(keyCode: MacKeyCode.rightOption, modifierFlags: flags)
        actions += translator.modifierChanged(keyCode: MacKeyCode.rightOption, modifierFlags: 0)

        #expect(actions == [ .down(KeySymbols.altR), .up(KeySymbols.altR) ])
    }

    @Test func locallyHandledShortcutLeaksNoModifier() {
        var translator = KeyTranslator(mapping: .pcStandard)
        var actions = translator.modifierChanged(keyCode: MacKeyCode.option, modifierFlags: optionDown)
        actions += translator.modifierChanged(keyCode: MacKeyCode.command, modifierFlags: optionDown | commandDown)

        // The viewer handles ⌥⌘S itself
        translator.discardPendingModifiers()

        actions += translator.modifierChanged(keyCode: MacKeyCode.command, modifierFlags: optionDown)
        actions += translator.modifierChanged(keyCode: MacKeyCode.option, modifierFlags: 0)

        #expect(actions.isEmpty)
        #expect(!translator.hasPressedKeys)
    }

    @Test func loneModifierTapIsDelivered() {
        var translator = KeyTranslator(mapping: .pcStandard)
        var actions = translator.modifierChanged(keyCode: MacKeyCode.command, modifierFlags: commandDown)
        actions += translator.modifierChanged(keyCode: MacKeyCode.command, modifierFlags: 0)

        // A Windows-key tap opens the Start menu, as on a PC
        #expect(actions == [ .down(KeySymbols.superL), .up(KeySymbols.superL) ])
    }

    @Test func pendingModifiersFlushInPressOrderBeforeClicks() {
        var translator = KeyTranslator(mapping: .mac)
        _ = translator.modifierChanged(keyCode: MacKeyCode.control, modifierFlags: controlDown)
        _ = translator.modifierChanged(keyCode: MacKeyCode.command, modifierFlags: controlDown | commandDown)

        let r7 = translator.flushPendingModifiers()
        #expect(r7 == [ .down(KeySymbols.controlL), .down(KeySymbols.superL) ])
        let r8 = translator.flushPendingModifiers()
        #expect(r8.isEmpty)
    }

    @Test func twoMacKeysMappedToTheSameRemoteModifierAreReferenceCounted() {
        var translator = KeyTranslator(mapping: .pcWithMacShortcuts)
        var actions = translator.modifierChanged(keyCode: MacKeyCode.command, modifierFlags: commandDown)
        actions += translator.modifierChanged(keyCode: MacKeyCode.control, modifierFlags: commandDown | controlDown)
        actions += translator.flushPendingModifiers()

        #expect(actions == [ .down(KeySymbols.controlL) ])

        // Releasing ⌘ keeps Control down because ⌃ still holds it
        let r9 = translator.modifierChanged(keyCode: MacKeyCode.command, modifierFlags: controlDown)
        #expect(r9.isEmpty)
        let r10 = translator.modifierChanged(keyCode: MacKeyCode.control, modifierFlags: 0)
        #expect(r10 == [ .up(KeySymbols.controlL) ])
    }

    @Test func releaseAllReleasesEverythingHeld() {
        var translator = KeyTranslator(mapping: .mac)
        _ = translator.modifierChanged(keyCode: MacKeyCode.shift, modifierFlags: shiftDown)
        _ = translator.modifierChanged(keyCode: MacKeyCode.control, modifierFlags: shiftDown | controlDown)
        _ = translator.keyDown(key(MacKeyCode.ansiA, "A"))

        let actions = translator.releaseAll()

        #expect(Set(actions.map(\.keysym)) == [ 0x41, KeySymbols.shiftL, KeySymbols.controlL ])
        #expect(actions.allSatisfy { !$0.isDown })
        #expect(!translator.hasPressedKeys)
        let r11 = translator.releaseAll()
        #expect(r11.isEmpty)
    }

    @Test func capsLockTogglesRemoteCapsLock() {
        var translator = KeyTranslator(mapping: .mac)

        #expect(translator.modifierChanged(keyCode: MacKeyCode.capsLock, modifierFlags: 1 << 16)
                == [ .down(KeySymbols.capsLock), .up(KeySymbols.capsLock) ])
    }

    @Test func combinationSkipsKeysTheUserAlreadyHolds() {
        var translator = KeyTranslator(mapping: .mac)
        _ = translator.modifierChanged(keyCode: MacKeyCode.shift, modifierFlags: shiftDown)

        let ctrlAltDel = translator.combination(SpecialKeyCombination.ctrlAltDelete.keysyms)

        #expect(ctrlAltDel == [ .down(KeySymbols.controlL), .down(KeySymbols.altL), .down(KeySymbols.delete),
                                .up(KeySymbols.delete), .up(KeySymbols.altL), .up(KeySymbols.controlL) ])
        let r12 = translator.combination([ KeySymbols.shiftL, 0x61 ])
        #expect(r12 == [ .down(0x61), .up(0x61) ])
    }

    @Test func keyUpWithoutPressIsIgnored() {
        var translator = KeyTranslator(mapping: .mac)

        let r13 = translator.keyUp(key(MacKeyCode.ansiA, "a"))
        #expect(r13.isEmpty)
    }

    @Test func customProfileUsesCustomMapping() {
        var preferences = ConnectionPreferences()
        preferences.keyboardProfile = .custom
        preferences.customKeyboardMapping = KeyboardMapping(command: .meta, option: .superKey, control: .alt)

        #expect(preferences.keyboardMapping.command.keysym(isRight: false) == KeySymbols.metaL)
        #expect(preferences.keyboardMapping.option.keysym(isRight: true) == KeySymbols.superR)

        preferences.keyboardProfile = .pcWithMacShortcuts
        #expect(preferences.keyboardMapping == .pcWithMacShortcuts)
    }
}

@Suite("Shortcut routing")
struct ShortcutRouterTests {
    @Test func commandShortcutsGoRemoteByDefault() {
        for character in [ "c", "v", "x", "z", "a", "w", "t", "f" ] {
            #expect(ShortcutRouter.route(charactersIgnoringModifiers: character, modifierFlags: commandDown, passthrough: false) == .remote)
        }
    }

    @Test func macSystemShortcutsStayLocal() {
        for character in [ "q", "h", "m", ",", "`" ] {
            #expect(ShortcutRouter.route(charactersIgnoringModifiers: character, modifierFlags: commandDown, passthrough: false) == .localFirst)
        }
    }

    @Test func viewerChordsAreLocalFirst() {
        #expect(ShortcutRouter.route(charactersIgnoringModifiers: "s", modifierFlags: commandDown | optionDown, passthrough: false) == .localFirst)
        #expect(ShortcutRouter.route(charactersIgnoringModifiers: "f", modifierFlags: commandDown | controlDown, passthrough: false) == .localFirst)
    }

    @Test func passthroughSendsEverythingExceptTheEscapeChord() {
        #expect(ShortcutRouter.route(charactersIgnoringModifiers: "q", modifierFlags: commandDown, passthrough: true) == .remote)
        #expect(ShortcutRouter.route(charactersIgnoringModifiers: "s", modifierFlags: commandDown | optionDown, passthrough: true) == .remote)
        #expect(ShortcutRouter.route(charactersIgnoringModifiers: "k", modifierFlags: commandDown | optionDown | controlDown, passthrough: true) == .localFirst)
    }

    @Test func nonCommandKeysGoRemote() {
        #expect(ShortcutRouter.route(charactersIgnoringModifiers: "c", modifierFlags: controlDown, passthrough: false) == .remote)
    }
}

@Suite("Scrolling")
struct ScrollAccumulatorTests {
    @Test func preciseDeltasAccumulateIntoSteps() {
        var accumulator = ScrollAccumulator()

        let r14 = accumulator.steps(deltaX: 0, deltaY: 5, isPrecise: true)
        #expect(r14.isEmpty)
        let steps = accumulator.steps(deltaX: 0, deltaY: 20, isPrecise: true)

        #expect(steps.count == 1)
        #expect(steps.first?.0 == .up)
        #expect(steps.first?.1 == 2)
    }

    @Test func wheelDeltasMapDirectly() {
        var accumulator = ScrollAccumulator()
        let steps = accumulator.steps(deltaX: 0, deltaY: -3, isPrecise: false)

        #expect(steps.first?.0 == .down)
        #expect(steps.first?.1 == 3)
    }

    @Test func horizontalScrolling() {
        var accumulator = ScrollAccumulator()

        let r15 = accumulator.steps(deltaX: 1, deltaY: 0, isPrecise: false)
        #expect(r15.first?.0 == .left)
        let r16 = accumulator.steps(deltaX: -1, deltaY: 0, isPrecise: false)
        #expect(r16.first?.0 == .right)
    }
}
